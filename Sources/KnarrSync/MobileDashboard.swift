import Foundation

/// The whole house at a glance: how many Issues sit in each stage, which Hirds are working,
/// and what the Mac last did. Built from the same records the lists use, with no extra fetch.
public struct MobileDashboard: Sendable, Equatable {
    /// The same states the Mac's cards show, named the same way.
    public enum Bucket: String, Sendable, CaseIterable {
        case needsAnswer, awaitingApproval, judging, awaitingIntegration, unmet, failed, running, recentlyDone
        public var title: String {
            switch self {
            case .needsAnswer: "답변 필요"
            case .awaitingApproval: "승인 대기"
            case .judging: "판정 중"
            case .awaitingIntegration: "통합 대기"
            case .unmet: "미충족"
            case .failed: "실행 실패"
            case .running: "진행 중"
            case .recentlyDone: "최근 완료"
            }
        }
    }

    public struct Count: Identifiable, Sendable, Equatable {
        public var bucket: Bucket
        public var count: Int
        public var id: String { bucket.rawValue }
        public init(bucket: Bucket, count: Int) { self.bucket = bucket; self.count = count }
    }

    public struct ProjectCount: Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var open: Int
        public var needsAnswer: Int
        public init(id: String, name: String, open: Int, needsAnswer: Int) {
            self.id = id; self.name = name; self.open = open; self.needsAnswer = needsAnswer
        }
    }

    /// One Hird working now. `stage` is 1...5; `activity` is the Mac's one-line current action.
    public struct Working: Identifiable, Sendable, Equatable {
        public var issue: String
        public var title: String
        public var project: String
        public var run: String
        public var stage: Int
        public var stageTitle: String
        public var activity: String
        public var startedAt: Date
        public var waiting: Bool
        public var id: String { issue + "/" + run }
        public init(issue: String, title: String, project: String, run: String, stage: Int, stageTitle: String,
                    activity: String, startedAt: Date, waiting: Bool) {
            self.issue = issue; self.title = title; self.project = project; self.run = run
            self.stage = stage; self.stageTitle = stageTitle; self.activity = activity
            self.startedAt = startedAt; self.waiting = waiting
        }
    }

    public var counts: [Count]
    public var projects: [ProjectCount]
    public var working: [Working]
    public var pendingQuestions: Int
    public var pendingRequests: Int
    public var unreadAlerts: Int
    public var lastChangedAt: Date?

    public init(counts: [Count] = Bucket.allCases.map { Count(bucket: $0, count: 0) }, projects: [ProjectCount] = [],
                working: [Working] = [], pendingQuestions: Int = 0, pendingRequests: Int = 0,
                unreadAlerts: Int = 0, lastChangedAt: Date? = nil) {
        self.counts = counts; self.projects = projects; self.working = working
        self.pendingQuestions = pendingQuestions; self.pendingRequests = pendingRequests
        self.unreadAlerts = unreadAlerts; self.lastChangedAt = lastChangedAt
    }

    public func count(_ bucket: Bucket) -> Int { counts.first { $0.bucket == bucket }?.count ?? 0 }

    /// Which bucket an Issue belongs to. The Mac's own presentation key wins so the phone groups
    /// match the cards; a pending question still outranks the Issue's own execution state.
    public static func bucket(of issue: MobileIssue, asking: Bool) -> Bucket {
        if issue.group == .finished { return .recentlyDone }
        if asking || issue.state == .needsInput { return .needsAnswer }
        if let status = issue.status {
            switch status {
            case "awaitingApproval": return .awaitingApproval
            case "inProgress": return .running
            case "needsAnswer": return .needsAnswer
            case "judging": return .judging
            case "awaitingIntegration": return .awaitingIntegration
            case "unmet": return .unmet
            case "failed": return .failed
            case "completed": return .recentlyDone
            case "cancelled": return .recentlyDone
            default: break
            }
        }
        // Records written before the Mac's status travelled keep the older mapping.
        if issue.state == .failed || issue.state == .rejected { return .failed }
        if issue.state == .awaitingApproval { return .awaitingApproval }
        if issue.state == .running { return .running }
        return .judging
    }

    public static func make(issues: [MobileIssue], questions: [MobileQuestion], projects: [MobileProject],
                            working run: (MobileIssue) -> [MobileRunActivity] = { $0.runs.map(MobileRunActivity.init(run:)) },
                            pendingRequests: Int = 0, unreadAlerts: Int = 0, lastChangedAt: Date?) -> MobileDashboard {
        let asking = Set(questions.filter { $0.state == .pending }.map(\.issue))
        var counts: [Bucket: Int] = [:]
        for issue in issues { counts[bucket(of: issue, asking: asking.contains(issue.id)), default: 0] += 1 }

        var byProject: [String: ProjectCount] = [:]
        for project in projects { byProject[project.id] = .init(id: project.id, name: project.name, open: 0, needsAnswer: 0) }
        for issue in issues where issue.group != .finished {
            let needsAnswer = bucket(of: issue, asking: asking.contains(issue.id)) == .needsAnswer
            var entry = byProject[issue.project] ?? .init(id: issue.project, name: issue.project, open: 0, needsAnswer: 0)
            entry.open += 1
            if needsAnswer { entry.needsAnswer += 1 }
            byProject[issue.project] = entry
        }

        var working: [Working] = []
        for issue in issues where issue.state == .running || issue.group == .working {
            for activity in run(issue) where activity.status == .working || activity.status == .waiting {
                let stage = activity.stage ?? 0
                let title = activity.stages.flatMap { stages in
                    stages.indices.contains(stage - 1) ? stages[stage - 1].title : nil
                } ?? HirdStage.titles[max(0, min(HirdStage.titles.count - 1, stage - 1))]
                working.append(.init(issue: issue.id, title: issue.title, project: issue.project, run: activity.name,
                                     stage: stage, stageTitle: title,
                                     activity: activity.activity ?? activity.stages?.first(where: { $0.state == .active })?.title ?? issue.headline,
                                     startedAt: activity.startedAt ?? issue.startedAt, waiting: activity.status == .waiting))
            }
        }

        return MobileDashboard(
            counts: Bucket.allCases.map { Count(bucket: $0, count: counts[$0] ?? 0) },
            projects: byProject.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            working: working.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) },
            pendingQuestions: asking.count, pendingRequests: pendingRequests,
            unreadAlerts: unreadAlerts, lastChangedAt: lastChangedAt)
    }

    /// The five stages every Hird run passes through, in order.
    public enum HirdStage {
        public static let titles = ["준비", "실패 테스트 작성", "구현", "최종 검사", "보고"]
    }
}

