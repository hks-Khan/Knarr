import Foundation
import Darwin
import Testing
@testable import KnarrCore

private let rpcFixture = #"""
import sys,json,os,subprocess,signal,time
mode=sys.argv[1]
def emit(v):
 sys.stdout.write(json.dumps(v,separators=(',',':'))+'\n');sys.stdout.flush()
def response(r,data=None):
 return dict(type='response',id=r['id'],command=r['type'],success=True,data=data or {})
if mode in ('child','detached-child'):
 child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(120)'],start_new_session=(mode=='detached-child'),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,stdin=subprocess.DEVNULL)
 open(sys.argv[2],'w').write(str(child.pid))
if mode=='no-ready': time.sleep(120)
emit(dict(type='ready',protocolVersion=1,supportedProtocolVersions=[1] if mode=='v1' else [1,2],maxFrameBytes=1048576,maxReassembledFrameBytes=67108864))
held=[];final=None;question=None
for line in sys.stdin:
 r=json.loads(line);t=r['type']
 if t=='negotiate_protocol':
  emit(response(r,dict(protocolVersion=1 if mode=='bad-v2' else 2)))
  if mode=='backpressure':
   open('blocked','w').write('yes')
   while not os.path.exists('resume'): time.sleep(.01)
 elif t=='echo':
  held.append(r)
  if len(held)==2:
   for x in reversed(held): emit(response(x,dict(value=x['value'])))
 elif t=='ask_test': question=r;emit(dict(type='host_tool_call',id='human-1',toolCallId='tool-1',toolName='ask_user',arguments={}))
 elif t=='host_tool_result':
  if r['id']=='human-1': emit(response(question,dict(answered=True)))
 elif t=='final': final=r;emit(dict(type='final_pending'))
 elif t=='crash':
  emit(response(r,dict(last=True)));sys.exit(7)
 elif t=='malformed': sys.stdout.write('bad-json\n');sys.stdout.flush();time.sleep(120)
 elif t=='remote_error': emit(dict(type='response',id=r['id'],command=t,success=False,error='SECRET https://login.invalid/token'))
 elif t=='hold': pass
 elif t=='wrong_command': emit(dict(type='response',id=r['id'],command='other',success=True))
 else: emit(response(r,dict(sessionId='fixture',isStreaming=False)))
