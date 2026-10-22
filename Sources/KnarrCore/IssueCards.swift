import Foundation

/// Presentation shared by the top area and the history page. No runtime reads or timers.
public struct IssueCards: Sendable, Hashable {
    public enum Scope: Sendable, Hashable {
        /// Every open issue regardless of owner: main conversation, history and project panels.
        case allProjects
        case project(String)
        case thread(String, project: String?)
        case issue(Issue.ID)
    }
    public enum Entry: Identifiable, Sendable, Hashable {
        case issue(Issue)
        case stallariWork([SubagentWork])
        public var id: String {
            switch self {
            case .issue(let issue): "issue:" + issue.id.rawValue
            case .stallariWork: "stallari-work"
            }
        }
    }
    public let entries: [Entry]
    public let issues: [Issue]
    public let answerCount: Int

    public init(issues: [Issue], questions: [Question] = [], threads: [ConversationThread] = [],
                stallariWork: [SubagentWork] = [], scope: Scope) {
        let asking = Set(questions.filter(\.isPending).compactMap(\.issue))
        let origins = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0.originThreadID) })
        self.issues = issues.filter { issue in
            let status = issue.presentationStatus(hasPendingQuestion: asking.contains(issue.id))
            guard issue.archivedAt == nil, status != .completed, status != .cancelled else { return false }
            switch scope {
            case .allProjects: return true
            case .project(let name): return issue.projectName == name
            case .thread(let id, let project):
                let origin = origins[issue.conversationThreadID] ?? nil
                return (issue.conversationThreadID == id || origin == id) && (project == nil || issue.projectName == project)
            case .issue(let id): return issue.id == id
            }
        }.sorted {
            let a = Self.rank($0, asking: asking), b = Self.rank($1, asking: asking)
            return (a, $0.startedAt, $0.id.rawValue) < (b, $1.startedAt, $1.id.rawValue)
        }
        answerCount = self.issues.filter { $0.needsAnswer(hasPendingQuestion: asking.contains($0.id)) }.count
        var entries = self.issues.map(Entry.issue)
        if !stallariWork.isEmpty {
            let index = self.issues.firstIndex { Self.rank($0, asking: asking) >= 3 } ?? entries.endIndex
            entries.insert(.stallariWork(stallariWork), at: index)
        }
        self.entries = entries
    }

    /// Answer, then approval, then a finished run waiting on judgement, then work in flight.
    private static func rank(_ issue: Issue, asking: Set<Issue.ID>) -> Int {
        switch issue.presentationStatus(hasPendingQuestion: asking.contains(issue.id)) {
        case .needsAnswer: return 0
        case .awaitingApproval: return 1
        case .judging, .awaitingIntegration, .unmet, .failed: return 2
        case .inProgress: return 3
        case .completed, .cancelled: return 4
        }
    }

    public static func activeHirds(for issue: Issue) -> [HirdRun] {
        issue.hirds.filter { switch $0.status { case .working, .waitingOnHuman: true; default: false } }
    }

    public static func quietLabel(for hird: HirdRun, now: Date) -> String? {
        if case .quiet(let minutes) = hird.liveness(now: now) { return "\(minutes)분째 조용함" }
        return nil
    }

    public static func quietLabel(for work: SubagentWork, now: Date) -> String? {
        let silence = max(0, now.timeIntervalSince(work.lastActivityAt))
        return silence < Liveness.quietAfter ? nil : "\(Int(silence / 60))분째 조용함"
    }

    public static func elapsed(from start: Date, to end: Date, completed: Bool = false) -> String {
        let minutes = Int(max(0, end.timeIntervalSince(start)) / 60)
        if completed { return minutes < 60 ? "걸린 시간 \(minutes)분" : "걸린 시간 \(minutes / 60)시간 \(minutes % 60)분" }
        return minutes < 60 ? "\(minutes)분째" : "\(minutes / 60)시간 \(minutes % 60)분째"
    }

    public static func firstApproval(of issue: Issue) -> Date? {
        let historical = issue.approvalHistory?.lazy.map(\.approvedAt).min()
        guard let current = issue.approval?.approvedAt else { return historical }
        return historical.map { min($0, current) } ?? current
    }

    public static func completion(of issue: Issue) -> Date? {
        guard issue.state != .awaitingApproval, issue.state != .needsInput,
              issue.state != .running || !issue.hasActiveHird || issue.displayStatus == .completed else { return nil }
        return issue.completedAt ?? issue.hirds.lazy.compactMap {
            switch $0.status {
            case .done(let at), .failed(let at): return at
            default: return nil
            }
        }.max()
    }

    public static func elapsed(for issue: Issue, now: Date) -> String? {
        guard let start = firstApproval(of: issue) else { return nil }
        let end = completion(of: issue)
        return elapsed(from: start, to: end ?? now, completed: end != nil)
    }

    public static func acceptanceSummary(for issue: Issue) -> String {
        let total = issue.acceptance.count
        let pending = issue.acceptance.filter { $0.state == .pending }.count
        let unmet = issue.acceptance.filter { $0.state == .unmet }.count
        if pending == total { return "완료 조건 \(total)개 · 판정 전" }
        if issue.metCriteria == total { return "완료 조건 \(total)개 충족" }
        var parts: [String] = []
        if issue.metCriteria > 0 { parts.append("충족 \(issue.metCriteria)개") }
        if unmet > 0 { parts.append("미충족 \(unmet)개") }
        if pending > 0 { parts.append("미판정 \(pending)개") }
        return parts.joined(separator: " · ")
    }

    public static func progress(for issue: Issue) -> HirdProgress {
        var furthest: HirdProgress?
        var latest: HirdProgress?
        var latestStart = Date.distantPast
        var hasCustomPlan = false
        var waiting = issue.state == .needsInput
        for hird in issue.hirds {
            switch hird.status {
            case .working: break
            case .waitingOnHuman: waiting = true
            default: continue
            }
            let progress = hird.stageProgress ?? .initial
            waiting = waiting || progress.condition == .waitingQuestion
            hasCustomPlan = hasCustomPlan || !progress.plannedStages.isEmpty
            let start = hird.startedAt ?? hird.lastActivityAt
            if latest == nil || start >= latestStart {
                latest = progress
                latestStart = start
            }
            if let current = furthest, current.stage.rawValue > progress.stage.rawValue { continue }
            furthest = progress
        }
        // Custom plans do not share a stage scale. Select the latest active run instead of
        // comparing stage counts or mixing a custom index with the fixed legacy stages.
        if let progress = hasCustomPlan ? latest : furthest {
            return waiting && progress.condition == .running ? HirdProgress(waitingOnQuestion: progress) : progress
        }
        if let last = issue.hirds.last {
            if let progress = last.stageProgress { return progress }
            let outcome: HirdProgress.Outcome = switch last.status {
            case .done: .done
            case .failed: .stopped
            case .working, .waitingOnHuman: .active
            }
            return HirdProgress(.init(outcome: outcome))
        }
        return HirdProgress(.init(outcome: issue.state == .done ? .done : issue.state == .failed ? .stopped : .active))
    }

    public static func latestLine(for issue: Issue) -> String {
        guard !issue.needsNewProposal else { return "" }
        if issue.displayStatus == .awaitingApproval {
            return issue.proposalReviewNote == nil ? "" : "수정 요청 전달 · 새 제안 대기"
        }
        let text: String
        if issue.displayStatus == .unmet || issue.displayStatus == .failed {
            text = issue.detail.isEmpty ? issue.headline : issue.detail
        } else if issue.displayStatus != .inProgress, issue.displayStatus != .needsAnswer {
            text = issue.latestResult?.summary ?? (issue.detail.isEmpty ? issue.headline : issue.detail)
        } else {
            text = issue.headline
        }
        let line = String(text.prefix { !$0.isNewline })
        switch line {
        case "Hird 실행", "완료 조건 충족", "실행 실패", "실행 중단", "취소됨": return ""
        default: return line == issue.statusLine ? "" : line
        }
    }

    public static func history(issues: [Issue]) -> [Issue] {
        issues.filter { $0.displayStatus == .completed || $0.displayStatus == .cancelled }
            .sorted { ($0.archivedAt ?? completion(of: $0) ?? $0.startedAt, $0.id.rawValue) > ($1.archivedAt ?? completion(of: $1) ?? $1.startedAt, $1.id.rawValue) }
    }
}

