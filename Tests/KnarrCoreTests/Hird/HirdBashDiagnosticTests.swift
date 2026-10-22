import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_HIRD_DIAG"] == "1"))
struct HirdBashDiagnosticTests {
    @Test func inspectPinnedShellAgainstExplicitSystemPython() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let f = try await HirdFixture.make()
        do {
            for command in ["printf knarr-diagnostic", "python3 -c 'print(42)'", "/usr/bin/python3 -c 'print(42)'"] {
                let rpc = OMPRPCSession()
                var environment = ProcessInfo.processInfo.environment
                environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
                do {
                    try await rpc.start(.init(installation: OMPInstallation(executable: URL(fileURLWithPath: executable)), workingDirectory: f.directory,
                        arguments: ["--mode", "rpc", "--no-session", "--no-tools", "--no-lsp", "--no-pty", "--no-title", "--no-extensions", "--no-skills", "--no-rules"], environment: environment))
                    let response = try await rpc.request("bash", fields: ["command": .string(command)], timeout: .seconds(10))
                    print("Hird shell diagnostic command=\(command) code=\(response["data"]?["exitCode"]?.integer ?? -1) output=\(response["data"]?["output"]?.string ?? "missing")")
                } catch { print("Hird shell diagnostic command=\(command) rpc_error=\(String(describing: error))") }
                _ = try? await rpc.request("abort_bash", timeout: .seconds(2))
                let exit = await rpc.shutdown(cancel: true)
                #expect(exit.remainingProcessIDs.isEmpty)
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
