import Foundation
import Darwin
import Testing
@testable import KnarrCore

private let hiveSyntheticKey = "knarr-hive-synthetic-credential-only"

@Suite(.serialized) struct HiveProviderRuntimeTests {
    @Test func legacyProjectDefaultUses1017WithoutChangingOtherSettings() throws {
        let original = ProjectSettings(memo: "preserved", maxHirds: 3,
            hirdModel: "hive/deepseek-ai/deepseek-v4.1-flash", hirdThinking: "high")
        let decoded = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded.hirdModel == "hive/deepseek-ai/deepseek-v4.1-flash-1017")
        #expect(decoded.memo == original.memo && decoded.maxHirds == original.maxHirds)
        #expect(decoded.hirdThinking == original.hirdThinking)
        for model in [nil, "openai-codex/gpt-6.1-sol", "hive/deepseek-ai/deepseek-v4.1-flash-1017"] as [String?] {
            let settings = ProjectSettings(hirdModel: model)
            #expect(try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/hive-recovery/provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func oldProposalModelRemainsHistoricalWhileNewSelectionUses1017() throws {
        let old = "hive/deepseek-ai/deepseek-v4.1-flash"
        let proposal = IssueProposal(instruction: "preserved", model: old)
        let decoded = try JSONDecoder().decode(IssueProposal.self, from: JSONEncoder().encode(proposal))
        #expect(decoded.model == old)
        #expect(HiveProviderRuntime.currentModelIdentifier(old) == HiveProviderRuntime.modelIdentifier)
        #expect(HiveProviderRuntime.currentModelIdentifier("openai-codex/fixture-model") == "openai-codex/fixture-model")
    }