/// Open project counters share the same presentation mapping as cards and the panel.
public struct IssueCounts: Sendable, Hashable {
    /// Counts per open status, in the same order the lists use.
    public private(set) var byStatus: [IssueStatus: Int] = [:]
    public private(set) var completedThisWeek = 0

    public init(issues: [Issue], questions: [Question] = [], now: Date = .now, calendar: Calendar = .current) {
        let asking = Set(questions.lazy.filter(\.isPending).compactMap(\.issue))
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        for issue in issues where issue.archivedAt == nil {
            let status = issue.presentationStatus(hasPendingQuestion: asking.contains(issue.id))
            switch status {
            case .completed:
                if let completed = IssueCards.completion(of: issue), let week,
                   completed >= week.start, completed < week.end, completed <= now { completedThisWeek += 1 }
            case .cancelled: break
            default: byStatus[status, default: 0] += 1
            }
        }
    }

    public func count(_ status: IssueStatus) -> Int { byStatus[status] ?? 0 }

    /// One line naming every non-zero open state, then this week's completions.
    public var summary: String {
        var parts = IssueStatus.openCases.compactMap { status -> String? in
            let n = count(status)
            return n == 0 ? nil : "\(status.title) \(n)"
        }
        parts.append("이번 주 완료 \(completedThisWeek)")
        return parts.joined(separator: " · ")
    }
}

extension KnarrStore {
    public var selectedIssue: Issue? {
        guard let id = threads.first(where: { $0.id == selectedThreadID })?.issueID else { return nil }
        return issue(id)
    }
    public var issueConversationIsReadOnly: Bool {
        guard let status = selectedIssue?.displayStatus else { return false }
        return status == .completed || status == .cancelled
    }
    public var topIssueCards: IssueCards {
        if let issue = selectedIssue, !preparationSourceIDs.contains(issue.id) {
            return IssueCards(issues: [issue], questions: questions, stallariWork: stallariWork, scope: .issue(issue.id))
        }
        if let projectID = threads.first(where: { $0.id == selectedThreadID })?.projectID {
            return IssueCards(issues: executionIssues(inProject: projectID), questions: questions,
                              stallariWork: stallariWork, scope: .allProjects)
        }
        let scope: IssueCards.Scope = selectedThreadID == ConversationThread.defaultID
            ? .allProjects : .thread(selectedThreadID, project: nil)
        return IssueCards(issues: issues.filter { !preparationSourceIDs.contains($0.id) }, questions: questions, threads: threads, stallariWork: stallariWork, scope: scope)
    }
}
