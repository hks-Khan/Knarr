import Foundation
import CryptoKit

public enum DesktopNotificationAuthorization: Sendable { case notDetermined, denied, authorized }
public enum DesktopNotificationStatus: String, Sendable {
    case unavailable, notDetermined, ready, denied, failed
    public var message: String { DesktopNotificationPolicy.current.statuses[rawValue]! }
}

struct DesktopNotificationPolicy: Decodable, Sendable {
    let titles: [String: String]
    let body: String
    let statuses: [String: String]
    let shutdownCancellationReason: String
    // Packaged/runtime resource, like project-session.json. Never model/log/user content.
    static let current = try! JSONDecoder().decode(Self.self, from: HirdPolicyFiles.resource("desktop-notifications.json"))
}

public struct DesktopNotificationEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case approval, question, failed, cancelled, interrupted, hirdCompleted, issueCompleted, issueFailed
    }
    public struct Target: Codable, Sendable, Equatable {
        public let projectID: String
        public let issueID: Issue.ID
        public let threadID: String
        public let originThreadID: String?
        public let proposalVersion: Int?
    }
    public let id: String
    public let kind: Kind
    public let target: Target
    public var title: String { DesktopNotificationPolicy.current.titles[kind.rawValue]! }
    public var body: String { DesktopNotificationPolicy.current.body }

    /// Only durable state, never chat turns, UI cards, command output or question text.
    /// The same completion cannot appear both as an issue projection and a run notice.
    public static func events(in snapshot: PersistenceSnapshot) -> [Self] {
        var events: [Self] = []
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        let threads = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0) })
        let runs = Dictionary(uniqueKeysWithValues: snapshot.runs.map { ($0.id, $0) })
        let runsByIssue = Dictionary(grouping: snapshot.runs, by: \.issueID)
        let questionsByIssue = Dictionary(grouping: snapshot.questions, by: \.issueID)
        let noticesByRun = Dictionary(uniqueKeysWithValues: snapshot.notifications.map { ($0.runID, $0) })
        for issue in snapshot.issues where issue.archivedAt == nil {
            guard let projectID = snapshot.issueProjects[issue.id], let project = projects[projectID], project.archivedAt == nil,
                  let thread = threads[issue.conversationThreadID],
                  thread.issueID == issue.id || (thread.issueID == nil && thread.projectID == nil),
                  thread.projectID == nil || thread.projectID == projectID else { continue }
            if let originID = thread.originThreadID {
                guard let origin = threads[originID], origin.issueID == nil,
                      origin.projectID == nil || origin.projectID == projectID else { continue }
            }
            func add(_ kind: Kind, _ identity: String, version: Int? = nil) {
                let data = try! JSONEncoder().encode([kind.rawValue, projectID, issue.id.rawValue, identity])
                let id = "knarr-desktop-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                events.append(Self(id: id, kind: kind, target: .init(projectID: projectID, issueID: issue.id,
                    threadID: thread.id, originThreadID: thread.originThreadID, proposalVersion: version)))
            }
            if issue.state == .awaitingApproval, issue.proposalReviewNote == nil, let proposal = issue.proposal {
                add(.approval, String(proposal.version), version: proposal.version)
            }
            for question in questionsByIssue[issue.id] ?? [] where question.state == .pending {
                guard let run = runs[question.runID], run.issueID == issue.id, run.projectID == projectID,
                      !run.state.isTerminal else { continue }
                add(.question, question.id)
            }
            let ownRuns = runsByIssue[issue.id] ?? []
            for run in ownRuns where run.projectID == projectID {
                switch run.state {
                case .failed: add(.failed, run.id.rawValue)
                case .cancelled:
                    add(run.stopReason == DesktopNotificationPolicy.current.shutdownCancellationReason ? .interrupted : .cancelled, run.id.rawValue)
                case .interrupted: add(.interrupted, run.id.rawValue)
                case .succeeded:
                    if let notice = noticesByRun[run.id] { add(.hirdCompleted, notice.id) }
                default: break
                }
            }
            if issue.state == .done, let completed = issue.completedAt {
                // The last run scopes a new judgement after a follow-up, not a mutable label.
                let identity = (ownRuns.last?.id.rawValue ?? "") + ":" + String(completed.timeIntervalSince1970)
                add(.issueCompleted, identity)
            }
            if issue.state == .failed, let latest = ownRuns.last, latest.state == .succeeded,
               !issue.acceptance.isEmpty, issue.acceptance.allSatisfy({ $0.state != .pending }),
               issue.acceptance.contains(where: { $0.state == .unmet }) {
                add(.issueFailed, latest.id.rawValue)
            }
        }
        return events
    }
}

@MainActor public protocol DesktopNotificationClient: AnyObject {
    func authorizationStatus() async -> DesktopNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    /// OS-accepted pending/delivered IDs reconcile a crash between add and the receipt write.
    func acceptedIdentifiers() async -> Set<String>
    func send(_ event: DesktopNotificationEvent) async throws
}
