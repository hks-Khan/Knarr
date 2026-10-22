import AppKit
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ThreadUITests {
    init() { _ = NSApplication.shared }
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityValue": "AXValue", "accessibilityIdentifier": "AXIdentifier"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: action) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Press.self)(node, action)
    }
    private func button(_ h: HomeHarness, id: String) throws -> NSObject {
        let host = try #require(h.window.contentView)
        return try #require(elements(host).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing control: \(id)")
    }
    private func selectIssueHistory(_ h: HomeHarness) throws {
        let picker = try button(h, id: "history-kind")
        let issues = try #require(elements(picker).first {
            value($0, "accessibilityLabel") as? String == "이슈·대화"
        })
        issues.accessibilityPerformAction(.press)
        h.settle()
    }

    @Test func projectSelectionKeepsHomeTabsAndReusesHistoryAndDraftAcrossSurfaces() async throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        store.selectProjectConversation("gamza")
        let a = store.selectedThreadID
        store.send("프로젝트 A의 기존 기록", about: nil, project: "gamza", attachments: [])
        store.composerDraft.text = "A 초안"
        let historyA = store.chat
        store.selectProjectConversation("knarr")
        let b = store.selectedThreadID
        store.send("프로젝트 B의 기존 기록", about: nil, project: "knarr", attachments: [])
        store.composerDraft.text = "B 초안"
        let historyB = store.chat
        store.selectThread(ConversationThread.defaultID)
        let mainHistory = store.chat
        let h = HomeHarness(width: 1440, height: 900, store: store) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
        }
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        #expect(press(try button(h, id: "thread-" + a)))
        h.settle()
        #expect(store.selectedThreadID == a && store.composerDraft.project == "gamza")
        #expect(store.chat == historyA && h.composer?.string == "A 초안")
        #expect(await h.revealMessage("프로젝트 A의 기존 기록") != nil)
        #expect(press(try button(h, id: "thread-" + b)))
        h.settle()
        #expect(store.selectedThreadID == b && store.composerDraft.project == "knarr")
        #expect(store.chat == historyB && h.composer?.string == "B 초안")
        #expect(await h.revealMessage("프로젝트 B의 기존 기록") != nil)
        #expect(press(try button(h, id: "thread-" + ConversationThread.defaultID)))
        h.settle()
        #expect(store.chat == mainHistory)
        #expect(press(try button(h, id: "thread-" + a)))
        h.settle()
        let host = try #require(h.window.contentView)
        let railProjects = try #require(elements(host).first { value($0, "accessibilityLabel") as? String == "프로젝트" })
        #expect(press(railProjects))
        h.settle()
        #expect(store.selectedThreadID == a && store.chat == historyA)
        #expect(h.composer?.string == "A 초안")
        _ = try button(h, id: "project-session-panel-gamza")
        let railHome = try #require(elements(host).first { value($0, "accessibilityLabel") as? String == "홈" })
        #expect(press(railHome))
        h.settle()
        #expect(store.selectedThreadID == a && store.chat == historyA)
        #expect(h.composer?.string == "A 초안")
        let ids = elements(host).compactMap { value($0, "accessibilityIdentifier") as? String }
        #expect(ids.contains("thread-" + b))
        #expect(!ids.contains("close-thread-" + a) && !ids.contains("close-thread-" + b))
    }

    @Test func selectingProjectOnHomeDoesNotRouteToProjectWorkspace() async throws {
        let store = SampleKnarrStore()
        let h = HomeHarness(width: 1440, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        store.selectProjectConversation("gamza")
        h.settle()
        let ids = elements(try #require(h.window.contentView)).compactMap { value($0, "accessibilityIdentifier") as? String }
        #expect(ids.contains("thread-" + ConversationThread.defaultID))
        #expect(!ids.contains("project-session-panel-gamza"))
        #expect(store.composerDraft.project == "gamza")
        #expect(h.composer != nil)
    }
    @Test func liveProjectTabsPreserveLazySessionsScopeAndOwnerActions() async throws {
        let f = try await LiveFixture.make()
        var repository = f.repository
        let suite = "knarr-project-tab-ui-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var opened: [String] = []
        var sessions: [String: StallariSession] = [:]
        var rpcs: [String: LiveTestRPC] = [:]
        func makeStore() -> LiveKnarrStore {
            let rpc = LiveTestRPC()
            let store = LiveKnarrStore(repository: repository,
                session: StallariSession(repository: repository, rpc: rpc, hird: f.hird),
                rpc: rpc, hird: f.hird, preferences: preferences, subscriptionUsage: .init(sample: true))
            store.setThreadFactory { thread in
                opened.append(thread.id)
                let rpc = LiveTestRPC()
                let session = StallariSession(repository: repository, rpc: rpc, hird: f.hird, threadID: thread.id)
                sessions[thread.id] = session; rpcs[thread.id] = rpc
                return LiveConversation(repository: repository, session: session, rpc: rpc, hird: f.hird,
                    threadID: thread.id, preferences: preferences)
            }
            return store
        }
        var store = makeStore()
        do {
            let a = try await f.repository.createProjectConversation(projectID: "p", threadID: "project-tab-a")
            let b = try await f.repository.createProjectConversation(projectID: "other", threadID: "project-tab-b")
            let replyA = ChatItem(at: .now, kind: .stallari("A 기존 답변", project: nil))
            let replyB = ChatItem(at: .now, kind: .stallari("B 기존 답변", project: nil))
            try await f.repository.appendChat(replyA, projectID: "p", threadID: a.id)
            try await f.repository.appendChat(replyB, projectID: "other", threadID: b.id)
            try await store.connect()
            let before = try await f.repository.snapshot()
            let h = HomeHarness(width: 1440, height: 900, store: store) {
                $0.set(false, forKey: "knarr.projectSessionCollapsed.other")
            }
            var closed = false
            defer { if !closed { h.close() } }
            TestWindow.present(h.window); h.settle()
            for (thread, draft, reply) in [(a, "A 보존 초안", replyA), (b, "B 보존 초안", replyB)] {
                #expect(press(try button(h, id: "thread-" + thread.id)))
                h.settle()
                #expect(store.chat == [reply])
                let editor = try #require(h.composer)
                editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                h.settle()
                #expect(store.composerDraft == .init(text: draft, project: thread.projectID))
            }
            #expect(opened.isEmpty)
            #expect(try await f.repository.snapshot().threads == before.threads)
            #expect(try await f.repository.snapshot().chat == before.chat)
            let host = try #require(h.window.contentView)
            let projects = try #require(elements(host).first { value($0, "accessibilityLabel") as? String == "프로젝트" })
            #expect(press(projects)); h.settle()
            _ = try button(h, id: "project-session-panel-other")
            #expect(store.selectedThreadID == b.id && store.chat == [replyB])
            #expect(h.composer?.string == "B 보존 초안")
            let home = try #require(elements(host).first { value($0, "accessibilityLabel") as? String == "홈" })
            #expect(press(home)); h.settle()
            #expect(store.selectedThreadID == b.id && store.chat == [replyB])
            #expect(press(try button(h, id: "thread-" + a.id))); h.settle()
            #expect(h.composer?.string == "A 보존 초안")
            #expect(press(try button(h, id: "thread-" + ConversationThread.defaultID))); h.settle()
            #expect(!store.chat.contains { $0.id == replyA.id || $0.id == replyB.id })
            #expect(press(try button(h, id: "thread-" + a.id))); h.settle()
            h.close()
            closed = true
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            repository = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            store = makeStore()
            try await store.connect()
            #expect(store.selectedThreadID == a.id && store.chat == [replyA])
            #expect(store.composerDraft == .init(text: "A 보존 초안", project: "p"))
            #expect(opened.isEmpty)
            let restored = HomeHarness(width: 1440, height: 900, store: store) {
                $0.set(false, forKey: "knarr.projectSessionCollapsed.p")
            }
            defer { restored.close() }
            TestWindow.present(restored.window); restored.settle()
            let editor = try #require(restored.composer)
            editor.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: restored.window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
            for _ in 0..<200 {
                if store.chat.contains(where: { $0.kind == .user("A 보존 초안") }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await store.whenIdle()
            #expect(opened == [a.id])
            let projectSession = try #require(sessions[a.id])
            let projectRPC = try #require(rpcs[a.id])
            #expect(await projectRPC.prompts.filter { $0["message"]?.string?.contains("A 보존 초안") == true }.count == 1)
            let liveHistory = store.chat
            let restoredHost = try #require(restored.window.contentView)
            let projectRail = try #require(elements(restoredHost).first { value($0, "accessibilityLabel") as? String == "프로젝트" })
            #expect(press(projectRail)); restored.settle()
            _ = try button(restored, id: "project-session-panel-p")
            #expect(store.selectedThreadID == a.id && store.chat == liveHistory)
            let homeRail = try #require(elements(restoredHost).first { value($0, "accessibilityLabel") as? String == "홈" })
            #expect(press(homeRail)); restored.settle()
            #expect(store.selectedThreadID == a.id && store.chat == liveHistory)
            #expect(opened == [a.id])
            let issueID = try await projectSession.createIssue(id: "tab-owned", title: "탭 소유 승인",
                criteria: ["격리 검증"], instruction: "실제 작업 없는 stub")
            await #expect(throws: StallariError.rejectedEvidence(store.projectSessionPolicy.wrongProjectMessage)) {
                _ = try await projectSession.createIssue(id: "tab-escape", title: "범위 밖",
                    criteria: ["거부"], instruction: "거부", projectID: "other")
            }
            try await store.whenIdle(); restored.settle()
            let review = try button(restored, id: "integrated-issue-" + issueID.rawValue)
            let approve = try #require(elements(review).first { value($0, "accessibilityLabel") as? String == "이 제안대로 실행" })
            #expect(press(approve))
            restored.settle()
            try await store.whenIdle(); restored.settle()
            let snapshot = try await repository.snapshot()
            let issue = try #require(snapshot.issues.first { $0.id == issueID })
            let run = try #require(snapshot.runs.first { $0.issueID == issueID })
            #expect(snapshot.threads.first { $0.id == issue.conversationThreadID }?.originThreadID == a.id)
            #expect(run.projectID == "p")
            #expect(store.selectedThreadID == a.id)
            let owner = try #require(sessions[issue.conversationThreadID])
            _ = try await owner.ask(id: "tab-question", runID: run.id, issueID: issueID,
                prompt: "원소유 질문", options: ["QA 선택"])
            try await store.whenIdle(); restored.settle()
            let nodes = elements(try #require(restored.window.contentView))
            let option = try #require(nodes.first { value($0, "accessibilityLabel") as? String == "QA 선택" })
            #expect(press(option)); restored.settle()
            let replyHost = try #require(restored.window.contentView)
            let send = try #require(elements(replyHost).first {
                value($0, "accessibilityLabel") as? String == "보내기"
            })
            #expect(press(send))
            try await store.whenIdle()
            #expect(await f.hird.resolutions.contains { $0.runID == run.id && $0.answer == .init(selectedOptions: ["QA 선택"], text: nil) })
            let saved = try await repository.snapshot()
            #expect(saved.questions.first { $0.id == "tab-question" }?.issueID == issueID)
            #expect(saved.chatLinks.first { link in saved.chat.contains { $0.id == link.chatID && $0.kind == .user("A 보존 초안") } }?.conversationThreadID == a.id)
            #expect((await store.shutdown()).remainingProcessIDs.isEmpty)
            try await repository.close()
            try await f.cleanup()
        } catch { _ = await store.shutdown(); try await repository.close(); try await f.cleanup(); throw error }
    }


    @Test func legacyConversationOpensFromHistoryWithItsDraftButNoTab() async throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        store.createThread(name: "스레드테스트")
        let legacy = store.selectedThreadID
        store.composerDraft.text = "이전 스레드 초안"
        store.selectThread(ConversationThread.defaultID)
        let h = HomeHarness(width: 1100, height: 800, page: .history, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        try selectIssueHistory(h)
        #expect(press(try button(h, id: "history-thread-" + legacy)))
        h.settle()
        #expect(store.selectedThreadID == legacy)
        #expect(h.composer?.string == "이전 스레드 초안")
        #expect(!store.conversationTabs.contains { $0.id == legacy })
        #expect(press(try button(h, id: "thread-" + ConversationThread.defaultID)))
        h.settle()
        #expect(store.selectedThreadID == ConversationThread.defaultID)
    }

    @Test func topCardOpensReusableIssueTabAndClosePreservesConversation() async throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        store.createThread(name: "사용자 대화")
        let custom = store.selectedThreadID
        store.selectThread(ConversationThread.defaultID)
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        // The card body opens the detail; moving to the issue's own thread is the card menu's item.
        let card = try button(h, id: "integrated-issue-" + issue.id.rawValue)
        let frame = try #require(card.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let point = h.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            h.window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        h.settle()
        #expect(elements(try #require(h.window.contentView)).contains {
            value($0, "accessibilityIdentifier") as? String == "issue-drawer"
        })
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        try #require(IssueCardActions(issue: issue, store: store, open: {}, goToThread: {
            store.goToThread(for: issue.id)
        }).items.first { $0.id == "thread" }).perform()
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
        let ids = elements(try #require(h.window.contentView)).compactMap { value($0, "accessibilityIdentifier") as? String }
        #expect(ids.contains("thread-" + issue.conversationThreadID))
        #expect(!ids.contains("thread-" + custom))
        #expect(!ids.contains("new-thread"))
        #expect(!ids.contains("issue-main-return"))
        #expect(press(try button(h, id: "thread-" + ConversationThread.defaultID)))
        h.settle()
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        #expect(press(try button(h, id: "thread-" + issue.conversationThreadID)))
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
        #expect(press(try button(h, id: "close-thread-" + issue.conversationThreadID)))
        h.settle()
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        #expect(store.threads.contains { $0.id == issue.conversationThreadID })
        #expect(store.issues.contains { $0.id == issue.id })
        try #require(IssueCardActions(issue: issue, store: store, open: {}, goToThread: {
            store.goToThread(for: issue.id)
        }).items.first { $0.id == "thread" }).perform()
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
    }

    @Test func actualDisclosurePersistsAndClosedConversationHasNoComposer() async throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        #expect(press(try button(h, id: "issue-cards-disclosure")))
        h.settle()
        #expect(h.defaults.bool(forKey: "knarr.issueCardsCollapsed"))
        h.resize(width: 900, height: 700)
        #expect(h.defaults.bool(forKey: "knarr.issueCardsCollapsed"))
        let history = SampleKnarrStore(issueSessionScene: .history)
        let closed = try #require(history.issues.first { $0.archivedAt != nil })
        let closedHome = HomeHarness(width: 1100, height: 800, page: .history, store: history)
        defer { closedHome.close() }
        TestWindow.present(closedHome.window); closedHome.settle()
        try selectIssueHistory(closedHome)
        #expect(press(try button(closedHome, id: "history-issue-" + closed.id.rawValue)))
        closedHome.settle()
        #expect(history.selectedIssue?.id == closed.id)
        #expect(closedHome.composer == nil)
        #expect(history.issueConversationIsReadOnly)
    }

    @Test func multipleRunningWorkersKeepBothCommandsVisible() async throws {
        let running = HomeHarness(width: 1300, height: 900, store: SampleKnarrStore(issueSessionScene: .conversation))
        defer { running.close() }
        TestWindow.present(running.window); running.settle()
        func labels(_ home: HomeHarness) throws -> [String] {
            elements(try #require(home.window.contentView)).flatMap { node in
                ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }
            }
        }
        #expect(try labels(running).contains("명령 실행 · swift test --filter DialogueTests"))
        #expect(try labels(running).contains("명령 실행 · swift test --filter SaveCompatibilityTests"))
    }

    @Test func appliedUnconfirmedHistoryOpensWithoutTopCardOrComposer() async throws {
        let store = SampleKnarrStore(issueStatusScene: true)
        let applied = try #require(store.issues.first { $0.isApplied && $0.archivedAt == nil && !$0.confirmed })
        let h = HomeHarness(width: 1300, height: 900, page: .history, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        try selectIssueHistory(h)
        #expect(press(try button(h, id: "history-issue-" + applied.id.rawValue)))
        h.settle()
        #expect(store.selectedIssue?.id == applied.id)
        #expect(h.composer == nil)
        let ids = elements(try #require(h.window.contentView)).compactMap { value($0, "accessibilityIdentifier") as? String }
        #expect(!ids.contains("integrated-issue-" + applied.id.rawValue))
        #expect(!ids.contains("issue-cards-disclosure"))
    }
}
