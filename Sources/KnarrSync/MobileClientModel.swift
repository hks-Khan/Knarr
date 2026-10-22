import Foundation
import Observation

/// The phone's view of Knarr, built from records fetched out of CloudKit.
@MainActor @Observable
public final class MobileClientModel {
    public struct Section: Identifiable, Sendable, Hashable {
        public var group: MobileIssue.Group
        public var issues: [MobileIssue]
        public var id: MobileIssue.Group { group }
        public init(group: MobileIssue.Group, issues: [MobileIssue]) { self.group = group; self.issues = issues }
    }

    public private(set) var issues: [String: MobileIssue] = [:]
    public private(set) var questions: [String: MobileQuestion] = [:]
    public private(set) var messageByID: [String: MobileMessage] = [:]
    public private(set) var projectByID: [String: MobileProject] = [:]
    public private(set) var requestByID: [String: MobileRequest] = [:]
    public private(set) var proposalResults: [String: MobileAlert] = [:]
    public private(set) var threadByID: [String: MobileThread] = [:]
    /// Alerts are kept by the phone for a week, with read state, because the Mac deletes them after six hours.
    public private(set) var inbox = MobileAlertInbox()
    public private(set) var status: MobileStatus?
    /// Latest time the Mac changed anything the phone has seen.
    public var lastChangedAt: Date?

    public init() {}

    /// Applies a fetch. Returns the phone's requests the Mac has now applied (it deletes them once done).
    @discardableResult
    public func apply(saved: [MobileRecord], deleted: [String]) -> [MobileRequest] {
        var applied: [MobileRequest] = []
        for name in deleted where name.hasPrefix("request-") {
            if let request = requestByID[String(name.dropFirst("request-".count))] { applied.append(request) }
        }
        for name in deleted {
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { if name == "status" { status = nil }; continue }
            switch parts[0] {
            case "thing": issues[parts[1]] = nil
            case "question": questions[parts[1]] = nil
            case "message": messageByID[parts[1]] = nil
            case "project": projectByID[parts[1]] = nil
            case "request": requestByID[parts[1]] = nil
            case "alert": proposalResults[parts[1]] = nil
            case "thread": threadByID[parts[1]] = nil
            default: break
            }
        }
        for record in saved {
            switch record {
            case .issue(let v): issues[v.id] = v
            case .question(let v): questions[v.id] = v
            case .message(let v): messageByID[v.id] = v
            case .project(let v): projectByID[v.id] = v
            case .request(let v): requestByID[v.id] = v
            case .status(let v): status = v
            case .alert(let v):
                if v.requestID != nil { proposalResults[v.id] = v }
                inbox.merge(saved: [v], now: .now)
            case .activityDevice: break
            case .thread(let v): threadByID[v.id] = v
            }
        }
        return applied.sorted { $0.createdAt < $1.createdAt }
    }

    /// The phone withdrew a request before the Mac applied it.
    public func forget(request id: String) { requestByID[id] = nil }

    /// A full refetch: keep only what the cloud holds now. `uploading` requests have not reached the cloud yet and stay;
    /// other pending requests the cloud no longer has were applied by the Mac and are returned.
    @discardableResult
    public func replaceAll(with records: [MobileRecord], uploading: Set<String> = []) -> [MobileRequest] {
        let before = requestByID
        removeAll()
        apply(saved: records, deleted: [])
        var applied: [MobileRequest] = []
        for (id, request) in before where requestByID[id] == nil {
            if uploading.contains(id) { requestByID[id] = request } else { applied.append(request) }
        }
        return applied.sorted { $0.createdAt < $1.createdAt }
    }

    public func removeAll() {
        issues = [:]; questions = [:]; messageByID = [:]; projectByID = [:]; requestByID = [:]; status = nil
        proposalResults = [:]; threadByID = [:]
    }

    public var sections: [Section] {
        MobileIssue.Group.allCases.compactMap { group in
            let list = issues.values.filter { $0.group == group }.sorted { $0.updatedAt > $1.updatedAt }
            return list.isEmpty ? nil : Section(group: group, issues: list)
        }
    }

