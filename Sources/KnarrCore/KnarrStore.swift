import Foundation
import Observation

// The boundary between the screens (KnarrUI) and the runtime (storage, OMP RPC,
// Stallari host tools, Hird runs). Screens read these properties and call these
// methods only; a runtime implementation keeps them current.

/// What the user can do to a Issue from the conversation, the panel or the drawer.
public enum IssueAction: Sendable, Hashable {
    /// "확인했어": accept a finished result.
    case confirmResult
    /// Explicit user attestation; never exposed as a Stallari host tool.
    case confirmAppResult(note: String)
    case closeIssue(reason: IssueCloseReason)
    /// "다시 손봐줘": send a finished result back to Hird.
    case requestChanges(note: String)
    /// "로그인했어" and the like: the person fixed what Hird was waiting for.
    case resolvedInput
    /// A version captured from the issue the user actually reviewed.
    case approveProposal(version: Int)
    /// Persist the note and ask Stallari to revise; this never authorizes execution.
    case requestProposalChanges(version: Int, note: String)
    case rejectProposal(version: Int, note: String)
    /// Stop every Hird on the Issue.
    case stop
    /// "다시 시작": run a stopped Issue again with the same instruction, building on any preserved result.
    case resume
}

public struct ChatItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case day(String)
        case user(String)
        case stallari(String, project: String?)
        /// Live card for a Issue Stallari started; rendered from `KnarrStore.issues`.
        case issue(Issue.ID)
        /// One durable review position per proposal version; stale versions have no action buttons.
        case proposal(Issue.ID, version: Int)
        /// Stallari's routine checks, folded into one line.
        case autoCheck(summary: String, lines: [String])
        case notice(Notice)
        /// A question card, rendered live from `KnarrStore.questions` so it shows the answer once given.
        case question(Question.ID)
        /// A generated work report; rendered live from `KnarrStore.workReports` so a retry updates it.
        case report(String)
    }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var attachments: [URL] = []
    /// Provider-supplied progress, kept distinct from the assistant answer.
    public var activity: ChatActivity?
    public var conversationRootID: UUID?
    public var preparationID: String?
    public var isConversationLink = false

    public init(id: UUID = UUID(), at: Date, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }
}

public struct Notice: Sendable, Hashable {
    public enum Tone: Sendable, Hashable { case needsInput, failed, result }

    public var tone: Tone
    public var title: String
    public var body: String
    public var issue: Issue.ID
    /// The one-click answer, e.g. "로그인했어" → `.resolvedInput`.
    public var primary: Button?

    public struct Button: Sendable, Hashable {
        public var label: String
        public var action: IssueAction
        public init(_ label: String, _ action: IssueAction) {
            self.label = label
            self.action = action
        }
    }

    public init(tone: Tone, title: String, body: String, issue: Issue.ID, primary: Button?) {
        self.tone = tone
        self.title = title
        self.body = body
        self.issue = issue
        self.primary = primary
    }
}

/// No synthetic Issue/Hird: an extension answer belongs to the original RPC generation.
public struct StallariDialogIdentity: Sendable, Hashable {
    public let threadID: String
    public let sessionID: String
    public let rpcGeneration: String
    public let rpcID: String
    public init(threadID: String, sessionID: String, rpcGeneration: String, rpcID: String) {
        self.threadID = threadID; self.sessionID = sessionID; self.rpcGeneration = rpcGeneration; self.rpcID = rpcID
    }
}
public struct ExtensionPresentation: Sendable, Hashable {
    public var statuses: [String: String] = [:]
    public var widgets: [String: [String]] = [:]
    public var toast: Toast?
    public var isReloading = false
    public init() {}
    public struct Toast: Sendable, Hashable, Identifiable {
        public let id: UUID
        public let message: String
        public let tone: String
        public init(message: String, tone: String) { self.id = UUID(); self.message = message; self.tone = tone }
    }
}

/// Something Hird or Stallari is waiting on the person to answer (OMP `ask_user`).
/// Maps to the stored `PersistedQuestion`; the reply is a `QuestionAnswer`.
public struct Question: Identifiable, Sendable, Hashable {
    public struct ID: Hashable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    public enum State: Sendable, Hashable {
        case pending
        case answered(QuestionAnswer)
        case cancelled
        /// Stored pending question whose original execution cannot receive an answer anymore.
        case unavailable
    }