/// The fields the dashboard reads from one run. A plain value so the aggregation does not depend on
/// the Mac's `HirdRun` or on a newer activity type another change may add.
public struct MobileRunActivity: Sendable, Equatable {
    public var name: String
    public var stage: Int?
    public var stages: [MobileIssue.Run.Step]?
    public var activity: String?
    public var startedAt: Date?
    public var status: MobileIssue.Run.Status
    public init(name: String, stage: Int?, stages: [MobileIssue.Run.Step]?, activity: String?, startedAt: Date?,
                status: MobileIssue.Run.Status) {
        self.name = name; self.stage = stage; self.stages = stages; self.activity = activity
        self.startedAt = startedAt; self.status = status
    }

    public init(run: MobileIssue.Run) {
        self.init(name: run.name, stage: run.stage, stages: run.stages, activity: run.activity,
                  startedAt: run.startedAt, status: run.status)
    }
}

/// The phone's alert list. Alerts live six hours in CloudKit, so the phone keeps what it has seen
/// (and which ones were read) for a week in its own preferences.
public struct MobileAlertInbox: Sendable, Equatable {
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static let limit = 100

    public private(set) var alerts: [MobileAlert] = []
    public private(set) var read: Set<String> = []

    public init() {}

    public var unreadCount: Int { alerts.filter { !read.contains($0.id) }.count }

