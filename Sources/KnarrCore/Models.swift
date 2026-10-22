import Foundation

public enum IssueState: String, Sendable, Hashable, Codable {
    case awaitingApproval
    case rejected
    case running
    case needsInput
    case failed
    case done
}

/// Presentation only; the persisted execution state and judgement remain unchanged.
/// Each state is what the saved records prove, never a request for the person to review or merge.
public enum IssueStatus: Sendable, Hashable, CaseIterable {
    /// A saved proposal waits for approval; a running issue without one needs a new proposal.
    case awaitingApproval
    /// A Hird is working right now.
    case inProgress
    /// A question from Stallari or a Hird waits for an answer.
    case needsAnswer
    /// The worker finished; Stallari has not recorded its judgement yet.
    case judging
    /// Stallari met every completion criterion; the result is not in the original project yet.
    case awaitingIntegration
    /// Stallari judged at least one criterion unmet.
    case unmet
    /// The worker stopped before Stallari judged the criteria.
    case failed
    case completed
    case cancelled

    /// Statuses an open issue can show. Terminal statuses live in history.
    public static let openCases: [IssueStatus] = [
        .awaitingApproval, .needsAnswer, .inProgress, .judging, .awaitingIntegration, .unmet, .failed
    ]

    public var title: String {
        switch self {
        case .awaitingApproval: "승인 대기"
        case .inProgress: "진행 중"
        case .needsAnswer: "답변 필요"
        case .judging: "판정 중"
        case .awaitingIntegration: "통합 대기"
        case .unmet: "미충족"
        case .failed: "실행 실패"
        case .completed: "완료"
        case .cancelled: "취소"
        }
    }

    /// Stable wire key shared with the phone; the display title may change, this may not.
    public var key: String {
        switch self {
        case .awaitingApproval: "awaitingApproval"
        case .inProgress: "inProgress"
        case .needsAnswer: "needsAnswer"
        case .judging: "judging"
        case .awaitingIntegration: "awaitingIntegration"
        case .unmet: "unmet"
        case .failed: "failed"
        case .completed: "completed"
        case .cancelled: "cancelled"
        }
    }
}

public struct Issue: Identifiable, Sendable, Hashable, Codable {
    public struct ID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    public var id: ID
    /// nil in legacy payloads means the migrated 기본 conversation.
    public var threadID: String?
    /// The project milestone this issue was planned for. nil in legacy payloads and for
    /// issues created without a milestone; an existing issue is never moved automatically.
    public var milestoneID: Milestone.ID?
    /// Immutable canonical admin creation request hash; nil for legacy and non-admin issues.
    public var creationRequestFingerprint: String?
    public var conversationThreadID: String { threadID ?? ConversationThread.defaultID }
    public var title: String
    public var projectName: String
    public var state: IssueState
    /// Historical acknowledgement, not a presentation status or a source of user work.
    public var confirmed: Bool
    /// One line under the title in the panel, e.g. "Hird 2명 · 19분째".
    public var headline: String
    /// The drawer's first block: what is happening now, what is needed, why it stopped, or the result.
    public var detail: String
    public var acceptance: [Criterion]
    public var hirds: [HirdRun]
    public var events: [ActivityEvent]
    public var startedAt: Date
    /// Durable Stallari judgement time, independent of Hird's earlier completion.
    public var completedAt: Date?
    /// Git reconciliation or explicit application into the original project.
    public var application: ResultApplication?
    /// Explicit user closure preserves the original judgement and evidence in history.
    public var archivedAt: Date?
    public var archiveReason: String?
    public var archiveNote: String?
    public var supersededBy: ID?
    /// Applied as part of this other issue; nil in older payloads and standalone closures.
    public var integratedInto: ID?
    /// The exact versioned instruction the user reviews before any Hird launch.
    public var proposal: IssueProposal?
    /// Immutable proposal versions, including drafts that were never approved.
    public var proposalHistory: [IssueProposal]?
    public var approval: IssueApproval?
    public var approvalHistory: [IssueApproval]?
    public var proposalReviewNote: String?
    public var userAppConfirmation: UserAppConfirmation?
    /// Derived from the latest durable run, not reconstructed from Markdown in the UI.
    public var latestResult: RunResult?
    public var executionModel: String?
    public var executionThinking: String?

