import Foundation
import Observation

/// Example data for building and reviewing screens before the runtime exists.
/// Every name, time and command here is illustrative.
@MainActor @Observable
public final class SampleKnarrStore: KnarrStore {
    public var workReports: [WorkReport] = []

    public private(set) var stallari = StallariInfo(engine: "OMP · opus", scope: "모든 프로젝트")
    public private(set) var chat: [ChatItem]
    public private(set) var projectTransfers: [ProjectTransfer] = []
    public private(set) var threads: [ConversationThread] = [.default]
    public private(set) var selectedThreadID = ConversationThread.defaultID
    private var threadChats: [String: [ChatItem]] = [:]
    private var threadDrafts: [String: ChatDraft] = [:]
    private var issueProjects: [Issue.ID: String] = [:]
    private var threadWork: [String: [SubagentWork]] = [:]
    public var stallariWork: [SubagentWork] { threadWork[selectedThreadID] ?? [] }
    /// Illustrative only: same titles and hierarchy as the real tree, with preview paths.
    public private(set) var instructionSources: [InstructionSource] = SampleKnarrStore.previewInstructionSources()
    public func reloadInstructionSources() {}
    public func saveInstructionSource(role: InstructionRole, kind: InstructionKind, projectID: String?,
                                      text: String, expectedHash: String) async throws -> InstructionSource {
        throw StallariError.invalidArguments
    }
    private var tabs = ConversationTabs()
    public var conversationTabs: [ConversationThread] { tabs.displayed(threads: threads, projects: projects) }
    /// Preview-only read marks, so a sample scene can show a count without touching real preferences.
    var unreadLedgers: [String: UnreadAnswerLedger] = [:]
    public var appIsActive = true
    public private(set) var activationRevision = 0
    public func setAppActive(_ active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        if active { activationRevision += 1 }
    }
    private func threadAnswers(_ threadID: String) -> [UnreadAnswer] {
        (threadID == selectedThreadID ? chat : threadChats[threadID] ?? []).compactMap(UnreadAnswers.answer)
    }
    /// Same rule as the live store: only the main and project conversations count.
    public func unreadAnswerCount(forThread threadID: String) -> Int {
        guard threads.first(where: { $0.id == threadID })?.issueID == nil else { return 0 }
        let answers = threadAnswers(threadID)
        let ledger = unreadLedgers[threadID] ?? .init(baselining: answers)
        return answers.lazy.filter { !ledger.isRead($0) }.count
    }
    public func markAnswersRead(_ messageIDs: [UUID], threadID: String) {
        guard appIsActive, threadID == selectedThreadID, !messageIDs.isEmpty,
              threads.first(where: { $0.id == threadID })?.issueID == nil else { return }
        let answers = threadAnswers(threadID)
        let wanted = Set(messageIDs)
        var ledger = unreadLedgers[threadID] ?? .init(baselining: answers)
        ledger.markRead(answers.filter { wanted.contains($0.id) }, among: answers)
        unreadLedgers[threadID] = ledger
    }
    public func closeConversationTab(_ id: String) {
        tabs.close(id)
        if selectedThreadID == id { selectThread(ConversationThread.defaultID) }
    }