    public var id: ID
    public var issue: Issue.ID?
    public var run: HirdRun.ID?
    public enum ReplyStyle: String, Sendable, Hashable { case select, confirm, input, editor }
    public var replyStyle: ReplyStyle?
    public var placeholder: String?
    public var prefill: String?
    public var extensionIdentity: StallariDialogIdentity?
    /// Who asked, e.g. "Hird-2" or "Stallari".
    public var asker: String
    public var prompt: String
    /// Empty when only a typed answer makes sense.
    public var options: [String]
    public var allowsMultiple: Bool
    public var askedAt: Date
    public var state: State

    public init(id: ID, issue: Issue.ID, run: HirdRun.ID, asker: String, prompt: String, options: [String],
                allowsMultiple: Bool = false, askedAt: Date, state: State = .pending) {
        self.id = id
        self.issue = issue
        self.run = run
        self.asker = asker
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.askedAt = askedAt
        self.state = state
    }

    public init(id: ID, identity: StallariDialogIdentity, prompt: String, options: [String], replyStyle: ReplyStyle,
                placeholder: String? = nil, prefill: String? = nil, askedAt: Date, state: State = .pending) {
        self.id = id; issue = nil; run = nil; asker = "Stallari"
        self.extensionIdentity = identity; self.replyStyle = replyStyle
        self.placeholder = placeholder; self.prefill = prefill
        self.prompt = prompt; self.options = options; allowsMultiple = false; self.askedAt = askedAt; self.state = state
    }

    public var isPending: Bool { state == .pending }
}

/// A project Stallari manages, for the composer's picker and the project list.
public struct ProjectSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var path: String
    /// Open todo, in-progress and review issues; applied results and closures do not require attention.
    public var openIssues: Int
    /// Off the list: Stallari takes no new work here. Folder and history stay.
    public var archived: Bool
    public var settings: ProjectSettings

    public init(id: String, name: String, path: String, openIssues: Int, archived: Bool = false, settings: ProjectSettings = .init()) {
        self.id = id
        self.name = name
        self.path = path
        self.openIssues = openIssues
        self.archived = archived
        self.settings = settings
    }
}

public struct StallariInfo: Sendable, Hashable {
    /// e.g. "OMP · opus"
    public var engine: String
    public var scope: String

    public init(engine: String, scope: String) {
        self.engine = engine
        self.scope = scope
    }
}

