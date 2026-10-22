import Foundation
import Observation

/// UI boundary: selection chooses a conversation, never moves a live response between sessions.
@MainActor @Observable
public final class LiveKnarrStore: KnarrStore {
    private var workReportController: WorkReportController?
    public var workReports: [WorkReport] { workReportController?.reports ?? [] }
    public var workReportError: String? { workReportController?.error }
    public var workReportBusy: Bool { workReportController?.isBusy ?? false }
    public func cancelWorkReportAnalysis() { workReportController?.cancel() }
    public func retryWorkReport(_ id: String?) { workReportController?.retry(id) }
    public private(set) var subscriptionUsage = SubscriptionUsageModel()
    public private(set) var hiveConnection: HiveConnection?
    @ObservationIgnored private var hiveInstallation: OMPInstallation?
    @ObservationIgnored private var hiveConfiguration: LiveKnarrConfiguration?
    public private(set) var threads: [ConversationThread] = [.default]
    public private(set) var projectSessionPolicy = ProjectSessionPolicy.current
    private var deferredProjectThreads: [String: ConversationThread] = [:]
    private var projectDrafts: [String: ChatDraft] = [:]
    private var savedProjectChat: [String: [ChatItem]] = [:]
    public private(set) var selectedThreadID: String {
        didSet {
            guard oldValue != selectedThreadID else { return }
            conversations[oldValue]?.streamingPresentation.finish()
            current?.streamingPresentation.finish()
        }
    }
    private var tabs: ConversationTabs
    /// Highest snapshot revision already applied; delivery order alone cannot guarantee freshness.
    private var appliedRevision = -1
    public var conversationTabs: [ConversationThread] { tabs.displayed(threads: threads, projects: projects) }
    public func closeConversationTab(_ id: String) {
        tabs.close(id)
        persistTabs()
        if selectedThreadID == id { selectThread(ConversationThread.defaultID) }
    }
    private func persistTabs() { preferences.set(tabs.issueThreadIDs, forKey: "knarr.openIssueTabs") }
    private func reconcileTabs(_ update: PersistenceUpdate, confirmed: Bool = false) {
        // Writes coalesce before the snapshot is built, so an older value can be delivered after a
        // newer read. Applying it would rewind threads, chat, and selection.
        guard update.revision > appliedRevision else { return }
        appliedRevision = update.revision
        let snapshot = update.snapshot
        if projectTransfers != snapshot.projectTransfers { projectTransfers = snapshot.projectTransfers }
        let savedProjects = Set(snapshot.threads.compactMap(\.projectID))
        let projectIDs = Set(snapshot.projects.map(\.id))
        deferredProjectThreads = deferredProjectThreads.filter { projectIDs.contains($0.key) && !savedProjects.contains($0.key) }
        if let selected = snapshot.threads.first(where: { $0.id == selectedThreadID }) { restoreProjectDraft(for: selected) }
        threads = snapshot.threads + deferredProjectThreads.values.sorted { $0.id < $1.id }
        let links = Dictionary(uniqueKeysWithValues: snapshot.chatLinks.map { ($0.chatID, $0.conversationThreadID) })
        let projectThreads = Set(snapshot.threads.filter { $0.projectID != nil }.map(\.id))
        savedProjectChat = [:]
        savedChatByThread = [:]
        let savedThreadIDs = Set(snapshot.threads.map(\.id))
        for item in snapshot.chat {
            let id = links[item.id] ?? ConversationThread.defaultID
            if projectThreads.contains(id) { savedProjectChat[id, default: []].append(item) }
            // A project conversation saved before its first message has no thread column yet; keep it on the main one.
            savedChatByThread[(savedThreadIDs.contains(id) ? id : ConversationThread.defaultID), default: []].append(item)
        }
        tabs.reconcile(threads: threads, issues: snapshot.issues, runs: snapshot.runs)
        let selected = threads.first { $0.id == selectedThreadID }
        if selected == nil, !confirmed {
            // A delivered value can be older than this store's last read. Confirm the thread is
            // really gone before abandoning the person's selection; the check does not block the
            // stream, and a newer applied value cancels it.
            confirmSelectedThreadStillExists()
        } else if selected == nil || (selected?.issueID != nil && !tabs.issueThreadIDs.contains(selectedThreadID)) {
            selectedThreadID = ConversationThread.defaultID
            preferences.set(selectedThreadID, forKey: "knarr.selectedThread")
        }
        persistTabs()
        baselineUnreadLedgers()
        recountAllUnread()
    }
    /// The first snapshot of a run is the history baseline: only answers arriving after it are new,
    /// so an upgrade never lights up every past conversation. A conversation that appears later —
    /// created during this run, or saved by another device — starts with no read marks, so its own
    /// answers count as unread until the person actually sees them.
    private func baselineUnreadLedgers() {
        // Baseline only the conversations that already existed when this run first read storage:
        // their history predates the feature. A conversation created later starts with every
        // answer unread, which is what the person expects from a tab they just opened.
        let firstPass = !unreadBaselineDone
        unreadBaselineDone = true
        for thread in threads where countsAnswers(thread.id) && unreadLedgers[thread.id] == nil {
            if let stored = unreadBook?.ledger(thread: thread.id) {
                unreadLedgers[thread.id] = stored
            } else if firstPass {
                installLedger(for: thread.id, baselining: savedAnswers(thread.id))
            } else {
                let empty = UnreadAnswerLedger()
                unreadLedgers[thread.id] = empty
                unreadBook?.save(empty, thread: thread.id)
            }
        }
    }
    private func installLedger(for threadID: String, baselining answers: [UnreadAnswer]) {
        if let stored = unreadBook?.ledger(thread: threadID) {
            unreadLedgers[threadID] = stored
            return
        }
        let ledger = UnreadAnswerLedger(baselining: answers)
        unreadLedgers[threadID] = ledger
        unreadBook?.save(ledger, thread: threadID)
    }
    /// What the last snapshot already held for a conversation, used only for a baseline.
    private func savedAnswers(_ threadID: String) -> [UnreadAnswer] {
        let items = savedChatByThread[threadID] ?? (threadID == ConversationThread.defaultID ? initialMessages : [])
        return items.compactMap(UnreadAnswers.answer)
    }
    /// Re-reads persistence once when a delivered snapshot drops the selected thread.
    private func confirmSelectedThreadStillExists() {
        guard !confirmingSelection, let repository else { return }
        confirmingSelection = true
        let missing = selectedThreadID
        Task { [weak self] in
            guard let self else { return }
            let latest = try? await repository.snapshotUpdate()
            self.confirmingSelection = false
            guard let latest, self.selectedThreadID == missing,
                  !latest.snapshot.threads.contains(where: { $0.id == missing }) else { return }
            // The fresh read is authoritative even when no write advanced the revision since.
            guard latest.revision > self.appliedRevision else {
                self.selectedThreadID = ConversationThread.defaultID
                self.preferences.set(self.selectedThreadID, forKey: "knarr.selectedThread")
                self.persistTabs()
                return
            }
            self.reconcileTabs(latest, confirmed: true)
        }
    }
    private var confirmingSelection = false
    private var conversations: [String: LiveConversation] = [:]
    private var auxiliaryBusyComposers: Set<UUID> = []
    public func setAuxiliaryComposerBusy(_ id: UUID, busy: Bool) {
        if busy { auxiliaryBusyComposers.insert(id) } else { auxiliaryBusyComposers.remove(id) }
        autoInstaller?.resumeIfWaiting()
    }
    /// Starts true: until AppKit reports the app inactive, assume someone is using it.
    public private(set) var appIsActive = true
    /// Advances on every activation so the transcript re-checks what is now visible.
    public private(set) var activationRevision = 0
    public func setAppActive(_ active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        if active { activationRevision += 1; workReportController?.wake() }
        if !active { autoInstaller?.resumeIfWaiting() }
    }
    /// The number beside each tab title. Recomputed only when that conversation's rows change or
    /// the person's own reading advances, never inside the tab bar's body.
    public private(set) var unreadCounts: [String: Int] = [:]
    private var unreadBook: UnreadAnswerBook?
    private var unreadLedgers: [String: UnreadAnswerLedger] = [:]
    /// The first snapshot of this run is the only one whose history becomes a baseline.
    private var unreadBaselineDone = false
    public func unreadAnswerCount(forThread threadID: String) -> Int { unreadCounts[threadID] ?? 0 }
    /// The tab bar never badges Issue conversations; only the main and project conversations count.
    private func countsAnswers(_ threadID: String) -> Bool {
        threads.contains { $0.id == threadID && $0.issueID == nil }
    }
    private func ledger(_ threadID: String) -> UnreadAnswerLedger {
        if let ledger = unreadLedgers[threadID] { return ledger }
        // Before the first snapshot the history is unknown; treat everything already there as read
        // so an early chat update cannot badge a past conversation. The baseline pass then stores
        // the real boundary.
        guard unreadBaselineDone else { return .init() }
        // A conversation first seen after the baseline has read nothing of its own history.
        let ledger = UnreadAnswerLedger()
        unreadLedgers[threadID] = ledger
        unreadBook?.save(ledger, thread: threadID)
        return ledger
    }
    /// Answers a tab could report, from the live conversation when it is open and the last
    /// snapshot otherwise. Both already hold the streaming row, so one answer is never counted twice.
    private func unreadAnswers(_ threadID: String) -> [UnreadAnswer]? {
        if let conversation = conversations[threadID] {
            guard conversation.hasLoadedHistory else { return nil }
            return conversation.chat.compactMap(UnreadAnswers.answer)
        }
        if let saved = savedChatByThread[threadID] { return saved.compactMap(UnreadAnswers.answer) }
        if threadID == ConversationThread.defaultID, !initialMessages.isEmpty { return initialMessages.compactMap(UnreadAnswers.answer) }
        return []
    }
    private func recountUnread(_ threadID: String) {
        guard countsAnswers(threadID) else {
            if unreadCounts[threadID] != nil { unreadCounts[threadID] = nil }
            return
        }
        guard let answers = unreadAnswers(threadID) else { return }
        let ledger = ledger(threadID)
        let count = answers.lazy.filter { !ledger.isRead($0) }.count
        if unreadCounts[threadID] != count { unreadCounts[threadID] = count }
    }
    private func recountAllUnread() {
        var seen: Set<String> = []
        for thread in threads where seen.insert(thread.id).inserted { recountUnread(thread.id) }
        for id in conversations.keys where seen.insert(id).inserted { recountUnread(id) }
        for id in unreadCounts.keys where seen.insert(id).inserted { recountUnread(id) }
    }
    /// The page reports only rows it actually showed. The store re-checks identity, thread,
    /// app activity, and that each id is a countable answer of this tab.
    public func markAnswersRead(_ messageIDs: [UUID], threadID: String) {
        guard appIsActive, threadID == selectedThreadID, !closing,
              countsAnswers(threadID), !messageIDs.isEmpty else { return }
        guard let all = unreadAnswers(threadID) else { return }
        let wanted = Set(messageIDs)
        let answers = all.filter { wanted.contains($0.id) }
        guard !answers.isEmpty else { return }
        var ledger = ledger(threadID)
        guard answers.contains(where: { !ledger.isRead($0) }) else { return }
        ledger.markRead(answers, among: all)
        unreadLedgers[threadID] = ledger
        unreadBook?.save(ledger, thread: threadID)
        recountUnread(threadID)
    }
    var localInstallIsIdle: Bool {
        !closing && autoInstallEnabled && !appIsActive && opening.isEmpty
            && !issues.contains(where: \.hasActiveHird)
            && !conversations.values.contains(where: { $0.isBusyForInstall }) && !hasUnsentDraft
    }
    private var initialDraft = ChatDraft()
    private var initialMessages: [ChatItem] = []
    private var startupError: String?
    public var lastError: String? { current?.lastError ?? startupError }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var repository: SQLiteKnarrRepository?
    @ObservationIgnored private var threadFactory: ((ConversationThread) async throws -> LiveConversation)?
    @ObservationIgnored private var opening: [String: Task<LiveConversation, Error>] = [:]
    @ObservationIgnored private var bootstrap: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var snapshots: Task<Void, Never>?
    @ObservationIgnored private var ownsRepository = false
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var startupExits: [OMPProcessExit] = []
    public var installHandoff: (@MainActor (InstallRestart.Job) throws -> Void)?
    /// Native delivery observes committed snapshots without changing in-app/mobile deliveries.
    public var desktopNotificationSnapshot: ((PersistenceSnapshot) -> Void)?
    public var desktopNotificationStatus: DesktopNotificationStatus = .unavailable
    public private(set) var notificationNavigationRevision = 0
    public func currentNotificationSnapshot() async throws -> PersistenceSnapshot {
        guard let repository, !closing else { throw StallariError.closed }
        return try await repository.snapshot(includeHistory: false)
    }
    public func openNotificationThread(_ id: String) {
        selectThread(id)
        notificationNavigationRevision += 1
    }
    @ObservationIgnored private var dataDirectory: URL?
    /// One-line auto install state for Settings. Updated from the installer, never polled.
    public private(set) var autoInstallStatus: String?
    @ObservationIgnored private var autoInstaller: AutoInstaller?
    @ObservationIgnored private var sourceRootCache: URL?
    /// Every conversation reads the same preference; this copy keeps the composer observing it.
    public private(set) var whileRespondingMode: WhileRespondingMode = .steer
    public func setWhileRespondingMode(_ mode: WhileRespondingMode) {
        preferences.set(mode.rawValue, forKey: WhileRespondingMode.preferenceKey)
        whileRespondingMode = mode
        for conversation in conversations.values { conversation.whileRespondingModeChanged() }
    }
    public var autoInstallEnabled: Bool { preferences.object(forKey: "knarr.autoInstall") as? Bool ?? true }
    public func setAutoInstall(_ enabled: Bool) {
        preferences.set(enabled, forKey: "knarr.autoInstall")
        autoInstaller?.enabledChanged(enabled)
        if enabled { checkAutoInstall() }
    }
    public var installationBlockReason: String? { global?.installationBlockReason }
    public func approvalBlockReason(for id: Issue.ID) -> String? { global?.approvalBlockReason(for: id) }
    public func refreshResultApplications() { global?.refreshResultApplications() }
    public func resultReport(_ id: Issue.ID) async -> String { await global?.resultReport(id) ?? "저장된 결과 보고서가 없어요" }
    public func installAndRestart(_ id: Issue.ID) {
        enqueue { [self] in
            let target = try await owner(of: id)
            target.installAndRestart(id, dataDirectory: dataDirectory, installHandoff: installHandoff)
            try await target.whenIdle()
        }
    }
    private var current: LiveConversation? { conversations[selectedThreadID] }
    private var global: LiveConversation? { conversations[ConversationThread.defaultID] }

