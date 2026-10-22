import Foundation
import Observation
import Testing
@testable import KnarrCore

/// Only the card projection is exercised; every other store call delegates to the sample store.
@MainActor @Observable private final class ProjectOwnedCardsStore: KnarrStore {
    private let base = SampleKnarrStore()
    let owned: [KnarrCore.Issue]
    let ownerThreads: [ConversationThread]
    let ownedQuestions: [Question]
    init(issues: [KnarrCore.Issue], threads: [ConversationThread], questions: [Question]) {
        owned = issues; ownerThreads = threads; ownedQuestions = questions
    }
    var stallari: StallariInfo { base.stallari }
    var subscriptionUsage: SubscriptionUsageModel { base.subscriptionUsage }
    var threads: [ConversationThread] { ownerThreads }
    var selectedThreadID: String { ConversationThread.defaultID }
    var conversationTabs: [ConversationThread] { ownerThreads }
    var chat: [ChatItem] { [] }
    var stallariWork: [SubagentWork] { [] }
    var isResponding: Bool { false }
    func isThreadWorking(_ threadID: String) -> Bool { threadBoundIssueIsWorking(threadID) }
    var streamingText: String { "" }
    var extensionPresentation: ExtensionPresentation { base.extensionPresentation }
    var projectSessionPolicy: ProjectSessionPolicy { base.projectSessionPolicy }
    var composerDraft: ChatDraft { get { ChatDraft() } set {} }
    var issues: [KnarrCore.Issue] { owned }
    var projects: [ProjectSummary] { [] }
    var models: [String] { [] }
    var model: String? { nil }
    var storageBytes: Int64? { nil }
    var questions: [Question] { ownedQuestions }
    func closeConversationTab(_ id: String) {}
    func createThread(name: String) {}
    func selectThread(_ id: String) {}
    func selectProjectConversation(_ projectID: String) {}
    func renameThread(_ id: String, to name: String) {}
    func goToThread(for issue: KnarrCore.Issue.ID) {}
    func dismissExtensionToast() {}
    func send(_ text: String, about: KnarrCore.Issue.ID?, project: String?, attachments: [URL]) {}
    func steer(_ text: String, issue: KnarrCore.Issue.ID) {}
    func perform(_ action: IssueAction, on issue: KnarrCore.Issue.ID) {}
    func answer(_ question: Question.ID, with answer: QuestionAnswer) {}
    func cancel(_ question: Question.ID) {}
    func addProject(path: String) {}
    func issues(inProject id: String) -> [KnarrCore.Issue] { owned }
    func inspectProject(_ id: String) async -> ProjectInspection {
        .init(readAt: .now, problem: "테스트")
    }
    func renameProject(_ id: String, to name: String) {}
    func setProjectArchived(_ id: String, _ archived: Bool) {}
    func updateProjectSettings(_ id: String, _ settings: ProjectSettings) {}
    func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {}
    func selectModel(_ model: String) {}
    func cleanFinishedWorkspaces() {}
}

@MainActor struct TopIssueCardsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mainConversationShowsProjectOwnedTodoReviewRunningAndAnswerNeeded() {
        func issue(_ id: String, state: IssueState, hirds: [HirdRun] = []) -> KnarrCore.Issue {
            var value = KnarrCore.Issue(id: .init(id), title: id, projectName: "Linked", state: state,
                                        headline: "", detail: "", acceptance: [], hirds: hirds, events: [], startedAt: now)
            value.threadID = "issue-" + id
            return value
        }
        let working = HirdRun(id: "run", name: "Hird", role: "", status: .working, steps: [],
                              currentCommand: nil, lastActivityAt: now)
        let waiting = HirdRun(id: "run", name: "Hird", role: "", status: .waitingOnHuman(since: now), steps: [],
                              currentCommand: nil, lastActivityAt: now)
        let project = ConversationThread(id: "project-thread", name: "Project", projectID: "linked")
        let owned = [issue("project-todo", state: .awaitingApproval),
                     issue("project-review", state: .failed),
                     issue("project-running", state: .running, hirds: [working]),
                     issue("project-question", state: .running, hirds: [waiting]),
                     issue("legacy", state: .awaitingApproval)]
        var archived = issue("project-archived", state: .awaitingApproval)
        archived.archivedAt = now
        var applied = issue("project-applied", state: .done)
        applied.application = .applied(branch: "main", commit: "abc")
        let threads = [ConversationThread.default, project] + owned.map {
            ConversationThread(id: $0.conversationThreadID, name: $0.title, issueID: $0.id, originThreadID: project.id)
        }
        let store = ProjectOwnedCardsStore(issues: owned + [archived, applied], threads: threads, questions: [])
        let cards = store.topIssueCards
        #expect(cards.issues.map(\.id.rawValue) == ["project-question", "legacy", "project-todo", "project-review", "project-running"])
        #expect(cards.answerCount == 1)
    }
}
