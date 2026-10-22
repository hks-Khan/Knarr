import Foundation
import Observation

/// One thread's transcript, drafts and response lifecycle. Selection never mutates this state.
@MainActor @Observable
final class LiveConversation {
    @ObservationIgnored private let subscriptionUsage: SubscriptionUsageModel?
    let threadID: String
    public private(set) var stallari = StallariInfo(engine: "OMP · 연결 전", scope: "모든 프로젝트")
    public private(set) var chat: [ChatItem] = []
    private var subagents = OMPSubagentActivity()
    public var stallariWork: [SubagentWork] { subagents.active }
    @ObservationIgnored private var acceptsSubagentEvents = true
    public var isResponding: Bool { !pendingResponses.isEmpty || agentResponding }
    /// Any work this thread owns: an answer, admission, or a send queued behind an answer.
    var isWorking: Bool { isResponding || isSubmitting || isSubmissionWaiting }
    public private(set) var streamingText = ""
    public private(set) var streamingMessageID: UUID?
    let streamingPresentation = StreamingTextPresentation()
    public private(set) var responseRulesPath: String?
    public private(set) var responseRulesText = ""
    public private(set) var thinkingLevel: String?
    public private(set) var thinkingLevels: [String] = []
    public private(set) var contextUsage: ContextUsage?
    public private(set) var responseStatus = "응답 준비 중"
    public private(set) var responseStartedAt: Date?
    public private(set) var responseLastEventAt: Date?
    public private(set) var isStopping = false
    public private(set) var isSubmitting = false
    private var isClearingContext = false
    public private(set) var failedDraft: ChatDraft?
    public private(set) var assistantPersistenceError: String?
    public private(set) var isRetryingAssistantPersistence = false
    public var composerDraft = ChatDraft() {
        didSet {
            if let data = try? JSONEncoder().encode(composerDraft) { preferences.set(data, forKey: draftKey) }
            if composerDraft.isEmpty != oldValue.isEmpty { onStateChange?() }
        }
    }
    @ObservationIgnored private var stoppingTask: Task<Void, Never>?
    /// Notifies the store when a wait condition for auto install may have just changed.
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?
    /// Notifies the store when this conversation's rows changed, so only its tab is recounted.
    @ObservationIgnored var onChatChange: (@MainActor () -> Void)?
    /// True once at least one durable snapshot has been applied, so an empty transcript means
    /// "no history" rather than "history not loaded yet".
    @ObservationIgnored var hasLoadedHistory = false
    /// True while this thread would be interrupted by a restart.
    var isBusyForInstall: Bool { isResponding || isSubmitting || !pendingSubmissions.isEmpty || !assistantPersistenceTasks.isEmpty }
    @ObservationIgnored private var admittingDraft: ChatDraft?
    @ObservationIgnored private var admittingConversationRootID: UUID?
    @ObservationIgnored private var responseFailure: String?
    @ObservationIgnored private var submittedDrafts: [String: ChatDraft] = [:]
    @ObservationIgnored private var submittedConversationRoots: [String: UUID] = [:]
    @ObservationIgnored private var submissionGeneration = 0
    @ObservationIgnored private var levelsModel: String?
    public private(set) var requestedModel: String?
    public private(set) var pendingModel: String?
    @ObservationIgnored private var responseRules: ResponseRulesFile?
    @ObservationIgnored private var instructionDataDirectory: URL?
    @ObservationIgnored private var instructionProjectID: String?
    public private(set) var instructionSources: [InstructionSource] = []
    @ObservationIgnored private var assistantMessages: [AssistantMessageKey: AssistantDraft] = [:]
    @ObservationIgnored private var completedMessages: Set<AssistantMessageKey> = []
    @ObservationIgnored private var assistantPersistenceTasks: [AssistantMessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedAssistantMessages: Set<AssistantMessageKey> = []
    @ObservationIgnored private var assistantGeneration = 0
    @ObservationIgnored private var assistantRefreshFailed = false
    @ObservationIgnored private var pendingStream: AssistantDraft?
    @ObservationIgnored private var streamFlush: Task<Void, Never>?
    @ObservationIgnored private var lastStreamPaint: TimeInterval = 0
    private struct AssistantMessageKey: Hashable {
        let generation: Int
        let messageID: String
        var segment = "text"
    }
    private final class AssistantDraft {
        let id = UUID()
        var at = Date()
        var blocks: [Int: String] = [:]
        var isTerminal = false
        var activity: ChatActivity?
        var conversationRootID: UUID?
        init(activity: ChatActivity? = nil) { self.activity = activity }
        var text: String { blocks.keys.sorted().compactMap { blocks[$0] }.joined(separator: "\n") }
        var item: ChatItem {
            var item = ChatItem(id: id, at: at, kind: .stallari(text, project: nil))
            item.activity = activity
            item.conversationRootID = conversationRootID
            return item
        }
    }
    private struct PreparedSubmission: Sendable {
        let itemID: UUID
        let message: String
        let projectID: String
        let images: [OMPJSON]
        let preparationID: String?
    }
    private struct PendingSubmission {
        let draft: ChatDraft
        let about: Issue.ID?
        let newRootID: UUID?
        let preparation: Task<PreparedSubmission, Error>?
        let completion: @MainActor (Result<Void, Error>) -> Void
        let startedAt: Date
    }
    private var pendingSubmissions: [PendingSubmission] = []
    /// The draft currently being admitted to the session, or waiting for its turn.
    public private(set) var sendingDraft: ChatDraft?
    /// True while a submitted draft sits in the queue behind an answer in progress.
    public private(set) var isSubmissionWaiting = false
    /// Test seam: runs inside the admission task before the message reaches the session.
    @ObservationIgnored var submissionHook: (@MainActor () async -> Void)?
    private func admitNextPending() {
        guard !closing, !isStopping, !isSubmitting, !isResponding, !pendingSubmissions.isEmpty else { return }
        let next = pendingSubmissions.removeFirst()
        if pendingSubmissions.isEmpty { isSubmissionWaiting = false }
        queueSubmission(next.draft, about: next.about, newRootID: next.newRootID,
                        preparation: next.preparation, sentAt: next.startedAt, completion: next.completion)
    }
    var whileRespondingMode: WhileRespondingMode { .init(preferences: preferences) }
    /// Main input steers a running main answer. Message-conversation input, a new root, queue mode
    /// and an answer that belongs to a message conversation all wait until the answer ends.
    private func mustWait(_ draft: ChatDraft, newRootID: UUID?) -> Bool {
        newRootID != nil || draft.conversationRootID != nil || whileRespondingMode == .queue
            || admittingConversationRootID != nil || !submittedConversationRoots.isEmpty
    }
    /// Switching to steer sends the main input at the front of the queue into the running answer now.
    /// Anything behind a waiting message-conversation send keeps its place.
    func whileRespondingModeChanged() {
        guard !closing, !isStopping, whileRespondingMode == .steer else { return }
        let ready = Array(pendingSubmissions.prefix { !mustWait($0.draft, newRootID: $0.newRootID) })
        guard !ready.isEmpty else { return }
        pendingSubmissions.removeFirst(ready.count)
        isSubmissionWaiting = !pendingSubmissions.isEmpty
        for next in ready {
            queueSubmission(next.draft, about: next.about, preparation: next.preparation, sentAt: next.startedAt, completion: next.completion)
        }
        onStateChange?()
    }
    private func cancelWaitingMessages() {
        let waiting = pendingSubmissions; pendingSubmissions.removeAll()
        isSubmissionWaiting = false; sendingDraft = nil
        for message in waiting {
            message.preparation?.cancel()
            message.completion(.failure(CancellationError()))
        }
    }
    private var pendingResponses: Set<UUID> = []
    /// Roots of the answer that is actually in flight, before any queued draft is admitted.
    private var runningConversationRoots: Set<UUID> {
        var roots = Set(submittedConversationRoots.values)
        if let admittingConversationRootID { roots.insert(admittingConversationRootID) }
        if let root = admittingDraft?.conversationRootID { roots.insert(root) }
        if let root = sendingDraft?.conversationRootID { roots.insert(root) }
        return roots
    }
    /// Roots the person's focused conversation is answering or waiting behind, for in-transcript canvases.
    var respondingConversationRoots: Set<UUID> {
        var roots = runningConversationRoots
        roots.formUnion(waitingConversationRoots)
        return roots
    }
    /// Roots whose own send sits in the queue behind the answer in flight.
    var waitingConversationRoots: Set<UUID> {
        Set(pendingSubmissions.compactMap { $0.draft.conversationRootID ?? $0.newRootID })
    }
    /// Only the answer in flight can be aborted, and `stopResponse()` also drops every queued draft.
    /// A canvas may stop a root only when that answer is this root's and nothing else is waiting.
    var stoppableConversationRoots: Set<UUID> {
        guard isResponding, !isStopping, pendingSubmissions.isEmpty else { return [] }
        return runningConversationRoots
    }
    /// A canvas stop aborts the one shared prompt, so it is offered only when nothing else is queued.
    func stopBlockReason(for root: UUID) -> String? {
        guard isResponding, respondingConversationRoots.contains(root), !stoppableConversationRoots.contains(root) else { return nil }
        if isStopping { return "이미 응답을 중지하는 중이에요" }
        return "대기 중인 메시지가 있어 이 답변만 중지할 수 없어요"
    }
    private var agentResponding = false
    @ObservationIgnored private var responseIDs: [String: UUID] = [:]
    @ObservationIgnored private var admittingResponse: UUID?
    // The event consumer may run before the request continuation resumes.
    @ObservationIgnored private var earlyResults: Set<String> = []
    public private(set) var issues: [Issue] = []
    /// Project plan history, read from the same event-driven snapshot as issues.
    public private(set) var milestones: [Milestone] = []
    public private(set) var preparationItems: [PreparationItem] = []
    public private(set) var preparationSourceIDs: Set<Issue.ID> = []
    /// Project-level weekly plans from the same snapshot.
    public private(set) var weekPlans: [ProjectWeekPlan] = []
    public private(set) var questions: [Question] = []
    public private(set) var extensionQuestions: [Question] = []
    public private(set) var extensionPresentation = ExtensionPresentation()
    @ObservationIgnored private var extensionGeneration = UUID().uuidString
    @ObservationIgnored private var extensionSessionID = ""
    @ObservationIgnored private var extensionRoutes: [Question.ID: OMPExtensionDialog] = [:]
    @ObservationIgnored private var extensionReplies: [Question.ID: Task<Void, Never>] = [:]
    public func dismissExtensionToast() { extensionPresentation.toast = nil }
    public private(set) var projects: [ProjectSummary] = []
    @ObservationIgnored private var issueProjects: [Issue.ID: String] = [:]
    public private(set) var models: [String] = []
    public private(set) var model: String?
    public private(set) var storageBytes: Int64?
    public private(set) var installationBlockReason: String?
    private var activeHirdsByProject: [String: Int] = [:]
    public func approvalBlockReason(for id: Issue.ID) -> String? {
        if preparationSourceIDs.contains(id) { return "준비 항목으로 옮긴 원본 이슈예요" }
        guard let projectID = issueProjects[id], let owner = projects.first(where: { $0.id == projectID }) else { return nil }
        let active = activeHirdsByProject[projectID, default: 0]
        return owner.settings.allowsAdditionalHird(activeCount: active) ? nil : "동시 Hird 실행 한도 \(active)/\(owner.settings.maxHirds) · 진행 중인 실행이 끝난 뒤 승인해 주세요"
    }
    public private(set) var lastError: String?
    @ObservationIgnored private var repository: SQLiteKnarrRepository?
    @ObservationIgnored private var session: StallariSession?
    @ObservationIgnored private var rpc: (any StallariRPC)?
    @ObservationIgnored private var hird: (any HirdAdapter)?
    @ObservationIgnored private var snapshots: Task<Void, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// Highest snapshot revision already applied; delivery order alone cannot guarantee freshness.
    @ObservationIgnored private var appliedRevision = -1
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var localMessages: [ChatItem] = []
    @ObservationIgnored private var cardIDs: [String: UUID] = [:]
    @ObservationIgnored private let preferences: UserDefaults
    /// Where Hird work copies live; cleanup never touches anything outside it.
    @ObservationIgnored private var resultsRoot: URL?
    private static let modelKey = "knarr.model"

    init(repository: SQLiteKnarrRepository, session: StallariSession, rpc: any StallariRPC, hird: any HirdAdapter,
         threadID: String = ConversationThread.defaultID, preferences: UserDefaults = .standard, resultsRoot: URL? = nil,
         responseRules: ResponseRulesFile? = nil, instructionDataDirectory: URL? = nil,
         instructionProjectID: String? = nil, subscriptionUsage: SubscriptionUsageModel? = nil) {
        self.subscriptionUsage = subscriptionUsage
        self.threadID = threadID
        self.repository = repository; self.session = session; self.rpc = rpc; self.hird = hird
        self.preferences = preferences; self.resultsRoot = resultsRoot; self.responseRules = responseRules
        self.instructionDataDirectory = instructionDataDirectory
        self.instructionProjectID = instructionProjectID
        responseRulesPath = responseRules?.url.path
        responseRulesText = (try? responseRules?.load()) ?? ""
        composerDraft = preferences.data(forKey: draftKey).flatMap { try? JSONDecoder().decode(ChatDraft.self, from: $0) } ?? .init()
    }
    /// The conversation's own Stallari, for callers that already resolved issue ownership.
    var stallariSession: StallariSession? { session }
    func setApprovalRouter(_ router: @escaping @Sendable (Issue.ID, Int, String?) async throws -> HirdRun.ID) async {
        await session?.setApprovalRouter(router)
    }
    func approveIssue(_ id: Issue.ID, version: Int, source: String?) async throws -> HirdRun.ID {
        guard let session else { throw StallariError.closed }
        defer { onStateChange?() }
        return try await session.approveIssue(issueID: id, version: version, source: source)
    }
    func setQuestionAnswerRouter(_ router: @escaping @Sendable (String, HirdRun.ID, Issue.ID, QuestionAnswer) async throws -> MutationOutcome) async {
        await session?.setQuestionAnswerRouter(router)
    }
    func answerPendingQuestion(_ questionID: String, runID: HirdRun.ID, issueID: Issue.ID, answer: QuestionAnswer) async throws -> MutationOutcome {
        guard let session else { throw StallariError.closed }
        defer { onStateChange?() }
        return try await session.answer(questionID: questionID, runID: runID, issueID: issueID, answer: answer, requirePending: true)
    }
    func drainDeliveries() async throws {
        try await session?.deliverNotifications()
        try await session?.deliverAnswers()
        try await session?.deliverProjectTransfers()
    }
    private var draftKey: String { threadID == ConversationThread.defaultID ? "knarr.draft" : "knarr.draft." + threadID }


    public func connect() async throws {
        guard !closing, snapshots == nil, let repository, let session, let rpc else { throw StallariError.closed }
        try await repository.ensureProposalCards()
        if !(try await repository.snapshot(includeHistory: false).projects.contains { $0.id == StoredProject.hubID }) {
            try await repository.saveProject(.init(id: StoredProject.hubID, name: "Stallari", absolutePath: NSTemporaryDirectory()))
        }
        // Register first, then read. Nothing is missed, and no snapshot captured before this read
        // can arrive later and rewind what the conversation already applied.
        let updates = try await repository.subscribe(initial: false)
        apply(try await repository.snapshotUpdate())
        let frames = await rpc.subscribe()
        snapshots = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled, let self, !self.closing else { break }
                self.apply(snapshot)
            }
        }
        events = Task { [weak self] in
            for await event in frames {
                guard !Task.isCancelled, let self, !self.closing else { break }
                await self.observe(event)
            }
        }
        try await session.connect()
        _ = try await rpc.request("set_event_filter", fields: ["events": .null, "messageUpdates": .string("delta")], timeout: .seconds(10))
        models = Self.supported(try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10)))
        try applyRuntimeState(try await session.getState()["data"] ?? .null); await refreshThinkingLevels()
        refreshStorage()
        if threadID == ConversationThread.defaultID { refreshResultApplications() }
    }

    /// Reuses the existing restart/restore boundary; never changes project defaults.
    func refreshHiveProvider() async throws {
        guard !closing, !isResponding, !isSubmitting, let session, let rpc else { throw HiveProbeError.incomplete }
        let result = try await session.performTool("reload_extensions", arguments: .object([:]))
        models = Self.supported(try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10)))
        try applyRuntimeState(try await session.getState()["data"] ?? .null)
        await refreshThinkingLevels()
        guard result["status"]?.string == "restarted", (result["errors"]?.array ?? []).isEmpty else { throw HiveProbeError.incomplete }
    }

    /// Available models, in OMP's actual catalog order.
    static func supported(_ available: OMPJSON) -> [String] {
        (available["data"]?["models"]?.array ?? []).compactMap { m in
            guard let provider = m["provider"]?.string, !provider.isEmpty, let id = m["id"]?.string, !id.isEmpty else { return nil }
            return provider + "/" + id
        }
    }

    public func selectModel(_ wanted: String) {
        guard models.contains(wanted), wanted != (requestedModel ?? model) else { return }
        enqueue { [self] in
            guard let session else { throw StallariError.closed }
            try applyRuntimeState(try await session.selectModel(wanted))
            await refreshThinkingLevels()
        }
    }
    public func installAndRestart(_ id: Issue.ID, dataDirectory: URL?, installHandoff: (@MainActor (InstallRestart.Job) throws -> Void)?) {
        enqueue { [self] in
            guard let repository else { throw LiveKnarrError.installUnavailable }
            let snapshot = try await repository.snapshot(includeHistory: false)
            _ = try scopedIssue(id, in: snapshot)
            guard !snapshot.runs.contains(where: { !$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil) }) else { throw LiveKnarrError.installBusy }
            guard let root = dataDirectory, let installHandoff else { throw LiveKnarrError.installUnavailable }
            guard let latest = snapshot.runs.last(where: { $0.issueID == id }), latest.mode != .inspect,
                  let result = latest.result else { throw LiveKnarrError.installUnavailable }
            let candidate = URL(fileURLWithPath: result.worktreePath).appendingPathComponent("outputs/Knarr.app")
            let target = Bundle.main.bundleURL
            let job = try await Task.detached(priority: .utility) {
                try InstallRestart.prepare(candidate: candidate, target: target, database: root.appendingPathComponent("knarr.db"), root: root.appendingPathComponent("installations"))
            }.value
            var frozen = false
            do {
                guard !closing else { throw StallariError.closed }
                try await repository.beginInstallation()
                frozen = true
                try installHandoff(job)
            } catch {
                if frozen { await repository.cancelInstallation() }
                try? FileManager.default.removeItem(at: job.directory)
                throw error
            }
        }
    }

    /// Read-only Git reconciliation on focus, never a periodic idle lookup.
    public func refreshResultApplications() {
        enqueue { [self] in
            guard let repository else { return }
            let snapshot = try await repository.snapshot(includeHistory: false)
            for var issue in snapshot.issues where issue.archivedAt == nil {
                guard let projectID = snapshot.issueProjects[issue.id],
                      let project = snapshot.projects.first(where: { $0.id == projectID }),
                      let run = snapshot.runs.last(where: { $0.issueID == issue.id }), run.state.isTerminal,
                      let result = run.result,
                      let applied = await ResultApplier.included(result, application: issue.application, in: URL(fileURLWithPath: project.absolutePath)) else { continue }
                let application = ResultApplication.applied(branch: applied.branch, commit: applied.commit)
                guard issue.application != application else { continue }
                issue.application = application
                issue.hirds = []; issue.events = []
                try await repository.saveIssue(issue, projectID: projectID)
            }
        }
    }

    private func applyRuntimeState(_ state: OMPJSON) throws {
        guard let provider = state["model"]?["provider"]?.string,
              let id = state["model"]?["id"]?.string else { throw StallariError.invalidArguments }
        let actual = provider + "/" + id
        model = actual
        thinkingLevel = state["thinkingLevel"]?.string
        contextUsage = ContextUsage(state: state)
        requestedModel = state["requestedModel"]?.string ?? actual
        pendingModel = state["pendingModel"]?.string
        stallari.engine = "OMP · " + actual
    }

    private func refreshRuntimeState() async {
        guard !closing, let session else { return }
        do { try applyRuntimeState(try await session.getState()["data"] ?? .null); await refreshThinkingLevels() }
        catch { report(Self.safeError(error, fallback: "OMP 실제 실행 상태를 확인하지 못했어요")) }
    }

    private func refreshThinkingLevels() async {
        guard levelsModel != model, let rpc else { return }
        if let data = try? await rpc.request("get_available_thinking_levels", fields: [:], timeout: .seconds(10)) {
            thinkingLevels = data["data"]?["levels"]?.array?.compactMap(\.string) ?? []
            levelsModel = model
        }
    }
    public func selectThinking(_ level: String) {
        guard thinkingLevels.contains(level), !isResponding, !isSubmitting else { return }
        enqueue { [self] in
            guard let session else { throw StallariError.closed }
            try applyRuntimeState(try await session.selectThinking(level))
            preferences.set(level, forKey: "knarr.thinking")
        }
    }
    public func stopResponse() {
        guard isResponding, !isStopping, let rpc else { return }
        isStopping = true
        cancelWaitingMessages()
        streamingPresentation.finish()
        submissionGeneration += 1
        responseStatus = "중지 중"
        let pending = operation
        stoppingTask = Task { [self] in
            defer { isStopping = false; stoppingTask = nil }
            await pending?.value
            do {
                _ = try await rpc.request("abort", fields: [:], timeout: .seconds(15))
                await finishAssistantMessages(activityState: .stopped)
                clearResponses()
                await session?.finishMessageConversationResponse()
                responseStatus = "중지됨"
                await refreshRuntimeState()
            } catch { report("응답을 중지하지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요.") }
        }
    }
    /// Reads the same tree the settings screen and the chat tool write through.
    public func reloadInstructionSources() {
        guard let instructionDataDirectory else { instructionSources = []; return }
        do { instructionSources = try InstructionSources.sources(dataDirectory: instructionDataDirectory, projectID: instructionProjectID) }
        catch { report(Self.safeError(error, fallback: "지침 파일을 읽지 못했어요. 설정에서 경로와 권한을 확인해 주세요")) }
    }

    @discardableResult
    public func saveInstructionSource(role: InstructionRole, kind: InstructionKind, projectID: String?,
                                      text: String, expectedHash: String) async throws -> InstructionSource {
        guard let instructionDataDirectory else { throw StallariError.closed }
        let saved = try InstructionSources.save(dataDirectory: instructionDataDirectory, role: role, kind: kind,
                                                projectID: role == .project ? projectID : nil,
                                                text: text, expectedHash: expectedHash)
        reloadInstructionSources()
        return saved
    }

    public func reloadResponseRules() {
        do { responseRulesText = try responseRules?.load() ?? "" }
        catch { report(Self.safeError(error, fallback: "응답 지침 파일을 읽지 못했어요. 경로와 읽기 권한을 확인해 주세요")) }
    }

    public func saveResponseRules(_ text: String) {
        do {
            guard let responseRules else { throw StallariError.closed }
            try responseRules.save(text)
            responseRulesText = try responseRules.load()
        } catch { report(Self.safeError(error, fallback: "응답 지침 파일을 저장하지 못했어요. 경로와 쓰기 권한을 확인해 주세요")) }
    }

    public func cleanFinishedWorkspaces() {
        enqueue { [self] in
            guard let repository, let resultsRoot else { return }
            let snapshot = try await repository.snapshot(includeHistory: false)
            var freed: Int64 = 0, count = 0
            for workspace in WorkspaceCleanup.removable(runs: snapshot.runs, issues: snapshot.issues) {
                guard let run = snapshot.runs.first(where: { $0.workspace == workspace }),
                      let project = snapshot.projects.first(where: { $0.id == run.projectID }) else { continue }
                if let bytes = try? await WorkspaceCleanup.remove(workspace, project: URL(fileURLWithPath: project.absolutePath), resultsRoot: resultsRoot), bytes > 0 {
                    freed += bytes; count += 1
                }
            }
            notify(count == 0 ? "정리할 작업본이 없어요" : "끝난 작업본 \(count)개를 정리해서 \(Bytes.text(freed))를 비웠어요")
            refreshStorage()
        }
    }

    private func refreshStorage() {
        guard let resultsRoot else { return }
        Task.detached(priority: .utility) { [weak self] in
            let bytes = WorkspaceCleanup.bytes(at: resultsRoot)
            await MainActor.run { self?.storageBytes = bytes }
        }
    }

    private func apply(_ update: PersistenceUpdate) {
        // Same coalescing as the store: never apply a value older than what was already read.
        guard update.revision > appliedRevision else { return }
        appliedRevision = update.revision
        let snapshot = update.snapshot
        let projection = update.conversationProjection
        if activeHirdsByProject != projection.activeHirdsByProject { activeHirdsByProject = projection.activeHirdsByProject }
        let nextBlock = projection.installationBlocked ? LiveKnarrError.installBusy.localizedDescription : nil
        if installationBlockReason != nextBlock { installationBlockReason = nextBlock }
        issueProjects = snapshot.issueProjects
        if milestones != snapshot.milestones { milestones = snapshot.milestones }
        if preparationItems != snapshot.preparationItems {
            preparationItems = snapshot.preparationItems
            preparationSourceIDs = Set(snapshot.preparationItems.compactMap(\.sourceIssueID))
        }
        if weekPlans != snapshot.weekPlans { weekPlans = snapshot.weekPlans }
        if issues != projection.issues { issues = projection.issues }
        if projects != projection.projects { projects = projection.projects }
        let nextQuestions = projection.questions + extensionQuestions
        if questions != nextQuestions { questions = nextQuestions }
        let storedChat = projection.chatByThread[threadID] ?? []
        let storedIDs = Set(storedChat.map(\.id))
        localMessages.removeAll { storedIDs.contains($0.id) }
        var items = storedChat + localMessages
        // Cards derive from durable entities. Stable IDs keep SwiftUI identity on every event.
        for issue in projection.issuesByThread[threadID] ?? [] where !items.contains(where: {
            switch $0.kind { case .issue(let id), .proposal(let id, _): id == issue.id; default: false }
        }) {
            items.append(card(key: "thing:" + issue.id.rawValue, at: issue.startedAt, kind: .issue(issue.id)))
        }
        for question in (projection.questionsByThread[threadID] ?? []) + extensionQuestions.filter({ q in issues.contains { $0.id == q.issue && $0.conversationThreadID == threadID } }) where !items.contains(where: { $0.kind == .question(question.id) }) {
            items.append(card(key: "question:" + question.id.rawValue, at: question.askedAt, kind: .question(question.id)))
        }
        // Retain source rows on disk and in the preparation provenance view; execution cards
        // no longer participate in the conversation once the candidate was explicitly imported.
        items.removeAll { item in
            switch item.kind {
            case .issue(let id), .proposal(let id, _): preparationSourceIDs.contains(id)
            default: false
            }
        }
        let nextChat = items.enumerated().sorted { a, b in a.element.at == b.element.at ? a.offset < b.offset : a.element.at < b.element.at }.map(\.element)
        let chatChanged = chat != nextChat
        if chatChanged { chat = nextChat }
        hasLoadedHistory = true
        if chatChanged { onChatChange?() }
        if assistantRefreshFailed {
            assistantRefreshFailed = false
            updateAssistantPersistenceError()
        }
    }
    private func card(key: String, at: Date, kind: ChatItem.Kind) -> ChatItem {
        let id = cardIDs[key] ?? UUID(); cardIDs[key] = id
        return .init(id: id, at: at, kind: kind)
    }
    private func observe(_ event: OMPEvent) async {
        switch event {
        case .terminated:
            subagents = .init(); acceptsSubagentEvents = false
            await finishAssistantMessages()
            clearResponses()
            stallari.engine = "OMP · 실행 종료"
        case .frame(let frame):
            await observe(frame: frame)
        }
    }
    func observe(frame: OMPJSON) async {
        guard !closing else { return }
        defer { admitNextPending() }
        subscriptionUsage?.observeStallariFrame(frame)
        if ["agent_start", "message_start", "message_update", "message_end", "tool_execution_start", "tool_execution_update", "tool_execution_end", "auto_compaction_start", "auto_compaction_end"].contains(frame["type"]?.string ?? "") {
            responseLastEventAt = .now
        }
        switch frame["type"]?.string {
        case "knarr_rpc_restarting":
            subagents = .init(); acceptsSubagentEvents = false
            await finishAssistantMessages()
            clearResponses()
            completedMessages.removeAll()
            assistantGeneration += 1
            extensionPresentation.isReloading = true
            responseStatus = "확장 다시 불러오는 중"
            invalidateExtensionQuestions()
            extensionPresentation.statuses.removeAll(); extensionPresentation.widgets.removeAll()
        case "knarr_rpc_ready":
            if let generation = frame["generation"]?.string, generation != extensionGeneration {
                subagents = .init()
                invalidateExtensionQuestions(); extensionGeneration = generation
            }
            extensionSessionID = frame["sessionID"]?.string ?? ""
            extensionPresentation.isReloading = false
            acceptsSubagentEvents = true
            await refreshRuntimeState()
        case "knarr_rpc_reload_failed":
            extensionPresentation.isReloading = false
            report("확장을 다시 불러오지 못했어요. 연결을 확인해 주세요.")
        case "extension_ui_request":
            observeExtensionUI(frame)
        case "agent_start":
            if !isResponding || responseStartedAt == nil { responseStartedAt = .now }
            agentResponding = true
            responseStatus = "응답 준비 중"
            onStateChange?()
            await refreshRuntimeState()
        case "agent_end":
            if frame["isTerminal"]?.bool != false || frame["yielded"]?.bool == true {
                agentResponding = false
                onStateChange?()
                await finishAssistantMessages()
            }
        case "subagent_lifecycle", "subagent_progress":
            guard acceptsSubagentEvents,
                  frame["knarrRPCGeneration"]?.string.map({ $0 == extensionGeneration }) ?? true else { break }
            subagents.receive(frame, at: .now)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            await observeToolActivity(frame)
        case "auto_compaction_start": responseStatus = "대화 정리 중"
        case "auto_compaction_end": await refreshRuntimeState()
        case "message_start", "message_update", "message_end":
            guard let message = frame["message"], message["role"]?.string == "assistant",
                  let messageID = frame["messageId"]?.string else { return }
            let key = AssistantMessageKey(generation: assistantGeneration, messageID: messageID)
            guard !completedMessages.contains(key) else { return }
            if let error = message["errorMessage"]?.string {
                if error.contains("401") || error.localizedCaseInsensitiveContains("invalid api key") {
                    responseFailure = "모델 연결 인증이 유효하지 않아요. 계정을 다시 연결한 뒤 재시도해 주세요."
                } else if error.contains("429") {
                    responseFailure = "모델의 사용 한도에 도달했어요. 잠시 후 다시 시도하거나 모델을 바꿔 주세요."
                }
            }
            await observeReasoning(frame, message: message, messageID: messageID)
            let draft = assistantMessages[key] ?? AssistantDraft()
            if assistantMessages[key] == nil { draft.conversationRootID = await session?.responseConversationRootID }
            assistantMessages[key] = draft
            // A snapshot may accompany a delta. Status must advance on either wire format.
            switch frame["assistantMessageEvent"]?["type"]?.string {
            case "thinking_start", "thinking_delta": responseStatus = "생각 중"
            case "text_start", "text_delta", "text_end": responseStatus = "답변 작성 중"
            default:
                if let block = message["content"]?.array?.last(where: {
                    ($0["type"]?.string == "text" && !($0["text"]?.string ?? "").isEmpty) ||
                    ($0["type"]?.string == "thinking" && !($0["thinking"]?.string ?? "").isEmpty)
                }) { responseStatus = block["type"]?.string == "thinking" ? "생각 중" : "답변 작성 중" }
            }
            guard !draft.isTerminal else { return }
            let wasEmpty = draft.text.isEmpty
            if let content = message["content"]?.array {
                let blocks = Self.textBlocks(content)
                // Error/abort terminals may omit already streamed text.
                if blocks.values.contains(where: { !$0.isEmpty }) || frame["type"]?.string != "message_end" { draft.blocks = blocks }
            } else if let update = frame["assistantMessageEvent"],
                      let index = update["contentIndex"]?.integer, index >= 0 {
                switch update["type"]?.string {
                case "thinking_start", "thinking_delta": responseStatus = "생각 중"
                case "text_delta":
                    responseStatus = "답변 작성 중"
                    if let delta = update["delta"]?.string { draft.blocks[index, default: ""] += delta }
                case "text_end":
                    if let text = update["content"]?.string { draft.blocks[index] = text }
                default: break // Thinking and tool arguments are not assistant prose.
                }
            }
            if wasEmpty, !draft.text.isEmpty { draft.at = .now }
            show(draft, immediately: frame["assistantMessageEvent"]?["type"]?.string == "text_end")
            if frame["type"]?.string == "message_end" {
                await finishAssistantMessage(key)
                await refreshRuntimeState()
            }
        case "prompt_result":
            guard let id = frame["id"]?.string else { return }
            if let local = responseIDs.removeValue(forKey: id) {
                pendingResponses.remove(local)
                if pendingResponses.isEmpty { agentResponding = false }
            } else if admittingResponse != nil {
                earlyResults.insert(id)
            }
            if !isResponding { await finishAssistantMessages(activityState: frame["status"]?.string == "aborted" ? .stopped : .interrupted) }
            onStateChange?()
            let responseRootID = submittedConversationRoots.removeValue(forKey: id) ?? admittingConversationRootID
            if let draft = submittedDrafts.removeValue(forKey: id) ?? admittingDraft, frame["status"]?.string == "error" {
                if draft.conversationRootID == nil { failedDraft = draft }
                report(responseFailure ?? "응답을 완료하지 못했어요. 다시 시도하거나 모델을 바꿔 주세요.", conversationRootID: responseRootID ?? draft.conversationRootID)
            }
            if !isResponding { await session?.finishMessageConversationResponse() }
        case "session_settled":
            await refreshRuntimeState()
            if !isResponding {
                await session?.finishMessageConversationResponse()
                try? await drainDeliveries()
            }
        default: break
        }
    }
    private func invalidateExtensionQuestions() {
        for index in extensionQuestions.indices where extensionQuestions[index].isPending { extensionQuestions[index].state = .unavailable }
        extensionRoutes.removeAll()
        syncExtensionQuestions()
    }
    private func syncExtensionQuestions() {
        questions = questions.filter { $0.extensionIdentity == nil } + extensionQuestions
    }
    private func observeExtensionUI(_ frame: OMPJSON) {
        if ProjectTransferProtocol.isBridgeFrame(frame) { return }
        let generation = frame["knarrRPCGeneration"]?.string ?? extensionGeneration
        guard generation == extensionGeneration, !extensionPresentation.isReloading else { return }
        switch frame["method"]?.string {
        case "notify":
            if let message = frame["message"]?.string {
                extensionPresentation.toast = .init(message: message, tone: frame["notifyType"]?.string ?? "info")
            }
        case "setStatus":
            if let key = frame["statusKey"]?.string, key != "__knarr_tool_policy__" { extensionPresentation.statuses[key] = frame["statusText"]?.string }
        case "setWidget":
            if let key = frame["widgetKey"]?.string { extensionPresentation.widgets[key] = frame["widgetLines"]?.array?.compactMap(\.string) }
        case "cancel":
            if let target = frame["targetId"]?.string,
               let index = extensionQuestions.firstIndex(where: { $0.extensionIdentity?.rpcID == target && $0.extensionIdentity?.rpcGeneration == generation && $0.isPending }) {
                extensionQuestions[index].state = .cancelled
                extensionRoutes.removeValue(forKey: extensionQuestions[index].id)
                syncExtensionQuestions()
            }
        default:
            guard let dialog = OMPExtensionDialog(frame) else { return }
            let identity = StallariDialogIdentity(threadID: threadID, sessionID: extensionSessionID, rpcGeneration: generation, rpcID: dialog.rpcID)
            let id = Question.ID("stallari-question:\(threadID):\(extensionSessionID):\(generation):\(dialog.rpcID)")
            guard extensionRoutes[id] == nil, !extensionQuestions.contains(where: { $0.id == id }) else { return }
            extensionRoutes[id] = dialog
            let question = Question(id: id, identity: identity, prompt: dialog.prompt, options: dialog.options, replyStyle: dialog.method,
                placeholder: dialog.placeholder, prefill: dialog.prefill, askedAt: .now)
            extensionQuestions.append(question); syncExtensionQuestions()
            let item = card(key: id.rawValue, at: question.askedAt, kind: .question(id))
            localMessages.append(item); chat.append(item)
        }
    }
    func resolveExtensionQuestion(_ id: Question.ID, answer: QuestionAnswer?) async {
        guard !closing, let rpc, let index = extensionQuestions.firstIndex(where: { $0.id == id && $0.isPending }),
              let identity = extensionQuestions[index].extensionIdentity, identity.threadID == threadID,
              identity.sessionID == extensionSessionID, identity.rpcGeneration == extensionGeneration,
              let route = extensionRoutes[id], answer.map(route.accepts) ?? true else { return }
        extensionQuestions[index].state = answer.map(Question.State.answered) ?? .cancelled
        syncExtensionQuestions()
        var fields = route.response(answer)
        fields["knarrRPCGeneration"] = .string(identity.rpcGeneration)
        do { try await rpc.send("extension_ui_response", fields: fields) }
        catch {
            guard identity.rpcGeneration == extensionGeneration else { return }
            extensionQuestions[index].state = .pending; syncExtensionQuestions()
            report("질문 응답을 전달하지 못했어요. 다시 보내 주세요.")
        }
    }
    private func observeReasoning(_ frame: OMPJSON, message: OMPJSON, messageID: String) async {
        let terminal = frame["type"]?.string == "message_end"
        let conversationRootID = await session?.responseConversationRootID
        func receive(_ text: String, index: Int, append: Bool) {
            let key = AssistantMessageKey(generation: assistantGeneration, messageID: messageID, segment: "thinking\(index)")
            guard !completedMessages.contains(key) else { return }
            let draft = assistantMessages[key] ?? AssistantDraft(activity: .init(kind: .reasoning, title: "추론 요약"))
            if assistantMessages[key] == nil { draft.conversationRootID = conversationRootID }
            guard !draft.isTerminal else { return }
            if append { draft.blocks[0, default: ""] += text }
            else if !text.isEmpty { draft.blocks[0] = text }
            guard !draft.text.isEmpty else { return }
            draft.activity?.updatedAt = .now
            assistantMessages[key] = draft
            publishStream(draft)
        }
        if let content = message["content"]?.array {
            for (index, block) in content.enumerated() where block["type"]?.string == "thinking" {
                receive(block["thinking"]?.string ?? "", index: index, append: false)
            }
        } else if let update = frame["assistantMessageEvent"], let index = update["contentIndex"]?.integer, index >= 0 {
            if update["type"]?.string == "thinking_delta" { receive(update["delta"]?.string ?? "", index: index, append: true) }
            if update["type"]?.string == "thinking_end" { receive(update["content"]?.string ?? "", index: index, append: false) }
        }
        if terminal {
            for key in Array(assistantMessages.keys) where key.generation == assistantGeneration && key.messageID == messageID && key.segment.hasPrefix("thinking") {
                if message["stopReason"]?.string == "error" { assistantMessages[key]?.activity?.state = .failed }
                if isStopping || message["stopReason"]?.string == "aborted" { assistantMessages[key]?.activity?.state = .stopped }
                await finishAssistantMessage(key)
            }
        }
    }
    private func observeToolActivity(_ frame: OMPJSON) async {
        let tool = OMPToolActivity(frame)
        guard let callID = tool.callID else { return }
        let key = AssistantMessageKey(generation: assistantGeneration, messageID: callID, segment: "tool")
        guard !completedMessages.contains(key) else { return }
        let type = frame["type"]?.string
        if type == "tool_execution_start", assistantMessages[key] == nil {
            let draft = AssistantDraft(activity: .init(kind: .tool, title: ChatActivity.toolTitle(tool.name)))
            draft.conversationRootID = await session?.responseConversationRootID
            draft.blocks[0] = ChatActivity.toolTarget(frame)
            assistantMessages[key] = draft
        }
        guard let draft = assistantMessages[key], !draft.isTerminal else { return }
        draft.activity?.updatedAt = .now
        if type == "tool_execution_end" {
            let failed = frame["isError"]?.bool == true || frame["result"]?["isError"]?.bool == true
            draft.activity?.state = failed ? .failed : .completed
            if let active = assistantMessages.values.filter({ $0.activity?.kind == .tool && $0.activity?.state == .running }).min(by: { $0.at < $1.at }) {
                responseStatus = (active.activity?.title ?? "도구") + " 진행 중"
            } else { responseStatus = failed ? "작업 실패 확인 중" : "다음 응답 기다리는 중" }
            await finishAssistantMessage(key)
        } else {
            responseStatus = (draft.activity?.title ?? "도구") + " 진행 중"
            publishStream(draft)
        }
    }
    private static func textBlocks(_ content: [OMPJSON]) -> [Int: String] {
        var blocks: [Int: String] = [:]
        for (index, block) in content.enumerated() where block["type"]?.string == "text" {
            if let text = block["text"]?.string { blocks[index] = text }
        }
        return blocks
    }
    private func show(_ draft: AssistantDraft, immediately: Bool = false) {
        if draft.activity != nil { publishStream(draft); return }
        let text = draft.text
        if !text.isEmpty { streamingPresentation.receive(text, messageID: draft.id, animate: !isStopping) }
        let now = ProcessInfo.processInfo.systemUptime
        if immediately || streamingMessageID != draft.id || now - lastStreamPaint >= 0.25 {
            streamFlush?.cancel(); streamFlush = nil; pendingStream = nil
            publishStream(draft)
            return
        }
        pendingStream = draft
        guard streamFlush == nil else { return }
        let delay = max(0, 0.25 - (now - lastStreamPaint))
        streamFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.streamFlush = nil
            guard !self.closing, let draft = self.pendingStream else { return }
            self.pendingStream = nil
            self.publishStream(draft)
        }
    }
    private func publishStream(_ draft: AssistantDraft) {
        lastStreamPaint = ProcessInfo.processInfo.systemUptime
        let item = draft.item
        guard case .stallari(let text, _) = item.kind, !text.isEmpty else { return }
        if draft.activity == nil, streamingMessageID == item.id, streamingText == text { return }
        let wasCountable = chat.first { $0.id == item.id }.map(UnreadAnswers.isCountable) ?? false
        if let index = localMessages.firstIndex(where: { $0.id == item.id }) { localMessages[index] = item }
        else { localMessages.append(item) }
        if let index = chat.firstIndex(where: { $0.id == item.id }) { chat[index] = item }
        else { chat.append(item) }
        // Only the appearance of a countable answer changes a tab's badge; later deltas of the same
        // streaming answer must not re-count the transcript.
        if UnreadAnswers.isCountable(item) != wasCountable { onChatChange?() }
        if draft.activity == nil {
            streamingMessageID = item.id
            streamingText = text
        }
    }
    private func finishAssistantMessage(_ key: AssistantMessageKey) async {
        if let task = assistantPersistenceTasks[key] { await task.value; return }
        guard let draft = assistantMessages[key] else { return }
        draft.isTerminal = true
        if draft.activity?.state == .running {
            let terminalState: ChatActivity.State = draft.activity?.kind == .reasoning ? .completed : .interrupted
            draft.activity?.state = terminalState
            draft.activity?.updatedAt = .now
        }
        if streamingPresentation.messageID == draft.id { streamingPresentation.finish() }
        if pendingStream?.id == draft.id {
            streamFlush?.cancel(); streamFlush = nil; pendingStream = nil
        }
        // Flush even a throttled final paint before persistence can fail.
        publishStream(draft)
        if streamingMessageID == draft.id { streamingMessageID = nil; streamingText = "" }
        let item = draft.item
        guard case .stallari(let text, _) = item.kind,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            assistantMessages.removeValue(forKey: key)
            completedMessages.insert(key)
            return
        }
        var stored = item
        if let root = resultsRoot, text.contains("![") {
            // Keep the pictures beside Knarr's own records; the reply itself is saved either way.
            stored.kind = .stallari(ChatImageSource.persisting(text, root: ChatImageSource.storageRoot(forDataDirectory: root.deletingLastPathComponent())), project: nil)
        }
        let task = Task { [self] in
            defer { assistantPersistenceTasks.removeValue(forKey: key); onStateChange?() }
            do {
                guard let repository else { throw StallariError.closed }
                try await repository.appendAssistantChat(stored, threadID: threadID)
            } catch {
                failedAssistantMessages.insert(key)
                updateAssistantPersistenceError()
                return
            }
            // Commit and projection are different boundaries. A failed refresh must never append again.
            assistantMessages.removeValue(forKey: key)
            completedMessages.insert(key)
            failedAssistantMessages.remove(key)
            do { try await refresh() }
            catch { assistantRefreshFailed = true }
            updateAssistantPersistenceError()
        }
        assistantPersistenceTasks[key] = task
        await task.value
    }
    private func finishAssistantMessages(retryFailed: Bool = false, activityState: ChatActivity.State = .interrupted) async {
        for draft in assistantMessages.values where !draft.isTerminal && draft.activity?.state == .running {
            draft.activity?.state = isStopping ? .stopped : activityState
            draft.activity?.updatedAt = .now
        }
        for task in Array(assistantPersistenceTasks.values) { await task.value }
        for key in Array(assistantMessages.keys) where retryFailed || assistantMessages[key]?.isTerminal == false {
            await finishAssistantMessage(key)
        }
    }
    private func updateAssistantPersistenceError() {
        if !failedAssistantMessages.isEmpty {
            assistantPersistenceError = "응답 기록을 저장하지 못했어요. 받은 답변은 이 대화에 보관 중이에요. 앱을 닫기 전에 저장을 다시 시도해 주세요."
        } else if assistantRefreshFailed {
            assistantPersistenceError = "응답은 저장했지만 대화 기록을 새로고침하지 못했어요. 새로고침을 다시 시도해 주세요."
        } else {
            assistantPersistenceError = nil
        }
    }
    /// Retries local persistence/projection only; never asks OMP to generate another answer.
    public func retryAssistantPersistence() async {
        guard !closing, !isRetryingAssistantPersistence else { return }
        isRetryingAssistantPersistence = true
        defer { isRetryingAssistantPersistence = false }
        let retryRefresh = assistantRefreshFailed
        for key in Array(failedAssistantMessages) { await finishAssistantMessage(key) }
        if retryRefresh, assistantRefreshFailed {
            do { try await refresh() }
            catch { assistantRefreshFailed = true }
        }
        updateAssistantPersistenceError()
    }
    private func clearResponses() {
        cancelWaitingMessages()
        streamFlush?.cancel(); streamFlush = nil; pendingStream = nil

        pendingResponses.removeAll()
        responseIDs.removeAll()
        submittedDrafts.removeAll()
        submittedConversationRoots.removeAll()
        earlyResults.removeAll()
        admittingResponse = nil
        admittingConversationRootID = nil
        agentResponding = false
        streamingText = ""
        streamingMessageID = nil
    }
    private func enqueue(onCancel: @escaping @MainActor () -> Void = {}, _ work: @escaping @MainActor () async throws -> Void) {
        guard !closing else { onCancel(); return }
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !self.closing, !Task.isCancelled else { onCancel(); return }
            do { try await work(); try await self.refresh() }
            catch { self.report(Self.safeError(error, fallback: "요청을 처리하지 못했어요. 이슈의 실행 상태와 연결을 확인해 주세요")) }
        }
    }
    /// Provider/RPC errors may contain credentials or login URLs. Only app-owned messages are public.
    static func safeError(_ error: Error, fallback: String) -> String {
        if let rpc = error as? OMPRPCError, rpc == .requestTooLarge {
            return "메시지와 첨부의 전체 전송 용량을 초과했어요. 이미지를 나눠서 보내 주세요."
        }
        if let error = error as? ConversationResetError { return error.localizedDescription }
        if let error = error as? ChatAttachmentError { return error.localizedDescription }
        if let error = error as? StallariThinkingError { return error.localizedDescription }
        if let error = error as? ResponseRulesError { return error.localizedDescription }
        if let error = error as? LiveKnarrError { return error.localizedDescription }
        if let error = error as? ProjectGitError { return error.localizedDescription }
        if let error = error as? PersistenceError { return error.message }
        // App-written refusals (a close while a Hird runs, stale proposal versions) name the reason
        // the person can act on. Provider text never reaches this branch.
        if case .rejectedEvidence(let reason)? = error as? StallariError { return reason }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, (256..<768).contains(cocoa.code) {
            return "파일을 읽거나 저장하지 못했어요. 응답 지침과 데이터 경로의 권한을 확인해 주세요. (오류 \(cocoa.code))"
        }
        return fallback
    }
    private func notify(_ message: String) {
        let item = ChatItem(at: .now, kind: .stallari(message, project: nil))
        localMessages.append(item); chat.append(item)
    }
    func report(_ message: String, conversationRootID: UUID? = nil) {
        if conversationRootID == nil { lastError = message }
        var item = ChatItem(at: .now, kind: .stallari(message, project: nil))
        item.conversationRootID = conversationRootID
        localMessages.append(item); chat.append(item)
    }
    private func refresh() async throws {
        guard let repository else { throw StallariError.closed }
        apply(try await repository.snapshotUpdate())
    }
    /// Drains queued local work, including a requested stop, without ending an active response or its reveal.
    public func whenIdle() async throws {
        for task in extensionReplies.values { await task.value }
        await operation?.value
        await stoppingTask?.value
        // A final assistant message is persisted by the frame task, which is not part of the
        // submission queue. Waiting only for that queue can return before the reply is durable.
        while let task = assistantPersistenceTasks.values.first { await task.value }
        try await refresh()
        if let draft = pendingStream {
            streamFlush?.cancel(); streamFlush = nil; pendingStream = nil
            publishStream(draft)
        }
    }
    public func resultReport(_ issue: Issue.ID) async -> String {
        guard let repository, let snapshot = try? await repository.snapshot(includeHistory: false),
              let run = snapshot.runs.last(where: { $0.issueID == issue }),
              let path = run.result?.reportPath else { return "저장된 결과 보고서가 없어요" }
        return await Task.detached(priority: .utility) {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "결과 보고서를 읽지 못했어요"
        }.value
    }
    private func scopedIssue(_ id: Issue.ID, in snapshot: PersistenceSnapshot) throws -> (issue: Issue, projectID: String) {
        guard let projectID = snapshot.issueProjects[id], projectID != StoredProject.hubID,
              let issue = snapshot.issues.first(where: { $0.id == id && $0.conversationThreadID == threadID }) else { throw StallariError.wrongProject }
        if snapshot.threads.first(where: { $0.id == threadID })?.issueID == id, issue.archivedAt != nil {
            throw StallariError.rejectedEvidence("닫힌 이슈 대화는 읽기 전용이에요.")
        }
        return (issue, projectID)
    }
    public func send(_ text: String, about: Issue.ID?, project: String?, attachments: [URL]) {
        queueSubmission(.init(text: text, attachments: attachments, project: project), about: about) { _ in }
    }
    public func submit(_ draft: ChatDraft) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queueSubmission(draft, about: nil) { continuation.resume(with: $0) }
        }
    }
    public func startMessageConversation(_ draft: ChatDraft) async throws -> UUID {
        try await startMessageConversation(draft, onCreated: { _ in })
    }
    public func startMessageConversation(_ draft: ChatDraft, onCreated: @escaping @MainActor (UUID) -> Void) async throws -> UUID {
        guard !closing, !draft.isEmpty, draft.conversationRootID == nil else { throw StallariError.invalidArguments }
        guard draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != "/clear" else { throw ConversationResetError.focused }
        let rootID = UUID()
        let generation = submissionGeneration
        let preparation = Task {
            let prepared = try await prepareSubmission(draft, about: nil, newRootID: rootID, sentAt: .now, generation: generation)
            try Task.checkCancellation()
            guard !closing, generation == submissionGeneration else { throw CancellationError() }
            onCreated(rootID)
            return prepared
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queueSubmission(draft, about: nil, newRootID: rootID, preparation: preparation) { continuation.resume(with: $0) }
        }
        return rootID
    }
    public func linkMessageConversation(_ id: UUID) async throws {
        guard !closing, let repository else { throw StallariError.closed }
        try await repository.linkMessageConversation(id, threadID: threadID)
        try await refresh()
    }
    private func queueContextReset(_ draft: ChatDraft, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard draft.conversationRootID == nil else { completion(.failure(ConversationResetError.focused)); return }
        guard draft.attachments.isEmpty else { completion(.failure(ConversationResetError.attachments)); return }
        guard !isResponding, !isSubmitting, !isStopping, pendingSubmissions.isEmpty,
              assistantPersistenceTasks.isEmpty, failedAssistantMessages.isEmpty else {
            completion(.failure(ConversationResetError.busy)); return
        }
        isClearingContext = true
        isSubmitting = true
        responseStatus = "대화 문맥 초기화 중"
        onStateChange?()
        enqueue(onCancel: { [self] in
            isClearingContext = false; isSubmitting = false
            completion(.failure(CancellationError()))
        }) { [self] in
            defer {
                isClearingContext = false; isSubmitting = false
                onStateChange?(); admitNextPending()
            }
            do {
                guard let session else { throw StallariError.closed }
                let state = try await session.resetContext()
                clearResponses()
                failedDraft = nil; responseFailure = nil; lastError = nil
                responseStartedAt = nil; responseLastEventAt = nil
                subagents = .init()
                invalidateExtensionQuestions()
                extensionSessionID = state["sessionId"]?.string ?? ""
                extensionPresentation.statuses.removeAll(); extensionPresentation.widgets.removeAll()
                try applyRuntimeState(state)
                responseStatus = "대화 문맥 초기화 완료"
                if composerDraft.hasSameInput(as: draft) { composerDraft = .init(project: draft.project) }
                notify("대화 문맥을 초기화했어요. 이전 대화 기록과 프로젝트·이슈는 그대로 보관돼요.")
                completion(.success(()))
            } catch {
                responseStatus = "대화 문맥 초기화 실패"
                if composerDraft.isEmpty { composerDraft = draft }
                report(Self.safeError(error, fallback: "대화 문맥 초기화를 확인하지 못했어요. /clear를 다시 시도해 주세요."))
                completion(.failure(error))
            }
        }
    }
    private func queueSubmission(_ draft: ChatDraft, about: Issue.ID?, newRootID: UUID? = nil, preparation: Task<PreparedSubmission, Error>? = nil, sentAt: Date = .now, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !closing, !draft.isEmpty else { preparation?.cancel(); completion(.failure(StallariError.closed)); return }
        if isClearingContext { completion(.failure(ConversationResetError.busy)); return }
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == "/clear" {
            preparation?.cancel()
            queueContextReset(draft, completion: completion)
            return
        }
        let responseRootID = newRootID ?? draft.conversationRootID
        if isStopping {
            preparation?.cancel()
            completion(.failure(StallariError.rejectedEvidence("응답을 중지하는 중이에요. 끝난 뒤에 보내 주세요.")))
            return
        }
        // Re-clicking send on the same draft must not persist or prompt twice: the identical
        // message is already being admitted, queued, or answered and will be sent once.
        // Root-creating sends carry their own durable source, so they are never collapsed.
        if newRootID == nil, sendingDraft == draft
            || pendingSubmissions.contains(where: { $0.newRootID == nil && $0.draft == draft }) {
            completion(.success(()))
            return
        }
        // Sends already waiting keep their order; steering never jumps ahead of them.
        if (isResponding || isSubmitting) && (!pendingSubmissions.isEmpty || mustWait(draft, newRootID: newRootID)) {
            pendingSubmissions.append(.init(draft: draft, about: about, newRootID: newRootID,
                                            preparation: preparation, completion: completion, startedAt: sentAt))
            isSubmissionWaiting = true
            return
        }
        let generation = submissionGeneration
        let submission = UUID()
        if !isResponding { responseStartedAt = sentAt; responseLastEventAt = sentAt }
        pendingResponses.insert(submission)
        failedDraft = nil
        responseFailure = nil
        isSubmitting = true
        sendingDraft = draft
        responseStatus = "응답 준비 중"
        enqueue(onCancel: { [self] in preparation?.cancel(); isSubmitting = false; pendingResponses.remove(submission); completion(.failure(CancellationError())) }) { [self] in
            var admitted = false
            var prepared: PreparedSubmission?
            defer {
                isSubmitting = false
                sendingDraft = nil
                admittingResponse = nil
                admittingDraft = nil
                admittingConversationRootID = nil
                earlyResults.removeAll()
                if !admitted { pendingResponses.remove(submission) }
                admitNextPending()
                onStateChange?()
            }
            do {
                await submissionHook?()
                let ready: PreparedSubmission
                if let preparation { ready = try await preparation.value }
                else { ready = try await prepareSubmission(draft, about: about, newRootID: nil, sentAt: sentAt, generation: generation) }
                prepared = ready
                guard !closing, let session, generation == submissionGeneration else { throw CancellationError() }
                admittingResponse = submission
                admittingDraft = draft
                admittingConversationRootID = responseRootID
                let projectID = draft.conversationRootID == nil ? draft.project : (ready.projectID == StoredProject.hubID ? nil : ready.projectID)
                let response = try await session.send(ready.message, about: about, projectID: about == nil ? projectID : nil,
                                                      images: ready.images, messageID: ready.itemID, conversationRootID: responseRootID, preparationID: ready.preparationID)
                guard let id = response["id"]?.string, response["data"]?["agentInvoked"]?.bool != false else { throw StallariError.invalidArguments }
                if earlyResults.contains(id) {
                    pendingResponses.remove(submission)
                    if pendingResponses.isEmpty { agentResponding = false }
                } else {
                    responseIDs[id] = submission
                    submittedDrafts[id] = draft
                    submittedConversationRoots[id] = responseRootID
                    admitted = true
                }
                if failedDraft != draft, composerDraft.hasSameInput(as: draft) { composerDraft = .init(project: draft.project) }
                completion(.success(()))
                await refreshRuntimeState()
            } catch StallariSteerError.messageConversationAnswer {
                // Already persisted: wait with the same message and send it once the answer ends.
                let ready = prepared
                pendingSubmissions.insert(.init(draft: draft, about: about, newRootID: nil,
                                                preparation: ready.map { value in Task { () throws -> PreparedSubmission in value } }, completion: completion, startedAt: sentAt), at: 0)
                isSubmissionWaiting = true
            } catch {
                // A read-only refusal is not a failed send: keep no retry draft and no transcript noise.
                if draft.conversationRootID == nil, !Self.isClosedThreadRejection(error) {
                    failedDraft = draft
                    report(Self.safeError(error, fallback: "전송하지 못했어요. 작성한 내용은 그대로 보관돼 있어요."))
                }
                completion(.failure(error))
            }
        }
    }
    /// A thread that owns a closed Issue is read-only: sending must be refused before it persists.
    static let closedThreadMessage = "닫힌 이슈 대화는 읽기 전용이에요."
    static func isClosedThreadRejection(_ error: Error) -> Bool {
        if case StallariError.rejectedEvidence(let message)? = error as? StallariError { return message == closedThreadMessage }
        return false
    }
    static func isClosedIssueThread(threadID: String, in snapshot: PersistenceSnapshot) -> Bool {
        guard let ownedID = snapshot.threads.first(where: { $0.id == threadID })?.issueID else { return false }
        return snapshot.issues.first(where: { $0.id == ownedID })?.archivedAt != nil
    }
    private func prepareSubmission(_ draft: ChatDraft, about: Issue.ID?, newRootID: UUID?, sentAt: Date, generation: Int) async throws -> PreparedSubmission {
        let images = try await Task.detached(priority: .userInitiated) { try Self.images(for: draft.attachments) }.value
        try Task.checkCancellation()
        guard !closing, let repository, session != nil, generation == submissionGeneration else { throw CancellationError() }
        let snapshot = try await repository.snapshot(includeHistory: false)
        // A closed Issue conversation is read-only: refuse before persisting, so a rejected send
        // cannot leave a user message in the transcript or reach the session.
        guard !Self.isClosedIssueThread(threadID: threadID, in: snapshot) else {
            throw StallariError.rejectedEvidence(Self.closedThreadMessage)
        }
        let thread = snapshot.threads.first { $0.id == threadID }
        let ownedProject = thread?.projectID ?? thread?.issueID.flatMap { snapshot.issueProjects[$0] }
        var link = draft.project ?? ownedProject ?? StoredProject.hubID
        if let about { link = try scopedIssue(about, in: snapshot).projectID }
        else if let project = draft.project, !snapshot.projects.contains(where: { $0.id == project }) { throw StallariError.wrongProject }
        if let rootID = draft.conversationRootID {
            guard let root = snapshot.chat.first(where: { $0.id == rootID }), root.isConversationLink,
                  let rootLink = snapshot.chatLinks.first(where: { $0.chatID == rootID && $0.conversationThreadID == threadID }) else { throw StallariError.invalidArguments }
            link = rootLink.projectID
        }
        let typed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = typed + (draft.attachments.isEmpty ? "" : "\n\nAttached files:\n" + draft.attachments.map { "- " + $0.path }.joined(separator: "\n"))
        try Task.checkCancellation()
        guard !closing, generation == submissionGeneration else { throw CancellationError() }
        var item = ChatItem(id: newRootID ?? UUID(), at: sentAt, kind: .user(typed))
        item.attachments = draft.attachments
        item.conversationRootID = draft.conversationRootID
        item.preparationID = draft.conversationRootID.flatMap { rootID in snapshot.chat.first { $0.id == rootID }?.preparationID }
            ?? (draft.conversationRootID == nil ? draft.preparationID : nil)
        // Persist once before prompting; a queued root can open before its response is admitted.
        try await repository.appendChat(item, projectID: link, issueID: about, threadID: threadID)
        if let newRootID {
            try await repository.linkMessageConversation(newRootID, threadID: threadID)
            try await refresh()
        }
        return .init(itemID: item.id, message: message, projectID: link, images: images, preparationID: item.preparationID)
    }
    nonisolated private static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    nonisolated private static func images(for attachments: [URL]) throws -> [OMPJSON] {
        try attachments.compactMap { url in
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { throw ChatAttachmentError.unreadable(url.lastPathComponent) }
            guard let mime = imageTypes[url.pathExtension.lowercased()] else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_000_000 else { throw ChatAttachmentError.oversized(url.lastPathComponent) }
            guard let data = try? Data(contentsOf: url) else { throw ChatAttachmentError.unreadable(url.lastPathComponent) }
            return .object(["type": .string("image"), "mimeType": .string(mime), "data": .string(data.base64EncodedString())])
        }
    }
    public func addProject(path: String) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            do {
                let found = try StoredProject.at(path: path)
                if var known = try await repository.snapshot(includeHistory: false).projects.first(where: { $0.id == found.id }) {
                    known.archivedAt = nil
                    try await repository.saveProject(known)
                } else {
                    try await repository.saveProject(found)
                }
            } catch { report("\(path)를 프로젝트로 추가하지 못했어요. 폴더가 있는지 확인해 주세요") }
        }
    }
    public func issues(inProject id: String) -> [Issue] { issues.filter { issueProjects[$0.id] == id } }
    public func milestones(inProject id: String) -> [Milestone] { milestones.filter { $0.projectID == id } }
    public func milestone(_ id: Milestone.ID) -> Milestone? { milestones.first { $0.id == id } }
    public func saveMilestone(_ milestone: Milestone) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            try await repository.saveMilestone(milestone)
        }
    }
    public func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID]) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            try await repository.reorderMilestones(projectID: projectID, orderedIDs: orderedIDs)
        }
    }
    public func deleteMilestone(_ id: Milestone.ID) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            try await repository.deleteMilestone(id)
        }
    }
    public func weekPlans(inProject id: String) -> [ProjectWeekPlan] { weekPlans.filter { $0.projectID == id } }
    public func saveWeekPlan(_ plan: ProjectWeekPlan) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            try await repository.saveWeekPlan(plan, at: .now)
        }
    }
    public func inspectProject(_ id: String) async -> ProjectInspection {
        guard let project = projects.first(where: { $0.id == id }) else { return .init(problem: "프로젝트를 찾지 못했어요") }
        return await ProjectGit.inspect(URL(fileURLWithPath: project.path, isDirectory: true))
    }
    public func renameProject(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeProject(id) { $0.name = name }
    }
    public func setProjectArchived(_ id: String, _ archived: Bool) {
        changeProject(id) { $0.archivedAt = archived ? ($0.archivedAt ?? .now) : nil }
        guard archived else { return }
        enqueue { [self] in
            guard let repository, let session else { throw StallariError.closed }
            for run in try await repository.snapshot(includeHistory: false).runs where run.projectID == id && !run.state.isTerminal {
                _ = try await session.cancelRun(run.id)
            }
        }
    }
    public func updateProjectSettings(_ id: String, _ settings: ProjectSettings) {
        let settings = settings.cleaned
        changeProject(id) { $0.settings = settings }
    }
    private func changeProject(_ id: String, _ change: @escaping (inout StoredProject) -> Void) {
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            guard id != StoredProject.hubID, var project = try await repository.snapshot(includeHistory: false).projects.first(where: { $0.id == id }) else { throw StallariError.wrongProject }
            change(&project)
            try await repository.saveProject(project)
        }
    }
    public func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {
        guard let project = projects.first(where: { $0.id == id }) else { throw StallariError.wrongProject }
        try await ProjectGit.saveAgents(URL(fileURLWithPath: project.path, isDirectory: true), text: text, expected: expected)
    }
    public func steer(_ text: String, issue: Issue.ID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        enqueue { [self] in
            guard let repository, let hird else { throw StallariError.closed }
            let snapshot = try await repository.snapshot(includeHistory: false); _ = try scopedIssue(issue, in: snapshot)
            guard let run = snapshot.runs.last(where: { $0.issueID == issue }), !run.state.isTerminal else { throw StallariError.terminalRun }
            try await hird.steer(text, runID: run.id)
            try await repository.appendActivity(.init(at: .now, actor: "나", text: "Hird에게 한마디", detail: text), issueID: issue, runID: run.id)
        }
    }
    public func reviewProposal(_ action: IssueAction, on id: Issue.ID, source: String) async throws {
        guard let session else { throw StallariError.closed }
        switch action {
        case .approveProposal(let version):
            _ = try await session.approveIssue(issueID: id, version: version, source: source)
        case .requestProposalChanges(let version, let note):
            try await session.requestIssueProposalChanges(issueID: id, version: version, note: note, source: source)
        case .rejectProposal(let version, let note):
            try await session.rejectIssueProposal(issueID: id, version: version, note: note, source: source)
        default: throw StallariError.invalidArguments
        }
    }

    public func perform(_ action: IssueAction, on id: Issue.ID) {
        // A new command clears the previous refusal so the detail shows only the current outcome.
        lastError = nil
        enqueue { [self] in
            guard let repository, let session, let hird else { throw StallariError.closed }
            let snapshot = try await repository.snapshot(includeHistory: false)
            let scoped = try scopedIssue(id, in: snapshot)
            var issue = scoped.issue
            let projectID = scoped.projectID
            let latest = snapshot.runs.last { $0.issueID == id }
            switch action {
            case .confirmAppResult(let note):
                try await repository.confirmAppResult(issueID: id, note: note, at: .now)
            case .closeIssue(let reason):
                guard !snapshot.runs.contains(where: { $0.issueID == id && (!$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil)) }) else {
                    throw StallariError.rejectedEvidence("진행 중인 Hird 실행이 있어 이슈를 닫지 않았어요. 먼저 실행을 멈추거나 끝날 때까지 기다리세요.")
                }
                if reason == .applied {
                    guard let project = snapshot.projects.first(where: { $0.id == projectID }),
                          let result = latest?.result,
                          let included = await ResultApplier.included(result, application: issue.application, in: URL(fileURLWithPath: project.absolutePath)) else {
                        report("결과 커밋이 현재 브랜치에 포함되지 않았어요. 반영 후 닫거나 대체됨·취소를 선택해 주세요"); break
                    }
                    issue.application = .applied(branch: included.branch, commit: included.commit)
                    issue.hirds = []; issue.events = []
                    try await repository.saveIssue(issue, projectID: projectID)
                }
                try await repository.closeIssue(id, reason: reason, at: .now)
            case .confirmResult:
                let attested = issue.needsAppConfirmation && issue.userAppConfirmation?.runID == latest?.id
                guard issue.state == .done || attested, latest?.state == .succeeded, let result = latest?.result else { throw StallariError.missingEvidence }
                issue.state = .done; issue.confirmed = true; issue.hirds = []; issue.events = []
                if latest?.mode == .inspect {
                    // Inspection confirmation preserves the report; it has no source change to merge.
                    issue.application = nil
                    try await repository.saveIssue(issue, projectID: projectID)
                    break
                }
                // Confirming brings the judged change into the original; a refusal is kept on the Issue
                // so it stays in 내가 할 것 and can be retried after the user tidies up.
                do {
                    guard let project = snapshot.projects.first(where: { $0.id == projectID }) else { throw ResultApplier.Problem.missingResult }
                    let merge = project.settings.resultMode == .merge
                    let applied = try await ResultApplier.apply(result, toProject: URL(fileURLWithPath: project.absolutePath, isDirectory: true), title: issue.title, merge: merge)
                    issue.application = merge ? .applied(branch: applied.branch, commit: applied.commit) : .kept(branch: applied.branch, commit: applied.commit)
                    // Merged: this Issue's work copies are no longer needed. Branches stay.
                    if let resultsRoot {
                        for run in snapshot.runs where run.issueID == id { if let w = run.workspace {
                            // Retain a built candidate until the user's separate install handoff.
                            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: w.worktreePath).appendingPathComponent("outputs/Knarr.app").path) { continue }
                            _ = try? await WorkspaceCleanup.remove(w, project: URL(fileURLWithPath: project.absolutePath), resultsRoot: resultsRoot)
                        } }
                        refreshStorage()
                    }
                } catch let problem as ResultApplier.Problem {
                    issue.application = .blocked(problem.message)
                }
                try await repository.saveIssue(issue, projectID: projectID)
                onStateChange?()
            case .requestChanges(let note):
                guard let latest, latest.state.isTerminal, latest.result != nil else { throw StallariError.missingEvidence }
                let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    try await repository.appendChat(.init(at: .now, kind: .user(note)), projectID: projectID,
                                                    issueID: id, threadID: threadID)
                }
                let correction = "\n사용자가 결과를 다시 손봐 달라고 요청했어요. 보존된 변경을 유지하고 완료 조건을 다시 검사하세요." +
                    (note.isEmpty ? "" : "\n사용자의 수정 요청:\n" + note)
                _ = try await session.resumeIssue(issueID: id, instruction: latest.hird.role + correction,
                    previousRunID: latest.id, mode: latest.mode, model: latest.requestedModel)
            case .resolvedInput:
                guard issue.state == .needsInput else {
                    throw StallariError.rejectedEvidence("외부 작업을 기다리는 이슈에서만 이어서 진행할 수 있어요. 제안은 저장된 버전으로 승인해 주세요.")
                }
                if snapshot.questions.contains(where: { $0.issueID == id && $0.state == .pending }) {
                    report("이슈의 질문 카드에서 답변 내용을 선택하거나 입력해 주세요")
                } else if let latest, !latest.state.isTerminal {
                    try await hird.steer("사용자가 필요한 외부 입력을 준비했어요. 대기 원인을 다시 확인하고 작업을 이어가세요.", runID: latest.id)
                } else { try await session.send("사용자가 필요한 외부 입력을 준비했어요. 저장된 상태를 확인해 다음 실행을 결정하세요.", about: id) }
            case .approveProposal(let version):
                _ = try await session.approveIssue(issueID: id, version: version)
            case .requestProposalChanges(let version, let note):
                try await session.requestIssueProposalChanges(issueID: id, version: version, note: note)
            case .rejectProposal(let version, let note):
                try await session.rejectIssueProposal(issueID: id, version: version, note: note)
            case .stop:
                for run in snapshot.runs where run.issueID == id && !run.state.isTerminal { _ = try await session.cancelRun(run.id) }
            case .resume:
                // Same instruction again; a preserved result is carried over, a bare stop starts fresh.
                guard issue.state == .failed, let latest, latest.state.isTerminal, latest.state != .succeeded else { throw StallariError.invalidArguments }
                _ = try await session.resumeIssue(issueID: id, instruction: latest.hird.role,
                    previousRunID: latest.result == nil ? nil : latest.id, mode: latest.mode, model: latest.requestedModel)
            }
        }
    }
    public func answer(_ id: Question.ID, with answer: QuestionAnswer) { resolve(id, answer: answer) }
    public func cancel(_ id: Question.ID) { resolve(id, answer: nil) }
    public func replyToQuestion(_ id: Question.ID, answer: QuestionAnswer?) async throws {
        let isExtension = extensionQuestions.contains(where: { $0.id == id })
        resolve(id, answer: answer)
        if isExtension { await extensionReplies[id]?.value } else { try await whenIdle() }
        if questions.first(where: { $0.id == id })?.isPending == true {
            throw NSError(domain: "Knarr.Question", code: 1, userInfo: [NSLocalizedDescriptionKey: "질문 응답을 전달하지 못했어요. 다시 보내 주세요."])
        }
    }
    private func resolve(_ id: Question.ID, answer: QuestionAnswer?) {
        if extensionQuestions.contains(where: { $0.id == id }) {
            guard extensionReplies[id] == nil else { return }
            extensionReplies[id] = Task { [self] in
                await resolveExtensionQuestion(id, answer: answer)
                extensionReplies.removeValue(forKey: id)
            }
            return
        }
        enqueue { [self] in
            guard let repository, let session else { throw StallariError.closed }
            let snapshot = try await repository.snapshot(includeHistory: false)
            guard let question = snapshot.questions.first(where: { $0.id == id.rawValue }), question.state == .pending else { return }
            _ = try scopedIssue(question.issueID, in: snapshot)
            if let answer { _ = try await session.answer(questionID: question.id, runID: question.runID, issueID: question.issueID, answer: answer) }
            else { _ = try await session.cancelQuestion(questionID: question.id, runID: question.runID, issueID: question.issueID) }
        }
    }
    func confirmTerminated(_ ids: [HirdRun.ID]) async {
        guard let repository, let hird else { return }
        for id in ids where await hird.terminationConfirmed(id) { _ = try? await repository.markProcessEnded(id, at: .now) }
    }
    func remainingHirdProcessIDs() async -> [Int32] { await hird?.remainingProcessIDs() ?? [] }
    public func shutdown(includeSharedHird: Bool = true) async -> OMPProcessExit {
        closing = true
        subagents = .init(); acceptsSubagentEvents = false
        clearResponses()
        operation?.cancel(); snapshots?.cancel(); events?.cancel()
        for task in extensionReplies.values { task.cancel() }
        await stoppingTask?.value
        let exit = await session?.shutdown() ?? .init(status: 0, reason: .cancelled, remainingProcessIDs: [])
        await operation?.value; await snapshots?.value; await events?.value
        for task in extensionReplies.values { await task.value }
        extensionReplies.removeAll()
        await finishAssistantMessages(retryFailed: true)
        snapshots = nil; events = nil; operation = nil
        let hirdRemaining = includeSharedHird ? await remainingHirdProcessIDs() : []
        let remaining = Array(Set(exit.remainingProcessIDs + hirdRemaining)).sorted()
        return .init(status: remaining.isEmpty ? exit.status : -1, reason: remaining.isEmpty ? exit.reason : .failed, remainingProcessIDs: remaining)
    }
}

/// Local command errors contain no provider payloads or credentials.
public enum ConversationResetError: Error, LocalizedError {
    case busy, focused, attachments, cancelled, unconfirmed
    public var errorDescription: String? {
        switch self {
        case .busy: "응답이나 기록 저장이 진행 중이에요. 응답을 중지하고 저장이 끝난 뒤 /clear를 보내 주세요."
        case .focused: "작은 대화는 상위 대화와 문맥을 공유해요. 상위 대화에서 /clear를 보내 주세요."
        case .attachments: "문맥을 초기화하려면 첨부 없이 /clear만 보내 주세요."
        case .cancelled: "대화 문맥 초기화가 취소됐어요. 기존 문맥을 유지해요."
        case .unconfirmed: "새 대화 문맥으로 전환됐는지 확인하지 못했어요. /clear를 다시 시도해 주세요."
        }
    }
}