    public var stallari: StallariInfo { current?.stallari ?? .init(engine: "OMP · 연결 전", scope: "모든 프로젝트") }
    public var chat: [ChatItem] {
        if let current { return current.chat }
        if selectedProjectID != nil { return savedProjectChat[selectedThreadID] ?? [] }
        return initialMessages
    }
    /// Every conversation the Mac holds, for the phone's thread list. An open conversation keeps
    /// its live message list; the rest come from the last snapshot, so nothing newer is lost.
    public var chatByThread: [String: [ChatItem]] {
        var value = savedChatByThread
        if !initialMessages.isEmpty, value[ConversationThread.defaultID] == nil { value[ConversationThread.defaultID] = initialMessages }
        for (id, conversation) in conversations where !conversation.chat.isEmpty || value[id] != nil {
            value[id] = conversation.chat
        }
        if value[selectedThreadID] == nil { value[selectedThreadID] = chat }
        return value
    }
    @ObservationIgnored private var savedChatByThread: [String: [ChatItem]] = [:]
    public var stallariWork: [SubagentWork] { current?.stallariWork ?? [] }
    public var isResponding: Bool { current?.isResponding ?? false }
    public var respondingConversationRoots: Set<UUID> { current?.respondingConversationRoots ?? [] }
    public var stoppableConversationRoots: Set<UUID> { current?.stoppableConversationRoots ?? [] }
    public var waitingConversationRoots: Set<UUID> { current?.waitingConversationRoots ?? [] }
    public func stopBlockReason(for root: UUID) -> String? { current?.stopBlockReason(for: root) }
    /// Reads every session, not only the selected one: a background answer or a Hird on the
    /// thread's issue must still mark its tab.
    public func isThreadWorking(_ threadID: String) -> Bool {
        if conversations[threadID]?.isWorking == true { return true }
        return threadBoundIssueIsWorking(threadID)
    }
    public var streamingText: String { current?.streamingText ?? "" }
    public var streamingMessageID: UUID? { current?.streamingMessageID }
    public var streamingPresentation: StreamingTextPresentation? { current?.streamingPresentation }
    public var responseRulesPath: String? { current?.responseRulesPath }
    public var responseRulesText: String { current?.responseRulesText ?? "" }
    public var thinkingLevel: String? { current?.thinkingLevel ?? global?.thinkingLevel }
    public var thinkingLevels: [String] { current?.thinkingLevels ?? global?.thinkingLevels ?? [] }
    public var contextUsage: ContextUsage? { current?.contextUsage }
    public var responseStartedAt: Date? { current?.responseStartedAt }
    public var responseLastEventAt: Date? { current?.responseLastEventAt }
    public var responseStatus: String { current?.responseStatus ?? "응답 준비 중" }
    public var extensionPresentation: ExtensionPresentation { current?.extensionPresentation ?? .init() }
    public func dismissExtensionToast() { current?.dismissExtensionToast() }
    public var isStopping: Bool { current?.isStopping ?? false }
    public var isSubmitting: Bool { current?.isSubmitting ?? false }
    public var sendingDraft: ChatDraft? { current?.sendingDraft }
    public var isSubmissionWaiting: Bool { current?.isSubmissionWaiting ?? false }
    public var failedDraft: ChatDraft? { current?.failedDraft }
    public var assistantPersistenceError: String? { current?.assistantPersistenceError }
    public var isRetryingAssistantPersistence: Bool { current?.isRetryingAssistantPersistence ?? false }
    public func retryAssistantPersistence() async { await current?.retryAssistantPersistence() }
    public private(set) var projectTransfers: [ProjectTransfer] = []
    public func transferToMain(summary: String, requestMessageID: UUID, messageIDs: [UUID]) async throws -> ProjectTransfer {
        guard !closing, let repository, let thread = threads.first(where: { $0.id == selectedThreadID }),
              thread.projectID != nil, thread.issueID == nil else { throw StallariError.wrongProject }
        // UI and model bridge share the same repository operation and durable ownership checks.
        let transfer = try await repository.enqueueProjectTransfer(id: UUID().uuidString, originThreadID: thread.id,
            requestMessageID: requestMessageID, summary: summary, messageIDs: messageIDs)
        reconcileTabs(try await repository.snapshotUpdate())
        return transfer
    }
    public func retryProjectTransfer(_ id: String) async throws {
        guard !closing, let repository else { throw StallariError.closed }
        try await repository.retryProjectTransfer(id, originThreadID: selectedThreadID)
    }
    public var requestedModel: String? { current?.requestedModel ?? global?.requestedModel }
    public var pendingModel: String? { current?.pendingModel ?? global?.pendingModel }
    public var models: [String] { current?.models ?? global?.models ?? [] }
    public var model: String? { current?.model ?? global?.model }
    public var storageBytes: Int64? { global?.storageBytes }
    public var issues: [Issue] { global?.issues ?? [] }
    public var questions: [Question] {
        (global?.questions.filter { $0.extensionIdentity == nil } ?? []) + (current?.extensionQuestions ?? [])
    }
    public var projects: [ProjectSummary] { global?.projects ?? [] }
    private var selectedProjectID: String? { threads.first { $0.id == selectedThreadID }?.projectID }
    private func projectDraftKey(_ id: String) -> String { "knarr.projectDraft." + id }
    private func restoreProjectDraft(for thread: ConversationThread) {
        guard let id = thread.projectID, projectDrafts[id] == nil else { return }
        let data = preferences.data(forKey: "knarr.draft." + thread.id) ?? preferences.data(forKey: projectDraftKey(id))
        var draft = data.flatMap { try? JSONDecoder().decode(ChatDraft.self, from: $0) } ?? .init()
        draft.project = id
        projectDrafts[id] = draft
    }
    public var composerDraft: ChatDraft {
        get {
            if let current { return current.composerDraft }
            if let id = selectedProjectID {
                return projectDrafts[id] ?? .init(project: id)
            }
            return initialDraft
        }
        set {
            let draftWasEmpty = composerDraft.isEmpty
            var draft = newValue
            if let id = selectedProjectID {
                draft.project = id
                projectDrafts[id] = draft
                if let data = try? JSONEncoder().encode(draft) { preferences.set(data, forKey: projectDraftKey(id)) }
            }
            if let current { current.composerDraft = draft }
            else if selectedProjectID == nil {
                initialDraft = draft
                let key = selectedThreadID == ConversationThread.defaultID ? "knarr.draft" : "knarr.draft." + selectedThreadID
                if let data = try? JSONEncoder().encode(draft) { preferences.set(data, forKey: key) }
            }
            // Draft text is one of the install wait conditions; the gate re-checks the whole store.
            if draftWasEmpty != composerDraft.isEmpty { autoInstaller?.resumeIfWaiting() }
        }
    }