    @Test func missingCredentialDoesNotAddProviderOrChangeLaunchPolicy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = OMPLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: root,
            arguments: ["--mode", "rpc-ui", "--thinking", "high"], environment: ["FIXTURE": "preserved"])
        let configured = try HiveProviderRuntime().configure(original)
        #expect(configured.arguments == original.arguments)
        #expect(configured.environment == original.environment)
        #expect(configured.hiveCredential == nil)
    }

    @Test func validationRejectsEmptyControlsAndOversizeWithoutReplacingPreparedCredential() throws {
        let runtime = HiveProviderRuntime()
        #expect(!runtime.isPrepared)
        try runtime.replaceCredential(hiveSyntheticKey)
        for invalid in ["", " ", "a\nb", "a\rb", "a\0b", "a\u{7f}b", "a\u{85}b", String(repeating: "x", count: 4096), String(repeating: "가", count: 1366)] {
            #expect(throws: (any Error).self) { try runtime.replaceCredential(invalid) }
            #expect(runtime.isPrepared)
        }
        try runtime.replaceCredential(String(repeating: "x", count: 4095))
        try runtime.replaceCredential(nil)
        #expect(!runtime.isPrepared)
        #expect(HiveProviderRuntime.modelIdentifier == "hive/deepseek-ai/deepseek-v4.1-flash-1017")
    }

    @Test func snapshotsAreRedactedAndNeverWrittenToProviderSourceArgumentsOrEnvironment() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HiveProviderRuntime()
        try runtime.replaceCredential(hiveSyntheticKey)
        let configuration = try runtime.configure(.init(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: root, environment: [:]))
        #expect(configuration.hiveCredential != nil)
        #expect(!String(reflecting: configuration).contains(hiveSyntheticKey))
        #expect(!String(reflecting: runtime).contains(hiveSyntheticKey))
        #expect(!configuration.arguments.joined().contains(hiveSyntheticKey))
        #expect(!configuration.environment.values.joined().contains(hiveSyntheticKey))
        let index = try #require(configuration.arguments.firstIndex(of: "--trusted-extension"))
        let source = try String(contentsOfFile: configuration.arguments[index + 1], encoding: .utf8)
        #expect(!source.contains(hiveSyntheticKey))
        try runtime.replaceCredential(nil)
        #expect(configuration.hiveCredential != nil)
        #expect(try runtime.configure(.init(executable: URL(fileURLWithPath: "/usr/bin/true"), workingDirectory: root)).hiveCredential == nil)
    }

    @Test(arguments: [hiveSyntheticKey, String(repeating: "x", count: 4095)])
    func actualSubprocessReceivesOneShotPipeButNeverCredentialInArgsEnvironmentOrChild(key: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.py")
        try #"""
import os,sys,json,subprocess
fd=198
secret=os.read(fd,4096)
eof=os.read(fd,1)==b''
os.close(fd)
# Child checks the dedicated descriptor is gone before any tool executes.
child=subprocess.run([sys.executable,'-c','import os;\ntry: os.fstat(198); print("open")\nexcept OSError: print("closed")'],capture_output=True,text=True,close_fds=False)
report=dict(received=bool(secret),bounded=0<len(secret)<4096,eof=eof,closed=child.stdout.strip()=='closed',argvSafe=secret.decode() not in repr(sys.argv),envSafe=secret.decode() not in repr(dict(os.environ)))
# Only booleans enter the public RPC stream; never echo the synthetic credential.
def emit(v): print(json.dumps(v),flush=True)
emit(dict(type='ready',protocolVersion=1,supportedProtocolVersions=[1,2],maxFrameBytes=1048576,maxReassembledFrameBytes=67108864))
for line in sys.stdin:
 r=json.loads(line)
 emit(dict(type='response',id=r['id'],command=r['type'],success=True,data=dict(protocolVersion=2) if r['type']=='negotiate_protocol' else report))
"""#.write(to: script, atomically: true, encoding: .utf8)
        let runtime = HiveProviderRuntime(); try runtime.replaceCredential(key)
        let original = OMPLaunchConfiguration(executable: URL(fileURLWithPath: "/usr/bin/python3"), workingDirectory: root,
            arguments: [script.path], environment: ["PATH": "/usr/bin:/bin"], handshakeTimeout: .seconds(3))
        let configured = try runtime.configure(original)
        // Python only consumes the pipe, not OMP's trusted extension CLI switch.
        var launch = configured; launch.arguments = original.arguments
        let session = OMPRPCSession()
        do {
            try await session.start(launch)
            let reply = try await session.request("fixture_report")
            for field in ["received", "bounded", "eof", "closed", "argvSafe", "envSafe"] {
                #expect(reply["data"]?[field]?.bool == true)
            }
            #expect(!(try String(data: reply.jsonLine(), encoding: .utf8) ?? "").contains(key))
            let exit = await session.shutdown()
            #expect(exit.status == 0)
            #expect(exit.remainingProcessIDs.isEmpty)
        } catch { _ = await session.shutdown(cancel: true); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil), arguments: [true, false])
    func stallariKeepsProviderEvenWhenOwnedExtensionsAreDisabled(loading: Bool) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = HiveProviderRuntime(); try runtime.replaceCredential(hiveSyntheticKey)
        let installation = try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])))
        let configuration = try StallariTools.configuration(installation: installation, workingDirectory: root,
            configurationFile: root.appendingPathComponent("config.yml"), sessionDirectory: root.appendingPathComponent("sessions"),
            environment: [:], loadingExtensions: loading, hive: runtime)
        #expect(configuration.hiveCredential != nil)
        #expect(configuration.arguments.contains("--no-extensions"))
        #expect(configuration.arguments.contains("high"))
        let paths = configuration.arguments.enumerated().compactMap { i, value in
            value == "--trusted-extension" && i + 1 < configuration.arguments.count ? configuration.arguments[i + 1] : nil
        }
        #expect(paths.contains { $0.hasSuffix("hive-provider.ts") })
        #expect(!configuration.arguments.contains(HiveProviderRuntime.modelIdentifier))
        #expect(!configuration.arguments.joined().contains(hiveSyntheticKey))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil), arguments: [HirdRunMode.change, .inspect])
    func hirdBothModesReceiveTrustedProviderWithoutChangingApprovedModel(mode: HirdRunMode) async throws {
        let fixture = try await HirdFixture.make()
        let rpc = ScriptedHirdRPC()
        let runtime = HiveProviderRuntime(); try runtime.replaceCredential(hiveSyntheticKey)
        let run = PersistedRun(hird: .init(id: .init(UUID().uuidString), name: "Hird", role: "fixture", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
            issueID: fixture.run.issueID, projectID: fixture.run.projectID, ompSessionID: nil, ownershipToken: UUID().uuidString, startedAt: .now, mode: mode)
        _ = try await fixture.repository.createRun(run)
        let adapter = OMPHirdAdapter(repository: fixture.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"]))),
            resultRoot: fixture.directory.appendingPathComponent("results"), expectedModel: "ollama/gemma4:12b", makeRPC: { rpc }, hive: runtime)
        let task = Task { try await adapter.start(run, emit: fixture.sink) }
        do {
            for _ in 0..<500 {
                if await rpc.started > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let args = await rpc.arguments
            #expect(args.contains { $0.hasSuffix("hive-provider.ts") })
            #expect(!args.contains(HiveProviderRuntime.modelIdentifier))
            #expect(!args.joined().contains(hiveSyntheticKey))
            await adapter.cancel(run.id); _ = await task.result
            try await fixture.cleanup()
        } catch {
            await adapter.cancel(run.id); _ = await task.result
            try await fixture.cleanup(); throw error
        }
    }
}
