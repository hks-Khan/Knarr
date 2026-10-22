import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled && ProcessInfo.processInfo.environment["KNARR_PREPARATION_RENDER"] == "1")) struct PreparationWindowTests {
    @Test(arguments: [false, true]) func archiveLayoutRendersWithSavedDataAndCompactWidth(dark: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let database = root.appendingPathComponent("outputs/archive-ui/fixture/data/knarr.db")
        let repository = try await SQLiteKnarrRepository.open(at: database)
        let rpc = LiveTestRPC(), hird = LiveTestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird)
        let suite = "knarr-preparation-render-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = LiveKnarrStore(repository: repository, session: session, rpc: rpc, hird: hird, preferences: preferences,
                                  subscriptionUsage: .init(sample: true))
        do {
            try await store.connect()
            let project = try #require(store.projects.first { $0.settings.workspaceStyle == .preparation })
            #expect(store.preparationItems(inProject: project.id).count == 3)
            let documents = ProjectDocumentsModel()
            let window = TestWindow.make(size: NSSize(width: dark ? 640 : 1296, height: 1213), dark: dark)
            window.contentView = NSHostingView(rootView: ProjectDetail(store: store, project: project,
                tab: .constant(.overview), issueFilter: .constant(.all), open: { _ in }, talk: { _ in }, request: { _ in },
                documents: documents).environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(preferences))
            TestWindow.present(window)
            defer { window.contentView = nil; window.close() }
            let content = try #require(window.contentView)
            for _ in 0..<200 {
                content.layoutSubtreeIfNeeded()
                if documents.recent.count >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(documents.recent.count >= 2)
            try await Task.sleep(for: .milliseconds(200))
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let folder = root.appendingPathComponent("outputs/archive-ui/screenshots")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(dark ? "archive-compact-dark.png" : "archive-wide-light.png"))
            #expect(try await repository.snapshot().runs.isEmpty)
            let exit = await store.shutdown(); #expect(exit.remainingProcessIDs.isEmpty)
            try await repository.close()
        } catch { _ = await store.shutdown(); try? await repository.close(); throw error }
    }
}
