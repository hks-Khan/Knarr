import AppKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// Injects only the OS transport. Routing, SQLite snapshots and the rendered HomeView are production code.
@MainActor @Suite(.serialized) struct DesktopNotificationRoutingTests {
    @MainActor final class Fixture {
        let directory: URL
        let suite = "knarr-native-routing-\(UUID())"
        let preferences: UserDefaults
        let repository: SQLiteKnarrRepository
        let hird = LiveTestHird()
        var store: LiveKnarrStore
        let client = DesktopNotificationTests.Client()
        var service: DesktopNotificationService
        let signals = AsyncStream<String>.makeStream()
        var activations = 0

        private init(directory: URL, repository: SQLiteKnarrRepository) throws {
            self.directory = directory; self.repository = repository
            preferences = UserDefaults(suiteName: suite)!
            store = Self.makeStore(repository: repository, hird: hird, preferences: preferences)
            service = try DesktopNotificationService(client: client, ledgerURL: directory.appendingPathComponent("receipts.json"))
            bind()
        }
        private static func makeStore(repository: SQLiteKnarrRepository, hird: LiveTestHird, preferences: UserDefaults) -> LiveKnarrStore {
            let rpc = LiveTestRPC()
            let store = LiveKnarrStore(repository: repository,
                session: StallariSession(repository: repository, rpc: rpc, hird: hird), rpc: rpc, hird: hird,
                preferences: preferences, subscriptionUsage: .init(sample: true))
            store.setThreadFactory { thread in
                let rpc = LiveTestRPC()
                return LiveConversation(repository: repository,
                    session: StallariSession(repository: repository, rpc: rpc, hird: hird, threadID: thread.id),
                    rpc: rpc, hird: hird, threadID: thread.id, preferences: preferences)
            }
            return store
        }
        static func make() async throws -> Fixture {
            let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let directory = workspace.appendingPathComponent("outputs/issue-5/fixtures/notification-routing-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("knarr.db"))
            try await repository.saveProject(.init(id: "p", name: "알림 대상 프로젝트", absolutePath: directory.path))
            try await repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: directory.path))
            _ = try await repository.createProjectConversation(projectID: "p", threadID: "origin-p")
            _ = try await repository.createProjectConversation(projectID: "other", threadID: "origin-other")
            return try Fixture(directory: directory, repository: repository)
        }
        func bind() {
            service.observed = { [signals] in signals.continuation.yield($0) }
            service.connect(to: store) { [weak self] in self?.activations += 1 }
        }
        func wait(for prefix: String) async {
            for await signal in signals.stream { if signal.hasPrefix(prefix) { return } }
        }
        func connect() async throws {
            try await store.connect()
            await wait(for: "startup-baseline")
        }
        func restart() async throws {
            store.desktopNotificationSnapshot = nil
            _ = await store.shutdown()
            store = Self.makeStore(repository: repository, hird: hird, preferences: preferences)
            service = try DesktopNotificationService(client: client, ledgerURL: directory.appendingPathComponent("receipts.json"))
            bind()
        }
        func createIssue() async throws -> DesktopNotificationEvent {
            let owner = StallariSession(repository: repository, rpc: LiveTestRPC(), hird: hird, threadID: "origin-p")
            _ = try await owner.createIssue(id: "target", title: "알림 클릭 대상 이슈", criteria: ["사용자 승인 전 실행하지 않음"],
                instruction: "합성 이벤트 · 실행하지 않음", model: "openai-codex/fixture-gpt", projectID: "p")
            await wait(for: "accepted:approval:")
            return try #require(client.sent.first { $0.target.issueID == "target" })
        }
        func shutdown() async throws {
            store.desktopNotificationSnapshot = nil
            signals.continuation.finish()
            _ = await store.shutdown()
            try await repository.close()
            preferences.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        func expectNoExecution(comparedTo before: PersistenceSnapshot) async throws {
            let after = try await repository.snapshot()
            #expect(after.issues == before.issues)
            #expect(after.runs == before.runs)
            #expect(after.questions == before.questions)
            #expect(await hird.runs.isEmpty)
            #expect(await hird.cancelled.isEmpty)
            #expect(await hird.resolutions.isEmpty)
        }
    }