@MainActor
public protocol KnarrStore: AnyObject, Observable {
    var stallari: StallariInfo { get }
    /// Native notification availability; sample/mobile stores need no OS center.
    var desktopNotificationStatus: DesktopNotificationStatus { get }
    /// App-owned credential controls only; provider keys never cross the tool boundary.
    var hiveConnection: HiveConnection? { get }
    /// Reloads the actual provider catalog without changing selected models or projects.
    func refreshHiveProvider() async throws
    /// An explicit real provider probe, reflected by `hiveConnection.status`.
    func verifyHiveConnection() async
    /// Explicit notification navigation also leaves project/history/settings surfaces.
    var notificationNavigationRevision: Int { get }
    var threads: [ConversationThread] { get }
    var selectedThreadID: String { get }
    var conversationTabs: [ConversationThread] { get }
    func closeConversationTab(_ id: String)
    func createThread(name: String)
    func selectThread(_ id: String)
    /// Selects a project surface without starting RPC or saving a thread until the first message.
    func selectProjectConversation(_ projectID: String)
    func renameThread(_ id: String, to name: String)
    func goToThread(for issue: Issue.ID)
    var chat: [ChatItem] { get }
    /// Messages of every conversation, so the phone's thread list can show what each one holds.
    /// The selected conversation stays `chat`; stores that keep only one conversation return it under its own id.
    var chatByThread: [String: [ChatItem]] { get }
    /// Active children of the selected Stallari conversation; memory-only, never aggregated across tabs.
    var stallariWork: [SubagentWork] { get }
    /// Ephemeral response state, including submission, first-token wait and tool execution.
    var isResponding: Bool { get }
    /// Roots whose focused conversation is waiting for or receiving its answer, so a canvas can show
    /// `응답 중` for that root only. Empty when the store cannot scope responses by root.
    var respondingConversationRoots: Set<UUID> { get }
    /// Roots whose own answer is the one in flight and whose stop would not discard another draft.
    /// A canvas stop must use this narrower set; `stopResponse()` aborts the single shared prompt.
    var stoppableConversationRoots: Set<UUID> { get }
    /// Roots whose reply is queued behind someone else's answer; their canvas shows waiting, not stop.
    var waitingConversationRoots: Set<UUID> { get }
    /// Why a canvas for this root cannot stop its answer, when it is answering but not stoppable.
    func stopBlockReason(for root: UUID) -> String?
    /// True while this thread's Stallari conversation is responding, sending or waiting to send,
    /// or while a Hird bound to the thread's issue is running or waiting on the person.
    func isThreadWorking(_ threadID: String) -> Bool
    /// Assistant answers this tab has not shown the person yet. Only the main conversation and
    /// project conversations count; issue conversations and focused answers stay out.
    func unreadAnswerCount(forThread threadID: String) -> Int
    /// Records answers the person actually saw in the viewport while the app was active. Selecting
    /// a tab never marks anything; an inactive app or a scrolled-away transcript keeps the count.
    func markAnswersRead(_ messageIDs: [UUID], threadID: String)
    /// Whether the app is frontmost; a background arrival stays unread until the answer is shown.
    var appIsActive: Bool { get }
    /// Advances when the transcript must re-check viewport visibility; 0 means never asked.
    var activationRevision: Int { get }
    /// Current assistant text; committed chat replaces it at message_end.
    var streamingText: String { get }
    var streamingMessageID: UUID? { get }
    /// Display-only interpolation for the current assistant row; never used for chat persistence.
    var streamingPresentation: StreamingTextPresentation? { get }
    var thinkingLevel: String? { get }
    var thinkingLevels: [String] { get }
    var contextUsage: ContextUsage? { get }
    /// Shared menu-bar/header quota state. No engine types or provider credentials cross the UI boundary.
    var subscriptionUsage: SubscriptionUsageModel { get }
    /// Builds and installs a newer main automatically. Default: on.
    var autoInstallEnabled: Bool { get }
    func setAutoInstall(_ enabled: Bool)
    /// Native secondary composers report unsent input and in-flight submission synchronously.
    func setAuxiliaryComposerBusy(_ id: UUID, busy: Bool)
    /// Short one-line state for Settings; nil when the runtime has nothing to say.
    var autoInstallStatus: String? { get }
    /// Wording and limits for the automatic install row; never duplicated as UI literals.
    var autoInstallPolicy: AutoInstallPolicy { get }
    var responseStatus: String { get }
    var responseStartedAt: Date? { get }
    var responseLastEventAt: Date? { get }
    var extensionPresentation: ExtensionPresentation { get }
    func dismissExtensionToast()
    var isStopping: Bool { get }
    var isSubmitting: Bool { get }
    /// The draft being sent right now, so the composer can show progress and ignore repeat sends.
    var sendingDraft: ChatDraft? { get }
    /// True while a submitted draft waits behind a running answer instead of being sent yet.
    var isSubmissionWaiting: Bool { get }
    /// How main input sent during an answer is delivered; shared by every conversation. Default: steer.
    var whileRespondingMode: WhileRespondingMode { get }
    /// Switching to steer sends waiting main input into the running answer right away.
    func setWhileRespondingMode(_ mode: WhileRespondingMode)
    var failedDraft: ChatDraft? { get }
    var assistantPersistenceError: String? { get }
    var isRetryingAssistantPersistence: Bool { get }
    func retryAssistantPersistence() async
    var projectTransfers: [ProjectTransfer] { get }
    func transferToMain(summary: String, requestMessageID: UUID, messageIDs: [UUID]) async throws -> ProjectTransfer
    func retryProjectTransfer(_ id: String) async throws
    var composerDraft: ChatDraft { get set }
    func submit(_ draft: ChatDraft) async throws
    /// Persists and links one user source, then returns its identity after RPC admission.
    func startMessageConversation(_ draft: ChatDraft) async throws -> UUID
    /// Called once the durable source is available, even while its send waits behind another response.
    func startMessageConversation(_ draft: ChatDraft, onCreated: @escaping @MainActor (UUID) -> Void) async throws -> UUID
    /// Turns an existing user message in the selected thread into a conversation link.
    func linkMessageConversation(_ id: UUID) async throws
    func stopResponse()
    func selectThinking(_ level: String)
    var requestedModel: String? { get }
    var pendingModel: String? { get }
    var responseRulesPath: String? { get }
    var responseRulesText: String { get }
    func reloadResponseRules()
    func saveResponseRules(_ text: String)
    /// User-owned AGENTS.md/RULES.md hierarchy shared by Stallari and Hird.
    var instructionSources: [InstructionSource] { get }
    func reloadInstructionSources()
    /// Atomic, hash-checked save shared by the settings screen and the chat tool.
    @discardableResult
    func saveInstructionSource(role: InstructionRole, kind: InstructionKind, projectID: String?, text: String, expectedHash: String) async throws -> InstructionSource
    var issues: [Issue] { get }
    /// Every project Stallari manages.
    var projects: [ProjectSummary] { get }
    var projectSessionPolicy: ProjectSessionPolicy { get }
    /// Models Stallari and Hird may use, as `provider/id`, from OMP's actual available catalog.
    var models: [String] { get }
    /// The model in use now.
    var workReports: [WorkReport] { get }
    var workReportError: String? { get }
    var workReportBusy: Bool { get }
    func cancelWorkReportAnalysis()
    func retryWorkReport(_ id: String?)
    var model: String? { get }
    /// External helper handoff; the implementation rejects active Hird runs.
    func installAndRestart(_ issue: Issue.ID)
    var installationBlockReason: String? { get }
    func approvalBlockReason(for issue: Issue.ID) -> String?
    func resultReport(_ issue: Issue.ID) async -> String
    /// Bytes held by Hird work copies, when known.
    var storageBytes: Int64? { get }
    /// Recent questions, answered and cancelled ones included so cards can show what was decided.
    var questions: [Question] { get }

