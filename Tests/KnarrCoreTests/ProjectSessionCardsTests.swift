import Testing
import KnarrCore

@MainActor struct ProjectSessionCardsTests {
    @Test func mainCardsIgnoreComposerProjectFilter() {
        let store = SampleKnarrStore()
        let all = store.topIssueCards.issues.map(\.id)
        store.composerDraft.project = "gamza"
        #expect(store.topIssueCards.issues.map(\.id) == all)
    }

    @Test func projectIdentityDoesNotMatchAnotherProjectsDisplayName() {
        let store = SampleKnarrStore()
        store.addProject(path: "/synthetic/duplicate/Gamza Saga")
        let duplicateID = "/synthetic/duplicate/Gamza Saga"
        #expect(store.issues(inProject: duplicateID).isEmpty)
        let original = store.issues(inProject: "gamza").map(\.id)
        #expect(!original.isEmpty)
        store.renameProject("gamza", to: "새 프로젝트 이름")
        #expect(store.issues(inProject: "gamza").map(\.id) == original)
        #expect(store.issues(inProject: duplicateID).isEmpty)
    }
}

@MainActor struct ProjectSessionSampleTests {
    @Test func projectSelectionIsLazyReusesMemoryAndLocksItsDraft() async throws {
        let store = SampleKnarrStore()
        let main = store.chat
        #expect(!store.threads.contains { $0.projectID != nil })
        store.selectProjectConversation("gamza")
        let selected = store.selectedThreadID
        #expect(store.chat.isEmpty)
        #expect(!store.isResponding)
        #expect(store.composerDraft.project == "gamza")
        #expect(store.conversationTabs.filter { $0.id == selected && $0.projectID == "gamza" }.count == 1)
        store.composerDraft.text = "프로젝트 초안"
        store.selectThread(ConversationThread.defaultID)
        #expect(store.chat == main)
        store.selectProjectConversation("gamza")
        #expect(store.selectedThreadID == selected)
        #expect(store.composerDraft.text == "프로젝트 초안")
        #expect(store.threads.filter { $0.projectID == "gamza" }.count == 1)
        await #expect(throws: StallariError.wrongProject) {
            try await store.submit(.init(text: "다른 프로젝트", project: "knarr"))
        }
        #expect(store.chat.isEmpty)
    }

    @Test func projectCardsIncludeEveryOwnedIssueAndWorkRemainsThreadLocal() {
        let store = SampleKnarrStore(projectSessionScene: .withCards)
        let ids = store.topIssueCards.issues.map(\.id)
        let allProject = IssueCards(issues: store.issues(inProject: "gamza"), questions: store.questions,
                                    scope: .allProjects).issues.map(\.id)
        #expect(ids == allProject)
        #expect(!ids.isEmpty)
        #expect(!ids.contains { id in store.issues(inProject: "knarr").contains { $0.id == id } })
        #expect(store.topIssueCards.entries.contains { $0.id == "stallari-work" })
        let threadID = store.selectedThreadID
        store.selectThread(ConversationThread.defaultID)
        #expect(store.topIssueCards.issues.count > ids.count)
        #expect(!store.topIssueCards.entries.contains { $0.id == "stallari-work" })
        store.selectThread(threadID)
        #expect(store.topIssueCards.entries.contains { $0.id == "stallari-work" })
    }
}
