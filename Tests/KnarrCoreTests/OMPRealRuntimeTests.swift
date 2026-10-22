import Foundation
import Darwin
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct OMPRealRuntimeTests {
    @Test func readyV2StateAndOwnedCleanupWithIndependentOMP() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let install = try OMPInstallation(executable: URL(fileURLWithPath: executable))
        let fixture = try RPCFixture(); defer { fixture.remove() }
        var environment = ProcessInfo.processInfo.environment
        // This no-model transport probe writes only official OMP state in the task workspace.
        // It neither copies an old auth store nor invokes login or a paid provider.
        environment["PI_CODING_AGENT_DIR"] = fixture.directory.appendingPathComponent("official-agent").path
        // Node path.join(home, relative) resolves here, keeping cache/log roots in this workspace too.
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + fixture.directory.path.dropFirst()
        environment.removeValue(forKey: "OMP_PROFILE"); environment.removeValue(forKey: "PI_PROFILE")
        let arguments = ["--mode", "rpc", "--no-session", "--no-tools", "--no-lsp", "--no-pty",
            "--no-extensions", "--no-skills", "--no-rules", "--no-title"]
        let independent = try TestChildProcess(.init(installation: install, workingDirectory: fixture.directory,
            arguments: arguments, environment: environment))
        defer { independent.signal(SIGKILL) }
        print("OMP independent pid=\(independent.id)")
        for mode in ["normal", "cancel", "failure"] {
            let session = OMPRPCSession()
            let config = OMPLaunchConfiguration(installation: install, workingDirectory: fixture.directory,
                arguments: mode == "failure" ? ["--mode", "invalid-knarr-test"] : arguments, environment: environment)
            do {
                if mode == "failure" {
                    await #expect(throws: OMPRPCError.self) { try await session.start(config) }
                } else {
                    try await session.start(config)
                    #expect(await session.readyFrame?["type"]?.string == "ready")
                    #expect(await session.negotiatedVersion == 2)
                    let state = try await session.request("get_state")
                    #expect(state["success"]?.bool == true)
                    #expect(state["data"]?["sessionId"]?.string?.isEmpty == false)
                    #expect(state["data"]?["todoPhases"]?.array != nil)
                    let subscription = try await session.request("set_subagent_subscription", fields: ["level": .string("progress")])
                    #expect(subscription["success"]?.bool == true)
                    let hostTools = try await session.request("set_host_tools", fields: ["tools": .array([.object([
                        "name": .string("knarr_transport_probe"), "description": .string("Transport registration probe"),
                        "loadMode": .string("essential"), "parameters": .object(["type": .string("object"), "properties": .object([:])])
                    ])])])
                    #expect(hostTools["data"]?["toolNames"]?.array?.contains(.string("knarr_transport_probe")) == true)
                    print("OMP mode=\(mode) pid=\(await session.processID ?? -1) ready=true protocol=2 get_state=true subscription=progress")
                    let childFile = fixture.directory.appendingPathComponent("real-child-\(mode).pid")
                    let probe = try await session.request("bash", fields: ["command": .string("printf knarr-omp-probe")], timeout: .seconds(5))
                    print("OMP bash probe exit=\(probe["data"]?["exitCode"]?.integer ?? -1) expected_output=\(probe["data"]?["output"]?.string == "knarr-omp-probe")")
                    let childCode = "import os,time;open('real-child-" + mode + ".pid','w').write(str(os.getpid()));time.sleep(120)"
                    let childScript = fixture.directory.appendingPathComponent("real-child.py")
                    try childCode.write(to: childScript, atomically: true, encoding: .utf8)
                    let childTask = Task { try await session.request("bash", fields: ["command": .string("/usr/bin/python3 '" + childScript.path + "'")], timeout: .seconds(30)) }
                    let deadline = ContinuousClock.now + .seconds(5)
                    var childPID: Int32?
                    while childPID == nil && ContinuousClock.now < deadline {
                        if let text = try? String(contentsOf: childFile, encoding: .utf8) { childPID = Int32(text) }
                        if childPID == nil { try await Task.sleep(for: .milliseconds(20)) }
                    }
                    if childPID == nil {
                        let response = try await childTask.value
                        let output = response["data"]?["output"]?.string ?? "no output"
                        let diagnostic = String(output.prefix(800)).replacingOccurrences(of: #"https?://[^\s]+"#, with: "[URL omitted]", options: .regularExpression)
                        print("Known fixture command exit=\(response["data"]?["exitCode"]?.integer ?? -1) diagnostic=\(diagnostic)")
                    }
                    let child = try #require(childPID)
                    // Independent cleanup remains available if the runtime assertion fails.
                    defer {
                        if kill(child, 0) == 0 {
                            var info = proc_bsdinfo()
                            let bytes = proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                            if bytes == MemoryLayout<proc_bsdinfo>.size && info.pbi_start_tvsec >= UInt64(Date().timeIntervalSince1970) - 60 {
                                _ = kill(child, SIGKILL)
                            }
                        }
                    }
                    print("OMP mode=\(mode) bash_child=\(child) group=\(getpgid(child))")
                    if mode == "normal" {
                        #expect(try await session.request("abort_bash")["success"]?.bool == true)
                        _ = try await childTask.value
                    }
                    let exit = await session.shutdown(cancel: mode == "cancel")
                    _ = await childTask.result
                    if mode == "normal" { #expect(exit.status == 0); #expect(exit.reason == .normal) }
                    #expect(kill(child, 0) == -1)
                    #expect(exit.remainingProcessIDs.isEmpty)
                    print("OMP mode=\(mode) bash_child_remaining=\(kill(child, 0) == -1 ? 0 : 1)")
                }
                let pid = await session.processID
                let exit = await session.shutdown(cancel: mode == "cancel")
                #expect(exit.remainingProcessIDs.isEmpty)
                if let pid { #expect(kill(pid, 0) == -1) }
                #expect(independent.isRunning)
                print("OMP mode=\(mode) exit=\(exit.status) reason=\(exit.reason) owned_remaining=\(exit.remainingProcessIDs.count) independent_alive=\(independent.isRunning)")
            } catch {
                _ = await session.shutdown(cancel: true)
                try await independent.cleanup()
                throw error
            }
        }
        independent.closeInput()
        do { #expect(try await independent.waitForExit() == 0) }
        catch { try await independent.cleanup(); throw error }
        #expect(kill(independent.id, 0) == -1)
        print("OMP independent cleanup remaining=0")
    }
}