    /// A message to Stallari. `about` attaches a Issue as context ("Stallari에게 묻기");
    /// `project` is the project picked in the composer, nil for all projects.
    /// Images in `attachments` go to Stallari with the message; other files go as paths.
    func send(_ text: String, about: Issue.ID?, project: String?, attachments: [URL])
    /// Sends to one named conversation without switching what the Mac shows. The thread may be the
    /// main, a project, or an Issue conversation; a missing thread is an error, never a fallback.
    func sendToThread(_ thread: String, text: String, project: String?, attachments: [URL]) async throws
    /// A note passed straight to the Hird working on a Issue (OMP `steer`).
    func steer(_ text: String, issue: Issue.ID)
    func perform(_ action: IssueAction, on issue: Issue.ID)
    /// Await durable proposal review before acknowledging a queued phone request.
    func reviewProposal(_ action: IssueAction, on issue: Issue.ID, source: String) async throws
    /// Answer one specific question. Answering an already resolved question does nothing.
    func answer(_ question: Question.ID, with answer: QuestionAnswer)
    /// Close a question without answering; the asker is told it was cancelled.
    func cancel(_ question: Question.ID)
    /// Wait for the question response before releasing the interactive submission lock.
    func replyToQuestion(_ question: Question.ID, answer: QuestionAnswer?) async throws
    /// Register a folder as a project Stallari can work in. A folder already registered comes back
    /// onto the list with its name and settings.
    func addProject(path: String)
    /// Issues filed under one project.
    func issues(inProject id: String) -> [Issue]
    /// Reads the project folder (Git state, AGENTS.md) once. Never polled.
    func inspectProject(_ id: String) async -> ProjectInspection
    /// Reads saved Hird results not yet included in the project's main branch. Never merges.
    func inspectProjectMergeResults(_ id: String) async -> ProjectMergeResults
    /// A blank name is ignored.
    func renameProject(_ id: String, to name: String)
    /// Archiving stops the project's running Hirds; Stallari takes no new work there until it is restored.
    func setProjectArchived(_ id: String, _ archived: Bool)
    func updateProjectSettings(_ id: String, _ settings: ProjectSettings)
    var preparationItems: [PreparationItem] { get }
    var preparationSourceIDs: Set<Issue.ID> { get }
    func selectedPreparationID(inProject id: String) -> String?
    func selectPreparation(_ itemID: String?, inProject id: String)
    @discardableResult func savePreparation(id: String, projectID: String, fields: PreparationItem.Fields, expectedRevision: Int, sourceIssueID: Issue.ID?) async throws -> PreparationItem
    @discardableResult func savePreparationDraft(itemID: String, projectID: String, expectedRevision: Int, documentID: String, title: String, text: String, kind: PreparationItem.Draft.Kind) async throws -> PreparationItem
    @discardableResult func addPreparationRecord(itemID: String, projectID: String, expectedRevision: Int, text: String, submission: PreparationItem.Submission?) async throws -> PreparationItem
    /// Planned stages for one project, ordered by `order`. Completion is only what was
    /// explicitly verified, never derived from the project's issues.
    func milestones(inProject id: String) -> [Milestone]
    func milestone(_ id: Milestone.ID) -> Milestone?
    /// Saves a new or edited milestone. Weekly history is append-only; the store rejects cycles,
    /// cross-project prerequisites and unverified reached state.
    func saveMilestone(_ milestone: Milestone)
    /// Applies a complete order for one project's milestones.
    func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID])
    /// Deletes a milestone no issue or other milestone refers to.
    func deleteMilestone(_ id: Milestone.ID)
    /// The project's weekly plans, oldest first. Only the server's current week may be saved;
    /// earlier weeks stay as history.
    func weekPlans(inProject id: String) -> [ProjectWeekPlan]
    /// Saves this week's plan for one project. Past weeks and archived projects are rejected.
    func saveWeekPlan(_ plan: ProjectWeekPlan)
    /// Writes the repository's AGENTS.md and commits only that file.
    /// - Parameter expected: the text the edit started from, nil when there was no file. A file
    ///   changed in between is not overwritten (`ProjectGitError.changedOnDisk`).
    func saveAgentsFile(_ id: String, text: String, expected: String?) async throws
    /// Switch only Stallari; Hird defaults and saved proposals are independent.
    func selectModel(_ model: String)
    /// Remove Hird work copies nobody needs any more (merged, superseded or stopped).
    func cleanFinishedWorkspaces()
}

