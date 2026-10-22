import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] != nil))
struct LiveMetadataTests {
    @Test func unauthenticatedRealOMPStartupStopsBeforePromptAndReclaimsProcess() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"])
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent("outputs/issue-5/fixtures/metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = root.appendingPathComponent("official-agent").path
        environment["PI_CONFIG_DIR"] = String(repeating: "../", count: FileManager.default.homeDirectoryForCurrentUser.pathComponents.count - 1) + root.path.dropFirst()
        let store = LiveKnarrStore()
        let configuration = LiveKnarrConfiguration(projects: [.init(id: "metadata", name: "로그인 없는 연결", absolutePath: root.path)],
            dataDirectory: root.appendingPathComponent("data"), executable: URL(fileURLWithPath: executable), environment: environment,
            jitdeckDatabase: nil)
        do {
            store.start(configuration)
            do { try await store.whenIdle(); Testing.Issue.record("An unauthenticated startup must not admit user prompts") }
            catch StallariError.closed {}
            #expect(store.lastError == LiveKnarrError.noSupportedSelectedModel.errorDescription)
            #expect(store.issues.isEmpty && store.questions.isEmpty)
            let exit = await store.shutdown()
            #expect(exit.remainingProcessIDs.isEmpty)
            print("Live OMP \(OMPInstallation.version): metadata-only; no supported authenticated selection; prompt not admitted; remaining=\(exit.remainingProcessIDs)")
            try FileManager.default.removeItem(at: root)
        } catch { _ = await store.shutdown(); try FileManager.default.removeItem(at: root); throw error }
    }
}
