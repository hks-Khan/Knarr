import Foundation

public struct ConversationThread: Identifiable, Codable, Sendable, Hashable {
    public static let defaultID = "default"
    public static let `default` = Self(id: defaultID, name: "기본", createdAt: Date(timeIntervalSince1970: 0))
    public let id: String
    public var name: String
    public let createdAt: Date
    /// Project and issue ownership are mutually exclusive and immutable once persisted.
    /// Legacy/custom conversations have neither owner.
    public var issueID: Issue.ID?
    public var projectID: String?
    /// Successful admission of the project's compact initial context survives reconnects.
    public var projectHandoffDeliveredAt: Date?
    public var originThreadID: String?

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = .now,
                issueID: Issue.ID? = nil, originThreadID: String? = nil,
                projectID: String? = nil, projectHandoffDeliveredAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt
        self.issueID = issueID; self.originThreadID = originThreadID
        self.projectID = projectID; self.projectHandoffDeliveredAt = projectHandoffDeliveredAt
    }
}

/// Tab state never owns or deletes a conversation. Explicit history opens remain readable;
/// only a new completion/cancellation transition automatically closes an open tab.
struct ConversationTabs {
    var issueThreadIDs: [String]
    private var endedThreadIDs: Set<String> = []
    private var initialized = false

    init(saved: [String] = []) {
        var seen: Set<String> = []
        issueThreadIDs = saved.filter { seen.insert($0).inserted }
    }

    mutating func open(_ thread: ConversationThread) {
        guard thread.issueID != nil, !issueThreadIDs.contains(thread.id) else { return }
        issueThreadIDs.append(thread.id)
    }

    mutating func close(_ id: String) { issueThreadIDs.removeAll { $0 == id } }

    mutating func reconcile(threads: [ConversationThread], issues: [Issue], runs: [PersistedRun] = []) {
        let issueByID = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })
        var latestRuns: [Issue.ID: PersistedRun] = [:]
        for run in runs { latestRuns[run.issueID] = run }
        var valid: Set<String> = []
        var ended: Set<String> = []
        for thread in threads {
            guard let id = thread.issueID, let issue = issueByID[id] else { continue }
            valid.insert(thread.id)
            if issue.state == .done || issue.state == .rejected || issue.archivedAt != nil ||
                issue.isApplied || latestRuns[id]?.state == .cancelled { ended.insert(thread.id) }
        }
        let closing = initialized ? ended.subtracting(endedThreadIDs) : ended
        issueThreadIDs.removeAll { !valid.contains($0) || closing.contains($0) }
        endedThreadIDs = ended
        initialized = true
    }

    func displayed(threads: [ConversationThread], projects: [ProjectSummary]) -> [ConversationThread] {
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        var main = byID[ConversationThread.defaultID] ?? .default
        main.name = "메인"
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        let projectThreads = threads.compactMap { thread -> ConversationThread? in
            guard let id = thread.projectID, let name = names[id] else { return nil }
            var tab = thread
            tab.name = name
            return tab
        }
        return [main] + issueThreadIDs.compactMap { byID[$0] } + projectThreads
    }
}