extension KnarrStore {
    /// Whether the app is frontmost; a background arrival stays unread until the answer is shown.
    public var appIsActive: Bool { true }
    /// Advances when the transcript must re-check viewport visibility; 0 means never asked.
    public var activationRevision: Int { 0 }
    /// Stores without a read ledger keep no tab badge.
    public func unreadAnswerCount(forThread threadID: String) -> Int { 0 }
    public func markAnswersRead(_ messageIDs: [UUID], threadID: String) {}
}

extension KnarrStore {
    /// The most recent app-owned failure for the selected conversation, when the store keeps one.
    /// The detail panel shows it so a refused command explains itself on screen.
    public var lastError: String? { nil }
    public func setAuxiliaryComposerBusy(_ id: UUID, busy: Bool) {}
    public var autoInstallEnabled: Bool { true }
    public func setAutoInstall(_ enabled: Bool) {}
    public var autoInstallStatus: String? { nil }
    public var autoInstallPolicy: AutoInstallPolicy { .current }
    public var responseStartedAt: Date? { nil }
    public var responseLastEventAt: Date? { nil }
    public func replyToQuestion(_ question: Question.ID, answer: QuestionAnswer?) async throws {
        if let answer { self.answer(question, with: answer) } else { cancel(question) }
    }

    public var desktopNotificationStatus: DesktopNotificationStatus { .unavailable }
    public var hiveConnection: HiveConnection? { nil }
    public func refreshHiveProvider() async throws { throw HiveConnectionError.unsupported }
    public func verifyHiveConnection() async {
        await hiveConnection?.verify { throw HiveConnectionError.unsupported }
    }
    public var notificationNavigationRevision: Int { 0 }
    public var streamingMessageID: UUID? { nil }
    public var streamingPresentation: StreamingTextPresentation? { nil }
    public var thinkingLevel: String? { nil }
    public var thinkingLevels: [String] { [] }
    public var contextUsage: ContextUsage? { nil }
    public var responseStatus: String { "응답 준비 중" }
    public var isStopping: Bool { false }
    public var isSubmitting: Bool { false }
    public var sendingDraft: ChatDraft? { nil }
    public var isSubmissionWaiting: Bool { false }
    public var whileRespondingMode: WhileRespondingMode { .steer }
    public func setWhileRespondingMode(_ mode: WhileRespondingMode) {}
    public var failedDraft: ChatDraft? { nil }
    public var assistantPersistenceError: String? { nil }
    public var isRetryingAssistantPersistence: Bool { false }
    public func retryAssistantPersistence() async {}
    public var projectTransfers: [ProjectTransfer] { [] }
    public func transferToMain(summary: String, requestMessageID: UUID, messageIDs: [UUID]) async throws -> ProjectTransfer {
        throw StallariError.rejectedEvidence("이 앱은 프로젝트→메인 영속 전달 bridge v1을 지원하지 않아요.")
    }
    public func retryProjectTransfer(_ id: String) async throws {
        throw StallariError.rejectedEvidence("이 앱은 프로젝트→메인 영속 전달 bridge v1을 지원하지 않아요.")
    }
    public var composerDraft: ChatDraft { get { .init() } set {} }
    public func submit(_ draft: ChatDraft) async throws { send(draft.text, about: nil, project: draft.project, attachments: draft.attachments) }
    public func startMessageConversation(_ draft: ChatDraft) async throws -> UUID {
        throw StallariError.rejectedEvidence("이 대화에서는 새 메시지 대화를 시작할 수 없어요.")
    }
    public func startMessageConversation(_ draft: ChatDraft, onCreated: @escaping @MainActor (UUID) -> Void) async throws -> UUID {
        let id = try await startMessageConversation(draft)
        onCreated(id)
        return id
    }
    public func linkMessageConversation(_ id: UUID) async throws {
        throw StallariError.rejectedEvidence("이 대화에서는 메시지 대화를 열 수 없어요.")
    }
    public func reviewProposal(_ action: IssueAction, on issue: Issue.ID, source: String) async throws {
        throw StallariError.rejectedEvidence("이 store는 제안 승인을 처리할 수 없어요")
    }
    public func stopResponse() {}
    public func selectThinking(_ level: String) {}
    public var requestedModel: String? { nil }
    public var pendingModel: String? { nil }
    public var responseRulesPath: String? { nil }
    public var responseRulesText: String { "" }
    public func reloadResponseRules() {}
    public func saveResponseRules(_ text: String) {}
    public var instructionSources: [InstructionSource] { [] }
    public func reloadInstructionSources() {}
    public func saveInstructionSource(role: InstructionRole, kind: InstructionKind, projectID: String?, text: String, expectedHash: String) async throws -> InstructionSource {
        throw StallariError.invalidArguments
    }
    public var chatByThread: [String: [ChatItem]] { [selectedThreadID: chat] }
    public func sendToThread(_ thread: String, text: String, project: String?, attachments: [URL]) async throws {
        guard thread == selectedThreadID else { throw StallariError.closed }
        try await submit(.init(text: text, attachments: attachments, project: project))
    }
    public func send(_ text: String, about: Issue.ID?) { send(text, about: about, project: nil, attachments: []) }
    public func send(_ text: String, about: Issue.ID?, project: String?) { send(text, about: about, project: project, attachments: []) }
    public func issue(_ id: Issue.ID) -> Issue? { issues.first { $0.id == id } }
    public func project(_ id: String) -> ProjectSummary? { projects.first { $0.id == id } }
    public func milestones(inProject id: String) -> [Milestone] { milestones.filter { $0.projectID == id } }
    public func milestone(_ id: Milestone.ID) -> Milestone? { milestones.first { $0.id == id } }
    public func saveMilestone(_ milestone: Milestone) {}
    public func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID]) {}
    public func deleteMilestone(_ id: Milestone.ID) {}
    public var milestones: [Milestone] { [] }
    public func weekPlans(inProject id: String) -> [ProjectWeekPlan] { weekPlans.filter { $0.projectID == id }.sorted { $0.weekStart < $1.weekStart } }
    public func saveWeekPlan(_ plan: ProjectWeekPlan) {}
    public var weekPlans: [ProjectWeekPlan] { [] }
    public func inspectProjectMergeResults(_ id: String) async -> ProjectMergeResults {
        guard let project = project(id) else { return .init(results: [], problem: "프로젝트를 찾지 못했어요") }
        return await ProjectMergeResults.read(root: URL(fileURLWithPath: project.path, isDirectory: true),
                                              issues: issues(inProject: id))
    }
    public func question(_ id: Question.ID) -> Question? { questions.first { $0.id == id } }
    public func pendingQuestions(for issue: Issue.ID) -> [Question] {
        questions.filter { $0.issue == issue && $0.isPending }
    }
    /// The issue owns this thread either through its own conversation binding or the tab's
    /// `issueID`; a running Hird or a pending question on it keeps the tab working.
    func threadBoundIssueIsWorking(_ threadID: String) -> Bool {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
        let ids = Set(issues.filter { $0.conversationThreadID == threadID }.map(\.id) + [thread.issueID].compactMap { $0 })
        return issues.contains { ids.contains($0.id) && ($0.hasActiveHird || !pendingQuestions(for: $0.id).isEmpty) }
    }
}