    /// Open work of any non-terminal state stays on the lists until history closes it.
    public var needsAttention: Bool {
        guard archivedAt == nil else { return false }
        switch displayStatus {
        case .completed, .cancelled: return false
        default: return true
        }
    }

    public init(id: ID, title: String, projectName: String, state: IssueState, confirmed: Bool = false,
                headline: String, detail: String, acceptance: [Criterion], hirds: [HirdRun],
                events: [ActivityEvent], startedAt: Date, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.state = state
        self.confirmed = confirmed
        self.headline = headline
        self.detail = detail
        self.acceptance = acceptance
        self.hirds = hirds
        self.events = events
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var metCriteria: Int { acceptance.filter { $0.state == .met }.count }
}

public enum IssueCloseReason: String, Sendable, Hashable, Codable, CaseIterable {
    case applied = "반영됨"
    case superseded = "대체됨"
    case cancelled = "취소"

    /// The raw value is durable closure metadata and must not be renamed.
    public var title: String {
        switch self {
        case .applied: "완료로 닫기"
        case .superseded: "대체하여 취소"
        case .cancelled: "취소"
        }
    }
}

public struct UserAppConfirmation: Sendable, Hashable, Codable {
    public var at: Date
    public var note: String
    public var runID: HirdRun.ID
}

extension Issue {
    public var hasActiveHird: Bool {
        hirds.contains { if case .working = $0.status { true } else if case .waitingOnHuman = $0.status { true } else { false } }
    }
    public var needsNewProposal: Bool {
        state == .running && !hasActiveHird && proposal == nil && latestResult == nil && completedAt == nil &&
            !hirds.contains { if case .failed = $0.status { true } else if case .done = $0.status { true } else { false } }
    }
    public var isApplied: Bool { if case .applied = application { true } else { false } }

    public var displayStatus: IssueStatus { presentationStatus() }

    /// Every open screen maps the same saved records to the same state. Judgement is Stallari's;
    /// integration is Stallari's; the person only answers questions and approves a saved proposal.
    public func presentationStatus(hasPendingQuestion: Bool = false) -> IssueStatus {
        if isApplied || (archivedAt != nil && archiveReason == IssueCloseReason.applied.rawValue) { return .completed }
        if archivedAt != nil { return .cancelled }
        switch state {
        case .rejected: return .cancelled
        case .awaitingApproval: return .awaitingApproval
        case .needsInput: return .needsAnswer
        case .failed:
            // Stallari's judgement records why each unmet criterion failed; a stopped run does not.
            return acceptance.contains { $0.state == .unmet } ? .unmet : .failed
        case .done:
            return .awaitingIntegration
        case .running:
            if hasPendingQuestion || hirds.contains(where: { if case .waitingOnHuman = $0.status { true } else { false } }) {
                return .needsAnswer
            }
            if hasActiveHird { return .inProgress }
            if hirds.contains(where: { if case .failed = $0.status { true } else { false } }) { return .failed }
            if latestResult != nil || completedAt != nil || hirds.contains(where: { if case .done = $0.status { true } else { false } }) {
                return .judging
            }
            return needsNewProposal ? .awaitingApproval : .inProgress
        }
    }

    public func needsAnswer(hasPendingQuestion: Bool = false) -> Bool {
        presentationStatus(hasPendingQuestion: hasPendingQuestion) == .needsAnswer
    }

    /// Explicit visual-check evidence enables the existing attestation action; it stays an unmet judgement.
    public var needsAppConfirmation: Bool {
        let remaining = acceptance.filter { $0.state != .met }
        return state == .failed && !remaining.isEmpty && remaining.allSatisfy {
            $0.state == .unmet && $0.evidence.contains("실제 앱 확인 필요")
        }
    }

    /// The exact count the judged result records, e.g. "미충족 2개".
    public var unmetCount: Int { acceptance.filter { $0.state == .unmet }.count }