    public func createThread(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let thread = ConversationThread(name: name)
        threads.append(thread); selectThread(thread.id)
    }
    public func selectProjectConversation(_ projectID: String) {
        guard let project = project(projectID), !project.archived else { return }
        if let thread = threads.first(where: { $0.projectID == projectID }) {
            selectThread(thread.id)
        } else {
            let thread = ConversationThread(name: project.name, projectID: projectID)
            threads.append(thread)
            threadDrafts[thread.id] = .init(project: projectID)
            selectThread(thread.id)
        }
    }
    public func selectThread(_ id: String) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        tabs.open(thread)
        guard id != selectedThreadID else { return }
        threadChats[selectedThreadID] = chat
        threadDrafts[selectedThreadID] = composerDraft
        selectedThreadID = id
        chat = threadChats[id] ?? []
        composerDraft = threadDrafts[id] ?? .init()
        if let projectID = thread.projectID { composerDraft.project = projectID }
        isResponding = false; streamingText = ""
    }
    public func renameThread(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].name = name
    }
    public func goToThread(for issue: Issue.ID) {
        if let issue = issues.first(where: { $0.id == issue }) { selectThread(issue.conversationThreadID) }
    }
    public var composerDraft = ChatDraft()
    public let subscriptionUsage: SubscriptionUsageModel
    public var thinkingLevel: String? = "high"
    public var thinkingLevels = ["off", "low", "medium", "high"]
    public func selectThinking(_ level: String) { thinkingLevel = level }
    public func stopResponse() { isResponding = false; stopped = true }
    public var responseStatus: String { stopped && !isResponding ? "중지됨" : streamingText.isEmpty ? "생각 중" : "답변 작성 중" }
    public var extensionPresentation = ExtensionPresentation()
    public func dismissExtensionToast() { extensionPresentation.toast = nil }
    private var stopped = false
    public var isResponding = false
    /// Sample scenes can show elapsed time on a running canvas.
    public var responseStartedAt: Date?
    /// Sample canvases show one root as answering while the fake stream runs.
    public var respondingConversationRoots: Set<UUID> = []
    /// A queued reply behind the sample answer; a non-empty queue makes the shared answer unstoppable.
    public var waitingConversationRoots: Set<UUID> = []
    public var stoppableConversationRoots: Set<UUID> {
        isResponding && waitingConversationRoots.isEmpty ? respondingConversationRoots : []
    }
    /// Same rule as LiveConversation, so a sample canvas explains a blocked stop exactly as the app does.
    public func stopBlockReason(for root: UUID) -> String? {
        guard isResponding, respondingConversationRoots.contains(root), !stoppableConversationRoots.contains(root) else { return nil }
        return "대기 중인 메시지가 있어 이 답변만 중지할 수 없어요"
    }
    /// The sample keeps one response flag for the selected thread; issue tabs add their own Hird.
    public func isThreadWorking(_ threadID: String) -> Bool {
        (isResponding && threadID == selectedThreadID) || threadBoundIssueIsWorking(threadID)
    }
    public var contextUsage: ContextUsage? = ContextUsage(state: .object(["contextUsage": .object(["tokens": .number(92_000), "contextWindow": .number(128_000)])]))
    public var streamingText = ""
    public var autoInstallEnabled = true
    public private(set) var autoInstallStatus: String? = AutoInstallPolicy.current.status("current", ["installed": "ec489d3", "main": "ec489d3"])
    public var autoInstallPolicy = AutoInstallPolicy.current
    public func setAutoInstall(_ enabled: Bool) { autoInstallEnabled = enabled }
    public private(set) var issues: [Issue]
    /// Plan examples for the project tabs; every value is illustrative.
    public private(set) var milestones: [Milestone] = []
    public private(set) var weekPlans: [ProjectWeekPlan] = []
    public private(set) var questions: [Question]
    public var projectSessionPolicy = ProjectSessionPolicy.current
    public private(set) var projects: [ProjectSummary] = [
        .init(id: "gamza", name: "Gamza Saga", path: "/Users/you/AppProject/GamzaSaga", openIssues: 3, settings: .init(
            verification: [.init(name: "코어 테스트", command: "swift test --package-path GameCore"),
                           .init(name: "iOS 빌드", command: "xcodebuild -scheme GamzaSaga build", timing: .codeChanged)],
            criteria: ["관련 테스트를 먼저 실패시키고 통과시킨다", "세이브 v1~v3 불러오기 테스트가 모두 통과한다"],
            memo: "TestFlight 업로드는 Apple 계정 로그인이 자주 풀린다. 막히면 기다리지 말고 바로 물어볼 것.",
            color: 2)),
        .init(id: "knarr", name: "Knarr", path: "/Users/you/AppProject/Knarr", openIssues: 1, settings: .init(
            verification: [.init(name: "전체 테스트", command: "swift test"),
                           .init(name: "화면 스냅샷", command: "swift run knarr-snapshot", timing: .screenChanged)],
            criteria: ["화면 변경은 스냅샷 PNG를 증거로 남긴다"], color: 0)),
        .init(id: "soomcha", name: "Soomcha", path: "/Users/you/AppProject/Soomcha", openIssues: 0, settings: .init(resultMode: .branch, maxHirds: 1, color: 5)),
        .init(id: "aquach", name: "Aquach", path: "/Users/you/AppProject/Aquach", openIssues: 0, archived: true, settings: .init(color: 6)),
    ]
    @ObservationIgnored private let sampleNow: Date

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var qaPreview = false

    /// - Parameter animated: nudges Hird-1's last activity every few seconds so liveness can be seen moving.
    public init(now: Date = .now, animated: Bool = false) {
        let s = Self.make(now: now)
        sampleNow = now
        let seconds = Int64(now.timeIntervalSince1970)
        subscriptionUsage = .init(clock: { seconds },
            claude: .init(fiveHour: .init(usedPercent: 57, resetsAt: seconds + 3660), weekly: .init(usedPercent: 20, resetsAt: seconds + 3 * 86400), capturedAt: seconds),
            codex: .init(fiveHour: .init(usedPercent: 25, resetsAt: seconds + 7200), weekly: .init(usedPercent: 80, resetsAt: seconds + 86400), capturedAt: seconds),
            sample: true)
        issues = s.issues.map { Self.withSampleProgress($0, now: now) }
        milestones = Self.makeMilestones(now: now)
        weekPlans = Self.makeWeekPlans(now: now)
        chat = s.chat
        questions = s.questions
        bindSampleIssues()
        if animated { startTicker() }
    }

    /// Static activity examples; never launches OMP or synthesizes progress events.
    public convenience init(stallariWorkScene scene: StallariWorkScene, now: Date = .now) {
        self.init(now: now)
        issues = []; questions = []
        chat = [.init(at: now, kind: .user("이슈 탭과 카드 표시 규칙을 조사해 주세요.")),
                .init(at: now, kind: .stallari("하위 작업으로 관련 코드를 확인하고 있어요.", project: nil))]
        var work = [SubagentWork(id: "IntegrateTabs", name: "IntegrateTabs", currentCommand: "read",
            startedAt: now.addingTimeInterval(-3660), lastActivityAt: now)]
        if scene == .multiple {
            work.append(.init(id: "CheckCards", name: "CheckCards", currentCommand: "bash",
                startedAt: now.addingTimeInterval(-1440), lastActivityAt: now.addingTimeInterval(-420)))
        }
        threadWork[selectedThreadID] = work
    }

    /// Extension UI sample for the existing snapshot renderer; never launches a worker.
    public convenience init(extensionPreview: Question.ReplyStyle, reloading: Bool = false) {
        self.init()
        let identity = StallariDialogIdentity(threadID: selectedThreadID, sessionID: "snapshot", rpcGeneration: "snapshot", rpcID: "preview")
        let question = Question(id: "extension-preview", identity: identity, prompt: "확장 실행을 이어갈까요?",
            options: extensionPreview == .confirm ? ["예", "아니요"] : [],
            replyStyle: extensionPreview, placeholder: "확장에 전달할 내용", prefill: "첫째 줄\n둘째 줄",
            askedAt: sampleNow, state: reloading ? .cancelled : .pending)
        questions = [question]
        chat = [.init(at: sampleNow, kind: .user("Stallari 확장 UI 예시")),
                .init(at: sampleNow, kind: .question(question.id))]
        extensionPresentation.isReloading = reloading
        if !reloading {
            extensionPresentation.statuses["확장"] = "VERSION_TWO · 준비됨"
            extensionPresentation.widgets["미리보기"] = ["확장 상태와 위젯은 입력창 위에 표시됩니다."]
            extensionPresentation.toast = .init(message: "확장 알림 예시", tone: "info")
        }
    }

    /// Isolated, explicitly synthetic approval/motion surface. No repository, OMP or CloudKit.
    public convenience init(qaProjectPath: String, animated: Bool = false) {
        self.init(animated: animated)
        qaPreview = true
        projects = [.init(id: "qa-project", name: "합성 QA 프로젝트", path: qaProjectPath, openIssues: 2)]
        var running = issues[0]
        running.title = "합성 카드 · 명령 줄과 완료 조건 전환"
        running.projectName = "합성 QA 프로젝트"
        running.headline = "합성 Hird 1명 · 상태 전환 중"
        running.detail = "7초마다 합성 명령 줄과 완료 조건만 바뀝니다. 실제 명령이나 OMP는 실행하지 않습니다."
        running.acceptance = [.init(text: "명령 줄이 바뀌어도 카드 높이를 유지한다", state: .pending, evidence: "합성 전환"),
                              .init(text: "읽던 대화 위치를 유지한다", state: .pending, evidence: "합성 전환")]
        running.hirds = [running.hirds[0]]
        running.hirds[0].role = "합성 상태 전환"
        running.hirds[0].currentCommand = "합성 검사 · 실제 명령을 실행하지 않음"
        running.events = []
        var proposal = Issue(id: "qa-approval", title: "합성 이슈 · 승인 화면 확인", projectName: "합성 QA 프로젝트",
            state: .awaitingApproval, headline: "제안 v1 · 승인 대기", detail: "실제 Hird 실행이 아닌 합성 QA입니다. 승인 전 실행은 없으며, 승인하면 합성 Hird 카드만 나타납니다.",
            acceptance: [.init(text: "표시된 제안 버전만 승인한다", state: .pending, evidence: ""),
                         .init(text: "수정 요청과 거절은 Hird를 시작하지 않는다", state: .pending, evidence: "")],
            hirds: [], events: [], startedAt: sampleNow)
        proposal.proposal = .init(instruction: "합성 QA 지시: 승인 화면을 확인하고, 입력한 수정 메모와 제안 버전이 전달되는지 확인하세요. 실제 파일 변경이나 OMP 실행은 하지 않습니다.",
            model: "openai-codex/gpt-6.1-sol", mode: .change)
        issues = [proposal, running]
        bindSampleIssues()
        questions = []
        chat = [ChatItem(at: sampleNow, kind: .stallari("격리된 합성 QA입니다. 운영 데이터·CloudKit·OMP 인증을 사용하지 않습니다.", project: "합성 QA 프로젝트"))]
        for i in 0..<16 {
            chat.append(ChatItem(at: sampleNow, kind: .user("합성 대화 \(i) · " + String(repeating: "카드의 명령 줄이 바뀌어도 읽던 대화 위치를 유지합니다. ", count: 5))))
        }
        chat.append(ChatItem(at: sampleNow, kind: .issue(running.id)))
        chat.append(ChatItem(at: sampleNow, kind: .issue(proposal.id)))
    }

    public private(set) var models = ["anthropic/claude-opus-5-5", "anthropic/claude-sonnet-5-5", "openai-codex/gpt-6.1-sol"]
    public private(set) var model: String? = "anthropic/claude-opus-5-5"
    public private(set) var storageBytes: Int64? = 1_830_000_000

    public func selectModel(_ model: String) { if models.contains(model) { self.model = model } }
    public func cleanFinishedWorkspaces() { storageBytes = 240_000_000 }

    public func addProject(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let i = projects.firstIndex(where: { $0.path == path }) { projects[i].archived = false; return }
        projects.append(.init(id: path, name: name, path: path, openIssues: 0, settings: .init(color: projects.count)))
    }

    public func issues(inProject id: String) -> [Issue] {
        issues.filter { issueProjects[$0.id] == id }
    }

    public func milestones(inProject id: String) -> [Milestone] {
        milestones.filter { $0.projectID == id }.sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    public func milestone(_ id: Milestone.ID) -> Milestone? {
        milestones.first { $0.id == id }
    }

    public func saveMilestone(_ milestone: Milestone) {
        let old = milestones.first { $0.id == milestone.id }
        guard old?.projectID == nil || old?.projectID == milestone.projectID else { return }
        guard let value = try? milestone.preparedForSave(over: old, at: sampleNow) else { return }
        if let index = milestones.firstIndex(where: { $0.id == value.id }) { milestones[index] = value }
        else { milestones.append(value) }
        issues = issues.map { issue in
            guard issue.milestoneID == value.id else { return issue }
            var copy = issue; copy.projectName = projects.first { $0.id == value.projectID }?.name ?? issue.projectName; return copy
        }
    }

    public func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID]) {
        let list = milestones(inProject: projectID)
        guard Set(list.map(\.id)) == Set(orderedIDs), list.count == orderedIDs.count else { return }
        let positions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        milestones = milestones.map { value in
            guard value.projectID == projectID, let position = positions[value.id] else { return value }
            var copy = value; copy.order = position; return copy
        }
    }

    public func deleteMilestone(_ id: Milestone.ID) {
        guard !issues.contains(where: { $0.milestoneID == id }),
              !milestones.contains(where: { $0.id != id && $0.prerequisites.contains(id) }) else { return }
        milestones.removeAll { $0.id == id }
    }

    public func weekPlans(inProject id: String) -> [ProjectWeekPlan] {
        weekPlans.filter { $0.projectID == id }.sorted { $0.weekStart < $1.weekStart }
    }

    public func saveWeekPlan(_ plan: ProjectWeekPlan) {
        let current = ProjectWeek.start(containing: sampleNow)
        guard plan.weekStart == current, !projects.contains(where: { $0.id == plan.projectID && $0.archived }) else { return }
        var value = plan
        value.plan = ProjectWeekPlan.lines(plan.plan)
        value.recordedAt = sampleNow
        if let index = weekPlans.firstIndex(where: { $0.projectID == value.projectID && $0.weekStart == value.weekStart }) {
            weekPlans[index] = value
        } else {
            weekPlans.append(value)
        }
    }

    public func renameProject(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].name = name
        for j in issues.indices where issueProjects[issues[j].id] == id { issues[j].projectName = name }
    }

    public func setProjectArchived(_ id: String, _ archived: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].archived = archived
    }

    public func updateProjectSettings(_ id: String, _ settings: ProjectSettings) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].settings = settings.cleaned
    }

    /// Example repository states; nothing is read from disk.
    private var agentsTexts: [String: String] = [
        "gamza": "# Gamza Saga 작업 규칙\n\n- 코어 테스트: `swift test --package-path GameCore`\n- 세이브 파일은 v1~v3을 모두 읽어야 합니다.\n- 대사 데이터(Resources/Dialogue/*.json)는 손으로 고치지 않고 scripts/gen-dialogue로 만듭니다.\n",
        "knarr": "# Knarr 작업 규칙\n\n- 기능 코드는 실패 테스트를 먼저 추가하고 `swift test`로 검증합니다.\n- 화면 변경은 `swift run knarr-snapshot`으로 확인합니다.\n",
    ]

    public func inspectProject(_ id: String) async -> ProjectInspection {
        func ago(_ minutes: Double) -> Date { sampleNow.addingTimeInterval(-minutes * 60) }
        let agents = agentsTexts[id].map { ProjectInspection.AgentsFile(text: $0, uncommitted: false) }
        switch id {
        case "issue-status":
            return .init(readAt: sampleNow, branch: "main", ahead: 0, behind: 0, changes: [],
                commits: [.init(hash: "synthetic-applied", subject: "합성 예시 · 결과를 main에 반영", date: ago(10))],
                agents: nil)
        case "gamza":
            return .init(readAt: sampleNow, branch: "main", ahead: 2, behind: 0,
                changes: [.init(code: "M", path: "Sources/Dialogue/LinePicker.swift"), .init(code: "M", path: "Sources/Save/SaveMigrator.swift"),
                          .init(code: "??", path: "Tests/DialogueTests/RepeatTests.swift")],
                commits: [.init(hash: "8c1e2fa", subject: "대화 상태 저장 순서 고정", date: ago(53)),
                          .init(hash: "41b09d3", subject: "세이브 v2 불러오기 테스트 추가", date: ago(60 * 20)),
                          .init(hash: "e77a210", subject: "인벤토리 정렬 버그 수정", date: ago(60 * 72))],
                agents: agents)
        case "knarr":
            return .init(readAt: sampleNow, branch: "main", ahead: 0, behind: 0, changes: [],
                commits: [.init(hash: "d236fe6", subject: "Record real-use QA evidence", date: ago(30)),
                          .init(hash: "a3f4ef4", subject: "Preserve motion and copy feedback", date: ago(95))],
                agents: agents)
        case "soomcha":
            return .init(readAt: sampleNow, branch: "feature/weekly-chart", ahead: 5, behind: 3, changes: [],
                commits: [.init(hash: "3f20c11", subject: "주간 그래프 축 레이블 정리", date: ago(150))], agents: nil)
        default:
            return .init(readAt: sampleNow, problem: "폴더가 없어요")
        }
    }

    public func saveAgentsFile(_ id: String, text: String, expected: String?) async throws {
        guard agentsTexts[id] == expected else { throw ProjectGitError.changedOnDisk }
        agentsTexts[id] = text.hasSuffix("\n") ? text : text + "\n"
    }

    public func submit(_ draft: ChatDraft) async throws {
        let projectID = threads.first { $0.id == selectedThreadID }?.projectID
        if let projectID, draft.project != projectID { throw StallariError.wrongProject }
        guard !draft.isEmpty,
              !issues.contains(where: { $0.conversationThreadID == selectedThreadID && $0.archivedAt != nil }) else { throw StallariError.invalidArguments }
        if let rootID = draft.conversationRootID {
            guard chat.contains(where: { $0.id == rootID && $0.isConversationLink }) else { throw StallariError.invalidArguments }
            appendMessageConversation(draft, sourceID: nil, rootID: rootID)
            if composerDraft == draft { composerDraft = .init(project: projectID) }
            return
        }
        send(draft.text, about: nil, project: projectID ?? draft.project, attachments: draft.attachments)
        if composerDraft == draft { composerDraft = .init(project: projectID) }
    }
    public func startMessageConversation(_ draft: ChatDraft) async throws -> UUID {
        guard !draft.isEmpty, draft.conversationRootID == nil,
              !issues.contains(where: { $0.conversationThreadID == selectedThreadID && $0.archivedAt != nil }) else { throw StallariError.invalidArguments }
        let projectID = threads.first { $0.id == selectedThreadID }?.projectID
        if let projectID, draft.project != projectID { throw StallariError.wrongProject }
        let rootID = UUID()
        appendMessageConversation(draft, sourceID: rootID, rootID: rootID)
        if composerDraft == draft { composerDraft = .init(project: projectID ?? draft.project) }
        return rootID
    }
    public func linkMessageConversation(_ id: UUID) async throws {
        guard let index = chat.firstIndex(where: { $0.id == id }),
              chat[index].conversationRootID == nil, chat[index].activity == nil,
              case .user = chat[index].kind else { throw StallariError.invalidArguments }
        chat[index].isConversationLink = true
    }
    private func appendMessageConversation(_ draft: ChatDraft, sourceID: UUID?, rootID: UUID) {
        stopped = false
        var user = ChatItem(id: sourceID ?? UUID(), at: .now, kind: .user(draft.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        user.attachments = draft.attachments
        user.conversationRootID = sourceID == nil ? rootID : nil
        user.isConversationLink = sourceID != nil
        var reply = ChatItem(at: .now, kind: .stallari("예시 화면이라 실제로 보내지는 않아요. 실행 엔진이 연결되면 여기서 답해요.", project: nil))
        reply.conversationRootID = rootID
        chat += [user, reply]
    }

    public func send(_ text: String, about: Issue.ID?, project: String?, attachments: [URL]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = about.flatMap { issue($0)?.conversationThreadID } ?? selectedThreadID
        guard !issues.contains(where: { $0.conversationThreadID == threadID && $0.archivedAt != nil }) else { return }
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        stopped = false
        let names = attachments.isEmpty ? "" : "\n\n첨부: " + attachments.map(\.lastPathComponent).joined(separator: ", ")
        let items: [ChatItem] = [
            .init(at: .now, kind: .user(trimmed + names)),
            .init(at: .now, kind: .stallari("예시 화면이라 실제로 보내지는 않아요. 실행 엔진이 연결되면 여기서 답해요.", project: nil))
        ]
        if threadID == selectedThreadID { chat += items }
        else { threadChats[threadID, default: []] += items }
    }

    public func steer(_ text: String, issue: Issue.ID) {
        update(issue) { $0.events.insert(ActivityEvent(at: .now, actor: "나", text: "Hird에게 한마디", detail: text), at: 0) }
    }

    public func reviewProposal(_ action: IssueAction, on id: Issue.ID, source: String) async throws {
        guard let issue = issue(id), issue.state == .awaitingApproval,
              issue.approval == nil, issue.proposalReviewNote == nil else { throw StallariError.invalidArguments }
        let version: Int
        switch action {
        case .approveProposal(let v), .requestProposalChanges(let v, _), .rejectProposal(let v, _): version = v
        default: throw StallariError.invalidArguments
        }
        guard issue.proposal?.version == version else { throw StallariError.invalidArguments }
        perform(action, on: id)
        if case .approveProposal = action {
            update(id) {
                $0.approval?.source = source
                if let last = $0.approvalHistory?.indices.last { $0.approvalHistory?[last].source = source }
            }
        }
    }

    public func perform(_ action: IssueAction, on id: Issue.ID) {
        guard issue(id)?.archivedAt == nil else { return }
        switch action {
        case .confirmAppResult(let note):
            update(id) { $0.userAppConfirmation = .init(at: .now, note: note, runID: $0.hirds.last?.id ?? "sample") }
        case .closeIssue(let reason):
            update(id) { $0.archivedAt = .now; $0.archiveReason = reason.rawValue }
        case .confirmResult:
            update(id) { $0.confirmed = true }
        case .requestChanges(let note):
            if !note.isEmpty { send(note, about: id) }
            update(id) { $0.state = .running; $0.confirmed = false; $0.completedAt = nil }
        case .approveProposal(let version):
            update(id) { issue in
                guard let proposal = issue.proposal, proposal.version == version,
                      issue.approval?.runID == nil, issue.state == .awaitingApproval else { return }
                let approval = IssueApproval(version: version, approvedAt: .now, runID: issue.hirds.last?.id)
                issue.approval = approval
                issue.approvalHistory = (issue.approvalHistory ?? []) + [approval]
                issue.state = .running
                if qaPreview && issue.hirds.isEmpty {
                    issue.hirds = [.init(id: "qa-approved-hird", name: "합성 Hird", role: "승인 후 표시 확인", status: .working,
                        steps: [.init(title: "합성 실행 표시", state: .active)], currentCommand: nil, lastActivityAt: .now)]
                    issue.approval?.runID = issue.hirds[0].id
                    if let last = issue.approvalHistory?.indices.last { issue.approvalHistory?[last].runID = issue.hirds[0].id }
                }
                for i in issue.hirds.indices { issue.hirds[i].status = .working; issue.hirds[i].lastActivityAt = .now }
            }
        case .requestProposalChanges(let version, let note):
            update(id) { issue in
                guard issue.proposal?.version == version, issue.state == .awaitingApproval else { return }
                issue.approval = nil
                issue.proposalReviewNote = note
            }
            if qaPreview {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.update(id) { issue in
                        guard issue.proposal?.version == version, issue.state == .awaitingApproval else { return }
                        issue.proposal?.version += 1
                        issue.proposal?.instruction += "\n합성 Stallari 수정: " + note
                        issue.proposalReviewNote = nil
                    }
                }
            }
        case .rejectProposal(let version, let note):
            update(id) { issue in
                guard issue.proposal?.version == version, issue.state == .awaitingApproval else { return }
                issue.approval = nil
                issue.proposalReviewNote = note
                issue.state = .rejected
            }
        case .resolvedInput:
            guard issue(id)?.state == .needsInput,
                  !questions.contains(where: { $0.issue == id && $0.isPending }) else { return }
            update(id) { t in
                t.state = .running
                for i in t.hirds.indices {
                    t.hirds[i].status = .working
                    t.hirds[i].lastActivityAt = .now
                    if let j = t.hirds[i].steps.firstIndex(where: { [.blocked, .failed].contains($0.state) }) {
                        t.hirds[i].steps[j].state = .active
                    }
                }
            }
        case .resume:
            update(id) { t in
                t.state = .running
                for i in t.hirds.indices { t.hirds[i].status = .working; t.hirds[i].lastActivityAt = .now }
            }
        case .stop:
            update(id) { t in
                t.state = .failed
                for i in t.hirds.indices { t.hirds[i].status = .failed(at: .now) }
            }
        }
        tabs.reconcile(threads: threads, issues: issues)
        if let thread = threads.first(where: { $0.id == selectedThreadID }), thread.issueID != nil,
           !tabs.issueThreadIDs.contains(thread.id) { selectThread(ConversationThread.defaultID) }
    }

    public func answer(_ id: Question.ID, with answer: QuestionAnswer) {
        guard let i = questions.firstIndex(where: { $0.id == id }), questions[i].isPending else { return }
        questions[i].state = .answered(answer)
        resume(questions[i])
    }

    public func cancel(_ id: Question.ID) {
        guard let i = questions.firstIndex(where: { $0.id == id }), questions[i].isPending else { return }
        questions[i].state = .cancelled
        resume(questions[i])
    }

    /// The asking Hird goes back to work once its question is resolved.
    private func resume(_ q: Question) {
        guard let issue = q.issue else { return }
        update(issue) { t in
            guard let h = t.hirds.firstIndex(where: { $0.id == q.run }) else { return }
            t.hirds[h].status = .working
            t.hirds[h].lastActivityAt = .now
            t.hirds[h].currentCommand = "답을 받아 불러오기 확인 이어감"
            if let j = t.hirds[h].steps.firstIndex(where: { $0.state == .blocked }) { t.hirds[h].steps[j].state = .active }
        }
    }

    private func update(_ id: Issue.ID, _ change: (inout Issue) -> Void) {
        guard let i = issues.firstIndex(where: { $0.id == id }) else { return }
        change(&issues[i])
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard let self else { return }
                self.update("npc-repeat") { t in
                    if let i = t.hirds.firstIndex(where: { $0.name == "Hird-1" }), t.hirds[i].status == .working {
                        t.hirds[i].lastActivityAt = .now
                        if self.qaPreview {
                            t.hirds[i].currentCommand = t.hirds[i].currentCommand == nil ? "합성 검사 · 실제 명령을 실행하지 않음" : nil
                            t.acceptance[0].state = t.acceptance[0].state == .met ? .pending : .met
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sample content
    /// Resolve synthetic fixtures once; display-name changes never change their ownership.
    private func bindSampleIssues() {
        issueProjects = Dictionary(uniqueKeysWithValues: issues.compactMap { issue in
            projects.first { $0.name == issue.projectName }.map { (issue.id, $0.id) }
        })
    }


    /// Illustrative plan for the project tabs. Dates are relative to the snapshot clock so the
    /// current week always has a scope; no milestone is marked reached without evidence.
    private static func makeMilestones(now: Date) -> [Milestone] {
        let gamza = "gamza"
        let knarr = "knarr"
        let thisWeek = Milestone.weekStart(containing: now)
        let lastWeek = thisWeek.addingTimeInterval(-7 * 86400)
        let createdAt = now.addingTimeInterval(-30 * 86400)

        var dialogue = Milestone(
            id: "gamza-dialogue", projectID: gamza, order: 0, title: "대화 반복 제거",
            detail: "NPC 대화가 같은 문장을 연달아 고르지 않도록 선택기와 저장 데이터를 함께 고칩니다.",
            status: .active, blockedReason: "", targetDate: thisWeek.addingTimeInterval(11 * 86400),
            criteria: [.init(text: "같은 문장 반복률이 측정 기준 아래로 내려간다", state: .met, evidence: "DialogueTests 반복 0건"),
                       .init(text: "기존 저장 데이터 3개가 그대로 열린다", state: .met, evidence: "샘플 3개 불러오기 확인"),
                       .init(text: "대화 선택 테스트가 통과한다", state: .pending, evidence: "")],
            evidence: "", inScope: ["대화 선택기 수정", "기존 저장 데이터 호환"],
            outOfScope: ["새 대화 작성 도구"], prerequisites: [],
            weeks: [.init(weekStart: lastWeek, scope: ["원인 재현", "선택기 수정"], result: "재현과 수정 완료", recordedAt: lastWeek.addingTimeInterval(4 * 86400)),
                    .init(weekStart: thisWeek, scope: ["테스트 보강", "저장 데이터 회귀 확인"], result: "", recordedAt: now)],
            reachedAt: nil, createdAt: createdAt, updatedAt: now)

        var release = Milestone(
            id: "gamza-release", projectID: gamza, order: 1, title: "1.0 출시 준비",
            detail: "출시 빌드와 안내 문서를 마무리합니다.",
            status: .planned, blockedReason: "", targetDate: thisWeek.addingTimeInterval(39 * 86400),
            criteria: [.init(text: "출시 빌드가 설치된다", state: .pending, evidence: "")],
            evidence: "", inScope: ["출시 빌드"], outOfScope: ["마케팅"], prerequisites: [Milestone.ID("gamza-dialogue")],
            weeks: [], reachedAt: nil, createdAt: createdAt, updatedAt: now)

        var onboarding = Milestone(
            id: "gamza-onboarding", projectID: gamza, order: 2, title: "튜토리얼 정리",
            detail: "첫 실행 안내를 짧게 정리했습니다.",
            status: .reached, blockedReason: "", targetDate: lastWeek,
            criteria: [.init(text: "새 게임에서 안내가 두 번 이하로 나온다", state: .met, evidence: "수동 확인 3회")],
            evidence: "출시 전 확인 완료", inScope: ["첫 실행 안내"], outOfScope: ["도움말 전체"],
            prerequisites: [], weeks: [.init(weekStart: lastWeek, scope: ["안내 문구 정리"], result: "완료", recordedAt: lastWeek.addingTimeInterval(3 * 86400))],
            reachedAt: lastWeek.addingTimeInterval(3 * 86400), createdAt: createdAt, updatedAt: now)

        let knarrPlan = Milestone(
            id: "knarr-milestones", projectID: knarr, order: 0, title: "마일스톤 탭",
            detail: "프로젝트별 계획과 주간 범위를 기록합니다.",
            status: .active, blockedReason: "", targetDate: thisWeek.addingTimeInterval(5 * 86400),
            criteria: [.init(text: "마일스톤을 만들고 고칠 수 있다", state: .met, evidence: "저장 테스트"),
                       .init(text: "주간 기록이 유지된다", state: .pending, evidence: "")],
            evidence: "", inScope: ["목록과 편집"], outOfScope: ["자동 일정"], prerequisites: [],
            weeks: [.init(weekStart: thisWeek, scope: ["저장 계약", "화면 연결"], result: "", recordedAt: now)],
            reachedAt: nil, createdAt: createdAt, updatedAt: now)

        dialogue.updatedAt = now; release.updatedAt = now; onboarding.updatedAt = now
        return [dialogue, release, onboarding, knarrPlan]
    }

    /// Illustrative project-level weekly plans; the current week is editable, past weeks are history.
    private static func makeWeekPlans(now: Date) -> [ProjectWeekPlan] {
        let thisWeek = ProjectWeek.start(containing: now)
        let lastWeek = thisWeek.addingTimeInterval(-7 * 86400)
        return [
            .init(projectID: "gamza", weekStart: lastWeek, plan: ["원인 재현", "선택기 수정"],
                  recordedAt: lastWeek.addingTimeInterval(4 * 86400)),
            .init(projectID: "gamza", weekStart: thisWeek, plan: ["테스트 보강", "저장 데이터 회귀 확인"], recordedAt: now),
            .init(projectID: "knarr", weekStart: thisWeek, plan: ["저장 계약", "화면 연결"], recordedAt: now),
        ]
    }

    private static func make(now: Date) -> (issues: [Issue], chat: [ChatItem], questions: [Question]) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let npc = Issue(
            id: "npc-repeat", title: "NPC 대화 반복 원인 찾아 수정", projectName: "Gamza Saga", state: .running,
            headline: "Hird 2명 · 19분째",
            detail: "Hird-1이 고친 대화 선택 코드로 테스트를 돌리고 있어요. Hird-2는 기존 저장 데이터 3개로 불러오기를 확인할 준비를 마쳤어요.",
            acceptance: [
                Criterion(text: "같은 문장이 연달아 나오는 비율 감소", state: .pending, evidence: "테스트 결과 기다리는 중"),
                Criterion(text: "관련 테스트 통과", state: .pending, evidence: "DialogueTests 실행 중"),
                Criterion(text: "기존 저장 데이터 그대로 불러와짐", state: .pending, evidence: "샘플 3개 준비됨"),
            ],
            hirds: [
                HirdRun(id: "h1", name: "Hird-1", role: "원인 찾고 고치기", status: .working,
                        steps: [.init(title: "원인 찾기", state: .done), .init(title: "수정", state: .done),
                                .init(title: "테스트", state: .active), .init(title: "정리", state: .pending)],
                        currentCommand: "swift test --filter DialogueTests", lastActivityAt: now.addingTimeInterval(-4)),
                HirdRun(id: "h2", name: "Hird-2", role: "저장 데이터 확인", status: .waitingOnHuman(since: ago(2)),
                        steps: [.init(title: "샘플 준비", state: .done), .init(title: "불러오기 확인", state: .blocked)],
                        currentCommand: "질문에 답 기다림", lastActivityAt: ago(2)),
            ],
            events: [
                ActivityEvent(at: ago(1), actor: "Hird-1", text: "테스트 실행", detail: "swift test --filter DialogueTests"),
                ActivityEvent(at: ago(3), actor: "Hird-1", text: "파일 수정", detail: "Sources/Dialogue/LinePicker.swift"),
                ActivityEvent(at: ago(6), actor: "Hird-2", text: "저장 샘플 복사", detail: "Fixtures/saves/v1.json 외 2개"),
                ActivityEvent(at: ago(12), actor: "Hird-1", text: "원인 찾음", detail: "recentLines가 장면 전환마다 비워짐"),
                ActivityEvent(at: ago(19), actor: "Stallari", text: "이슈 만들고 Hird 2명에게 맡김"),
            ],
            startedAt: ago(19))

        let testflight = Issue(
            id: "testflight", title: "TestFlight 빌드 업로드", projectName: "Gamza Saga", state: .needsInput,
            headline: "로그인 필요",
            detail: "Xcode › Settings › Accounts에서 Apple 개발자 계정에 다시 로그인해 주세요. 로그인하면 Hird가 바로 업로드를 이어가요.",
            acceptance: [
                Criterion(text: "Release 빌드 성공", state: .met, evidence: "xcodebuild archive 통과"),
                Criterion(text: "TestFlight에 빌드 올라감", state: .pending, evidence: "계정 로그인 필요로 멈춤"),
            ],
            hirds: [
                HirdRun(id: "h3", name: "Hird-3", role: "빌드와 업로드", status: .waitingOnHuman(since: ago(3)),
                        steps: [.init(title: "Release 빌드", state: .done), .init(title: "업로드", state: .blocked),
                                .init(title: "처리 확인", state: .pending)],
                        currentCommand: "Apple 계정 로그인 기다림", lastActivityAt: ago(3)),
            ],
            events: [
                ActivityEvent(at: ago(3), actor: "Hird-3", text: "업로드 실패, 사람 필요로 판단", detail: "No Accounts with App Store Connect access"),
                ActivityEvent(at: ago(6), actor: "Hird-3", text: "빌드 성공", detail: "xcodebuild archive -scheme GamzaSaga"),
            ],
            startedAt: ago(9))

        let darkMode = Issue(
            id: "dark-mode", title: "설정 화면 다크 모드 색 정리", projectName: "Knarr", state: .done,
            headline: "24분 걸림",
            detail: "설정 화면의 글자와 배경 대비를 맞추고, 다크 모드에서 회색 보조 글자가 안 보이던 부분을 고쳤어요. 확인하면 이슈를 닫아요.",
            acceptance: [
                Criterion(text: "다크 모드에서 모든 글자 대비 4.5:1 이상", state: .met, evidence: "대비 검사 스크립트 통과"),
                Criterion(text: "관련 테스트 통과", state: .met, evidence: "swift test · 12개 통과"),
                Criterion(text: "실제 앱에서 화면 확인", state: .met, evidence: "라이트·다크 화면 2장"),
            ],
            hirds: [
                HirdRun(id: "h4", name: "Hird-1", role: "색 정리", status: .done(at: ago(42)),
                        steps: [.init(title: "대비 검사", state: .done), .init(title: "색 수정", state: .done),
                                .init(title: "테스트", state: .done), .init(title: "앱 확인", state: .done)],
                        currentCommand: nil, lastActivityAt: ago(42)),
            ],
            events: [
                ActivityEvent(at: ago(42), actor: "Stallari", text: "조건 3개 대조 후 결과로 보고"),
                ActivityEvent(at: ago(45), actor: "Hird-1", text: "앱 실행 후 화면 캡처", detail: "settings-light.png, settings-dark.png"),
                ActivityEvent(at: ago(50), actor: "Hird-1", text: "테스트 실행", detail: "swift test · 12 passed"),
            ],
            startedAt: ago(66))

        let migration = Issue(
            id: "save-migration", title: "세이브 파일 마이그레이션", projectName: "Gamza Saga", state: .failed,
            headline: "시도 2번",
            detail: "v3 세이브 샘플이 없어서 변환 결과를 확인할 방법이 없었어요. 샘플을 만드는 이슈를 먼저 돌리자고 제안했어요.",
            acceptance: [
                Criterion(text: "v2 → v3 변환 후 내용 일치", state: .unmet, evidence: "v3 샘플 없음"),
                Criterion(text: "기존 테스트 통과", state: .pending, evidence: "변환 확인 전이라 실행 안 함"),
            ],
            hirds: [
                HirdRun(id: "h5", name: "Hird-2", role: "변환 코드", status: .failed(at: ago(60)),
                        steps: [.init(title: "샘플 찾기", state: .failed), .init(title: "변환", state: .pending),
                                .init(title: "내용 비교", state: .pending)],
                        currentCommand: nil, lastActivityAt: ago(60)),
            ],
            events: [
                ActivityEvent(at: ago(60), actor: "Stallari", text: "같은 원인으로 2번 멈춰서 사람에게 제안"),
                ActivityEvent(at: ago(68), actor: "Hird-2", text: "샘플 찾기 실패", detail: "find Fixtures -name \"*v3*\" → 0개"),
            ],
            startedAt: ago(80))

        let chat: [ChatItem] = [
            ChatItem(at: ago(20), kind: .day("오늘")),
            ChatItem(at: ago(20), kind: .user("감자사가에서 NPC가 같은 말을 계속 반복하는 거 고쳐줘. 저장 데이터는 깨지면 안 돼.")),
            ChatItem(at: ago(19), kind: .stallari("이슈 하나로 만들어서 **Hird 2명**에게 맡겼어요.\n\n- `LinePicker`의 최근 문장 기억이 장면마다 비워지는지 확인\n- 저장 데이터 v1~v3 불러오기 확인\n\n완료 조건이 다 확인되면 결과로 알려드릴게요.", project: "Gamza Saga")),
            ChatItem(at: ago(19), kind: .issue("npc-repeat")),
            ChatItem(at: ago(2), kind: .autoCheck(summary: "Stallari가 Hird 진행을 3번 확인했어요 · 이상 없음", lines: [
                "Hird-1이 대화 선택 코드에서 최근 문장 기억이 초기화되는 지점을 찾음",
                "Hird-2가 저장 데이터 샘플 3개로 불러오기 테스트 준비",
                "Hird-1이 수정 후 DialogueTests 실행 시작",
            ])),
            ChatItem(at: ago(2), kind: .question("q-v1-saves")),
            ChatItem(at: ago(3), kind: .notice(Notice(
                tone: .needsInput, title: "TestFlight 업로드에 Apple 계정 로그인이 필요해요",
                body: "Xcode › Settings › Accounts에서 다시 로그인해 주세요. 로그인하면 바로 이어서 올려요.",
                issue: "testflight", primary: .init("로그인했어", .resolvedInput)))),
            ChatItem(at: ago(1), kind: .notice(Notice(
                tone: .failed, title: "세이브 파일 마이그레이션이 멈췄어요",
                body: "v3 세이브 샘플이 없어서 변환 결과를 확인할 수 없었어요. 샘플을 만드는 이슈를 먼저 돌리고 이어서 할까요?",
                issue: "save-migration", primary: nil))),
            ChatItem(at: ago(0.5), kind: .notice(Notice(
                tone: .result, title: "설정 화면 다크 모드 색 정리 끝났어요",
                body: "완료 조건 3개 모두 확인했어요. 테스트 12개 통과, 실제 앱 화면 2장을 남겼어요.",
                issue: "dark-mode", primary: nil))),
        ]
        let questions = [
            Question(id: "q-v1-saves", issue: "npc-repeat", run: "h2", asker: "Hird-2",
                     prompt: "v1 저장 파일은 2023년 형식이라 대화 기록 필드가 없어요. 불러오기 확인에 v1도 넣을까요?",
                     options: ["v1도 넣어줘", "v2, v3만 확인해"], askedAt: ago(2)),
        ]
        var inventory = Issue(
            id: "inventory-sort", title: "인벤토리 정렬 버그 수정", projectName: "Gamza Saga", state: .done, confirmed: true,
            headline: "16분 걸림", detail: "정렬 기준을 이름에서 얻은 순서로 바꾸고 테스트 4개를 더했어요.",
            acceptance: [Criterion(text: "얻은 순서대로 정렬", state: .met, evidence: "InventoryTests 통과")],
            hirds: [HirdRun(id: "h6", name: "Hird-1", role: "정렬 수정", status: .done(at: ago(60 * 20)),
                            steps: [.init(title: "수정", state: .done), .init(title: "테스트", state: .done)],
                            currentCommand: nil, lastActivityAt: ago(60 * 20))],
            events: [], startedAt: ago(60 * 20 + 16))
        inventory.milestoneID = "gamza-dialogue"
        inventory.application = .applied(branch: "main", commit: "e77a210")
        var drawer = Issue(
            id: "drawer-chat", title: "이슈 서랍을 대화 한 화면으로", projectName: "Knarr", state: .done, confirmed: true,
            headline: "41분 걸림", detail: "탭을 없애고 대화 한 화면으로 바꿨어요.",
            acceptance: [Criterion(text: "입력창 하나", state: .met, evidence: "스냅샷 4장")],
            hirds: [HirdRun(id: "h7", name: "Hird-1", role: "서랍 정리", status: .done(at: ago(130)),
                            steps: [.init(title: "수정", state: .done), .init(title: "스냅샷", state: .done)],
                            currentCommand: nil, lastActivityAt: ago(130))],
            events: [], startedAt: ago(171))
        drawer.milestoneID = "knarr-milestones"
        drawer.application = .applied(branch: "main", commit: "a3f4ef4")
        return ([npc, testflight, darkMode, migration, inventory, drawer], chat, questions)
    }
}

/// Fixed, explicitly synthetic content for design review and snapshots. Nothing is read from disk or sent anywhere.
extension SampleKnarrStore {
    static func previewInstructionSources() -> [InstructionSource] {
        let base = "~/Library/Application Support/Knarr/instructions"
        return [
            .init(path: "\(base)/common/AGENTS.md", role: .common, projectID: nil, kind: .agents,
                  text: InstructionSources.packaged(role: .stallari).source(.agents, role: .common)?.text ?? "",
                  version: "preview", migratedFrom: nil),
            .init(path: "\(base)/common/RULES.md", role: .common, projectID: nil, kind: .rules,
                  text: InstructionSources.packaged(role: .stallari).source(.rules, role: .common)?.text ?? "",
                  version: "preview", migratedFrom: nil),
            .init(path: "\(base)/stallari/AGENTS.md", role: .stallari, projectID: nil, kind: .agents,
                  text: InstructionSources.packaged(role: .stallari).source(.agents, role: .stallari)?.text ?? "",
                  version: "preview", migratedFrom: nil),
            .init(path: "\(base)/stallari/RULES.md", role: .stallari, projectID: nil, kind: .rules,
                  text: InstructionSources.packaged(role: .stallari).source(.rules, role: .stallari)?.text ?? "",
                  version: "preview", migratedFrom: nil),
            .init(path: "\(base)/hird/AGENTS.md", role: .hird, projectID: nil, kind: .agents,
                  text: InstructionSources.packaged(role: .hird).source(.agents, role: .hird)?.text ?? "",
                  version: "preview", migratedFrom: nil),
            .init(path: "\(base)/hird/RULES.md", role: .hird, projectID: nil, kind: .rules,
                  text: InstructionSources.packaged(role: .hird).source(.rules, role: .hird)?.text ?? "",
                  version: "preview", migratedFrom: nil)
        ]
    }
}

public enum DesignScene: String, Sendable, CaseIterable {
    /// Attachments, the four callouts and a folded one, a chat issue card, a nearly full context.
    case chatCallouts
    /// A wide table, a narrow table with a number column, a code block, inline code.
    case chatTables
    /// Two running issues (one active, one quiet), one waiting on input, one stopped, one closed.
    case issues
    /// A linked question plus its focused replies, so the inline canvas can be reviewed.
    case conversationCanvas
    /// The main conversation with a generated work report card, and the same card after a failed analysis.
    case reportCard
}

extension SampleKnarrStore {
    /// The issue the `.issues` scene opens in the drawer: a saved proposal with metadata and a long instruction.
    public static let designDrawerIssue: Issue.ID = "design-npc"

    public convenience init(designScene scene: DesignScene, now: Date = .now) {
        self.init(now: now)
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let base = Self.make(now: now)
        switch scene {
        case .chatCallouts:
            contextUsage = ContextUsage(state: .object(["contextUsage": .object(["tokens": .number(125_000), "contextWindow": .number(128_000)])]))
            var request = ChatItem(at: ago(9), kind: .user("빌드가 왜 깨졌는지 로그랑 화면 캡처로 확인해 줘. 저장 데이터는 건드리면 안 돼."))
            request.attachments = [URL(fileURLWithPath: "/tmp/knarr-sample/build-error.png"), URL(fileURLWithPath: "/tmp/knarr-sample/빌드 로그.txt")]
            chat = [
                ChatItem(at: ago(9), kind: .day("오늘")),
                request,
                ChatItem(at: ago(8), kind: .stallari("""
                    로그와 캡처를 읽었어요. 원인은 하나였고 Hird 한 명이 고쳐서 테스트까지 돌렸어요.

                    > [!RESULT] 원인을 찾았고 테스트가 통과했어요
                    > `LinePicker`가 장면이 바뀔 때마다 최근 문장 기억을 비우고 있었어요. 한 줄 고쳤고 관련 테스트 12개가 통과했어요.

                    > [!INFO] 원본 `main`에는 아직 반영하지 않았어요
                    > Stallari가 판정과 통합을 이어가요.

                    > [!DECIDE] 저장 데이터 v1도 확인할까요?
                    > v1에는 대화 기록 필드가 없어서, 불러오기 확인에 넣으면 기본값으로 채워져요.

                    > [!STOP] TestFlight 업로드가 로그인 때문에 멈췄어요
                    > Xcode › Settings › Accounts에서 Apple 계정에 다시 로그인해 주세요.

                    > [!INFO]- 실행한 명령 7개
                    > - `cat Sources/Dialogue/LinePicker.swift` · 통과
                    > - `swift test --filter DialogueTests` · 통과
                    > - `git diff -- Sources/Dialogue` · 통과
                    """, project: "Gamza Saga")),
                ChatItem(at: ago(8), kind: .issue("npc-repeat")),
                ChatItem(at: ago(2), kind: .user("v1도 같이 확인해 줘")),
            ]
        case .chatTables:
            chat = [
                ChatItem(at: ago(6), kind: .day("오늘")),
                ChatItem(at: ago(6), kind: .user("검증 결과를 표로 정리해 줘")),
                ChatItem(at: ago(5), kind: .stallari("""
                    ## 검증
                    명령마다 종료 코드와 걸린 시간을 모았어요. `swift test`는 한 곳만 실패했어요.

                    | 확인 | 명령 | 결과 | 걸린 시간 | 비고 |
                    |---|---|:---:|---:|---|
                    | 대화 선택 | `swift test --filter DialogueTests --parallel --enable-code-coverage` | ✓ 통과 | 41초 | 12개 중 12개 통과, 커버리지 83% |
                    | 저장 불러오기 | `swift test --filter SaveMigratorTests --skip-update --no-parallel` | ✗ 실패 | 18초 | v3 샘플이 없어서 변환 결과를 비교하지 못함 |
                    | 화면 스냅샷 | `swift run knarr-snapshot outputs/ui-redesign/after` | ✓ 통과 | 2분 4초 | 라이트·다크 각 4장, 변경 없는 화면은 그대로 |

                    바뀐 파일은 두 개뿐이에요.

                    | 파일 | 바뀐 줄 |
                    |---|---:|
                    | `Sources/Dialogue/LinePicker.swift` | 14 |
                    | `Tests/DialogueTests/RepeatTests.swift` | 52 |

                    핵심 수정은 이 한 줄이에요.

                    ```swift
                    // 장면이 바뀌어도 최근 문장 기억을 비우지 않는다
                    func sceneDidChange() {
                        recentLines.removeAll(keepingCapacity: true)
                        recentLines = lastSceneLines
                    }
                    ```

                    `recentLines`는 `LinePicker`가 들고 있는 배열이고, 저장 데이터에는 들어가지 않아요.
                    """, project: "Gamza Saga")),
            ]
        case .issues:
            var npc = Issue(
                id: Self.designDrawerIssue, title: "NPC 대화 반복 원인 찾아 수정 — 장면 전환 때 최근 문장 기억이 비워지는 문제와 저장 데이터 불러오기까지 한 번에 확인",
                projectName: "Gamza Saga", state: .running, headline: "Hird 1명 · 19분째",
                detail: "Hird-1이 고친 대화 선택 코드로 `DialogueTests`를 돌리고 있어요. 끝나면 저장 데이터 v1~v3 불러오기를 확인해요.",
                acceptance: [
                    Criterion(text: "같은 문장이 연달아 나오는 비율 감소", state: .pending, evidence: "테스트 결과 기다리는 중"),
                    Criterion(text: "관련 테스트 통과", state: .pending, evidence: "DialogueTests 실행 중"),
                    Criterion(text: "저장 데이터 v1~v3 그대로 불러와짐", state: .pending, evidence: "아직 실행 전"),
                    Criterion(text: "바꾼 파일이 Sources/Dialogue 안에 있음", state: .pending, evidence: "diff 확인 전"),
                    Criterion(text: "변경 요약과 검증 출력을 증거로 남김", state: .pending, evidence: "마지막 단계"),
                ],
                hirds: [HirdRun(id: "h1", name: "Hird-1", role: "원인 찾고 고치기", status: .working,
                                steps: [.init(title: "원인 찾기", state: .done), .init(title: "수정", state: .done),
                                        .init(title: "테스트", state: .active), .init(title: "정리", state: .pending)],
                                currentCommand: "swift test --filter DialogueTests", lastActivityAt: now.addingTimeInterval(-4))],
                events: [ActivityEvent(at: ago(1), actor: "Hird-1", text: "테스트 실행", detail: "swift test --filter DialogueTests"),
                         ActivityEvent(at: ago(12), actor: "Hird-1", text: "원인 찾음", detail: "recentLines가 장면 전환마다 비워짐"),
                         ActivityEvent(at: ago(19), actor: "Stallari", text: "이슈 만들고 Hird에게 맡김")],
                startedAt: ago(19))
            npc.proposal = IssueProposal(version: 2, instruction: """
                저장 데이터를 건드리지 않고 NPC 대화 반복 원인을 찾아 고친다.

                1. `LinePicker`가 장면 전환마다 최근 문장 기억을 비우는지 확인한다.
                2. 원인을 고친 뒤 `swift test --filter DialogueTests`로 확인한다.
                3. 세이브 v1~v3을 모두 불러와 대화 기록이 그대로인지 확인한다.
                4. 바꾼 파일은 `Sources/Dialogue` 아래로 한정한다. 대사 데이터(`Resources/Dialogue/*.json`)는 손으로 고치지 않는다.
                5. 끝나면 변경 요약과 검증 출력을 증거로 남긴다.
                """, model: "openai-codex/gpt-6.1-sol", mode: .change, previousRunID: "run-3a91", thinking: "high")
            npc.approval = IssueApproval(version: 2, approvedAt: ago(19), runID: "h1")
            npc.executionModel = "openai-codex/gpt-6.1-sol"
            npc.executionThinking = "high"
            npc.hirds[0].currentActivity = .init(kind: .thinking, at: now.addingTimeInterval(-4))
            npc.hirds[0].recentActivities = [
                .init(kind: .command, target: "git diff -- Sources/Dialogue", at: ago(5)),
                .init(kind: .edit, target: "LinePicker.swift", at: ago(8)),
                .init(kind: .read, target: "RepeatTests.swift", at: ago(11)),
            ]

            var contrast = Issue(
                id: "design-contrast", title: "설정 화면 다크 모드 대비 검사", projectName: "Knarr", state: .running,
                headline: "Hird 1명 · 31분째", detail: "대비 검사 스크립트를 돌린 뒤 글자 색을 고치고 있어요.",
                acceptance: [Criterion(text: "다크 모드에서 모든 글자 대비 4.5:1 이상", state: .met, evidence: "대비 검사 스크립트 통과"),
                             Criterion(text: "관련 테스트 통과", state: .pending, evidence: "아직 실행 전"),
                             Criterion(text: "실제 앱에서 화면 확인", state: .pending, evidence: "스냅샷 대기")],
                hirds: [HirdRun(id: "h8", name: "Hird-2", role: "색 정리", status: .working,
                                steps: [.init(title: "대비 검사", state: .done), .init(title: "색 수정", state: .active),
                                        .init(title: "테스트", state: .pending)],
                                currentCommand: "python3 scripts/contrast.py --dark", lastActivityAt: ago(12))],
                events: [], startedAt: ago(31))
            contrast.hirds[0].currentActivity = .init(kind: .read, target: "Theme.swift", at: ago(1))
            contrast.hirds[0].recentActivities = [
                .init(kind: .command, target: "python3 scripts/contrast.py --dark", at: ago(12)),
                .init(kind: .edit, target: "Theme.swift", at: ago(7)),
            ]

            var closed = base.issues.first { $0.id == "inventory-sort" }!
            closed.archivedAt = ago(60 * 30); closed.archiveReason = IssueCloseReason.applied.rawValue
            issues = [npc, contrast] + base.issues.filter { $0.id == "testflight" || $0.id == "save-migration" } + [closed]
            questions = []
            chat = [
                ChatItem(at: ago(20), kind: .day("오늘")),
                ChatItem(at: ago(20), kind: .user("NPC 반복이랑 설정 화면 대비, 둘 다 맡길게요.")),
                ChatItem(at: ago(19), kind: .stallari("이슈 두 개로 나눠서 **Hird**에게 맡겼어요. 하나는 지금 활동 중이고, 하나는 잠시 조용해요.", project: "모든 프로젝트")),
                ChatItem(at: ago(19), kind: .issue(Self.designDrawerIssue)),
                ChatItem(at: ago(19), kind: .issue("design-contrast")),
            ]
        case .conversationCanvas:
            var link = ChatItem(at: ago(2), kind: .user("프로젝트 세션에서 돌아가는 작업은 탭에 어떻게 표시돼?"))
            link.isConversationLink = true
            func focused(_ text: String, _ assistant: Bool, _ minutes: Double) -> ChatItem {
                var item = ChatItem(at: ago(minutes), kind: assistant ? .stallari(text, project: nil) : .user(text))
                item.conversationRootID = link.id
                return item
            }
            chat = [
                ChatItem(at: ago(4), kind: .day("오늘")),
                ChatItem(at: ago(4), kind: .user("작업 중인 대화 탭에 활성 애니메이션을 표시하는 작업을 시작해 줘.")),
                ChatItem(at: ago(3), kind: .stallari("작업 중인 대화 탭에 활성 애니메이션을 표시하는 작업을 별도 이슈로 시작했습니다. 지금은 Hird가 준비 단계에 있습니다.", project: nil)),
                link,
                focused("지금 프로젝트 세션에서 돌아가고 있는 작업은 다음과 같이 표시되고 있습니다.", true, 1.5),
                focused("• Hird가 선택한 탭에서 동작 중인 작업이 활성 상태로 표시됩니다.\n• 각 작업은 애니메이션과 상태 배지로 실시간 진행 상황을 보여줍니다.\n• 완료되면 즉시 기록에 반영되어 진행 내역을 확인할 수 있습니다.", true, 1.2),
            ]
            isResponding = true
            responseStartedAt = ago(0.2)
            respondingConversationRoots = [link.id]
            streamingText = "필요한 추가 작업을 정리하고 있습니다."
        case .reportCard:
            let period = WorkReportPeriod(kind: .daily, start: ago(60 * 24), end: ago(60 * 9), timeZoneID: "Asia/Seoul")
            var ready = WorkReport(period: period, generatedAt: ago(2),
                                   items: [WorkReportItem(id: "design-npc", project: "Gamza Saga", title: "NPC 대화 반복 원인 찾아 수정",
                                                          reason: "장면 전환 때 최근 문장 기억이 비워지는 문제", outcome: "완료 조건 충족",
                                                          applicationRecord: "본체 반영·설치 확인 기록 없음", criteria: [],
                                                          runs: [.init(id: "run-1", startedAt: ago(120), endedAt: ago(71), state: "succeeded", stopReason: nil, previousRunID: nil, model: "openai-codex/gpt-6.1-sol")],
                                                          time: .init(total: 2_940, elapsed: 2_400)),
                                          WorkReportItem(id: "design-contrast", project: "Knarr", title: "설정 화면 다크 모드 대비 검사",
                                                         reason: "다크 모드 글자 대비 확인", outcome: "실행 중",
                                                         applicationRecord: "본체 반영·설치 확인 기록 없음", criteria: [],
                                                         runs: [.init(id: "run-2", startedAt: ago(32), endedAt: nil, state: "working", stopReason: nil, previousRunID: nil, model: "openai-codex/gpt-6.1-sol")],
                                                         time: .init(total: 1_860, elapsed: 1_500))],
                                   time: .init(total: 4_800, elapsed: 3_900), failures: ["코드 스냅샷 저장": 1], plans: [])
            ready.analysisState = .ready
            ready.analysis = "**주요 결과**\n\n두 작업 중 하나는 완료 조건을 채웠고, 다른 하나는 아직 실행 중이에요."
            var failed = ready
            failed.period = WorkReportPeriod(kind: .weekly, start: ago(60 * 24 * 7), end: ago(60 * 9), timeZoneID: "Asia/Seoul")
            failed.analysisState = .failed
            failed.analysisError = "Stallari 분석을 완료하지 못했어요. 연결 상태를 확인한 뒤 다시 시도해 주세요."
            workReports = [ready, failed]
            chat = [
                ChatItem(at: ago(180), kind: .day("어제")),
                ChatItem(at: ago(180), kind: .user("대비 검사까지 마무리해 줘.")),
                ChatItem(at: ago(179), kind: .stallari("맡긴 작업을 확인하고 있어요.", project: nil)),
            ]
        }
        issues = issues.map { Self.withSampleProgress($0, now: now) }
        bindSampleIssues()
    }

    /// Stage progress for the sample Hirds that are still going, built by the same function the app uses
    /// from checks that would have been recorded.
    static func withSampleProgress(_ issue: Issue, now: Date) -> Issue {
        var issue = issue
        for index in issue.hirds.indices {
            switch issue.hirds[index].status {
            case .working, .waitingOnHuman: break
            case .failed, .done: continue
            }
            issue.hirds[index].stageProgress = sampleProgress(for: issue.hirds[index], now: now)
        }
        return issue
    }

    private static func sampleProgress(for run: HirdRun, now: Date) -> HirdProgress? {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func check(_ command: String, _ exit: Int32?, _ minutes: Double) -> HirdProgress.Check {
            .init(command: command, exitCode: exit, finishedAt: ago(minutes))
        }
        let branch = check("git switch -c codex/sample", 0, 20)
        let red = check("swift test --filter SampleTests", 1, 12)
        let green = check("swift test --filter SampleTests", 0, 6)
        let waiting: Bool = if case .waitingOnHuman = run.status { true } else { false }
        func progress(_ checks: [HirdProgress.Check], edit: Double? = nil) -> HirdProgress {
            HirdProgress(.init(checks: checks, currentCommand: run.currentCommand, lastEditAt: edit.map(ago), waitingOnQuestion: waiting))
        }
        switch run.id.rawValue {
        case "h1", "h8", "board-1": return progress([branch, red], edit: 5)
        case "h2": return progress([branch, red])
        case "h3": return progress([branch, red, green, check("scripts/build-app.sh", 0, 4)])
        case "board-2": return progress([branch, red, green])
        case "board-3": return progress([branch, red], edit: 6)
        case "board-4": return progress([branch, red])
        default: return nil
        }
    }
}

public enum StallariWorkScene: Sendable { case single, multiple }

/// Synthetic issue-session scenes; no runtime, operational database or provider is opened.
public enum IssueSessionScene: String, Sendable, CaseIterable {
    case main, question, approval, completed, conversation, history, tabs, singleHird, multipleHirds
}

extension SampleKnarrStore {
    /// A deterministic offscreen preview of the saved-stage projection used by live cards.
    public convenience init(stageProgressPreview: Bool, now: Date = .now) {
        self.init(issueSessionScene: .singleHird, now: now)
        guard stageProgressPreview, !issues.isEmpty, !issues[0].hirds.isEmpty else { return }
        let plan: [IssueStage] = [
            .init(id: "storage", title: "저장 형식 조사", evidence: "구형 데이터 읽기", criterion: 1),
            .init(id: "runtime", title: "실행별 보고 연결", evidence: "소유 실행과 검증 ID 대조", criterion: 2),
            .init(id: "screen", title: "화면과 읽기 API 확인", evidence: "라이트·다크 화면과 세 읽기 API")
        ]
        let reports: [StageReport] = [
            .init(at: now.addingTimeInterval(-60), action: .completed, stageID: "storage", verified: true),
            .init(at: now.addingTimeInterval(-50), action: .completed, stageID: "runtime", note: "추가 검증 대기", verified: false),
            .init(at: now.addingTimeInterval(-40), action: .replanned, stageID: "", plan: [
                plan[0], plan[1], .init(id: "screen", title: "라이트·다크 화면 확인", evidence: "PNG 읽기")
            ], reason: "읽기 API 검사를 실행 단계에 합치고 화면 확인을 분리"),
            .init(at: now.addingTimeInterval(-30), action: .started, stageID: "screen")
        ]
        issues[0].title = "이슈별 단계 계획과 실행 기록 대조"
        issues[0].hirds[0].stageProgress = HirdProgress(.init(plan: plan, reports: reports))
        issues[0].hirds[0].currentCommand = nil
        if let index = threads.firstIndex(where: { $0.issueID == issues[0].id }) {
            threads[index].name = issues[0].title
        }
    }

    public convenience init(issueSessionScene scene: IssueSessionScene, now: Date = .now) {
        self.init(now: now)
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let base = Self.make(now: now)
        var running = base.issues.first { $0.id == "npc-repeat" }!
        running.hirds.removeAll { if case .waitingOnHuman = $0.status { true } else { false } }
        running.hirds.append(.init(id: "session-quiet", name: "Hird-2", role: "저장 데이터 회귀 확인",
            status: .working, steps: [.init(title: "관련 테스트", state: .active)],
            currentCommand: "swift test --filter SaveCompatibilityTests", lastActivityAt: ago(7)))
        running.hirds[1].currentActivity = .init(kind: .command, target: "swift test --filter SaveCompatibilityTests", at: ago(7))
        running.headline = "최근 문장 기억 수정 · 관련 테스트 확인 중"
        if scene == .singleHird {
            running.hirds = Array(running.hirds.prefix(1))
            running.headline = "Hird 실행"
            running.detail = "고친 대화 선택 코드로 DialogueTests를 돌리고 있어요. 끝나면 기존 저장 데이터 불러오기를 확인해요."
        }
        var asking = base.issues.first { $0.id == "testflight" }!
        asking.title = "저장 데이터 v1~v3 불러오기 확인"
        asking.headline = "v1 저장 데이터의 확인 범위를 정해야 해요"
        asking.detail = "v1 형식에는 대화 기록이 없어요. 저장 데이터 확인에 포함할까요?"
        asking.hirds[0].currentCommand = "답변 대기 · 저장 데이터 확인"
        var approval = Issue(id: "session-proposal", title: "설정 화면 대비 검사", projectName: "Knarr",
            state: .awaitingApproval, headline: "다크 모드 보조 글자 대비를 검사하고 수정",
            detail: "현재 Theme 토큰만 조정하고 라이트·다크 화면과 테스트로 확인합니다.",
            acceptance: [.init(text: "라이트·다크 대비 검사 통과", state: .pending, evidence: ""),
                         .init(text: "관련 테스트와 화면 검증", state: .pending, evidence: "")],
            hirds: [], events: [], startedAt: ago(2))
        approval.proposal = .init(instruction: "Theme 토큰의 보조 글자 대비를 검사하고 조정한다. 라이트·다크 화면과 관련 테스트로 확인한다.",
            model: "openai-codex/gpt-6.1-sol", thinking: "xhigh")
        var completed = base.issues.first { $0.id == "dark-mode" }!
        completed.headline = "라이트·다크 글자 대비 수정 · 조건 3/3 확인"
        completed.detail = "설정 화면의 보조 글자 대비를 수정하고 테스트와 라이트·다크 화면을 확인했어요."
        var stopped = base.issues.first { $0.id == "save-migration" }!
        stopped.headline = "v3 저장 샘플이 없어 변환 결과를 확인하지 못했어요"
        var closed = base.issues.first { $0.id == "inventory-sort" }!
        closed.archivedAt = ago(60)
        closed.archiveReason = IssueCloseReason.applied.rawValue
        switch scene {
        case .main: issues = [running, completed, stopped, approval, asking]
        case .question: issues = [asking]
        case .approval: issues = [approval]
        case .completed: issues = [completed]
        case .conversation, .singleHird, .multipleHirds: issues = [running]
        case .history: issues = [completed, closed]
        case .tabs: issues = [running, approval]
        }
        bindSampleIssues()
        threads = [.default]
        threadChats = [:]
        for index in issues.indices {
            let id = "issue-" + issues[index].id.rawValue
            issues[index].threadID = id
            threads.append(.init(id: id, name: issues[index].title, createdAt: issues[index].startedAt,
                issueID: issues[index].id, originThreadID: ConversationThread.defaultID))
            if issues[index].state != .awaitingApproval {
                let first = IssueApproval(version: 1, approvedAt: issues[index].startedAt, runID: issues[index].hirds.first?.id)
                issues[index].approval = first
                issues[index].approvalHistory = [first]
            }
            for hird in issues[index].hirds.indices {
                issues[index].hirds[hird].startedAt = issues[index].startedAt.addingTimeInterval(60)
            }
            if issues[index].state == .done {
                if case .done(let at) = issues[index].hirds.last?.status { issues[index].completedAt = at }
                issues[index].latestResult = .init(worktreePath: "/synthetic/issue-session",
                    branch: "knarr/hird/sample", commit: "sample", diffPath: nil, summary: issues[index].detail, verifications: [])
            }
            issues[index] = Self.withSampleProgress(issues[index], now: now)
            threadChats[id] = [
                .init(at: issues[index].startedAt, kind: .stallari("이슈 **\(issues[index].title)**를 맡았어요. 저장된 제안과 완료 조건을 기준으로 실행·검증을 이어갑니다.", project: issues[index].projectName)),
                .init(at: ago(1), kind: .stallari(issues[index].detail, project: issues[index].projectName))
            ]
        }
        questions = issues.contains { $0.id == asking.id } ? [
            .init(id: "session-question", issue: asking.id, run: asking.hirds[0].id, asker: "Hird-2",
                prompt: asking.detail, options: ["v1도 포함", "v2·v3만 확인"], askedAt: ago(3))
        ] : []
        chat = [
            .init(at: ago(21), kind: .user("NPC 반복 수정, 저장 데이터 확인과 설정 대비 검사를 맡길게요.")),
            .init(at: ago(20), kind: .stallari("목표별 이슈 대화를 열었어요. 결정이 필요한 내용은 위 카드에서 확인할 수 있어요.", project: nil))
        ]
        tabs.reconcile(threads: threads, issues: issues)
        if scene == .tabs {
            for issue in issues { goToThread(for: issue.id) }
            selectThread(ConversationThread.defaultID)
        } else if [.conversation, .singleHird, .multipleHirds].contains(scene), let id = issues.first?.conversationThreadID {
            selectThread(id)
        }
    }
}

extension SampleKnarrStore {
    /// 합성 상태 예시. 디스크·운영 DB·인증·실행 엔진을 읽거나 실행하지 않습니다.
    public convenience init(issueStatusScene: Bool, now: Date = .now) {
        self.init(now: now)
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let base = Self.make(now: now)
        let projectName = "합성 상태 프로젝트"
        var proposal = Issue(id: "status-proposal", title: "설정 화면 대비 검사 제안", projectName: projectName,
            state: .awaitingApproval, headline: "제안 v1 · 실행 전",
            detail: "합성 예시입니다. 저장된 제안을 직접 승인하기 전에는 실행하지 않습니다.",
            acceptance: [.init(text: "라이트·다크 글자 대비 확인", state: .pending, evidence: "")],
            hirds: [], events: [], startedAt: ago(2))
        proposal.proposal = .init(instruction: "합성 예시 · 설정 화면 대비를 검사하고 결과를 보고한다.",
            model: "openai-codex/gpt-6.1-sol")
        var working = base.issues.first { $0.id == "npc-repeat" }!
        working.title = "NPC 반복 대사 수정"
        working.hirds.removeAll { if case .waitingOnHuman = $0.status { true } else { false } }
        var asking = base.issues.first { $0.id == "testflight" }!
        asking.title = "저장 데이터 확인 범위 결정"
        asking.headline = "v1 형식도 확인할지 답변을 기다려요"
        asking.detail = "합성 질문입니다. 대화 기록 필드가 없는 v1 저장 데이터도 확인할까요?"
        asking.hirds[0].currentCommand = "합성 예시 · 확인 범위 답변 대기"
        var failed = base.issues.first { $0.id == "save-migration" }!
        failed.title = "저장 데이터 변환 · 미충족"
        failed.completedAt = ago(60)
        var review = base.issues.first { $0.id == "dark-mode" }!
        review.title = "다크 모드 수정 · 통합 대기"
        review.confirmed = true
        review.completedAt = ago(42)
        review.detail = "합성 성공 결과입니다. Stallari가 완료 조건 3개를 모두 충족으로 판정했고 원본 프로젝트에는 아직 반영하지 않았습니다."
        var judging = base.issues.first { $0.id == "inventory-sort" }!
        judging.id = "status-judging"
        judging.title = "정렬 수정 · 판정 대기"
        judging.state = .running
        judging.headline = "실행 종료 · 판정 대기"
        judging.detail = "합성 예시입니다. Hird 실행이 끝났고 Stallari가 완료 조건을 아직 대조하지 않았습니다."
        judging.hirds[0].status = .done(at: ago(6))
        judging.hirds[0].lastActivityAt = ago(6)
        judging.acceptance = [.init(text: "얻은 순서대로 정렬", state: .pending, evidence: "")]
        judging.completedAt = nil
        judging.confirmed = false
        judging.application = nil
        judging.latestResult = nil
        var applied = base.issues.first { $0.id == "inventory-sort" }!
        applied.title = "오래 시작한 정렬 수정 · 이번 주 완료"
        applied.confirmed = false
        applied.startedAt = ago(60 * 24 * 30)
        applied.completedAt = ago(10)
        applied.hirds[0].status = .done(at: ago(10))
        applied.hirds[0].lastActivityAt = ago(10)
        applied.detail = "합성 예시 · 한 달 전에 시작했고 이번 주 main에 반영했습니다. confirmed는 false입니다."
        var stopped = failed
        stopped.id = "status-stopped"
        stopped.title = "변환 시도 · 실행 실패"
        stopped.state = .running
        stopped.headline = "앱 종료로 중단됨 · 다시 시작"
        stopped.detail = "합성 예시입니다. 판정 전에 실행이 멈춰 완료 조건 대조 기록이 없습니다."
        stopped.acceptance = [.init(text: "v2 → v3 변환 후 내용 일치", state: .pending, evidence: "")]
        stopped.hirds[0].status = .failed(at: ago(18))
        stopped.hirds[0].lastActivityAt = ago(18)
        stopped.completedAt = nil
        stopped.latestResult = nil
        var cancelled = failed
        cancelled.id = "status-cancelled"
        cancelled.title = "이전 변환 시도 · 취소 보관"
        cancelled.archivedAt = ago(25)
        cancelled.archiveReason = IssueCloseReason.cancelled.rawValue
        var archivedApplied = base.issues.first { $0.id == "drawer-chat" }!
        archivedApplied.title = "이슈 서랍 정리 · 반영 후 보관"
        archivedApplied.archivedAt = ago(20)
        archivedApplied.archiveReason = IssueCloseReason.applied.rawValue
        archivedApplied.completedAt = ago(30)
        issues = [proposal, working, asking, judging, review, failed, stopped, applied, cancelled, archivedApplied]
        threads = [.default]
        threadChats = [:]
        for index in issues.indices {
            issues[index].projectName = projectName
            issues[index].events = []
            let threadID = "issue-" + issues[index].id.rawValue
            issues[index].threadID = threadID
            threads.append(.init(id: threadID, name: issues[index].title, createdAt: issues[index].startedAt,
                                 issueID: issues[index].id, originThreadID: ConversationThread.defaultID))
            threadChats[threadID] = [.init(at: now, kind: .stallari(issues[index].detail, project: projectName))]
            if issues[index].state == .done || issues[index].state == .failed {
                issues[index].latestResult = .init(worktreePath: "/synthetic/issue-status",
                    branch: "knarr/hird/synthetic", commit: "synthetic-result", diffPath: nil,
                    summary: issues[index].detail, verifications: [])
            }
            issues[index] = Self.withSampleProgress(issues[index], now: now)
        }
        projects = [.init(id: "issue-status", name: projectName, path: "/synthetic/issue-status", openIssues: 7)]
        bindSampleIssues()
        questions = [.init(id: "status-question", issue: asking.id, run: asking.hirds[0].id, asker: "Hird-2",
            prompt: asking.detail, options: ["v1도 포함", "v2·v3만 확인"], askedAt: ago(3))]
        chat = [
            .init(at: ago(20), kind: .user("제안부터 실행, 결과 검토와 반영 이후 기록까지 보여 주세요.")),
            .init(at: ago(19), kind: .stallari("명시적인 **합성 상태 예시**입니다. 실제 명령·인증·운영 데이터는 사용하지 않습니다.\n\n카드에는 승인 대기·답변 필요·진행 중·판정 중·통합 대기·미충족·실행 실패만 표시합니다. 판정과 통합은 Stallari가 처리합니다.", project: projectName))
        ]
    }
}

/// Project panels use the same observable store and conversation/card surfaces as the app.
public enum ProjectSessionScene: String, Sendable, CaseIterable {
    case open, closed, withCards, transferPending, transferSource, transferMain
}

/// Preview of the tab bar's unread counts: main and two project conversations, one still working.
public enum ThreadBadgeScene: Sendable { case unread }

extension SampleKnarrStore {
    public convenience init(threadBadgeScene: ThreadBadgeScene, now: Date = .now) {
        self.init(now: now)
        issues = []; questions = []; issueProjects = [:]
        chat = [
            .init(at: now.addingTimeInterval(-900), kind: .user("이번 주 우선순위를 정리해 주세요.")),
            .init(at: now.addingTimeInterval(-840), kind: .stallari("지난주 결과부터 확인했어요.", project: nil)),
            .init(at: now.addingTimeInterval(-120), kind: .stallari("검증이 끝난 항목과 남은 결정을 정리했어요. 다음 주 계획에 반영할까요?", project: nil))
        ]
        var projectThreads: [ConversationThread] = []
        for (index, project) in projects.prefix(2).enumerated() {
            let thread = ConversationThread(name: project.name, projectID: project.id)
            projectThreads.append(thread)
            let answers = (0...index).map { step in
                ChatItem(at: now.addingTimeInterval(-300 + Double(step) * 60),
                         kind: .stallari("\(project.name) 진행 상황 \(step + 1)건을 정리했어요.", project: project.name))
            }
            threadChats[thread.id] = [.init(at: now.addingTimeInterval(-400), kind: .user("\(project.name) 다음 작업을 알려 주세요."))] + answers
            // Every sample answer is unread: the read boundary sits before the conversation existed.
            unreadLedgers[thread.id] = .init()
        }
        threads.append(contentsOf: projectThreads)
        unreadLedgers[ConversationThread.defaultID] = .init(baselining: Array(chat.compactMap(UnreadAnswers.answer).prefix(1)))
        // The preview shows the tab bar while a project tab is open: the main tab and the other
        // project keep their counts, and the open one clears as its answers become visible.
        if let first = projectThreads.first { selectThread(first.id) }
    }
}

/// Synthetic milestone states for design review: recorded target-date edits, a blocked stage,
/// and a project whose stages are all reached. Built with the same save rule as the app.
public enum MilestoneScene: String, Sendable, CaseIterable {
    case history, blocked, allReached
}

extension SampleKnarrStore {
    public convenience init(milestoneScene scene: MilestoneScene, now: Date = .now) {
        self.init(now: now)
        guard let index = milestones.firstIndex(where: { $0.id == "gamza-dialogue" }) else { return }
        let dialogue = milestones[index]
        switch scene {
        case .history:
            // Two earlier target dates, each saved through the storage rule that appends history.
            let original = dialogue.targetDate ?? now
            let first = original.addingTimeInterval(-21 * 86400)
            let second = original.addingTimeInterval(-10 * 86400)
            var step = dialogue
            step.targetDate = first
            if let saved = try? step.preparedForSave(over: dialogue, at: now.addingTimeInterval(-20 * 86400)) {
                milestones[index] = saved
            }
            step = milestones[index]
            step.targetDate = second
            if let saved = try? step.preparedForSave(over: milestones[index], at: now.addingTimeInterval(-9 * 86400)) {
                milestones[index] = saved
            }
            step = milestones[index]
            step.targetDate = original
            if let saved = try? step.preparedForSave(over: milestones[index], at: now.addingTimeInterval(-2 * 86400)) {
                milestones[index] = saved
            }
        case .blocked:
            var value = dialogue
            value.status = .blocked
            value.blockedReason = "저장 데이터 형식 확인을 기다리고 있어요"
            milestones[index] = value
        case .allReached:
            for stage in milestones.indices where milestones[stage].projectID == "gamza" {
                var value = milestones[stage]
                value.status = .reached
                value.reachedAt = value.reachedAt ?? now.addingTimeInterval(-86400)
                value.criteria = value.criteria.map {
                    .init(text: $0.text.isEmpty ? "단계 확인" : $0.text, state: .met,
                          evidence: $0.evidence.isEmpty ? "화면 확인" : $0.evidence)
                }
                milestones[stage] = value
            }
        }
    }
}

extension SampleKnarrStore {
    public convenience init(projectSessionScene scene: ProjectSessionScene, now: Date = .now) {
        self.init(issueSessionScene: .main, now: now)
        if scene != .withCards { issues = []; questions = []; issueProjects = [:] }
        if scene != .closed {
            selectProjectConversation("gamza")
            chat = [
                .init(at: now.addingTimeInterval(-300), kind: .user("이 프로젝트의 다음 작업을 같이 정리해 주세요.")),
                .init(at: now.addingTimeInterval(-240), kind: .stallari(
                    "프로젝트 지침과 진행 중인 이슈를 확인하고 있어요. 별도의 실행이 필요한 목표는 이슈 대화로 넘기고, 여기서는 프로젝트의 우선순위와 다음 결정을 이어갈 수 있어요.",
                    project: "Gamza Saga"))
            ]
            if scene == .withCards {
                threadWork[selectedThreadID] = [.init(id: "ProjectResearch", name: "ProjectResearch",
                    currentCommand: "read", startedAt: now.addingTimeInterval(-180), lastActivityAt: now)]
            }
            if [.transferPending, .transferSource, .transferMain].contains(scene), let request = chat.first,
               let thread = threads.first(where: { $0.id == selectedThreadID }), case .user(let requestText) = request.kind {
                let transfer = ProjectTransfer(id: "sample-project-transfer", originProjectID: "gamza", originThreadID: thread.id,
                    projectName: "Gamza Saga", requestMessageID: request.id, requestText: requestText,
                    summary: "프로젝트 우선순위와 검증된 진행 상황을 공유합니다. 실제 변경은 소유 프로젝트의 정확한 제안 버전 승인이 필요합니다.",
                    messageIDs: chat.map(\.id), attachments: [], createdAt: now.addingTimeInterval(-120),
                    deliveredAt: scene == .transferMain ? now : nil,
                    lastError: scene == .transferSource ? ProjectTransfer.unsupportedFailureMessage : nil)
                projectTransfers = [transfer]
                if scene == .transferMain { selectThread(ConversationThread.defaultID) }
            }
        }
    }
}
