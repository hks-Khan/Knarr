import Foundation

/// One project's plan for a calendar week. The store writes only the server's current week;
/// earlier weeks stay readable as history and cannot be created or edited again.
public struct ProjectWeekPlan: Sendable, Hashable, Codable, Identifiable {
    public var projectID: String
    /// Monday 00:00 of the week in the person's calendar.
    public var weekStart: Date
    public var plan: [String]
    public var recordedAt: Date

    public var id: String {
        projectID + "@" + String(weekStart.timeIntervalSinceReferenceDate)
    }

    public init(projectID: String, weekStart: Date, plan: [String], recordedAt: Date) {
        self.projectID = projectID
        self.weekStart = weekStart
        self.plan = ProjectWeekPlan.lines(plan)
        self.recordedAt = recordedAt
    }

    /// Trims each line and drops blanks and duplicates; never invents content.
    public static func lines(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// One judged issue completed in a week, with the milestone it was planned for.
/// Results are derived from stored issues; there is no user-entered result field.
public struct ProjectWeeklyResult: Sendable, Hashable, Identifiable {
    public var id: Issue.ID
    public var title: String
    public var milestoneID: Milestone.ID?
    public var milestoneTitle: String?
    public var completedAt: Date

    public init(id: Issue.ID, title: String, milestoneID: Milestone.ID?, milestoneTitle: String?, completedAt: Date) {
        self.id = id
        self.title = title
        self.milestoneID = milestoneID
        self.milestoneTitle = milestoneTitle
        self.completedAt = completedAt
    }
}

public enum ProjectWeek {
    /// Weeks start on Monday, matching `Milestone.weekStart`.
    public static func start(containing date: Date, calendar: Calendar = .current) -> Date {
        Milestone.weekStart(containing: date, calendar: calendar)
    }

    /// Issues judged satisfied (`state == .done`) and completed inside the week. Closing an issue
    /// never changes this list; a milestone is not reached by these results.
    public static func results(issues: [Issue], milestones: [Milestone], weekStart: Date,
                               calendar: Calendar = .current) -> [ProjectWeeklyResult] {
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7 * 86400)
        let titles = Dictionary(uniqueKeysWithValues: milestones.map { ($0.id, $0.title) })
        return issues.compactMap { issue -> ProjectWeeklyResult? in
            guard issue.state == .done, issue.archivedAt == nil,
                  let completed = IssueCards.completion(of: issue),
                  completed >= weekStart, completed < end else { return nil }
            return .init(id: issue.id, title: issue.title, milestoneID: issue.milestoneID,
                         milestoneTitle: issue.milestoneID.flatMap { titles[$0] }, completedAt: completed)
        }
        .sorted { ($0.completedAt, $0.id.rawValue) < ($1.completedAt, $1.id.rawValue) }
    }
}
