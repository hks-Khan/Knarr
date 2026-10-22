import AppKit
import Observation
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

/// A transcript whose KnarrCore.Issue cards and response state change in place, the way a running Hird changes them.
@MainActor @Observable final class ChangingCardsStore: KnarrStore {
    let stallari = StallariInfo(engine: "test", scope: "모든 프로젝트")
    private let threadStore = SampleKnarrStore()
    var threads: [ConversationThread] { threadStore.threads }
    var selectedThreadID: String { threadStore.selectedThreadID }
    var conversationTabs: [ConversationThread] { threadStore.conversationTabs }
    func closeConversationTab(_ id: String) { threadStore.closeConversationTab(id) }
    func createThread(name: String) { threadStore.createThread(name: name) }
    func selectThread(_ id: String) { threadStore.selectThread(id) }
    func selectProjectConversation(_ projectID: String) { threadStore.selectProjectConversation(projectID) }
    func renameThread(_ id: String, to name: String) { threadStore.renameThread(id, to: name) }
    func goToThread(for issue: KnarrCore.Issue.ID) { selectThread(ConversationThread.defaultID) }
    func isThreadWorking(_ threadID: String) -> Bool { isResponding && threadID == selectedThreadID }
    let subscriptionUsage = SubscriptionUsageModel(sample: true)
    var chat: [ChatItem] = []
    var stallariWork: [SubagentWork] { threadStore.stallariWork }
    var isResponding = false
    /// Conversations the canvas and collapsed cards read as running.
    var respondingRoots: Set<UUID> = []
    var respondingConversationRoots: Set<UUID> { respondingRoots }
    /// Canvas stop is allowed only for these; tests set them explicitly.
    var stoppableRoots: Set<UUID> = []
    /// Mirrors LiveConversation: a root whose reply is queued is never stoppable.
    var stoppableConversationRoots: Set<UUID> { stoppableRoots.subtracting(waitingRoots) }
    var waitingRoots: Set<UUID> = []
    var waitingConversationRoots: Set<UUID> { waitingRoots }
    /// Same rule as LiveConversation: a reason exists only for a running root that cannot be stopped.
    func stopBlockReason(for root: UUID) -> String? {
        guard isResponding, respondingRoots.contains(root), !stoppableConversationRoots.contains(root) else { return nil }
        if stopping { return "이미 응답을 중지하는 중이에요" }
        return "대기 중인 메시지가 있어 이 답변만 중지할 수 없어요"
    }
    var stopCalls = 0
    func stopResponse() { stopCalls += 1 }
    /// Viewport-reported reads, in order, so a WebKit test can assert what the page actually showed.
    var markedRead: [(ids: [UUID], thread: String)] = []
    func markAnswersRead(_ messageIDs: [UUID], threadID: String) {
        markedRead.append((messageIDs, threadID))
    }
    /// Mirrors the live store: the transcript re-checks visibility when activation advances.
    var appIsActive = true
    private(set) var activationRevision = 0
    func setAppActive(_ active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        if active { activationRevision += 1 }
    }
    var stopping = false
    var isStopping: Bool { stopping }
    var responseStatus = "응답 준비 중"
    var responseStartedAt: Date?
    var responseLastEventAt: Date?
    var extensionPresentation = ExtensionPresentation()
    func dismissExtensionToast() { extensionPresentation.toast = nil }
    var streamingText = ""
    var streamingMessageID: UUID?
    var issues: [KnarrCore.Issue] = []
    var submittedDrafts: [ChatDraft] = []
    var composerDraft = ChatDraft()
    var failSubmit = false
    /// Mirrors LiveConversation: true while a send is being admitted, with the draft in flight.
    var isSubmitting = false
    private(set) var sendingDraft: ChatDraft?
    /// Holds one submit open so a test can observe the UI while a send is still in flight.
    var whileSubmitting: (@MainActor () async -> Void)?
    func submit(_ draft: ChatDraft) async throws {
        isSubmitting = true; sendingDraft = draft
        defer { isSubmitting = false; sendingDraft = nil }
        await whileSubmitting?()
        if failSubmit { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "전송 실패 · 다시 보내 주세요"]) }
        submittedDrafts.append(draft)
    }
    func startMessageConversation(_ draft: ChatDraft) async throws -> UUID {
        guard !draft.isEmpty, draft.conversationRootID == nil else { throw StallariError.invalidArguments }
        try await submit(draft)
        var item = ChatItem(at: .now, kind: .user(draft.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        item.attachments = draft.attachments
        item.isConversationLink = true
        chat.append(item)
        if composerDraft == draft { composerDraft = .init(project: draft.project) }
        return item.id
    }
    func linkMessageConversation(_ id: UUID) async throws {
        guard let index = chat.firstIndex(where: { $0.id == id }),
              chat[index].conversationRootID == nil, chat[index].activity == nil,
              case .user = chat[index].kind else { throw StallariError.invalidArguments }
        chat[index].isConversationLink = true
    }
    var performed: [(IssueAction, KnarrCore.Issue.ID)] = []
    var workReports: [WorkReport] = []
    var workReportBusy = false
    var retriedReports: [String] = []
    func retryWorkReport(_ id: String?) {
        guard let id else { return }
        retriedReports.append(id)
        guard let index = workReports.firstIndex(where: { $0.id == id }) else { return }
        workReports[index].analysisState = .ready
        workReports[index].analysis = "다시 분석한 결과예요."
        workReports[index].analysisError = nil
    }
    let projects: [ProjectSummary] = []
    let projectSessionPolicy = ProjectSessionPolicy.current
    let models: [String] = []
    let model: String? = nil
    let storageBytes: Int64? = nil
    var questions: [Question] = []
    var failQuestionReply = false
    var questionAttempts = 0

    /// Long messages with one running card near the top and one as the latest item.
    init() {
        issues = [Self.card("above"), Self.card("below")]
        func message(_ i: Int) -> ChatItem {
            ChatItem(at: .now, kind: .user(String(format: "메시지 %02d ", i) + String(repeating: "카드 상태가 바뀌어도 읽던 자리가 그대로인지 보는 긴 문장입니다. ", count: 6)))
        }
        chat = (0..<2).map(message) + [ChatItem(at: .now, kind: .issue("above"))]
            + (2..<24).map(message) + [ChatItem(at: .now, kind: .issue("below"))]
    }

    static func card(_ id: KnarrCore.Issue.ID) -> KnarrCore.Issue {
        KnarrCore.Issue(id: id, title: "합성 작업 \(id.rawValue)", projectName: "테스트", state: .running, headline: "실행 중", detail: "",
              acceptance: [Criterion(text: "관련 테스트 통과", state: .pending, evidence: "")],
              hirds: [hird("\(id.rawValue)-1")], events: [], startedAt: .now)
    }
    static func hird(_ id: String) -> HirdRun {
        HirdRun(id: .init(id), name: "Hird", role: "고치고 확인", status: .working,
                steps: [.init(title: "수정", state: .done), .init(title: "테스트", state: .active)],
                currentCommand: "swift test --filter DialogueTests", lastActivityAt: .now)
    }
    func setCommand(_ command: String?, on id: KnarrCore.Issue.ID) {
        guard let i = issues.firstIndex(where: { $0.id == id }) else { return }
        for h in issues[i].hirds.indices { issues[i].hirds[h].currentCommand = command }
    }
    func addHird(to id: KnarrCore.Issue.ID) {
        guard let i = issues.firstIndex(where: { $0.id == id }) else { return }
        issues[i].hirds.append(Self.hird("\(id.rawValue)-\(issues[i].hirds.count + 1)"))
    }

    func send(_ text: String, about: KnarrCore.Issue.ID?, project: String?, attachments: [URL]) {}
    func steer(_ text: String, issue: KnarrCore.Issue.ID) {}
    func perform(_ action: IssueAction, on issue: KnarrCore.Issue.ID) { performed.append((action, issue)) }
    func reviewProposal(_ action: IssueAction, on issue: KnarrCore.Issue.ID, source: String) async throws { perform(action, on: issue) }
    func answer(_ question: Question.ID, with answer: QuestionAnswer) {}
    func cancel(_ question: Question.ID) {}
    func replyToQuestion(_ id: Question.ID, answer: QuestionAnswer?) async throws {
        questionAttempts += 1
        if failQuestionReply { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "전송 실패 · 다시 보내 주세요"]) }
        if let index = questions.firstIndex(where: { $0.id == id }) { questions[index].state = answer.map(Question.State.answered) ?? .cancelled }
    }
    func addProject(path: String) {}
    func issues(inProject id: String) -> [KnarrCore.Issue] { [] }
    func inspectProject(_ id: String) async -> ProjectInspection { .init(readAt: .now, problem: "테스트") }
    func renameProject(_ id: String, to name: String) {}
    func setProjectArchived(_ id: String, _ archived: Bool) {}
    func updateProjectSettings(_ id: String, _ settings: ProjectSettings) {}
    func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {}
    func selectModel(_ model: String) {}
    func cleanFinishedWorkspaces() {}
}
