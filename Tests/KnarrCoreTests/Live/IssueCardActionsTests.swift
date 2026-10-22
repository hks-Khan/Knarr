import Testing
import KnarrCore
@testable import KnarrUI

private typealias Issue = KnarrCore.Issue

/// The card's `...` menu and its right-click menu share these items. Each item goes through the
/// same `store.perform` / `goToThread` paths as the card buttons and the drawer footer.
@MainActor struct IssueCardActionsTests {
    private func issue(_ store: SampleKnarrStore, _ id: String) throws -> Issue {
        try #require(store.issues.first { $0.id.rawValue == id })
    }

    private func actions(_ store: SampleKnarrStore, _ issue: Issue, opened: @escaping () -> Bool = { false }) -> IssueCardActions {
        _ = opened
        return IssueCardActions(issue: issue, store: store, open: {}, goToThread: { store.goToThread(for: issue.id) })
    }

    @Test func alwaysOffersDetailAndMovesThreadOnlyWhenAnotherThreadOwnsTheIssue() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        store.selectThread(ConversationThread.defaultID)
        let target = try issue(store, "npc-repeat")
        var opened = false
        let actions = IssueCardActions(issue: target, store: store, open: { opened = true }, goToThread: { store.goToThread(for: target.id) })
        #expect(actions.items.map(\.id) == ["open", "thread", "stop"])
        actions.items[0].perform()
        #expect(opened)
        actions.items[1].perform()
        #expect(store.selectedThreadID == target.conversationThreadID)
    }

    @Test func hidesThreadMoveInTheCurrentThreadAndForASingleThread() throws {
        let store = SampleKnarrStore()
        let target = try issue(store, "npc-repeat")
        let single = actions(store, target)
        #expect(!single.items.contains { $0.id == "thread" })
        #expect(store.threads.count == 1)
        let session = SampleKnarrStore(issueSessionScene: .main)
        session.selectThread(try issue(session, "npc-repeat").conversationThreadID)
        let sameThread = actions(session, try issue(session, "npc-repeat"))
        #expect(!sameThread.items.contains { $0.id == "thread" })
    }

    @Test func closeMenuUsesTheDrawerReasonsAndClosesThroughPerform() throws {
        let store = SampleKnarrStore(issueSessionScene: .completed)
        let target = try issue(store, "dark-mode")
        let actions = actions(store, target)
        #expect(actions.closeItems.map(\.title) == IssueCloseReason.allCases.map(\.title))
        let close = try #require(actions.closeItems.first { $0.id == "close-" + IssueCloseReason.applied.rawValue })
        #expect(close.enabled)
        close.perform()
        #expect(store.issue(target.id)?.archivedAt != nil)
        #expect(store.issue(target.id)?.archiveReason == IssueCloseReason.applied.rawValue)
        let after = try issue(store, "dark-mode")
        #expect(IssueCardActions(issue: after, store: store, open: {}, goToThread: {}).items.map(\.id).first == "open")
        #expect(!IssueCardActions(issue: after, store: store, open: {}, goToThread: {}).items.contains { $0.id == "stop" })
    }

    @Test func closeAndStopStayDisabledWhileAHirdRuns() throws {
        let store = SampleKnarrStore(issueSessionScene: .singleHird)
        let target = try issue(store, "npc-repeat")
        #expect(target.hasActiveHird)
        let actions = actions(store, target)
        #expect(actions.closeItems.allSatisfy { !$0.enabled })
        #expect(actions.items.contains { $0.id == "stop" })
    }

    @Test func proposalApprovalUsesTheStoredVersion() throws {
        let store = SampleKnarrStore(issueSessionScene: .approval)
        let target = try issue(store, "session-proposal")
        let approve = try #require(actions(store, target).items.first { $0.id == "approve" })
        #expect(approve.enabled)
        approve.perform()
        #expect(store.issue(target.id)?.approval?.version == target.proposal?.version)
    }

    @Test func stopIsOfferedButResumeAndRevisionAreNotShownToThePerson() throws {
        let store = SampleKnarrStore(issueSessionScene: .singleHird)
        let running = try issue(store, "npc-repeat")
        let stop = try #require(actions(store, running).items.first { $0.id == "stop" })
        stop.perform()
        #expect(store.issue(running.id)?.state == .failed)
        let failed = try issue(store, "npc-repeat")
        #expect(!actions(store, failed).items.contains { ["resume", "requestChanges", "confirm"].contains($0.id) })
        // The internal path is kept for Stallari; only its card and menu entry are gone.
        store.perform(.resume, on: running.id)
        #expect(store.issue(running.id)?.state == .running)
    }

    @Test func judgedAndIntegratedResultsOfferNoUserReviewOrMerge() throws {
        let store = SampleKnarrStore(issueStatusScene: true)
        for id in ["dark-mode", "save-migration", "status-judging", "inventory-sort"] {
            let target = try issue(store, id)
            let ids = actions(store, target).items.map(\.id)
            #expect(!ids.contains("confirm"))
            #expect(!ids.contains("requestChanges"))
            #expect(!ids.contains("resume"))
            #expect(!ids.contains("approve"))
        }
    }
}
