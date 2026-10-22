import Foundation
import Testing
@testable import KnarrCore

/// Read only OMP's public metadata. No credential records or login operations.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_HIRD_DISCOVER_MODELS"] == "1"))
struct HirdModelDiscoveryTests {
    @Test func discoverExistingSupportedModels() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let f = try await HirdFixture.make()
        let rpc = OMPRPCSession()
        var environment = ProcessInfo.processInfo.environment
        let root = f.directory.deletingLastPathComponent().deletingLastPathComponent()
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(environment["PI_CONFIG_DIR"] ?? ".omp")
        let profile = environment["OMP_PROFILE"] ?? environment["PI_PROFILE"] ?? ""
        let defaultAgent = profile.isEmpty ? config.appendingPathComponent("agent") : config.appendingPathComponent("profiles/" + profile + "/agent")
        let agent = environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ?? defaultAgent
        let store = agent.appendingPathComponent("agent.db")
        let exists = FileManager.default.fileExists(atPath: store.path)
        let inventory: [String: Any] = ["officialStorePath": store.path, "officialStoreExists": exists,
            "agentOverridePresent": environment["PI_CODING_AGENT_DIR"] != nil, "profilePresent": !profile.isEmpty,
            "requiredModelFamilies": ["GPT", "Claude"], "availableSupportedModels": [],
            "status": exists ? "metadata_pending" : "blocked_missing_official_store"]
        try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("official-auth-inventory.json"))
        do {
            guard exists else {
                print("Supported Hird blocked: OMP official agent.db is absent; no configured agent/profile override. GPT/Claude normal coding run was not started.")
                throw HirdModelDiscoveryError.missingOfficialStore
            }
            // Preserve the same official agent store; redirect only disposable root artifacts.
            environment["PI_CODING_AGENT_DIR"] = agent.path
            environment.removeValue(forKey: "OMP_PROFILE"); environment.removeValue(forKey: "PI_PROFILE")
            environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + f.directory.path.dropFirst()
            try await rpc.start(.init(installation: try OMPInstallation(executable: URL(fileURLWithPath: executable)), workingDirectory: f.directory, arguments: ["--mode", "rpc", "--no-title", "--no-lsp", "--no-pty", "--no-ui", "--session-dir", f.directory.appendingPathComponent("sessions").path], environment: environment))
            let providers = try await rpc.request("get_login_providers")["data"]?["providers"]?.array ?? []
            let models = try await rpc.request("get_available_models")["data"]?["models"]?.array ?? []
            let state = try await rpc.request("get_state")["data"]
            let supported = models.filter { model in
                let name = model["id"]?.string ?? ""
                return name.lowercased().contains("gpt") || name.lowercased().contains("claude")
            }.map { ["provider": $0["provider"]?.string ?? "", "id": $0["id"]?.string ?? ""] }
            let safe: [String: Any] = [
                "providers": providers.filter { ["openai-codex", "openai-codex-device", "anthropic"].contains($0["id"]?.string ?? "") }.map { ["id": $0["id"]?.string ?? "", "available": $0["available"]?.bool ?? false, "authenticated": $0["authenticated"]?.bool ?? false] as [String: Any] },
                "supportedModels": supported,
                "selected": ["provider": state?["model"]?["provider"]?.string ?? "", "id": state?["model"]?["id"]?.string ?? ""]
            ]
            try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("model-discovery.json"))
            print("OMP metadata: \(safe)")
            let exit = await rpc.shutdown(); #expect(exit.remainingProcessIDs.isEmpty)
            guard !supported.isEmpty else { throw HirdModelDiscoveryError.noSupportedModels }
            try await f.cleanup()
        } catch { _ = await rpc.shutdown(cancel: true); try await f.cleanup(); throw error }
    }
}

enum HirdModelDiscoveryError: Error { case missingOfficialStore, noSupportedModels }