    private func capture(_ h: HomeHarness, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["KNARR_REVIEW_SCREENSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try #require(h.window.contentView)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }

    @Test(.enabled(if: KnarrUITests.enabled), arguments: [HomePage.history, .projects])
    func clickReturnsToTheSameOwnerConversationFromAnotherPage(page: HomePage) async throws {
        _ = NSApplication.shared
        let f = try await Fixture.make()
        do {
            try await f.connect()
            let event = try await f.createIssue()
            try await f.repository.appendChat(.init(at: .now, kind: .user("소유 대화로 돌아왔어요")),
                projectID: "p", issueID: "target", threadID: event.target.threadID)
            await f.service.open(event.id)
            try await f.store.whenIdle()
            #expect(f.store.selectedThreadID == event.target.threadID)
            #expect(f.store.selectedIssue?.id == "target")
            #expect(f.store.selectedIssue?.projectName == "알림 대상 프로젝트")
            let thread = try #require(f.store.threads.first { $0.id == f.store.selectedThreadID })
            #expect(thread.issueID == "target" && thread.originThreadID == "origin-p")
            #expect(event.target.projectID == "p" && event.target.proposalVersion == 1)
            let before = try await f.repository.snapshot()
            let revision = f.store.notificationNavigationRevision
            // The thread is already selected: selectedThreadID.onChange cannot repair this screen.
            let h = HomeHarness(width: 900, height: 620, opened: "target", page: page, store: f.store)
            defer { h.close() }
            #expect(h.conversation == nil)
            try capture(h, name: page == .history ? "routing-history-before" : "routing-projects-before")
            await f.service.open(event.id)
            try await f.store.whenIdle()
            h.settle()
            #expect(f.store.notificationNavigationRevision == revision + 1)
            #expect(f.store.selectedThreadID == event.target.threadID)
            #expect(h.conversation != nil)
            #expect(h.composer != nil)
            await h.waitWeb()
            #expect(await h.webJSON("document.body.textContent.includes('소유 대화로 돌아왔어요')") as? Bool == true)
            #expect(h.panel == nil)
            try capture(h, name: page == .history ? "routing-history-after" : "routing-projects-after")
            try await f.expectNoExecution(comparedTo: before)
            try await f.shutdown()
        } catch { try await f.shutdown(); throw error }
    }

    @Test(.enabled(if: KnarrUITests.enabled)) func coldStartClickWaitsForTheActualStoreSnapshotAndMountedHome() async throws {
        _ = NSApplication.shared
        let f = try await Fixture.make()
        do {
            try await f.connect()
            let event = try await f.createIssue()
            // New store/service instances retain only the committed DB, preferences and durable receipt.
            try await f.restart()
            await f.service.open(event.id)
            #expect(f.activations == 0)
            #expect(f.store.notificationNavigationRevision == 0)
            let h = HomeHarness(width: 900, height: 620, page: .history, store: f.store)
            defer { h.close() }
            let before = try await f.repository.snapshot()
            // The production initial connect callback releases the queued click, not a synthetic snapshot.
            try await f.store.connect()
            await f.wait(for: "click-routed:")
            try await f.store.whenIdle()
            h.settle()
            #expect(f.activations == 1)
            #expect(f.store.notificationNavigationRevision == 1)
            #expect(f.store.selectedIssue?.id == "target")
            #expect(f.store.selectedThreadID == event.target.threadID)
            #expect(h.conversation != nil && h.composer != nil)
            try await f.expectNoExecution(comparedTo: before)
            #expect(f.client.sent.count == 1)
            try await f.shutdown()
        } catch { try await f.shutdown(); throw error }
    }

    enum StaleTarget: CaseIterable { case version, archivedIssue, archivedProject, deletedIssue, foreignOrigin, wrongOwner }
    @Test(arguments: StaleTarget.allCases)
    func staleStoredTargetsCannotNavigateOrAuthorize(target: StaleTarget) async throws {
        let f = try await Fixture.make()
        do {
            try await f.connect()
            let event = try await f.createIssue()
            switch target {
            case .version:
                try await f.repository.saveIssueProposal(issueID: "target",
                    proposal: .init(version: 2, instruction: "수정된 합성 제안", model: "openai-codex/fixture-gpt"), expectedVersion: 1)
            case .archivedIssue:
                try await f.repository.closeIssue("target", reason: .cancelled, at: .now)
            case .archivedProject:
                try await f.repository.saveProject(.init(id: "p", name: "알림 대상 프로젝트", absolutePath: f.directory.path, archivedAt: .now))
            case .deletedIssue, .foreignOrigin, .wrongOwner:
                // Fixture-only persisted deletion/corruption; never a production mutation seam.
                let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: 2)
                defer { try? writer.close() }
                switch target {
                case .deletedIssue:
                    try writer.transaction {
                        try writer.execute("DELETE FROM chat WHERE issue_id=?", ["target"])
                        try writer.execute("DELETE FROM issues WHERE id=?", ["target"])
                        try writer.execute("DELETE FROM threads WHERE id=?", [event.target.threadID])
                    }
                case .foreignOrigin:
                    try writer.execute("UPDATE threads SET payload=json_set(payload,'$.originThreadID','origin-other') WHERE id=?", [event.target.threadID])
                case .wrongOwner:
                    try writer.execute("UPDATE threads SET payload=json_set(payload,'$.issueID.rawValue','another-issue') WHERE id=?", [event.target.threadID])
                default: break
                }
            }
            let before = try await f.repository.snapshot()
            let revision = f.store.notificationNavigationRevision
            await f.service.open(event.id)
            await f.service.open("https://invalid.example/never-execute")
            await f.service.open("/tmp/never-open-notification-payload")
            #expect(f.activations == 0)
            #expect(f.store.notificationNavigationRevision == revision)
            #expect(f.store.selectedThreadID == ConversationThread.defaultID)
            try await f.expectNoExecution(comparedTo: before)
            try await f.shutdown()
        } catch { try await f.shutdown(); throw error }
    }
}