extension KnarrStore {
    public var installationBlockReason: String? {
        issues.contains(where: \.hasActiveHird) ? LiveKnarrError.installBusy.localizedDescription : nil
    }
    public func approvalBlockReason(for issue: Issue.ID) -> String? {
        guard let owner = projects.first(where: { issues(inProject: $0.id).contains { $0.id == issue } }) else { return nil }
        let active = issues(inProject: owner.id).filter(\.hasActiveHird).count
        return owner.settings.allowsAdditionalHird(activeCount: active) ? nil : "동시 Hird 실행 한도 \(active)/\(owner.settings.maxHirds) · 진행 중인 실행이 끝난 뒤 승인해 주세요"
    }
    public func installAndRestart(_ issue: Issue.ID) {
        send("이 저장소에서는 앱 설치를 실행할 수 없어요.", about: issue, project: nil, attachments: [])
    }
    public func resultReport(_ issue: Issue.ID) async -> String {
        self.issue(issue)?.detail ?? "저장된 보고서가 없어요"
    }
}

extension KnarrStore {
    public var workReports: [WorkReport] { [] }
    public var workReportError: String? { nil }
    public var workReportBusy: Bool { false }
    public var respondingConversationRoots: Set<UUID> { [] }
    public var stoppableConversationRoots: Set<UUID> { [] }
    public var waitingConversationRoots: Set<UUID> { [] }
    /// The default store cannot scope a stop at all, so it never offers one.
    public func stopBlockReason(for root: UUID) -> String? { "이 응답은 대화별로 중지할 수 없어요" }
    public func cancelWorkReportAnalysis() {}
    public func retryWorkReport(_ id: String?) {}
}