    public init(preferences: UserDefaults = .standard, subscriptionUsage: SubscriptionUsageModel? = nil) {
        if let subscriptionUsage { self.subscriptionUsage = subscriptionUsage }
        self.preferences = preferences
        unreadBook = UnreadAnswerBook(preferences: preferences)
        selectedThreadID = preferences.string(forKey: "knarr.selectedThread") ?? ConversationThread.defaultID
        whileRespondingMode = .init(preferences: preferences)
        tabs = ConversationTabs(saved: preferences.stringArray(forKey: "knarr.openIssueTabs") ?? [])
        initialDraft = preferences.data(forKey: selectedThreadID == ConversationThread.defaultID ? "knarr.draft" : "knarr.draft." + selectedThreadID).flatMap { try? JSONDecoder().decode(ChatDraft.self, from: $0) } ?? .init()
    }
    public init(repository: SQLiteKnarrRepository, session: StallariSession, rpc: any StallariRPC, hird: any HirdAdapter,
                preferences: UserDefaults = .standard, resultsRoot: URL? = nil, subscriptionUsage: SubscriptionUsageModel? = nil) {
        if let subscriptionUsage { self.subscriptionUsage = subscriptionUsage }
        self.preferences = preferences; self.repository = repository
        unreadBook = UnreadAnswerBook(preferences: preferences)
        selectedThreadID = preferences.string(forKey: "knarr.selectedThread") ?? ConversationThread.defaultID
        whileRespondingMode = .init(preferences: preferences)
        tabs = ConversationTabs(saved: preferences.stringArray(forKey: "knarr.openIssueTabs") ?? [])
        let main = LiveConversation(repository: repository, session: session, rpc: rpc, hird: hird,
            preferences: preferences, resultsRoot: resultsRoot, responseRules: nil, instructionDataDirectory: nil,
            instructionProjectID: nil, subscriptionUsage: self.subscriptionUsage)
        conversations[ConversationThread.defaultID] = main
        observeChat(main)
    }
    func setThreadFactory(_ factory: @escaping (ConversationThread) async throws -> LiveConversation) { threadFactory = factory }

