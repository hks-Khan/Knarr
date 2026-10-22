import Foundation

/// A planned stage of a project. Completion is recorded only by an explicit verification of
/// every criterion; it is never derived from issue counts or other work.
public struct Milestone: Identifiable, Sendable, Hashable, Codable {
    public struct ID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }
    }

    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case planned, active, blocked, reached

        public var title: String {
            switch self {
            case .planned: "예정"
            case .active: "진행 중"
            case .blocked: "막힘"
            case .reached: "도달"
            }
        }
    }

    /// One recorded target-date edit. The storage layer appends these; clients never supply them.
    public struct TargetDateChange: Sendable, Hashable, Codable {
        /// The date before the edit; `nil` when the milestone had no target date.
        public var previous: Date?
        /// The date after the edit; `nil` when the target date was cleared.
        public var updated: Date?
        public var changedAt: Date

        public init(previous: Date?, updated: Date?, changedAt: Date) {
            self.previous = previous
            self.updated = updated
            self.changedAt = changedAt
        }
    }

    /// One week's planned scope and its recorded result. Entries are kept as history.
    public struct Week: Sendable, Hashable, Codable {
        /// Monday 00:00 of the week in the person's calendar.
        public var weekStart: Date
        public var scope: [String]
        public var result: String
        public var recordedAt: Date

        public init(weekStart: Date, scope: [String], result: String, recordedAt: Date) {
            self.weekStart = weekStart
            self.scope = scope
            self.result = result
            self.recordedAt = recordedAt
        }
    }

    public var id: ID
    public let projectID: String
    /// Unique within the project; the list is shown in this order.
    public var order: Int
    public var title: String
    public var detail: String
    public var status: Status
    /// Required while `status == .blocked`; a blocked milestone says why.
    public var blockedReason: String?
    public var targetDate: Date?
    /// Append-only target-date edits. Absent in older stored payloads; history is never invented.
    public var targetDateHistory: [TargetDateChange] = []
    public var criteria: [Criterion]
    /// Overall verification note shown with the milestone; criterion evidence gates completion.
    public var evidence: String
    public var inScope: [String]
    public var outOfScope: [String]
    public var prerequisites: [ID]
    /// Append-only weekly history; the current week's entry may be revised.
    public var weeks: [Week]
    public var reachedAt: Date?
    public private(set) var createdAt: Date
    public var updatedAt: Date

    public init(id: ID, projectID: String, order: Int, title: String, detail: String = "",
                status: Status = .planned, blockedReason: String? = nil, targetDate: Date? = nil,
                criteria: [Criterion] = [], evidence: String = "", inScope: [String] = [],
                outOfScope: [String] = [], prerequisites: [ID] = [], weeks: [Week] = [],
                reachedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.order = order
        self.title = title
        self.detail = detail
        self.status = status
        self.blockedReason = blockedReason
        self.targetDate = targetDate
        self.criteria = criteria
        self.evidence = evidence
        self.inScope = inScope
        self.outOfScope = outOfScope
        self.prerequisites = prerequisites
        self.weeks = weeks
        self.reachedAt = reachedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var isReached: Bool { status == .reached && reachedAt != nil }
    public var displayStatus: Status { isReached ? .reached : status }

    /// Explicit completion requires at least one criterion, all met, each with recorded evidence.
    public var canReach: Bool {
        !criteria.isEmpty && criteria.allSatisfy {
            $0.state == .met && !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Monday 00:00 of the week containing `date`.
    public static func weekStart(containing date: Date, calendar: Calendar = .current) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: parts) ?? date
    }

    /// Records or revises this week's scope. Earlier weeks are immutable; a later week cannot be
    /// back-filled after a newer one.
    public mutating func setWeek(scope: [String], result: String, at now: Date, calendar: Calendar = .current) throws {
        let start = Self.weekStart(containing: now, calendar: calendar)
        let scope = Self.lines(scope)
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = weeks.last {
            if last.weekStart > start { throw MilestoneError.weekInPast }
            if last.weekStart == start {
                weeks[weeks.count - 1].scope = scope
                weeks[weeks.count - 1].result = result
                weeks[weeks.count - 1].recordedAt = now
            } else {
                weeks.append(.init(weekStart: start, scope: scope, result: result, recordedAt: now))
            }
        } else {
            weeks.append(.init(weekStart: start, scope: scope, result: result, recordedAt: now))
        }
        updatedAt = now
    }

    /// Records a target-date edit. Only the storage layer calls this; a save with the same date
    /// appends nothing, and older payloads without history never gain invented entries.
    public mutating func recordTargetDateChange(previous: Date?, updated: Date?, at now: Date) {
        guard previous != updated else { return }
        targetDateHistory.append(.init(previous: previous, updated: updated, changedAt: now))
    }

    /// The stage the project is on: active first, then blocked, then the earliest unstarted one.
    /// When everything is reached the last stage stays visible with its reached status.
    public static func current(in milestones: [Milestone]) -> Milestone? {
        milestones.first { $0.displayStatus == .active }
            ?? milestones.first { $0.displayStatus == .blocked }
            ?? milestones.first { !$0.isReached }
            ?? milestones.last
    }

    /// Marks the milestone reached. Fails unless every criterion has explicit evidence.
    public mutating func markReached(at now: Date) throws {
        guard canReach else { throw MilestoneError.incompleteCriteria }
        status = .reached
        reachedAt = now
        updatedAt = now
    }

    /// Returns to active work; the recorded reach time is cleared, criteria stay.
    public mutating func reopen(at now: Date) {
        status = .active
        reachedAt = nil
        updatedAt = now
    }

    /// Trims fields and drops blank lines and duplicate prerequisites. Never invents content.
    public var cleaned: Milestone {
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        value.evidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        value.blockedReason = reason?.isEmpty == true ? nil : reason
        value.inScope = Self.lines(inScope)
        value.outOfScope = Self.lines(outOfScope)
        value.criteria = criteria.map {
            Criterion(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), state: $0.state,
                      evidence: $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.text.isEmpty }
        var seen: Set<ID> = []
        value.prerequisites = prerequisites.filter { $0 != id && seen.insert($0).inserted }
        value.weeks = weeks.map {
            .init(weekStart: $0.weekStart, scope: Self.lines($0.scope), result: $0.result.trimmingCharacters(in: .whitespacesAndNewlines), recordedAt: $0.recordedAt)
        }
        return value
    }

    private static func lines(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Validates one milestone against the project's other milestones.
    public func validate(inProject projectID: String, existing: [Milestone] = []) throws {
        try Self.validate(cleaned, inProject: projectID, others: existing.filter { $0.id != id })
    }

    /// Validates the whole project list. Prerequisite order is a graph inside one project only.
    public static func validate(_ milestones: [Milestone], projectID: String) throws {
        for milestone in milestones {
            try validate(milestone, inProject: projectID, others: milestones.filter { $0.id != milestone.id })
        }
    }

    private static func validate(_ value: Milestone, inProject projectID: String, others: [Milestone]) throws {
        guard !value.title.isEmpty else { throw MilestoneError.emptyTitle }
        guard value.projectID == projectID else { throw MilestoneError.projectMismatch }
        guard value.order >= 0 else { throw MilestoneError.invalidOrder }
        guard !others.contains(where: { $0.order == value.order }) else { throw MilestoneError.duplicateOrder }
        guard Set(value.prerequisites).count == value.prerequisites.count else { throw MilestoneError.duplicatePrerequisite }
        let byID = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        for prerequisite in value.prerequisites {
            guard prerequisite != value.id else { throw MilestoneError.selfPrerequisite }
            guard let other = byID[prerequisite], other.projectID == projectID else { throw MilestoneError.unknownPrerequisite(prerequisite.rawValue) }
        }
        if value.status == .blocked, value.blockedReason == nil { throw MilestoneError.missingBlockedReason }
        if value.status == .blocked, value.isReached { throw MilestoneError.reachedWithoutVerification }
        if value.isReached != (value.reachedAt != nil) { throw MilestoneError.inconsistentReach }
        if value.isReached, !value.canReach { throw MilestoneError.incompleteCriteria }
        var previous: Date?
        for week in value.weeks {
            if let previous, week.weekStart <= previous { throw MilestoneError.weekOrder }
            previous = week.weekStart
        }
        // Cycle check across the project graph, including this milestone's prerequisites.
        var graph = others.reduce(into: [ID: [ID]]()) { $0[$1.id] = $1.prerequisites }
        graph[value.id] = value.prerequisites
        var visiting: Set<ID> = [], done: Set<ID> = []
        func visit(_ id: ID) throws {
            if done.contains(id) { return }
            if !visiting.insert(id).inserted { throw MilestoneError.prerequisiteCycle }
            for next in graph[id] ?? [] { try visit(next) }
            visiting.remove(id); done.insert(id)
        }
        for id in graph.keys { try visit(id) }
    }

    /// Weekly history may only grow, and only the week containing `now` may still be revised.
    /// A stale week (or one the client back-dates) is rejected even when it is the last entry.
    public static func preservesWeekHistory(_ old: [Week], in new: [Week],
                                            at now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard new.count >= old.count else { return false }
        let current = weekStart(containing: now, calendar: calendar)
        if old.isEmpty { return new.allSatisfy { $0.weekStart <= current } }
        guard Array(new.prefix(old.count - 1)) == Array(old.dropLast()) else { return false }
        guard let last = old.last, new[old.count - 1].weekStart == last.weekStart else { return false }
        if last.weekStart != current, new[old.count - 1] != last { return false }
        return new.dropFirst(old.count).allSatisfy { $0.weekStart == current }
    }

    /// The value a store actually persists: immutable creation time, server-clock history and
    /// week protection all decided here so every store shares one rule.
    public func preparedForSave(over old: Milestone?, at now: Date = .now,
                                calendar: Calendar = .current) throws -> Milestone {
        var value = cleaned
        value.createdAt = old?.createdAt ?? createdAt
        value.updatedAt = now
        guard Milestone.preservesWeekHistory(old?.weeks ?? [], in: value.weeks, at: now, calendar: calendar) else {
            throw MilestoneError.historyRewritten
        }
        let history = old?.targetDateHistory ?? []
        value.targetDateHistory = history
        if let old { value.recordTargetDateChange(previous: old.targetDate, updated: value.targetDate, at: now) }
        return value
    }
}

public enum MilestoneError: Error, Equatable, LocalizedError {
    case emptyTitle
    case projectMismatch
    case invalidOrder
    case duplicateOrder
    case duplicatePrerequisite
    case selfPrerequisite
    case unknownPrerequisite(String)
    case prerequisiteCycle
    case missingBlockedReason
    case reachedWithoutVerification
    case inconsistentReach
    case incompleteCriteria
    case weekOrder
    case weekInPast
    case historyRewritten

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "마일스톤 제목을 입력해 주세요"
        case .projectMismatch: "마일스톤의 프로젝트가 다릅니다"
        case .invalidOrder: "마일스톤 순서가 올바르지 않습니다"
        case .duplicateOrder: "같은 순서의 마일스톤이 이미 있습니다"
        case .duplicatePrerequisite: "같은 선행 마일스톤을 두 번 고를 수 없습니다"
        case .selfPrerequisite: "마일스톤은 자기 자신을 선행 조건으로 삼을 수 없습니다"
        case .unknownPrerequisite(let id): "선행 마일스톤 \(id)을(를) 이 프로젝트에서 찾지 못했습니다"
        case .prerequisiteCycle: "선행 조건이 순환합니다"
        case .missingBlockedReason: "막힌 이유를 적어 주세요"
        case .reachedWithoutVerification: "도달한 마일스톤을 막힘으로 표시할 수 없습니다"
        case .inconsistentReach: "도달 상태와 도달 시각이 맞지 않습니다"
        case .incompleteCriteria: "모든 완료 조건을 근거와 함께 확인해야 도달로 표시할 수 있습니다"
        case .weekOrder: "주간 기록은 주 시작 순서대로 하나씩만 있어야 합니다"
        case .weekInPast: "지난주 기록은 새로 만들 수 없습니다"
        case .historyRewritten: "지난 주간 계획과 결과는 바꿀 수 없습니다"
        }
    }
}