    /// Merges a fetch. Alerts the Mac deleted stay if the phone already archived them; the 6-hour
    /// server retention must not blank a list someone was reading.
    public mutating func merge(saved: [MobileAlert], now: Date) {
        var byID = Dictionary(uniqueKeysWithValues: alerts.map { ($0.id, $0) })
        for alert in saved { byID[alert.id] = alert }
        let cutoff = now.addingTimeInterval(-Self.retention)
        alerts = byID.values.filter { $0.createdAt >= cutoff }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        if alerts.count > Self.limit { alerts = Array(alerts.prefix(Self.limit)) }
        let kept = Set(alerts.map(\.id))
        read.formIntersection(kept)
    }

    public mutating func markRead(_ ids: Set<String>) { read.formUnion(ids) }
    public mutating func markAllRead() { read = Set(alerts.map(\.id)) }
    public func isRead(_ id: String) -> Bool { read.contains(id) }

    /// The alert that opens one Issue and can be acted on: newest unread first is the list order.
    public func alert(for issue: String) -> MobileAlert? {
        alerts.first { $0.issue == issue }
    }

    public struct Stored: Codable, Sendable {
        public var alerts: [MobileAlert]
        public var read: [String]
        public init(alerts: [MobileAlert], read: [String]) { self.alerts = alerts; self.read = read }
    }

    public init(stored: Stored) {
        alerts = stored.alerts; read = Set(stored.read)
        alerts = Array(alerts.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.prefix(Self.limit))
    }

    public var stored: Stored { .init(alerts: alerts, read: read.sorted()) }
}

/// Paging for messages older than the recent window the Mac uploads automatically.
public enum MobileHistory {
    /// The next page going back from `before`, newest first. Records keep their own IDs, so asking
    /// twice cannot make the phone show a message twice.
    public static func page(_ messages: [MobileMessage], thread: String, before: Date,
                            limit: Int = MobileLimits.historyPage) -> [MobileMessage] {
        messages.filter { ($0.thread ?? ConversationID.main) == thread && $0.at < before }
            .sorted { ($0.at, $0.id) > ($1.at, $1.id) }
            .prefix(limit).map { $0 }
    }

    /// Which older messages to drop once a thread holds more than `keep`; nil keeps nothing.
    public static func overflow(_ messages: [MobileMessage], thread: String, keep: Int = MobileLimits.historyOnMac) -> [String] {
        let older = messages.filter { ($0.thread ?? ConversationID.main) == thread }
            .sorted { ($0.at, $0.id) > ($1.at, $1.id) }
        return older.dropFirst(keep).map(\.id)
    }

    /// The oldest message the phone holds for a thread, i.e. where the next page starts.
    public static func oldest(_ messages: [MobileMessage], thread: String) -> MobileMessage? {
        messages.filter { ($0.thread ?? ConversationID.main) == thread }.min { ($0.at, $0.id) < ($1.at, $1.id) }
    }
}

/// The thread name records written before threads travelled belong to.
public enum ConversationID {
    public static let main = "default"
}

/// Keeps the most recently requested history pages per conversation within a fixed budget.
/// A newly requested older page must survive; eviction follows request order, not message age.
public struct MobileHistoryLedger: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: String
        public var at: Date
        public init(id: String, at: Date) { self.id = id; self.at = at }
    }

    /// Least recently requested first; each entry also retains its original message timestamp.
    public private(set) var byThread: [String: [(id: String, at: Date)]] = [:]

    public init() {}
    public init(byThread: [String: [(id: String, at: Date)]]) { self.byThread = byThread }

    public var messageIDs: Set<String> { Set(byThread.values.flatMap { $0 }.map(\.id)) }

    /// Remembers a page and returns the IDs that fell out of the limit and should leave CloudKit.
    @discardableResult
    public mutating func retain(_ messages: [MobileMessage], thread: String,
                                limit: Int = MobileLimits.historyOnMac) -> [String] {
        let incoming = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        var entries = (byThread[thread] ?? []).filter { incoming[$0.id] == nil }
        entries += incoming.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) }.map { (id: $0.id, at: $0.at) }
        let dropped = entries.prefix(max(0, entries.count - limit)).map(\.id)
        byThread[thread] = Array(entries.suffix(max(0, limit)))
        return dropped
    }

    public mutating func forget(_ id: String) {
        for (thread, entries) in byThread { byThread[thread] = entries.filter { $0.id != id } }
    }

    public mutating func reset() { byThread = [:] }
}
