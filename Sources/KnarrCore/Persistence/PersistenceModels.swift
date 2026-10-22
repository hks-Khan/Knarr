import Foundation

public struct StoredProject: Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var absolutePath: String
    /// Set when the person takes the project off the list. Folder and history stay.
    public var archivedAt: Date?
    public var settings: ProjectSettings
    public init(id: String, name: String, absolutePath: String, archivedAt: Date? = nil, settings: ProjectSettings = .init()) {
        self.id = id; self.name = name; self.absolutePath = absolutePath
        self.archivedAt = archivedAt; self.settings = settings
    }

    // Rows saved before archiving and settings existed have neither key.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        absolutePath = try c.decode(String.self, forKey: .absolutePath)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        settings = try c.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? .init()
    }
}

/// HirdRun.ID is the durable run ID. The OMP session ID is a separate identifier.
public enum DurableRunState: String, Codable, Sendable, Hashable {
    case working, waitingOnHuman, succeeded, failed, cancelled, interrupted
    public var isTerminal: Bool { self != .working && self != .waitingOnHuman }
}

public struct RunWorkspace: Codable, Sendable, Hashable {
    public let worktreePath: String
    public let branch: String?
    public let ompSessionPath: String?
    public init(worktreePath: String, branch: String?, ompSessionPath: String?) {
        self.worktreePath = worktreePath; self.branch = branch; self.ompSessionPath = ompSessionPath
    }
}

public enum HirdRunMode: String, Codable, Sendable { case inspect, change }

public struct PersistedRun: Codable, Sendable, Hashable {
    public var hird: HirdRun
    public let issueID: Issue.ID
    public let projectID: String
    public var ompSessionID: String?
    public var mode: HirdRunMode?
    public var requestedModel: String?
    public internal(set) var observedModel: String?
    public var requestedThinking: String?
    public internal(set) var observedThinking: String?
    /// Cancellation admission is not proof that owned processes have ended.
    public internal(set) var cancellationRequestedAt: Date?
    public internal(set) var processEndedAt: Date?
    /// An executor-issued identity, never an authentication token or a PID alone.
    public let ownershipToken: String
    public let startedAt: Date
    public let previousRunID: HirdRun.ID?
    public internal(set) var state: DurableRunState
    public internal(set) var endedAt: Date?
    public internal(set) var stopReason: String?
    public internal(set) var lastSequence: Int64
    public internal(set) var result: RunResult?
    public internal(set) var workspace: RunWorkspace?
    /// Run-scoped judgement survives the Issue's criteria reset on the next launch.
    /// nil in legacy payloads means no judgement was preserved.
    public internal(set) var acceptanceEvidence: [Criterion]?
    public internal(set) var resultHistory: [RunResult] = []
    /// Durable count lets ordinary state/readback avoid loading every immutable snapshot.
    public internal(set) var savedResultCount: Int?
    /// The approved plan is copied once; replans live only in the append-only report history.
    public internal(set) var stagePlan: [IssueStage]?
    public internal(set) var stageReports: [StageReport]?
    public internal(set) var lastFileChangeAt: Date?
    /// Bounded Stallari review state for this run; nil until a review actually reads evidence.
    public internal(set) var review: StallariReview?
    public var id: HirdRun.ID { hird.id }
    public init(hird: HirdRun, issueID: Issue.ID, projectID: String, ompSessionID: String?,
                ownershipToken: String, startedAt: Date, previousRunID: HirdRun.ID? = nil, workspace: RunWorkspace? = nil, mode: HirdRunMode? = nil, requestedModel: String? = nil, requestedThinking: String? = nil, stagePlan: [IssueStage]? = nil) {
        self.hird = hird; self.issueID = issueID; self.projectID = projectID
        self.ompSessionID = ompSessionID; self.ownershipToken = ownershipToken
        self.startedAt = startedAt; self.previousRunID = previousRunID; self.workspace = workspace
        self.mode = mode; self.requestedModel = requestedModel; self.observedModel = nil
        self.requestedThinking = requestedThinking
        self.stagePlan = stagePlan
        state = .working; endedAt = nil; stopReason = nil; lastSequence = 0; result = nil
    }
}