if final: emit(response(final,dict(last=True)))
if mode in ('child','detached-child'): time.sleep(120)
"""#

struct RPCFixture {
    let directory: URL
    let configuration: OMPLaunchConfiguration
    init(mode: String = "normal") throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = base.appendingPathComponent("docs/evidence/omp-issue-1/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fixture.py")
        try rpcFixture.write(to: script, atomically: true, encoding: .utf8)
        configuration = OMPLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            workingDirectory: directory, arguments: [script.path, mode, directory.appendingPathComponent("child.pid").path],
            environment: ProcessInfo.processInfo.environment, handshakeTimeout: .seconds(2))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) struct OMPRPCSessionTests {
    @Test func concurrentResponsesMatchIDsAndHumanWaitDoesNotBlockReceiver() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            let events = await session.subscribe()
            async let first = session.request("echo", fields: ["value": .string("first")])
            async let second = session.request("echo", fields: ["value": .string("second")])
            let (a,b) = try await (first,second)
            #expect(a["data"]?["value"]?.string == "first")
            #expect(b["data"]?["value"]?.string == "second")
            let waiting = Task { try await session.request("ask_test") }
            for await event in events {
                if case .frame(let frame) = event, frame["type"]?.string == "host_tool_call" { break }
            }
            #expect(try await session.request("get_state")["data"]?["sessionId"]?.string == "fixture")
            try await session.send("host_tool_result", fields: ["id": .string("human-1"), "result": .object(["content": .array([]), "details": .object([:])])])
            #expect(try await waiting.value["data"]?["answered"]?.bool == true)
            let exit = await session.shutdown()
            #expect(exit.status == 0)
            #expect(exit.remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test func finalResponseBeforeEOFAndExitStatusAreBothDelivered() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            let events = await session.subscribe()
            let final = Task { try await session.request("final") }
            for await event in events {
                if case .frame(let frame) = event, frame["type"]?.string == "final_pending" { break }
            }
            let exit = await session.shutdown()
            #expect(try await final.value["data"]?["last"]?.bool == true)
            #expect(exit.status == 0)
            #expect(exit.remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test func nonzeroExitStillDrainsLastResponse() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            #expect(try await session.request("crash")["data"]?["last"]?.bool == true)
            let exit = await session.waitForExit()
            #expect(exit.status == 7)
            #expect(exit.reason == .failed)
            #expect(exit.remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test(arguments: 0..<5) func cancellationReapsOwnedChildAndKeepsIndependentProcess(iteration: Int) async throws {
        let independent = Process()
        independent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        independent.arguments = ["120"]
        try independent.run()
        let independentPID = independent.processIdentifier
        var birth = proc_bsdinfo()
        #expect(proc_pidinfo(independentPID, PROC_PIDTBSDINFO, 0, &birth, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0)
        print("independent fixture pid=\(independentPID) start=\(birth.pbi_start_tvsec).\(birth.pbi_start_tvusec) command=/bin/sleep 120")
        defer {
            // Foundation's cached termination state can wait forever after the child
            // has already disappeared. Reclaim only this birth identity, with a bound.
            for signal in [SIGTERM, SIGKILL] {
                var current = proc_bsdinfo()
                guard proc_pidinfo(independentPID, PROC_PIDTBSDINFO, 0, &current, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                      current.pbi_start_tvsec == birth.pbi_start_tvsec,
                      current.pbi_start_tvusec == birth.pbi_start_tvusec else { break }
                _ = kill(independentPID, signal)
                for _ in 0..<100 { if kill(independentPID, 0) == -1 { break }; usleep(10_000) }
            }
            #expect(kill(independentPID, 0) == -1)
            print("independent fixture cleanup pid=\(independentPID) remaining=\(kill(independentPID, 0) == 0 ? 1 : 0)")
        }
        let fixture = try RPCFixture(mode: "child"); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            let pid = try #require(Int32(String(contentsOf: fixture.directory.appendingPathComponent("child.pid"), encoding: .utf8)))
            #expect(kill(pid, 0) == 0)
            print("fixture cancellation iteration=\(iteration) root=\(await session.processID ?? -1) child=\(pid) independent=\(independent.processIdentifier)")
            let exit = await session.shutdown(cancel: true)
            #expect(exit.reason == .cancelled)
            #expect(exit.remainingProcessIDs.isEmpty)
            var info = proc_bsdinfo()
            let infoBytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            print("fixture child after exit pid=\(pid) kill0=\(kill(pid, 0)) pgid=\(getpgid(pid)) status=\(info.pbi_status) infoBytes=\(infoBytes) remaining=\(exit.remainingProcessIDs) independent_alive=\(independent.isRunning)")
            #expect(kill(pid, 0) == -1)
            #expect(kill(independentPID, 0) == 0)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }


    @Test func cancellationReapsDetachedOwnedDescendant() async throws {
        let fixture = try RPCFixture(mode: "detached-child"); defer { fixture.remove() }
        let session = OMPRPCSession()
        var child: Int32?
        // Independent RED-stage recovery: this fixture explicitly creates a new group.
        defer {
            if let child, getpgid(child) == child {
                _ = kill(child, SIGKILL)
                for _ in 0..<100 { if kill(child, 0) == -1 { break }; usleep(10_000) }
            }
        }
        do {
            try await session.start(fixture.configuration)
            child = Int32(try String(contentsOf: fixture.directory.appendingPathComponent("child.pid"), encoding: .utf8))
            let pid = try #require(child)
            print("fixture detached root=\(await session.processID ?? -1) child=\(pid)")
            let exit = await session.shutdown(cancel: true)
            #expect(kill(pid, 0) == -1)
            #expect(exit.remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test(arguments: ["v1", "bad-v2", "no-ready"])
    func startupFailureReapsProcess(mode: String) async throws {
        let fixture = try RPCFixture(mode: mode); defer { fixture.remove() }
        let session = OMPRPCSession()
        await #expect(throws: OMPRPCError.self) { try await session.start(fixture.configuration) }
        let exit = await session.waitForExit()
        #expect(exit.remainingProcessIDs.isEmpty)
    }

    @Test func malformedFrameFailsPendingRequestAndReapsProcess() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            await #expect(throws: OMPRPCError.self) { try await session.request("malformed") }
            #expect(await session.waitForExit().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test func remoteErrorDescriptionDoesNotIncludePayloadSecrets() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            await #expect(throws: OMPRPCError.remoteFailure) { try await session.request("remote_error") }
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }
    @Test func mismatchedResponseCommandFailsSession() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            await #expect(throws: OMPRPCError.responseMismatch) { try await session.request("wrong_command") }
            #expect(await session.waitForExit().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test func timedOutRequestDoesNotStopOtherRequests() async throws {
        let fixture = try RPCFixture(); defer { fixture.remove() }
        let session = OMPRPCSession()
        do {
            try await session.start(fixture.configuration)
            await #expect(throws: OMPRPCError.timedOut) { try await session.request("hold", timeout: .milliseconds(50)) }
            #expect(try await session.request("get_state")["success"]?.bool == true)
            #expect(await session.shutdown().remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test func taskCancellationDuringStartupReapsProcess() async throws {
        let fixture = try RPCFixture(mode: "no-ready"); defer { fixture.remove() }
        let session = OMPRPCSession()
        let startup = Task { try await session.start(fixture.configuration) }
        let deadline = ContinuousClock.now + .seconds(1)
        while await session.processID == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        startup.cancel()
        await #expect(throws: OMPRPCError.cancelled) { try await startup.value }
        #expect(await session.waitForExit().remainingProcessIDs.isEmpty)
    }

    @Test func concurrentSessionCannotInheritAnotherSessionsInputPipe() async throws {
        let firstFixture = try RPCFixture(mode: "backpressure"); defer { firstFixture.remove() }
        let secondFixture = try RPCFixture(); defer { secondFixture.remove() }
        let first = OMPRPCSession(), second = OMPRPCSession()
        do {
            try await first.start(firstFixture.configuration)
            let write = Task { try await first.request("large", fields: ["text": .string(String(repeating: "a", count: 900_000))]) }
            // Peer is explicitly not reading stdin, so a large write remains in flight.
            try await Task.sleep(for: .milliseconds(100))
            try await second.start(secondFixture.configuration)
            try "yes".write(to: firstFixture.directory.appendingPathComponent("resume"), atomically: true, encoding: .utf8)
            #expect(try await write.value["success"]?.bool == true)
            let firstExit = await first.shutdown()
            #expect(firstExit.status == 0)
            #expect(firstExit.reason == .normal)
            #expect(firstExit.remainingProcessIDs.isEmpty)
            #expect(try await second.request("get_state")["success"]?.bool == true)
            #expect(await second.shutdown().remainingProcessIDs.isEmpty)
        } catch {
            _ = await first.shutdown(cancel: true)
            _ = await second.shutdown(cancel: true)
            throw error
        }
    }

}