    public var messages: [MobileMessage] { messageByID.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) } }
    public var projects: [MobileProject] { projectByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    public var pendingRequests: [MobileRequest] { requestByID.values.sorted { $0.createdAt < $1.createdAt } }

    /// Every conversation the Mac lists, main first, then by latest message.
    public var threads: [MobileThread] {
        threadByID.values.sorted { a, b in
            if a.id == ConversationID.main { return b.id != ConversationID.main }
            if b.id == ConversationID.main { return false }
            return (a.lastMessageAt ?? .distantPast, a.name) > (b.lastMessageAt ?? .distantPast, b.name)
        }
    }

    /// Messages of one conversation, oldest first. Messages written before threads travelled
    /// belong to the main conversation, which is where the app showed them.
    public func messages(in thread: String) -> [MobileMessage] {
        messageByID.values.filter { ($0.thread ?? ConversationID.main) == thread }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Where the phone asks the Mac to continue from. nil when nothing is loaded yet.
    public func oldestMessage(in thread: String) -> Date? {
        MobileHistory.oldest(Array(messageByID.values), thread: thread)?.at
    }

    public func thread(forIssue id: String) -> MobileThread? {
        threadByID.values.first { $0.issue == id }
    }

    /// Conversation of one Issue. Falls back to the main thread, the only one older records know.
    public func threadID(forIssue id: String) -> String {
        thread(forIssue: id)?.id ?? issues[id]?.thread ?? ConversationID.main
    }

    public func unreadAlerts() -> [MobileAlert] { inbox.alerts.filter { !inbox.isRead($0.id) } }
    public func markAllAlertsRead() { inbox.markAllRead() }
    public func markAlertRead(_ id: String) { inbox.markRead([id]) }
    public func markAlertsRead(_ ids: Set<String>) { inbox.markRead(ids) }

    /// Whether the Mac holds more messages than the phone has for this conversation. A thread
    /// record written before paging existed has no count, so nothing is claimed for it.
    public func canLoadOlder(thread: String) -> Bool {
        guard let total = threadByID[thread]?.messageCount else { return false }
        return messages(in: thread).count < total
    }

    public func dashboard(now: Date = .now) -> MobileDashboard {
        MobileDashboard.make(issues: Array(issues.values), questions: Array(questions.values), projects: projects,
                             working: { issue in issue.runs.map(MobileRunActivity.init(run:)) },
                             pendingRequests: pendingRequests.count, unreadAlerts: inbox.unreadCount,
                             lastChangedAt: lastChangedAt)
    }

    public func pendingQuestions(for issue: String) -> [MobileQuestion] {
        questions.values.filter { $0.issue == issue && $0.state == .pending }.sorted { $0.askedAt < $1.askedAt }
    }

    /// Answered and closed questions of a Issue, newest first, so the decisions stay visible.
    public func resolvedQuestions(for issue: String) -> [MobileQuestion] {
        questions.values.filter { $0.issue == issue && $0.state != .pending }.sorted { $0.askedAt > $1.askedAt }
    }

    public var pendingQuestionCount: Int { questions.values.filter { $0.state == .pending }.count }

    public func proposalResult(for issue: String) -> MobileAlert? {
        proposalResults.values.filter { $0.issue == issue }.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func makeRequest(_ kind: MobileRequest.Kind, now: Date = .now) -> MobileRequest {
        MobileRequest(id: UUID().uuidString, createdAt: now, kind: kind)
    }

    /// An answer or cancel for this question was sent and the Mac has not applied it yet.
    public func isAwaitingMac(question id: String) -> Bool {
        requestByID.values.contains {
            switch $0.kind {
            case .answer(let q, _, _): q == id
            case .cancelQuestion(let q): q == id
            default: false
            }
        }
    }

    public func isAwaitingMac(issue id: String) -> Bool {
        requestByID.values.contains {
            switch $0.kind {
            case .action(let t, _), .steer(let t, _): t == id
            case .approveProposal(let t, _), .requestProposalChanges(let t, _, _), .rejectProposal(let t, _, _): t == id
            default: false
            }
        }
    }
}