public struct VerificationRecord: Codable, Sendable, Hashable {
    public let id: String
    public let command: [String]
    public let workingDirectory: String
    public let startedAt: Date
    public let finishedAt: Date
    /// nil means no successful execution result was obtained, not a passing test.
    public let exitCode: Int32?
    public enum Kind: String, Codable, Sendable { case command, inspection }
    public let kind: Kind?
    public var isInspection: Bool { kind == .inspection }
    public let logPath: String
    public let attachmentPaths: [String]?
    public let summary: String
    public init(id: String, command: [String], workingDirectory: String, startedAt: Date,
                finishedAt: Date, exitCode: Int32?, logPath: String, summary: String, kind: Kind? = nil,
                attachmentPaths: [String]? = nil) {
        self.id = id; self.command = command; self.workingDirectory = workingDirectory
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.exitCode = exitCode
        self.logPath = logPath; self.summary = summary; self.kind = kind
        self.attachmentPaths = attachmentPaths
    }
}

extension VerificationRecord {
    /// One check per command. With `;`, `|`, `||`, a newline or a background `&`, the exit code
    /// only speaks for part of the command, so the record cannot prove a criterion on its own.
    /// `&&` is allowed: a zero exit means every step succeeded.
    public var isSingleCheck: Bool { !isInspection && ShellEvidence.isSingleCheck(command) }

    /// The last lines of the saved log, so a judgement can read what actually happened.
    public func logTail(maxLines: Int = 40, maxCharacters: Int = 4000) -> String? {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return tail.count > maxCharacters ? String(tail.suffix(maxCharacters)) : tail
    }
}

public struct HirdArtifactManifestMetadata: Codable, Sendable, Hashable {
    public let sha256: String
    public let artifactCount: Int
    public let totalBytes: Int64
    public init(sha256: String, artifactCount: Int, totalBytes: Int64) {
        self.sha256 = sha256; self.artifactCount = artifactCount; self.totalBytes = totalBytes
    }
}

public enum HirdArtifactRole: String, Codable, Sendable, Hashable { case patch, evidence, verification, report, sessionArtifact }
public enum HirdArtifactCaptureKind: String, Codable, Sendable, Hashable { case observedPrefix }

public struct HirdArtifact: Codable, Sendable, Hashable {
    public let role: HirdArtifactRole
    public let sourcePath: String
    public let blobPath: String
    public let sha256: String
    public let byteCount: Int64
    public let captureKind: HirdArtifactCaptureKind?
    init(role: HirdArtifactRole, sourcePath: String, blobPath: String, sha256: String, byteCount: Int64,
         captureKind: HirdArtifactCaptureKind? = nil) {
        self.role = role; self.sourcePath = sourcePath; self.blobPath = blobPath
        self.sha256 = sha256; self.byteCount = byteCount; self.captureKind = captureKind
    }
}

public struct HirdArtifactManifest: Codable, Sendable, Hashable {
    public let artifacts: [HirdArtifact]
    public let policy: HirdCapturePolicy
}

public struct RunResult: Codable, Sendable, Hashable {
    public let worktreePath: String
    public let branch: String?
    public let commit: String?
    public let diffPath: String?
    public let summary: String
    public let reportPath: String?
    public let artifactManifestPath: String?
    public let artifactManifestMetadata: HirdArtifactManifestMetadata?
    public let verifications: [VerificationRecord]
    public init(worktreePath: String, branch: String?, commit: String?, diffPath: String?,
                summary: String, verifications: [VerificationRecord], reportPath: String? = nil,
                artifactManifestPath: String? = nil, artifactManifestMetadata: HirdArtifactManifestMetadata? = nil) {
        self.worktreePath = worktreePath; self.branch = branch; self.commit = commit
        self.diffPath = diffPath; self.summary = summary; self.verifications = verifications; self.reportPath = reportPath
        self.artifactManifestPath = artifactManifestPath; self.artifactManifestMetadata = artifactManifestMetadata
    }
}

public struct QuestionAnswer: Codable, Sendable, Hashable {
    public let selectedOptions: [String]
    public let text: String?
    public init(selectedOptions: [String], text: String?) { self.selectedOptions = selectedOptions; self.text = text }
}
public struct PersistedQuestion: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable { case stallari, hird }
    public internal(set) var source: Source?
    public enum State: String, Codable, Sendable { case pending, answered, cancelled }
    public let id: String
    public let runID: HirdRun.ID
    public let issueID: Issue.ID
    public let prompt: String
    public let options: [String]
    public let createdAt: Date
    public internal(set) var state: State = .pending
    public internal(set) var answer: QuestionAnswer?
    public internal(set) var resolvedAt: Date?
    /// nil also decodes from v1 payloads written before Stallari delivery support.
    public internal(set) var deliveredAt: Date?
    public init(id: String, runID: HirdRun.ID, issueID: Issue.ID, prompt: String, options: [String], createdAt: Date, source: Source? = nil) {
        self.source = source
        self.id = id; self.runID = runID; self.issueID = issueID
        self.prompt = prompt; self.options = options; self.createdAt = createdAt
    }
}
public struct CompletionNotification: Codable, Sendable, Hashable {
    public let id: String
    public let runID: HirdRun.ID
    public let createdAt: Date
    public internal(set) var deliveredAt: Date?
}

