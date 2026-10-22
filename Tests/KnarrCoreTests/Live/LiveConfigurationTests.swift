import Foundation
import Testing
@testable import KnarrCore

struct LiveConfigurationTests {
    @Test func desktopLaunchUsesOMPLoginWithoutParentClaudeProxyOverrides() {
        let inherited = ["ANTHROPIC_BASE_URL": "https://unrelated-proxy.invalid", "ANTHROPIC_AUTH_TOKEN": "fixture-token", "ANTHROPIC_API_KEY": "fixture-key", "PI_CODING_AGENT_DIR": "/tmp/official-omp-agent", "OMP_PROFILE": "chosen-profile", "PATH": "/usr/bin"]
        let config = LiveKnarrConfiguration.standard(environment: inherited, arguments: ["Knarr"], loginPath: nil)
        #expect(config.environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(config.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(config.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(config.environment["PI_CODING_AGENT_DIR"] == inherited["PI_CODING_AGENT_DIR"])
        #expect(config.environment["OMP_PROFILE"] == inherited["OMP_PROFILE"])
        #expect(inherited["ANTHROPIC_AUTH_TOKEN"] == "fixture-token")
    }

    static func state(_ provider: String, _ id: String) -> OMPJSON {
        .object(["data": .object(["model": .object(["provider": .string(provider), "id": .string(id)])])])
    }
    static func available(_ provider: String, _ id: String) -> OMPJSON {
        .object(["data": .object(["models": .array([.object(["provider": .string(provider), "id": .string(id)])])])])
    }
    @Test func selectedConnectedGPTOrClaudeIsPreservedWithoutFixedModelOrFallback() throws {
        for (provider, model) in [("openai-codex", "gpt-fixture-new"), ("anthropic", "claude-fixture-next")] {
            #expect(try LiveKnarrConfiguration.selectedModel(state: Self.state(provider, model), available: Self.available(provider, model)) == provider + "/" + model)
        }
        #expect(throws: (any Error).self) { try LiveKnarrConfiguration.selectedModel(state: Self.state("anthropic", "claude-fixture"), available: .object(["data": .object(["models": .array([])])])) }
        #expect(throws: (any Error).self) { try LiveKnarrConfiguration.selectedModel(state: Self.state("openai-codex", "gpt-old"), available: Self.available("openai-codex", "gpt-other")) }
    }
}

@MainActor @Suite(.serialized) struct LiveStartupTests {
    @Test func startAndShutdownOwnSessionsWithoutModelPromptOrSampleData() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = workspace.appendingPathComponent("outputs/issue-5/fixtures/startup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rpc = LiveTestRPC(), store = LiveKnarrStore()
        let config = LiveKnarrConfiguration(projects: [.init(id: "p", name: "시작 프로젝트", absolutePath: directory.path)], dataDirectory: directory,
            executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] ??
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp").path), jitdeckDatabase: nil)
        do {
            store.start(config, makeRPC: { rpc })
            try await store.whenIdle()
            #expect(await rpc.starts == 1)
            #expect(await rpc.prompts.isEmpty)
            #expect(store.issues.isEmpty && store.questions.isEmpty)
            #expect(store.stallari.scope == "모든 프로젝트")
            #expect(store.projects.map(\.name) == ["시작 프로젝트"])
            #expect(await store.shutdown().remainingProcessIDs.isEmpty)
            #expect(await rpc.shutdowns > 0)
            try FileManager.default.removeItem(at: directory)
        } catch { _ = await store.shutdown(); try FileManager.default.removeItem(at: directory); throw error }
    }
}