    public var statusLine: String {
        displayStatus == .unmet && unmetCount > 0 ? "미충족 \(unmetCount)개" : displayStatus.title
    }

    /// What the saved records say is happening. It never asks the person to review or merge.
    public func userActionLine(hasPendingQuestion: Bool = false) -> String {
        switch presentationStatus(hasPendingQuestion: hasPendingQuestion) {
        case .completed, .cancelled: return "없음"
        case .awaitingApproval:
            if needsNewProposal { return "실행할 제안 없음" }
            if proposalReviewNote != nil { return "수정 요청 전달 · 새 제안 대기" }
            return approval?.runID == nil ? "저장된 제안 승인 대기" : "승인된 제안 · 실행 준비"
        case .needsAnswer: return "Stallari 또는 Hird의 질문에 답변 대기"
        case .inProgress: return "Hird 실행 중"
        case .judging: return "실행 종료 · Stallari 판정 대기"
        case .awaitingIntegration: return "완료 조건 충족 · 원본 프로젝트 미반영"
        case .unmet: return "Stallari가 완료 조건 미충족을 기록함"
        case .failed: return "판정 전에 실행이 멈춤"
        }
    }
}

public struct IssueStage: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var evidence: String
    /// One-based index into the issue's actual completion criteria.
    public var criterion: Int?

    public init(id: String, title: String, evidence: String, criterion: Int? = nil) {
        self.id = id; self.title = title; self.evidence = evidence; self.criterion = criterion
    }

    public static func plan(titles: [(title: String, evidence: String, criterion: Int?)]) -> [IssueStage] {
        titles.enumerated().map { index, value in
            .init(id: "stage-\(index + 1)", title: value.title, evidence: value.evidence, criterion: value.criterion)
        }
    }
}

public struct StageReport: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable { case started, completed, replanned }
    public var at: Date
    public var action: Action
    public var stageID: String
    public var note: String?
    public var verificationIDs: [String]
    public var plan: [IssueStage]?
    public var reason: String?
    /// Calculated by persistence at receipt, never trusted from Hird or re-evaluated later.
    public internal(set) var verified: Bool?

    public init(at: Date, action: Action, stageID: String, note: String? = nil,
                verificationIDs: [String] = [], plan: [IssueStage]? = nil,
                reason: String? = nil, verified: Bool? = nil) {
        self.at = at; self.action = action; self.stageID = stageID; self.note = note
        self.verificationIDs = verificationIDs; self.plan = plan; self.reason = reason; self.verified = verified
    }
}

public struct IssueProposal: Sendable, Hashable, Codable {
    public var version: Int
    public var instruction: String
    public var model: String
    public var mode: HirdRunMode
    public var thinking: String?
    public var previousRunID: HirdRun.ID?
    public var stages: [IssueStage]?
    public var stagePlan: [IssueStage] { stages ?? [] }

    public init(version: Int = 1, instruction: String, model: String, mode: HirdRunMode = .change,
                previousRunID: HirdRun.ID? = nil, thinking: String? = nil, stages: [IssueStage]? = nil) {
        self.version = version
        self.instruction = instruction
        self.model = model
        self.mode = mode
        self.thinking = thinking
        self.previousRunID = previousRunID
        self.stages = stages
    }
}

public struct IssueApproval: Sendable, Hashable, Codable {
    public var version: Int
    public var approvedAt: Date
    public var runID: HirdRun.ID?
    /// nil in older history; phone approvals explicitly record "phone".
    public var source: String?

    public init(version: Int, approvedAt: Date, runID: HirdRun.ID? = nil, source: String? = nil) {
        self.version = version
        self.approvedAt = approvedAt
        self.runID = runID
        self.source = source
    }
}

public enum ResultApplication: Sendable, Hashable, Codable {
    case applied(branch: String, commit: String)
    /// The project keeps results on their own branch; the person merges.
    case kept(branch: String, commit: String)
    case blocked(String)
}