public struct RunEvent: Codable, Sendable, Hashable {
    public enum Payload: Codable, Sendable, Hashable {
        case activity(ActivityEvent, currentCommand: String?, steps: [HirdStep]?)
        /// One state transition of the worker. Only the state is new; the activity ledger row is
        /// derived from it, so repeating the same state writes nothing.
        case activityState(HirdActivity, currentCommand: String?)
        case bindSession(String)
        case bindModel(String)
        case bindThinking(String)
        case recordResources(HirdRuntimeResources)
        case recordLSP(HirdLSPRecord)
        case recordWorkspace(RunWorkspace)
        case saveResult(RunResult)
        case stage(StageReport)
        case fileChanged(path: String)
        case ask(PersistedQuestion)
        case complete(RunResult, notificationID: String)
        case fail(String)
    }
    public let id: String
    public let runID: HirdRun.ID
    /// Strictly increasing, assigned by the Knarr RPC adapter, not inferred from timestamps.
    public let sequence: Int64
    public let at: Date
    public let payload: Payload
    public init(id: String, runID: HirdRun.ID, sequence: Int64, at: Date, payload: Payload) {
        self.id = id; self.runID = runID; self.sequence = sequence; self.at = at; self.payload = payload
    }
}
public enum MutationOutcome: String, Codable, Sendable, Hashable {
    case applied, duplicate, ignoredStale, ignoredTerminal
}
public enum OwnedRunLiveness: Sendable {
    /// The executor has verified the exact owned process/session, including PID reuse protection.
    case alive(ownershipToken: String, ompSessionID: String?)
    case dead
    case unverified
}
public struct ChatLink: Codable, Sendable, Hashable {
    public let chatID: UUID
    public let projectID: String
    public let issueID: Issue.ID?
    public let runID: HirdRun.ID?
    public var threadID: String? = nil
    public var conversationThreadID: String { threadID ?? ConversationThread.defaultID }
}
public struct PersistenceSnapshot: Sendable, Hashable {
    public let projects: [StoredProject]
    public let threads: [ConversationThread]
    public let issues: [Issue]
    public let issueProjects: [Issue.ID: String]
    public let chat: [ChatItem]
    public let chatLinks: [ChatLink]
    public let runs: [PersistedRun]
    public let questions: [PersistedQuestion]
    public let notifications: [CompletionNotification]
    public var projectTransfers: [ProjectTransfer] = []
    /// Planned project stages; empty in v1-v5 stores.
    public var milestones: [Milestone] = []
    /// Project-level weekly plans; empty in stores before v7.
    public var weekPlans: [ProjectWeekPlan] = []
    /// Coherent event-driven wake set; idle issue creation does not add a delivery.
    public var pendingDeliveryThreadIDs: Set<String> = []
    public var preparationItems: [PreparationItem] = []
}

/// One delivered snapshot with the write revision it was built at. A value built before a later
/// write can still be delivered after a newer read, so consumers compare revisions.
public struct PersistenceUpdate: Sendable {
    public let revision: Int
    public let snapshot: PersistenceSnapshot
    let conversationProjection: ConversationProjection
    public init(revision: Int, snapshot: PersistenceSnapshot) {
        self.revision = revision; self.snapshot = snapshot
        conversationProjection = ConversationProjection(snapshot)
    }
}

/// Includes the original path and an explicit recovery route; no fallback database is created.
public struct PersistenceError: Error, LocalizedError, Sendable {
    public let databasePath: String
    public let message: String
    public let sqliteCode: Int32?
    public init(databasePath: String, message: String, sqliteCode: Int32? = nil) {
        self.databasePath = databasePath; self.message = message; self.sqliteCode = sqliteCode
    }
    public var recoverySuggestion: String {
        "원본과 journal/WAL 파일을 보존한 채 별도 위치에 복사해 확인하세요. 백업 복원 또는 새 저장소 선택은 명시적으로 진행하고 원본을 덮어쓰지 마세요."
    }
    public var errorDescription: String? { "Knarr 저장소 오류 (\(databasePath)): \(message)" }
}