extension KnarrStore {
    public var preparationItems: [PreparationItem] { [] }
    public var preparationSourceIDs: Set<Issue.ID> { Set(preparationItems.compactMap(\.sourceIssueID)) }
    public func preparationItems(inProject id: String) -> [PreparationItem] { PreparationItem.ordered(preparationItems.filter { $0.projectID == id }) }
    public func executionIssues(inProject id: String) -> [Issue] { issues(inProject: id).filter { !preparationSourceIDs.contains($0.id) } }
    public func selectedPreparationID(inProject id: String) -> String? { nil }
    public func selectPreparation(_ itemID: String?, inProject id: String) {}
    @discardableResult public func savePreparation(id: String, projectID: String, fields: PreparationItem.Fields, expectedRevision: Int, sourceIssueID: Issue.ID?) async throws -> PreparationItem { throw StallariError.closed }
    @discardableResult public func savePreparationDraft(itemID: String, projectID: String, expectedRevision: Int, documentID: String, title: String, text: String, kind: PreparationItem.Draft.Kind) async throws -> PreparationItem { throw StallariError.closed }
    @discardableResult public func addPreparationRecord(itemID: String, projectID: String, expectedRevision: Int, text: String, submission: PreparationItem.Submission?) async throws -> PreparationItem { throw StallariError.closed }
}
