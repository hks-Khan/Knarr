import Foundation
import Testing
@testable import KnarrCore

private actor FixtureSessionReader: SessionReading {
    var requests: [OMPJSON] = []
    func query(_ request: OMPJSON) async throws -> OMPJSON {
        requests.append(request)
        return .object(["sessions": .array([.object(["provider": .string("codex"), "id": .string("fixture"), "title": .string("이전 대화")])])])
    }
}
@Suite(.serialized) struct SessionAPITests {
    @Test func hostSessionReadUsesReaderWithoutCreatingWorkOrPrompting() async throws {
        let f = try await StallariFixture.make()
        let reader = FixtureSessionReader()
        let session = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird, sessionReader: reader)
        do {
            try await session.connect()
            await f.rpc.emit(.frame(.object([
                "type": .string("host_tool_call"), "id": .string("history-call"), "toolName": .string("list_sessions"),
                "arguments": .object(["provider": .string("codex"), "limit": .number(5)])
            ])))
            let deadline = ContinuousClock.now + .seconds(2)
            while await f.rpc.sent.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(await reader.requests.first?["operation"]?.string == "list")
            #expect(await f.rpc.sent.first?["result"]?["details"]?["sessions"]?.array?.count == 1)
            #expect(await f.rpc.prompts.isEmpty)
            #expect(await f.hird.runs.isEmpty)
            #expect(try await f.repository.snapshot().issues.isEmpty)
            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }
    @Test func bridgeResultWaitsForOwnedProcessExit() async throws {
        let f = try await StallariFixture.make()
        let script = f.directory.appendingPathComponent("response.py")
        try "import sys,json\nr=json.loads(sys.stdin.readline())\nprint(json.dumps({'ok':True,'result':{'provider':r['provider'],'messages':[]}}))\n".write(to: script, atomically: true, encoding: .utf8)
        let process = SessionAPIProcess()
        do {
            let result = try await process.run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: f.directory, arguments: [script.path]), request: .object(["provider": .string("codex")]))
            #expect(result["provider"]?.string == "codex")
            #expect(await process.exit?.remainingProcessIDs == [])
            #expect(await process.exit?.status == 0)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func timeoutAndCancellationReclaimOwnedChild() async throws {
        for cancel in [false,true] {
            let f = try await StallariFixture.make()
            let script = f.directory.appendingPathComponent("slow.py")
            let marker = f.directory.appendingPathComponent("child.pid")
            try "import subprocess,time,pathlib,sys\np=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\npathlib.Path(sys.argv[1]).write_text(str(p.pid))\ntime.sleep(60)\n".write(to: script, atomically: true, encoding: .utf8)
            let process = SessionAPIProcess()
            let task = Task { try await process.run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: f.directory, arguments: [script.path, marker.path]), request: .object([:]), timeout: .seconds(cancel ? 10 : 1)) }
            do {
                if cancel {
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !FileManager.default.fileExists(atPath: marker.path) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    task.cancel()
                }
                do { _ = try await task.value; Testing.Issue.record("slow bridge unexpectedly succeeded") }
                catch let error as SessionAPIError { #expect(error == (cancel ? .cancelled : .timedOut)) }
                #expect(await process.exit?.remainingProcessIDs == [])
                print("session-api \(cancel ? "cancel" : "timeout") owned_remaining=0")
                try await f.cleanup()
            } catch { task.cancel(); _ = try? await task.value; try await f.cleanup(); throw error }
        }
    }
    @Test func malformedOutputIsReportedAfterCleanup() async throws {
        let f = try await StallariFixture.make()
        let process = SessionAPIProcess()
        do {
            await #expect(throws: SessionAPIError.failed("invalid_response")) {
                try await process.run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: f.directory, arguments: ["-c", "input(); print('not json')"]), request: .object([:]))
            }
            #expect(await process.exit?.remainingProcessIDs == [])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_TEST_SESSION_APIS"] == "1"))
    func installedProvidersListAndReadActualLocalSession() async throws {
        let reader = LocalSessionAPI()
        for provider in ["codex", "claude"] {
            let page = try await reader.query(.object(["provider": .string(provider), "operation": .string("list"), "limit": .number(3)]))
            let first = try #require(page["sessions"]?.array?.first)
            let id = try #require(first["id"]?.string)
            let history = try await reader.query(.object(["provider": .string(provider), "operation": .string("read"), "sessionID": .string(id), "limit": .number(10)]))
            #expect(history["session"]?["id"]?.string == id)
            #expect(history["messages"]?.array != nil)
            print("LIVE session-api provider=\(provider) listed=\(page["sessions"]?.array?.count ?? 0) read_messages=\(history["messages"]?.array?.count ?? 0) next_page=\(history["nextCursor"]?.string != nil)")
        }
    }
}
