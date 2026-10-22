import Foundation
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite struct ProjectConversationRequestTests {
    @Test func requestSelectsOwnedProjectAndPreservesBothDraftsWithoutSending() {
        let store = SampleKnarrStore()
        store.composerDraft.text = "메인 초안"
        store.selectProjectConversation("gamza")
        store.composerDraft.text = "프로젝트 초안"
        let attachment = URL(fileURLWithPath: "/tmp/retained.md")
        store.composerDraft.attachments = [attachment]
        store.selectThread(ConversationThread.defaultID)
        #expect(ProjectConversationRequest.prepare(store: store, projectID: "gamza", text: "docs/design.md"))
        #expect(store.threads.first { $0.id == store.selectedThreadID }?.projectID == "gamza")
        #expect(store.composerDraft.text == "프로젝트 초안\n\ndocs/design.md")
        #expect(store.composerDraft.attachments == [attachment])
        #expect(!store.chat.contains { $0.kind == .user("docs/design.md") })
        store.selectThread(ConversationThread.defaultID)
        #expect(store.composerDraft.text == "메인 초안")
    }

    @Test func archivedOrMissingProjectCannotChangeSelectionOrDraft() {
        let store = SampleKnarrStore()
        store.composerDraft.text = "보존"
        #expect(!ProjectConversationRequest.prepare(store: store, projectID: "aquach", text: "요청"))
        #expect(!ProjectConversationRequest.prepare(store: store, projectID: "missing", text: "요청"))
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        #expect(store.composerDraft.text == "보존")
    }
}