public struct Criterion: Sendable, Hashable, Codable {
    public enum State: Sendable, Hashable, Codable { case pending, met, unmet }
    public var text: String
    public var state: State
    public var evidence: String

    public init(text: String, state: State, evidence: String) {
        self.text = text
        self.state = state
        self.evidence = evidence
    }
}

public struct HirdRun: Identifiable, Sendable, Hashable, Codable {
    public struct ID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
    }

    public enum Status: Sendable, Hashable, Codable {
        case working
        case waitingOnHuman(since: Date)
        case failed(at: Date)
        case done(at: Date)
    }

    public var id: ID
    public var name: String
    public var role: String
    public var status: Status
    /// The Hird's own plan (OMP `todoPhases`), in order.
    public var steps: [HirdStep]
    public var currentCommand: String?
    public var lastActivityAt: Date
    /// Projected from the durable run, nil in legacy payloads.
    public var startedAt: Date?
    /// Captured once before the prompt; nil means an older or not-yet-started run.
    public var runtimeResources: HirdRuntimeResources?
    public var lspRecords: [HirdLSPRecord]?
    /// When the Hird last started a file-changing tool call (`edit`, `write`, `ast_edit`). Saved with the run so
    /// progress can tell implementation from test writing without re-reading the work copy.
    public var lastEditAt: Date?
    /// Derived from the run's saved checks each time the screens are rebuilt; never saved with the run.
    public var stageProgress: HirdProgress?
    /// What the Hird is doing now. nil in runs saved before activity transitions were recorded.
    public var currentActivity: HirdActivity?
    /// Distinct recent states, oldest first; the current one is not repeated. nil in legacy payloads.
    public var recentActivities: [HirdActivity]?

    private enum CodingKeys: String, CodingKey {
        case id, name, role, status, steps, currentCommand, lastActivityAt, runtimeResources, lspRecords, lastEditAt, startedAt,
             currentActivity, recentActivities
    }

    public init(id: ID, name: String, role: String, status: Status, steps: [HirdStep],
                currentCommand: String?, lastActivityAt: Date, startedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.status = status
        self.steps = steps
        self.currentCommand = currentCommand
        self.lastActivityAt = lastActivityAt
        self.startedAt = startedAt
    }
}

public struct HirdStep: Sendable, Hashable, Codable {
    public enum State: Sendable, Hashable, Codable {
        case done
        case active
        case pending
        /// Waiting for another Hird.
        case waiting
        /// Needs a person.
        case blocked
        case failed
    }

    public var title: String
    public var state: State
    /// OMP source data is retained even when a display enum has no exact equivalent.
    public var sourceStatus: String?
    public var blocker: String?
    public var sourceKey: String?

    public init(title: String, state: State, sourceStatus: String? = nil, blocker: String? = nil, sourceKey: String? = nil) {
        self.title = title; self.state = state
        self.sourceStatus = sourceStatus; self.blocker = blocker; self.sourceKey = sourceKey
    }
}

public struct ActivityEvent: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var at: Date
    public var actor: String
    public var text: String
    public var detail: String?

    public init(id: UUID = UUID(), at: Date, actor: String, text: String, detail: String? = nil) {
        self.id = id
        self.at = at
        self.actor = actor
        self.text = text
        self.detail = detail
    }
}

public struct StepProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int
    public var current: HirdStep?
}

extension HirdRun {
    /// Steps as they should look now: a run that stopped or finished has nothing in progress.
    public var displaySteps: [HirdStep] {
        switch status {
        case .working, .waitingOnHuman: return steps
        case .failed, .done:
            return steps.map { var s = $0; if s.state == .active { s.state = .pending }; return s }
        }
    }

    public var progress: StepProgress {
        let shown = displaySteps
        let current = shown.first { $0.state == .active }
            ?? shown.first { $0.state == .blocked || $0.state == .failed }
        return StepProgress(done: shown.filter { $0.state == .done }.count, total: shown.count, current: current)
    }
}

extension HirdRun {
    /// One display line for `role`, which may hold Stallari's whole instruction to the Hird.
    public var roleSummary: String {
        let line = role.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 64 ? String(line.prefix(64)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}
