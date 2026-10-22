import Foundation

public struct WorkReportPeriod: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case daily, weekly }
    public var kind: Kind
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var id: String { kind.rawValue + ":" + String(Int(end.timeIntervalSince1970)) + ":" + timeZoneID }
    public var title: String { kind == .daily ? "일일 작업 보고" : "주간 작업 보고" }
    public static func due(now: Date, dailyEnd: Date, weeklyEnd: Date, calendar: Calendar) -> [Self] {
        var result: [Self] = []
        for (kind, initial, days) in [(Kind.daily, dailyEnd, 1), (.weekly, weeklyEnd, 7)] {
            var end = calendar.startOfDay(for: initial)
            while let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: end), fire <= now {
                guard let start = calendar.date(byAdding: .day, value: -days, to: end),
                      let next = calendar.date(byAdding: .day, value: days, to: end), next > end else { break }
                result.append(.init(kind: kind, start: start, end: end, timeZoneID: calendar.timeZone.identifier))
                end = next
            }
        }
        return result.sorted { ($0.end, $0.kind.rawValue) < ($1.end, $1.kind.rawValue) }
    }
    public var dateLabel: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.timeZone = TimeZone(identifier: timeZoneID); f.dateFormat = "M월 d일"
        return kind == .daily ? f.string(from: start) : f.string(from: start) + " – " + f.string(from: end.addingTimeInterval(-1))
    }
}

public struct WorkReportTime: Codable, Sendable, Hashable {
    public var total: TimeInterval
    public var elapsed: TimeInterval
    public static func measure(_ intervals: [DateInterval], within period: DateInterval) -> Self {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let a = max(interval.start, period.start), b = min(interval.end, period.end)
            return b > a ? .init(start: a, end: b) : nil
        }.sorted { $0.start < $1.start }
        var elapsed: TimeInterval = 0, last: DateInterval?
        for interval in clipped {
            if let previous = last, interval.start <= previous.end {
                last = .init(start: previous.start, end: max(previous.end, interval.end))
            } else { elapsed += last?.duration ?? 0; last = interval }
        }
        return .init(total: clipped.reduce(0) { $0 + $1.duration }, elapsed: elapsed + (last?.duration ?? 0))
    }
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}


