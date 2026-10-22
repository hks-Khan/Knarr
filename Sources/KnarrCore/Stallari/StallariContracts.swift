import Foundation

public protocol StallariRPC: Sendable {
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON
    func send(_ command: String, fields: [String: OMPJSON]) async throws
    func subscribe() async -> AsyncStream<OMPEvent>
    func shutdown(cancel: Bool) async -> OMPProcessExit
}
extension OMPRPCSession: StallariRPC {}

/// All Hird mutations enter the repository's serialized event sequence through this sink.
public struct HirdUpdate: Sendable, Equatable {
    public let id: String
    public let runID: HirdRun.ID
    public let at: Date
    public let payload: RunEvent.Payload
    public init(id: String, runID: HirdRun.ID, at: Date, payload: RunEvent.Payload) {
        self.id = id; self.runID = runID; self.at = at; self.payload = payload
    }
}
public typealias HirdEventSink = @Sendable (HirdUpdate) async throws -> MutationOutcome
public struct QuestionResolution: Sendable, Equatable {
    public let questionID: String
    public let runID: HirdRun.ID
    public let issueID: Issue.ID
    public let answer: QuestionAnswer?
    public let cancelled: Bool
    /// Replay uses this same key. Hird must reject stale process generations and deduplicate it.
    public var deliveryID: String { "question:\(questionID):\(runID.rawValue)" }
}
public protocol HirdAdapter: Sendable {
    /// May remain suspended for the run's lifetime. dispatch never awaits it.
    func start(_ run: PersistedRun, emit: @escaping HirdEventSink) async throws
    /// Acknowledges delivery to the exact live run. Never respawns an interrupted run.
    func steer(_ text: String, runID: HirdRun.ID) async throws
    func remainingProcessIDs() async -> [Int32]
    func deliver(_ resolution: QuestionResolution) async throws
    /// Returns only after this run's owned process/children have ended.
    func cancel(_ runID: HirdRun.ID) async
    /// Exact-run confirmation, never inferred from another run's process list.
    func terminationConfirmed(_ runID: HirdRun.ID) async -> Bool
    /// The `provider/id` later runs should use. Runs already going keep theirs.
    func modelForNewRuns() async -> String?
    func setModel(_ model: String) async
}
extension HirdAdapter {
    public func modelForNewRuns() async -> String? { nil }
    public func setModel(_ model: String) async {}
    public func remainingProcessIDs() async -> [Int32] { [] }
    public func terminationConfirmed(_ runID: HirdRun.ID) async -> Bool { false }
    public func steer(_ text: String, runID: HirdRun.ID) async throws { throw StallariError.terminalRun }
}
public struct CriterionEvidence: Sendable, Equatable {
    public let criterionIndex: Int
    public let verificationIDs: [String]
    public let explanation: String
    /// false records the criterion as not satisfied; the explanation says why.
    public let met: Bool
    public init(criterionIndex: Int, verificationIDs: [String], explanation: String, met: Bool = true) {
        self.criterionIndex = criterionIndex; self.verificationIDs = verificationIDs; self.explanation = explanation; self.met = met
    }
}
/// Main input would move an answer Stallari is giving inside a message conversation back to main.
public enum StallariSteerError: Error, Sendable, Equatable {
    case messageConversationAnswer
}

public enum StallariError: Error, Sendable, Equatable {
    case invalidArguments, wrongProject, missingIssue, missingRun, conflictingID, terminalRun
    case missingEvidence, unsafeToolExposure, closed
    /// A judgement the model can correct; the text goes back to it as the tool error.
    case rejectedEvidence(String)
}