    public func startFromEnvironment() { start(.standard()) }
    public func start(_ configuration: LiveKnarrConfiguration) { start(configuration, makeRPC: { OMPRPCSession() }) }
    func start(_ configuration: LiveKnarrConfiguration, makeRPC: @escaping @Sendable () -> any HirdRPC) {
        guard bootstrap == nil, repository == nil, !closing else { return }
        hiveConfiguration = configuration
        if hiveConnection == nil {
            hiveConnection = HiveConnection(serviceNamespace: HiveConnection.serviceNamespace(dataDirectory: configuration.dataDirectory))
        }
        var usageEnvironment = configuration.environment
        usageEnvironment["KNARR_OMP_EXECUTABLE"] = configuration.executable.path
        let usageReader = LocalSessionAPI(environment: usageEnvironment)
        let previousUsage = subscriptionUsage
        bootstrap = Task { [weak self] in
            guard let self else { return }
            await previousUsage.shutdown()
            guard !self.closing, !Task.isCancelled else { return }
            self.subscriptionUsage = .init(reader: usageReader)
            do {
                let installation = try OMPInstallation(executable: configuration.executable)
                self.hiveInstallation = installation
                try Task.checkCancellation()
                let root = configuration.dataDirectory
                self.dataDirectory = root
                self.projectSessionPolicy = try ProjectSessionPolicy.load(directory: root.appendingPathComponent("hird"))
                // Seed the tree once at start; every launch re-reads it so edits apply without
                // restarting the app. A failure is kept and fails the request closed.
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let rules = ResponseRulesFile(url: try configuration.responseRulesURL)
                try rules.prepare()
                let repository = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("knarr.db"))
                await repository.setProjectSessionPolicy(self.projectSessionPolicy)
                self.repository = repository; self.ownsRepository = true
                let firstRun = try await repository.snapshot(includeHistory: false).projects.allSatisfy { $0.id == StoredProject.hubID }
                try await repository.saveProject(.init(id: StoredProject.hubID, name: "Stallari", absolutePath: root.path))
                var known = Set(try await repository.snapshot(includeHistory: false).projects.map(\.id))
                var imported: [StoredProject] = []
                if firstRun, let jitdeck = configuration.jitdeckDatabase { imported = (try? JitdeckProjects.read(database: jitdeck)) ?? [] }
                for project in imported + configuration.projects where known.insert(project.id).inserted { try await repository.saveProject(project) }
                let hive = self.hiveConnection?.runtime
                let hird = OMPHirdAdapter(repository: repository, installation: installation,
                    resultRoot: root.appendingPathComponent("results"), expectedModel: "openai-codex/gpt-6.1-sol", environment: configuration.environment, extensionRoot: root, hive: hive)
                let projectPolicy = self.projectSessionPolicy
                self.setThreadFactory { [weak self] thread in
                    guard let self, !self.closing else { throw StallariError.closed }
                    let runRoot = root.appendingPathComponent("stallari/launches/" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
                    let extensions = KnarrExtensions(root: root)
                    let sessionDirectory = try StallariTools.sessionDirectory(root: root, threadID: thread.id)
                    let rpc = StallariRPCProcess(launch: { loadingExtensions in
                        let instructions = try? InstructionSources.load(dataDirectory: root, role: .stallari, projectID: thread.projectID)
                        return try StallariTools.configuration(installation: installation, workingDirectory: runRoot,
                            configurationFile: runRoot.appendingPathComponent("stallari.yml"), sessionDirectory: sessionDirectory,
                            environment: configuration.environment, extensions: extensions, loadingExtensions: loadingExtensions,
                            projectID: thread.projectID, projectSessionPolicy: projectPolicy,
                            instructions: instructions, instructionFailure: instructions == nil ? InstructionSources.failure : nil,
                            threadID: thread.id, hive: hive)
                    }, makeRPC: makeRPC)
                    do {
                        try await rpc.start()
                        try Task.checkCancellation()
                        var state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))
                        let available = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))
                        if let wanted = self.preferences.string(forKey: "knarr.model"), LiveConversation.supported(available).contains(wanted) {
                            let parts = wanted.split(separator: "/", maxSplits: 1).map(String.init)
                            _ = try await rpc.request("set_model", fields: ["provider": .string(parts[0]), "modelId": .string(parts[1])], timeout: .seconds(20))
                            state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))
                        }
                        _ = try LiveKnarrConfiguration.selectedModel(state: state, available: available)
                        let session = StallariSession(repository: repository, rpc: rpc, hird: hird,
                            sessionReader: LocalSessionAPI(environment: configuration.environment), responseRules: rules,
                            instructionsDirectory: root, instructionProjectID: thread.projectID,
                            requestedModel: self.preferences.string(forKey: "knarr.model"),
                            projectSessionPolicy: projectPolicy,
                            requestedThinking: self.preferences.string(forKey: "knarr.thinking"),
                            persistModel: { [weak self] model in self?.preferences.set(model, forKey: "knarr.model") },
                            persistThinking: { [weak self] level in self?.preferences.set(level, forKey: "knarr.thinking") }, threadID: thread.id,
                            extensions: extensions, restartRPC: { try await rpc.restart() })
                        return LiveConversation(repository: repository, session: session, rpc: rpc, hird: hird, threadID: thread.id,
                            preferences: self.preferences, resultsRoot: root.appendingPathComponent("results"), responseRules: rules,
                            instructionDataDirectory: root, instructionProjectID: thread.projectID,
                            subscriptionUsage: self.subscriptionUsage)
                    } catch {
                        self.startupExits.append(await rpc.shutdown(cancel: true))
                        throw error
                    }
                }
                try await self.connect()
                let reports = WorkReportController(url: root.appendingPathComponent("reports/work-reports.json"),
                    snapshot: { try await repository.snapshot(includeHistory: false) },
                    analyze: { [weak self] report, previous in
                        guard let selection = await self?.reportModelSelection() else { throw WorkReportAnalyzer.Failure.modelUnavailable }
                        let directory = root.appendingPathComponent("reports/launches/" + UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        var launch = try WorkReportAnalyzer.configuration(installation: installation, directory: directory,
                            model: report.analysisModel ?? selection.0, thinking: selection.1, environment: configuration.environment)
                        if let hive { launch = try hive.configure(launch) }
                        return try await WorkReportAnalyzer.run(report: report, previous: previous, configuration: launch, rpc: makeRPC())
                    }, model: { [weak self] in self?.global?.model })
                self.workReportController = reports
                await reports.start()
                self.prepareAutoInstaller()
                self.checkAutoInstall()
            } catch {
                for conversation in self.conversations.values { self.startupExits.append(await conversation.shutdown()) }
                self.conversations.removeAll()
                self.snapshots?.cancel(); await self.snapshots?.value; self.snapshots = nil
                if self.ownsRepository { try? await self.repository?.close(); self.repository = nil; self.ownsRepository = false }
                if !self.closing { self.report(LiveConversation.safeError(error, fallback: "Live 연결을 시작하지 못했어요. OMP 설치와 저장 경로를 확인해 주세요")) }
            }
        }
    }

    /// The local MCP adapter's only entry point into the app. The endpoint lends exactly one
    /// fixed context — the app's main Stallari — and the caller cannot name an issue, thread or
    /// origin to move it. `StallariSession` then applies the same ownership, version and
    /// active-run rules the screens use, so main-origin issues are writable here and
    /// project-origin issues stay refused exactly as they are for the main conversation.
    public func adminService() -> KnarrAdminService? {
        guard let repository, !closing else { return nil }
        return KnarrAdminService(repository: repository) { [weak self] in
            guard let self, !self.closing else {
                throw KnarrAdminError.unavailable("Knarr 앱이 종료되어 요청을 처리할 수 없습니다.")
            }
            guard let conversation = self.global else {
                throw KnarrAdminError.unavailable("Knarr의 기본 Stallari 대화가 아직 준비되지 않았습니다. 잠시 뒤 다시 시도하십시오.")
            }
            guard let session = conversation.stallariSession else {
                throw KnarrAdminError.unavailable("Stallari 연결이 아직 준비되지 않았습니다. 잠시 뒤 다시 시도하십시오.")
            }
            return session
        }
    }

    /// Native UI action only; no credential-bearing Stallari host tool.
    public func refreshHiveProvider() async throws {
        guard !closing else { throw StallariError.closed }
        guard !conversations.values.contains(where: { $0.isResponding || $0.isSubmitting }),
              !issues.contains(where: \.hasActiveHird) else {
            throw StallariError.rejectedEvidence("진행 중인 실행은 유지했어요. 끝난 뒤 모델 목록을 새로 고쳐 주세요.")
        }
        if conversations.isEmpty, let configuration = hiveConfiguration {
            await bootstrap?.value
            bootstrap = nil
            start(configuration)
            await bootstrap?.value
            guard global != nil else { throw HiveProbeError.incomplete }
        } else {
            for conversation in conversations.values { try await conversation.refreshHiveProvider() }
        }
    }
    public func verifyHiveConnection() async {
        guard let hiveConnection else { return }
        await hiveConnection.verify { [self] in
            guard let hiveInstallation, let dataDirectory, !closing else { throw HiveProbeError.incomplete }
            let root = dataDirectory.appendingPathComponent("hive-verification")
            let receipt = try await HiveOMPProbe.run(installation: hiveInstallation, runtime: hiveConnection.runtime, root: root)
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("latest.json"), options: .atomic)
        }
    }

    public func connect() async throws {
        guard !closing, snapshots == nil, let repository else { throw StallariError.closed }
        // Register first, then read. Nothing is missed, and no snapshot captured before this read
        // can arrive later and rewind a thread created during connect.
        let updates = try await repository.subscribe(initial: false)
        let initialUpdate = try await repository.snapshotUpdate()
        let initialSnapshot = initialUpdate.snapshot
        threads = initialSnapshot.threads
        if let selected = threads.first(where: { $0.id == selectedThreadID }) { tabs.open(selected) }
        else { selectedThreadID = ConversationThread.defaultID }
        reconcileTabs(initialUpdate)
        subscriptionUsage.observeHirdRuns(initialSnapshot.runs)
        desktopNotificationSnapshot?(initialSnapshot)
        if let existing = global {
            await configureApprovalRouting(existing)
            try await existing.connect()
        }
        // Idle saved threads do not each create an OMP process at launch. Open their
        // durable outboxes when needed; selected conversations retain their own session.
        let snapshot = try await repository.snapshot(includeHistory: false)
        threads = snapshot.threads
        var required = snapshot.pendingDeliveryThreadIDs.union([ConversationThread.defaultID])
        if threads.first(where: { $0.id == selectedThreadID })?.projectID == nil { required.insert(selectedThreadID) }
        for thread in threads where required.contains(thread.id) { _ = try await conversation(for: thread.id) }
        snapshots = Task { [weak self] in
            for await delivered in updates {
                guard !Task.isCancelled, let self, !self.closing else { break }
                self.reconcileTabs(delivered)
                self.subscriptionUsage.observeHirdRuns(delivered.snapshot.runs)
                self.desktopNotificationSnapshot?(delivered.snapshot)
                for id in delivered.snapshot.pendingDeliveryThreadIDs {
                    do { try await self.conversation(for: id).drainDeliveries() }
                    catch { self.startupError = "저장된 후속 전달이 미완료예요. 전달 상태를 확인하고 다시 시도할 수 있어요." }
                }
            }
        }
    }
    private func configureApprovalRouting(_ conversation: LiveConversation) async {
        await conversation.setApprovalRouter { [weak self] issueID, version, source in
            guard let self else { throw StallariError.closed }
            return try await self.owner(of: issueID).approveIssue(issueID, version: version, source: source)
        }
        await conversation.setQuestionAnswerRouter { [weak self] questionID, runID, issueID, answer in
            guard let self else { throw StallariError.closed }
            return try await self.owner(of: issueID).answerPendingQuestion(questionID, runID: runID, issueID: issueID, answer: answer)
        }
    }
    private func reportModelSelection() -> (String, String)? {
        guard !closing, let model = global?.model else { return nil }
        return (model, global?.thinkingLevel ?? "high")
    }

    // MARK: - Auto install

    private func prepareAutoInstaller() {
        guard autoInstaller == nil, let dataDirectory else { return }
        let target = Bundle.main.bundleURL
        let source = knarrSourceRoot()
        let policy = AutoInstallPolicy.current
        let root = dataDirectory.appendingPathComponent(policy.rootDirectoryName)
        let builder: (any AutoInstallBuilding)? = source.map { DefaultAutoInstallBuilder(sourceRoot: $0, root: root, policy: policy) }
        let installed = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let installer = AutoInstaller(policy: policy, target: target, installedVersion: installed,
            source: source, builder: builder,
            install: { [weak self] candidate in
                guard let self else { throw LiveKnarrError.installUnavailable }
                try await self.installCandidate(candidate)
            },
            gate: { [weak self] in await self?.installGateInputs() ?? .init(runsBusy: true, activeHirds: true, conversationsBusy: true, hasDraft: true, appActive: true) },
            enabled: autoInstallEnabled,
            failedCommit: failedAttempt?.commit, failedReason: failedAttempt?.reason)
        installer.onPhaseChange = { [weak self] in
            guard let self else { return }
            self.autoInstallStatus = installer.statusLine()
            self.persistFailedAttempt(installer)
        }
        autoInstaller = installer
        autoInstallStatus = installer.statusLine()
        for conversation in conversations.values { attachStateCallback(conversation) }
    }

    private func attachStateCallback(_ conversation: LiveConversation) {
        conversation.onStateChange = { [weak self] in self?.autoInstaller?.resumeIfWaiting() }
    }
    /// Counts one tab's answers when only that conversation's rows changed; the tab bar never
    /// scans whole transcripts.
    private func observeChat(_ conversation: LiveConversation) {
        conversation.onChatChange = { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.recountUnread(conversation.threadID)
        }
        recountUnread(conversation.threadID)
    }

    /// Reads the installer state without a timer: activation, a committed approval, or an idle conversation.
    public func checkAutoInstall() {
        guard let autoInstaller else { return }
        Task { [weak self] in
            guard let self else { return }
            let commit = await self.mainCommit(relativeTo: autoInstaller.source)
            self.autoInstaller?.check(mainCommit: commit)
        }
    }

    private var failedAttemptKey: String { "knarr.autoInstall.failure" }
    private var failedAttempt: (commit: String, reason: String)? {
        guard let stored = preferences.dictionary(forKey: failedAttemptKey),
              let commit = stored["commit"] as? String, let reason = stored["reason"] as? String else { return nil }
        return (commit, reason)
    }
    private func persistFailedAttempt(_ installer: AutoInstaller) {
        guard let commit = installer.failedCommit, let reason = installer.failedReason else {
            preferences.removeObject(forKey: failedAttemptKey)
            return
        }
        preferences.set(["commit": commit, "reason": reason], forKey: failedAttemptKey)
    }

    /// The Knarr source tree is the project whose folder owns the build script.
    private func knarrSourceRoot() -> URL? {
        if let sourceRootCache { return sourceRootCache }
        let roots = projects.filter { $0.id != StoredProject.hubID }.map { URL(fileURLWithPath: $0.path) }
        sourceRootCache = AutoInstallSource.find(in: roots)
        return sourceRootCache
    }
    private func mainCommit(relativeTo source: URL?) async -> String? {
        guard let source else { return nil }
        let common = try? await HirdWorkspace.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: source)
        if let common, !common.isEmpty {
            let loose = URL(fileURLWithPath: common).appendingPathComponent("refs/heads/main")
            if let text = try? String(contentsOf: loose, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               text.count == 40 { return text }
        }
        return try? await HirdWorkspace.git(["rev-parse", "--verify", "refs/heads/main^{commit}"], at: source)
    }

    /// Restart-blocking state, read the same way `installAndRestart` reads it.
    private func installGateInputs() async -> AutoInstallGate.Inputs {
        let runsBusy: Bool
        if let repository, let snapshot = try? await repository.snapshot(includeHistory: false) {
            runsBusy = snapshot.runs.contains { !$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil) }
        } else { runsBusy = true }
        return .init(runsBusy: runsBusy, activeHirds: issues.contains(where: \.hasActiveHird),
            conversationsBusy: !opening.isEmpty || conversations.values.contains(where: { $0.isBusyForInstall }),
            hasDraft: hasUnsentDraft, appActive: appIsActive)
    }
    private var hasUnsentDraft: Bool {
        if !auxiliaryBusyComposers.isEmpty || !initialDraft.isEmpty { return true }
        if projectDrafts.values.contains(where: { !$0.isEmpty }) { return true }
        return conversations.values.contains { !$0.composerDraft.isEmpty }
    }

    private func installCandidate(_ candidate: AutoInstallCandidate) async throws {
        guard let repository, let dataDirectory, let installHandoff else { throw LiveKnarrError.installUnavailable }
        let target = Bundle.main.bundleURL
        let job = try await Task.detached(priority: .utility) {
            try InstallRestart.prepare(candidate: candidate.app, target: target,
                database: dataDirectory.appendingPathComponent("knarr.db"),
                root: dataDirectory.appendingPathComponent("installations"))
        }.value
        do {
            try Task.checkCancellation()
            guard localInstallIsIdle else { throw LiveKnarrError.installBusy }
            let main = await mainCommit(relativeTo: autoInstaller?.source)
            guard main == candidate.commit else {
                checkAutoInstall()
                throw LiveKnarrError.installBusy
            }
            try await repository.beginInstallation()
            // No suspension from this last local-state check through the synchronous handoff.
            try Task.checkCancellation()
            guard localInstallIsIdle else { throw LiveKnarrError.installBusy }
            try installHandoff(job)
        } catch {
            await repository.cancelInstallation()
            try? FileManager.default.removeItem(at: job.directory)
            throw error
        }
    }

    private func conversation(for id: String) async throws -> LiveConversation {
        guard !closing else { throw StallariError.closed }
        if let task = opening[id] { return try await task.value }
        if let existing = conversations[id] { return existing }
        if !threads.contains(where: { $0.id == id }), let repository {
            threads = try await repository.snapshot(includeHistory: false).threads
        }
        guard let thread = threads.first(where: { $0.id == id }), let threadFactory else { throw StallariError.closed }
        let task = Task {
            if thread.issueID != nil, let repository {
                try await repository.prepareIssueHandoff(threadID: thread.id)
            }
            let conversation = try await threadFactory(thread)
            await configureApprovalRouting(conversation)
            self.attachStateCallback(conversation)
            do { try await conversation.connect(); return conversation }
            catch { startupExits.append(await conversation.shutdown()); throw error }
        }
        opening[id] = task
        defer { opening.removeValue(forKey: id); autoInstaller?.resumeIfWaiting() }
        let result = try await task.value
        guard !closing else { startupExits.append(await result.shutdown()); throw StallariError.closed }
        conversations[id] = result
        observeChat(result)
        return result
    }
    private func enqueue(_ work: @escaping () async throws -> Void) {
        guard !closing else { return }
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !self.closing, !Task.isCancelled else { return }
            do { try await work() }
            catch { self.report(LiveConversation.safeError(error, fallback: "스레드 요청을 처리하지 못했어요. 저장 경로와 연결을 확인해 주세요")) }
        }
    }
    private func report(_ message: String) {
        startupError = message
        if let current { current.report(message) }
        else { initialMessages.append(.init(at: .now, kind: .stallari(message, project: nil))) }
    }
    public func createThread(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        enqueue { [self] in
            guard let repository else { throw StallariError.closed }
            let thread = ConversationThread(name: name)
            try await repository.saveThread(thread)
            threads = try await repository.snapshot(includeHistory: false).threads
            _ = try await conversation(for: thread.id)
            selectedThreadID = thread.id; preferences.set(thread.id, forKey: "knarr.selectedThread")
        }
    }
    public func selectThread(_ id: String) {
        // A stale subscription frame can leave the cached list without a freshly saved thread.
        // An explicit selection must survive that: fall back to persistence instead of dropping it.
        guard let thread = threads.first(where: { $0.id == id }) else {
            enqueue { [self] in
                guard let repository else { return }
                threads = try await repository.snapshot(includeHistory: false).threads
                guard let saved = threads.first(where: { $0.id == id }) else { return }
                restoreProjectDraft(for: saved)
                tabs.open(saved)
                persistTabs()
                _ = try await conversation(for: id)
                selectedThreadID = id; preferences.set(id, forKey: "knarr.selectedThread")
            }
            return
        }
        restoreProjectDraft(for: thread)
        tabs.open(thread)
        persistTabs()
        guard id != selectedThreadID else { return }
        if thread.projectID != nil || conversations[id] != nil {
            selectedThreadID = id; preferences.set(id, forKey: "knarr.selectedThread")
            return
        }
        enqueue { [self] in
            _ = try await conversation(for: id)
            selectedThreadID = id; preferences.set(id, forKey: "knarr.selectedThread")
        }
    }
    public func selectProjectConversation(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        if let existing = threads.first(where: { $0.projectID == projectID }) {
            selectThread(existing.id)
            return
        }
        let thread = deferredProjectThreads[projectID] ?? ConversationThread(name: project.name, projectID: projectID)
        deferredProjectThreads[projectID] = thread
        restoreProjectDraft(for: thread)
        if !threads.contains(where: { $0.id == thread.id }) { threads.append(thread) }
        selectedThreadID = thread.id
    }
    public func renameThread(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        enqueue { [self] in
            guard let repository, var thread = try await repository.snapshot(includeHistory: false).threads.first(where: { $0.id == id }) else { throw StallariError.closed }
            thread.name = name
            guard thread.issueID == nil else { throw StallariError.invalidArguments }
            try await repository.saveThread(thread)
            threads = try await repository.snapshot(includeHistory: false).threads
        }
    }
    public func goToThread(for issue: Issue.ID) { if let issue = issues.first(where: { $0.id == issue }) { selectThread(issue.conversationThreadID) } }
    private func owner(of id: Issue.ID) async throws -> LiveConversation {
        guard let repository, let issue = try await repository.snapshot(includeHistory: false).issues.first(where: { $0.id == id }) else { throw StallariError.missingIssue }
        return try await conversation(for: issue.conversationThreadID)
    }
    private func admittingConversation(threadID: String, draft: ChatDraft) async throws -> LiveConversation {
        guard !draft.isEmpty else { throw StallariError.invalidArguments }
        guard let thread = threads.first(where: { $0.id == threadID }) else { throw StallariError.closed }
        var id = threadID
        if let projectID = thread.projectID {
            guard draft.project == nil || draft.project == projectID else { throw StallariError.wrongProject }
            guard let repository else { throw StallariError.closed }
            let saved = try await repository.createProjectConversation(projectID: projectID, threadID: thread.id)
            id = saved.id
            deferredProjectThreads.removeValue(forKey: projectID)
            reconcileTabs(try await repository.snapshotUpdate())
            if selectedThreadID == threadID {
                selectedThreadID = id
                preferences.set(id, forKey: "knarr.selectedThread")
            }
        }
        return try await conversation(for: id)
    }
    public func submit(_ draft: ChatDraft) async throws {
        let draft = preparationContext(draft)
        let id = selectedThreadID
        let pendingDraft = composerDraft
        let conversation = try await admittingConversation(threadID: id, draft: draft)
        if conversation.composerDraft.isEmpty { conversation.composerDraft = pendingDraft }
        try await conversation.submit(draft)
        persistProjectDraft(for: conversation)
    }
    public func startMessageConversation(_ draft: ChatDraft) async throws -> UUID {
        try await startMessageConversation(draft, onCreated: { _ in })
    }
    public func startMessageConversation(_ draft: ChatDraft, onCreated: @escaping @MainActor (UUID) -> Void) async throws -> UUID {
        guard draft.conversationRootID == nil else { throw StallariError.invalidArguments }
        let draft = preparationContext(draft)
        let id = selectedThreadID
        let pendingDraft = composerDraft
        let conversation = try await admittingConversation(threadID: id, draft: draft)
        if conversation.composerDraft.isEmpty { conversation.composerDraft = pendingDraft }
        let rootID = try await conversation.startMessageConversation(draft, onCreated: onCreated)
        persistProjectDraft(for: conversation)
        return rootID
    }
    public func linkMessageConversation(_ id: UUID) async throws {
        guard !closing, let repository else { throw StallariError.closed }
        let threadID = selectedThreadID
        if let conversation = conversations[threadID] {
            try await conversation.linkMessageConversation(id)
        } else {
            try await repository.linkMessageConversation(id, threadID: threadID)
            reconcileTabs(try await repository.snapshotUpdate())
        }
    }
    private func persistProjectDraft(for conversation: LiveConversation) {
        if let projectID = threads.first(where: { $0.id == conversation.threadID })?.projectID {
            projectDrafts[projectID] = conversation.composerDraft
            if let data = try? JSONEncoder().encode(conversation.composerDraft) {
                preferences.set(data, forKey: projectDraftKey(projectID))
            }
        }
    }
    public func send(_ text: String, about: Issue.ID?, project: String?, attachments: [URL]) {
        let threadID = about.flatMap { id in issues.first { $0.id == id }?.conversationThreadID } ?? selectedThreadID
        if let target = conversations[threadID] {
            target.send(text, about: about, project: project, attachments: attachments)
            return
        }
        enqueue { [self] in
            let conversation: LiveConversation
            if let about { conversation = try await owner(of: about) }
            else { conversation = try await admittingConversation(threadID: threadID, draft: .init(text: text, attachments: attachments, project: project)) }
            conversation.send(text, about: about, project: project, attachments: attachments)
            try await conversation.whenIdle()
        }
    }
    /// Sends one message into the named conversation. When the Mac already has that conversation
    /// open its queue carries the message; otherwise the same durable path opens it first, without
    /// changing which tab the person sees on the Mac.
    public func sendToThread(_ thread: String, text: String, project: String?, attachments: [URL]) async throws {
        let draft = ChatDraft(text: text, attachments: attachments, project: project)
        let conversation = try await admittingConversation(threadID: thread, draft: draft)
        try await conversation.submit(draft)
    }
    public func reviewProposal(_ action: IssueAction, on id: Issue.ID, source: String) async throws {
        try await owner(of: id).reviewProposal(action, on: id, source: source)
    }
    public func perform(_ action: IssueAction, on issue: Issue.ID) {
        enqueue { [self] in let target = try await owner(of: issue); target.perform(action, on: issue); try await target.whenIdle() }
    }
    public func answer(_ question: Question.ID, with answer: QuestionAnswer) { resolve(question, answer: answer) }
    public func cancel(_ question: Question.ID) { resolve(question, answer: nil) }
    public func replyToQuestion(_ id: Question.ID, answer: QuestionAnswer?) async throws {
        if let target = conversations.values.first(where: { $0.extensionQuestions.contains(where: { $0.id == id }) }) {
            try await target.replyToQuestion(id, answer: answer)
            return
        }
        guard let repository,
              let question = try await repository.snapshot(includeHistory: false).questions.first(where: { $0.id == id.rawValue }) else { throw StallariError.invalidArguments }
        let target = try await owner(of: question.issueID)
        try await target.replyToQuestion(id, answer: answer)
    }
    private func resolve(_ id: Question.ID, answer: QuestionAnswer?) {
        if let target = conversations.values.first(where: { $0.extensionQuestions.contains(where: { $0.id == id }) }) {
            if let answer { target.answer(id, with: answer) } else { target.cancel(id) }
            return
        }
        enqueue { [self] in
            guard let repository, let question = try await repository.snapshot(includeHistory: false).questions.first(where: { $0.id == id.rawValue }) else { return }
            let target = try await owner(of: question.issueID)
            if let answer { target.answer(id, with: answer) } else { target.cancel(id) }
            try await target.whenIdle()
        }
    }
    public func steer(_ text: String, issue: Issue.ID) {
        enqueue { [self] in let target = try await owner(of: issue); target.steer(text, issue: issue); try await target.whenIdle() }
    }
    public func stopResponse() { current?.stopResponse() }
    public func selectThinking(_ level: String) { (current ?? global)?.selectThinking(level) }
    public func selectModel(_ model: String) { (current ?? global)?.selectModel(model) }
    public func reloadResponseRules() { current?.reloadResponseRules() }
    public func saveResponseRules(_ text: String) { current?.saveResponseRules(text) }
    public var instructionSources: [InstructionSource] { current?.instructionSources ?? [] }
    public func reloadInstructionSources() { current?.reloadInstructionSources() }
    public func saveInstructionSource(role: InstructionRole, kind: InstructionKind, projectID: String?, text: String, expectedHash: String) async throws -> InstructionSource {
        guard let current else { throw StallariError.closed }
        return try await current.saveInstructionSource(role: role, kind: kind, projectID: projectID, text: text, expectedHash: expectedHash)
    }
    public func addProject(path: String) { global?.addProject(path: path) }
    public func issues(inProject id: String) -> [Issue] { global?.issues(inProject: id) ?? [] }
    public func inspectProject(_ id: String) async -> ProjectInspection { await global?.inspectProject(id) ?? .init(problem: "프로젝트를 찾지 못했어요") }
    public func inspectProjectMergeResults(_ id: String) async -> ProjectMergeResults {
        guard let repository, !closing else {
            return .init(results: [], problem: "저장된 Hird 결과를 읽을 수 없어요")
        }
        do {
            let snapshot = try await repository.snapshot(includeHistory: true)
            guard let project = snapshot.projects.first(where: { $0.id == id }) else {
                return .init(results: [], problem: "프로젝트를 찾지 못했어요")
            }
            return await ProjectMergeResults.read(root: URL(fileURLWithPath: project.absolutePath, isDirectory: true),
                issues: snapshot.issues.filter { snapshot.issueProjects[$0.id] == id },
                runs: snapshot.runs.filter { $0.projectID == id })
        } catch {
            return .init(results: [], problem: "저장된 Hird 결과 이력을 읽지 못했어요")
        }
    }
    public func renameProject(_ id: String, to name: String) { global?.renameProject(id, to: name) }
    public func setProjectArchived(_ id: String, _ archived: Bool) { global?.setProjectArchived(id, archived) }
    public var preparationItems: [PreparationItem] { global?.preparationItems ?? [] }
    public var preparationSourceIDs: Set<Issue.ID> { global?.preparationSourceIDs ?? [] }
    private var preparationSelections: [String: String] = [:]
    public func selectedPreparationID(inProject id: String) -> String? {
        let selected = preparationSelections[id] ?? preferences.string(forKey: "knarr.preparation." + id)
        return preparationItems.first { $0.id == selected && $0.projectID == id }?.id
    }
    public func selectPreparation(_ itemID: String?, inProject id: String) {
        guard itemID == nil || preparationItems.contains(where: { $0.id == itemID && $0.projectID == id }) else { return }
        preparationSelections[id] = itemID
        preferences.set(itemID, forKey: "knarr.preparation." + id)
    }
    private func preparationContext(_ draft: ChatDraft) -> ChatDraft {
        var value = draft
        if draft.conversationRootID != nil { value.preparationID = nil; return value }
        let projectID = threads.first { $0.id == selectedThreadID }?.projectID ?? draft.project
        if draft.preparationID == nil, let projectID, projects.first(where: { $0.id == projectID })?.settings.workspaceStyle == .preparation {
            value.preparationID = selectedPreparationID(inProject: projectID)
        }
        return value
    }
    @discardableResult public func savePreparation(id: String, projectID: String, fields: PreparationItem.Fields, expectedRevision: Int, sourceIssueID: Issue.ID?) async throws -> PreparationItem {
        guard let repository, !closing else { throw StallariError.closed }
        return try await repository.savePreparation(id: id, projectID: projectID, fields: fields, expectedRevision: expectedRevision, sourceIssueID: sourceIssueID)
    }
    @discardableResult public func savePreparationDraft(itemID: String, projectID: String, expectedRevision: Int, documentID: String, title: String, text: String, kind: PreparationItem.Draft.Kind) async throws -> PreparationItem {
        guard let repository, !closing else { throw StallariError.closed }
        return try await repository.appendPreparationDraft(itemID: itemID, projectID: projectID, expectedRevision: expectedRevision, documentID: documentID, title: title, text: text, kind: kind)
    }
    @discardableResult public func addPreparationRecord(itemID: String, projectID: String, expectedRevision: Int, text: String, submission: PreparationItem.Submission?) async throws -> PreparationItem {
        guard let repository, !closing else { throw StallariError.closed }
        return try await repository.appendPreparationRecord(itemID: itemID, projectID: projectID, expectedRevision: expectedRevision, text: text, submission: submission)
    }
    public func updateProjectSettings(_ id: String, _ settings: ProjectSettings) { global?.updateProjectSettings(id, settings) }
    public func milestones(inProject id: String) -> [Milestone] { global?.milestones(inProject: id) ?? [] }
    public func milestone(_ id: Milestone.ID) -> Milestone? { global?.milestone(id) }
    public func saveMilestone(_ milestone: Milestone) { global?.saveMilestone(milestone) }
    public func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID]) { global?.reorderMilestones(projectID: projectID, orderedIDs: orderedIDs) }
    public func deleteMilestone(_ id: Milestone.ID) { global?.deleteMilestone(id) }
    public func weekPlans(inProject id: String) -> [ProjectWeekPlan] { global?.weekPlans(inProject: id) ?? [] }
    public func saveWeekPlan(_ plan: ProjectWeekPlan) { global?.saveWeekPlan(plan) }
    public func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {
        guard let global else { throw StallariError.closed }; try await global.saveAgentsFile(id, text: text, expected: expected)
    }
    public func cleanFinishedWorkspaces() { global?.cleanFinishedWorkspaces() }
    public func whenIdle() async throws {
        await bootstrap?.value; await operation?.value
        for conversation in conversations.values { try await conversation.whenIdle() }
        guard let repository else { throw StallariError.closed }
        // This value was just read from the database, so a missing thread is really gone.
        reconcileTabs(try await repository.snapshotUpdate(), confirmed: true)
    }
    func observe(frame: OMPJSON, threadID: String = ConversationThread.defaultID) async { await conversations[threadID]?.observe(frame: frame) }
    public func shutdown() async -> OMPProcessExit {
        closing = true
        await workReportController?.shutdown()
        await subscriptionUsage.shutdown()
        bootstrap?.cancel(); operation?.cancel(); snapshots?.cancel()
        for task in opening.values { task.cancel() }
        // Closing the transports releases requests awaited by queued facade work.
        // Waiting for that work first can keep shutdown behind an in-flight request.
        let interrupted = (try? await repository?.prepareForAppShutdown(at: .now)) ?? []
        var exits: [OMPProcessExit] = []
        for conversation in conversations.values { exits.append(await conversation.shutdown(includeSharedHird: false)) }
        for conversation in conversations.values { await conversation.confirmTerminated(interrupted) }
        await bootstrap?.value; await operation?.value
        for task in opening.values { _ = try? await task.value }
        exits.append(contentsOf: startupExits)
        await snapshots?.value
        if ownsRepository { try? await repository?.close(); ownsRepository = false }
        var hirdRemaining: [Int32] = []
        for conversation in conversations.values { hirdRemaining += await conversation.remainingHirdProcessIDs() }
        let remaining = Array(Set(exits.flatMap(\.remainingProcessIDs) + hirdRemaining)).sorted()
        return .init(status: remaining.isEmpty ? 0 : -1, reason: remaining.isEmpty ? .cancelled : .failed, remainingProcessIDs: remaining)
    }
}