public struct WorkReportRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var state: String
    public var stopReason: String?
    public var previousRunID: String?
    public var model: String?
}
public struct WorkReportItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var project: String
    public var title: String
    public var reason: String
    public var outcome: String
    public var applicationRecord: String
    public var criteria: [Criterion]
    public var runs: [WorkReportRun]
    public var time: WorkReportTime
}
public struct WorkReport: Codable, Sendable, Hashable, Identifiable {
    public enum AnalysisState: String, Codable, Sendable { case pending, generating, ready, failed, noActivity }
    public var period: WorkReportPeriod
    public var generatedAt: Date
    public var items: [WorkReportItem]
    public var time: WorkReportTime
    public var failures: [String: Int]
    public var plans: [String]
    public var analysisState: AnalysisState = .pending
    public var analysis: String = ""
    public var analysisModel: String?
    public var analysisError: String?
    public var id: String { period.id }
    public var runCount: Int { items.reduce(0) { $0 + $1.runs.count } }
    public var failedRunCount: Int { items.flatMap(\.runs).filter { $0.state == "failed" }.count }
    public var retryCount: Int { items.flatMap(\.runs).filter { $0.previousRunID != nil }.count }
    public static let coverage = "Hird 실행·대기 시간을 집계했어요. 실행 사이 공백과 별도 Codex·Claude 작업 시간은 포함하지 않아요. 판정·반영은 집계 시점의 저장 기록이며 Git·설치 상태는 별도 확인이 필요해요."
    public static func build(period: WorkReportPeriod, snapshot: PersistenceSnapshot, at: Date) -> Self {
        let bounds = DateInterval(start: period.start, end: period.end)
        let relevant = snapshot.runs.filter { $0.startedAt < period.end && ($0.endedAt ?? at) > period.start }
        let byIssue = Dictionary(grouping: relevant, by: \.issueID)
        let allByIssue = Dictionary(grouping: snapshot.runs, by: \.issueID)
        func within(_ date: Date?) -> Bool { date.map { $0 >= period.start && $0 < period.end } ?? false }
        func intervals(_ runs: [PersistedRun]) -> [DateInterval] {
            runs.compactMap { run in let end = run.endedAt ?? at; return end >= run.startedAt ? .init(start: run.startedAt, end: end) : nil }
        }
        var failures: [String: Int] = [:]
        for run in relevant where run.state == .failed {
            let reason = run.stopReason ?? "원인 기록 없음"
            let category = reason.contains("capture") || reason.contains("스냅샷") ? "코드 스냅샷 저장" :
                reason.contains("프로세스") && reason.contains("정리") ? "프로세스 정리" :
                reason.contains("omp_runtime") ? "OMP 연결·실행" : reason.contains("검증 보정") ? "검증 보정 한도" : "기타 실패"
            failures[category, default: 0] += 1
        }
        let items = snapshot.issues.filter { byIssue[$0.id] != nil || within($0.startedAt) || within($0.completedAt) || within($0.archivedAt) }.map { issue in
            let runs = (byIssue[issue.id] ?? []).sorted { $0.startedAt < $1.startedAt }
            let original = allByIssue[issue.id]?.min { $0.startedAt < $1.startedAt }?.hird.role ?? issue.proposal?.instruction
            let reason = original.map { String($0.prefix(4000)) + ($0.count > 4000 ? "\n(실행 지시 앞부분)" : "") } ?? "시작 이유가 별도로 기록되지 않았어요."
            let outcome: String
            if issue.archivedAt != nil, issue.archiveReason != IssueCloseReason.applied.rawValue { outcome = "닫힘 · " + (issue.archiveReason ?? "사유 미기록") }
            else { switch issue.state {
                case .done: outcome = "완료 조건 충족"
                case .failed: outcome = "완료 조건 미충족"
                case .awaitingApproval: outcome = "승인 대기"
                case .rejected: outcome = "거절됨"
                case .needsInput: outcome = "답변 필요"
                case .running: outcome = runs.contains { !$0.state.isTerminal } ? "실행 중" : "진행 중 기록 · 실행 종료 여부 확인 필요"
            } }
            let application: String
            switch issue.application {
            case .applied(let branch, let commit): application = "반영 기록: \(branch) · \(commit) (Git·설치 미대조)"
            case .kept(let branch, let commit): application = "작업본 보존: \(branch) · \(commit)"
            case .blocked(let reason): application = "반영 보류: " + reason
            case nil: application = "본체 반영·설치 확인 기록 없음"
            }
            return WorkReportItem(id: issue.id.rawValue, project: issue.projectName, title: issue.title,
                reason: reason, outcome: outcome, applicationRecord: application, criteria: issue.acceptance,
                runs: runs.map { .init(id: $0.id.rawValue, startedAt: $0.startedAt, endedAt: $0.endedAt, state: $0.state.rawValue,
                    stopReason: $0.stopReason, previousRunID: $0.previousRunID?.rawValue, model: $0.observedModel ?? $0.requestedModel) },
                time: WorkReportTime.measure(intervals(runs), within: bounds))
        }.sorted { ($0.time.total, $0.id) > ($1.time.total, $1.id) }
        let projectNames = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        let plans = snapshot.weekPlans.filter { plan in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: period.timeZoneID) ?? .current
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: plan.weekStart) ?? plan.weekStart
            return plan.weekStart < period.end && weekEnd > period.start
        }.flatMap { plan in plan.plan.map { "\(projectNames[plan.projectID] ?? plan.projectID): \($0)" } }
        var report = Self(period: period, generatedAt: at, items: items,
                          time: WorkReportTime.measure(intervals(relevant), within: bounds), failures: failures, plans: plans)
        if items.isEmpty { report.analysisState = .noActivity }
        return report
    }
}

/// One atomic document keeps reports and schedule cursors in the same commit.
public struct WorkReportArchive: Codable, Sendable, Hashable {
    public var timeZoneID: String
    public var dailyEnd: Date
    public var weeklyEnd: Date
    public var reports: [WorkReport] = []
    public init(now: Date, calendar: Calendar) {
        timeZoneID = calendar.timeZone.identifier
        dailyEnd = calendar.startOfDay(for: now)
        weeklyEnd = ProjectWeek.start(containing: now, calendar: calendar)
    }
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneID) ?? .current; c.firstWeekday = 2
        return c
    }
    public mutating func record(_ report: WorkReport) {
        if let i = reports.firstIndex(where: { $0.id == report.id }) { reports[i] = report }
        else { reports.append(report) }
        reports.sort { $0.period.end > $1.period.end }
        let next = calendar.date(byAdding: .day, value: report.period.kind == .daily ? 1 : 7, to: report.period.end)!
        if report.period.kind == .daily { dailyEnd = max(dailyEnd, next) } else { weeklyEnd = max(weeklyEnd, next) }
    }
    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
    public static func load(from url: URL, now: Date, calendar: Calendar) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(now: now, calendar: calendar) }
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        // A previous process may have received a response without persisting it. Keep the
        // aggregate and require an explicit retry instead of silently generating it twice.
        for i in value.reports.indices where value.reports[i].analysisState == .generating {
            value.reports[i].analysisState = .failed
            value.reports[i].analysisError = "앱 종료로 분석이 중단됐어요. 집계는 보관돼 있어요."
        }
        return value
    }
}
