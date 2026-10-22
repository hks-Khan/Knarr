import Foundation

/// One run's progress from its saved, optional stage reports. Confirmation is fixed at report
/// receipt by the repository; rendering never rescans commands or files to strengthen a claim.
/// An approved plan remains visible before its first report. Legacy command inference is
/// retained internally for old records, never used as a reported plan or completion proof.
/// Nothing here polls or infers a percentage.
///
/// | Stage | Evidence |
/// |---|---|
/// | 준비 | the run has started; `git switch -c`, `git status` |
/// | 실패 테스트 작성 | the first `swift test --filter …` that exits non-zero |
/// | 구현 | after that failure: a file edit, or another `--filter` run |
/// | 최종 검사 | `swift test --no-parallel`, `build-app`, `qa-build-app` |
/// | 보고 | a report exists and a final check has passed |
///
/// A check without an exit code is running (timed out or backgrounded), never a pass or a failure.
public struct HirdProgress: Sendable, Hashable {
    public enum Stage: Int, CaseIterable, Sendable, Hashable {
        case prepare, failingTest, implement, finalCheck, report

        public var key: String { ["prepare", "failingTest", "implement", "finalCheck", "report"][rawValue] }
        public var title: String { ["준비", "실패 테스트 작성", "구현", "최종 검사", "보고"][rawValue] }
    }

    public enum StageState: String, Sendable, Hashable { case done, active, pending }

    /// What the run is doing at its current stage.
    public enum Condition: String, Sendable, Hashable { case running, waitingQuestion, done, stopped }

    /// How the run ended, from the run's own state.
    public enum Outcome: Sendable, Hashable { case active, done, stopped }

    public struct Check: Sendable, Hashable {
        public var command: String
        public var exitCode: Int32?
        public var finishedAt: Date
        public init(command: String, exitCode: Int32?, finishedAt: Date) {
            self.command = command; self.exitCode = exitCode; self.finishedAt = finishedAt
        }
    }

    public struct Tally: Sendable, Hashable {
        public var passed: Int
        public var failed: Int
        public var running: Int
        public init(passed: Int, failed: Int, running: Int) {
            self.passed = passed; self.failed = failed; self.running = running
        }
    }

    /// A report's confirmation is a record match, not a judgement of completion criteria.
    public struct PlannedStage: Sendable, Hashable {
        public var id: String
        public var title: String
        public var evidence: String
        public var criterion: Int?
        public var state: StageState
        public var verified: Bool?
        public var note: String?
    }

    public struct PlanChange: Sendable, Hashable {
        public var at: Date
        public var reason: String
        public var titles: [String]
    }

    public struct Input: Sendable, Hashable {
        /// The run's saved verifications.
        public var checks: [Check]
        /// The tool call in flight now: a bash command, or the tool's name for `edit`, `write`, `read`, …
        public var currentCommand: String?
        /// When the last file-changing tool call started.
        public var lastEditAt: Date?
        public var hasReport: Bool
        public var waitingOnQuestion: Bool
        public var outcome: Outcome
        public var plan: [IssueStage]
        public var reports: [StageReport]
        public init(checks: [Check] = [], currentCommand: String? = nil, lastEditAt: Date? = nil,
                    hasReport: Bool = false, waitingOnQuestion: Bool = false, outcome: Outcome = .active,
                    plan: [IssueStage] = [], reports: [StageReport] = []) {
            self.checks = checks; self.currentCommand = currentCommand; self.lastEditAt = lastEditAt
            self.hasReport = hasReport; self.waitingOnQuestion = waitingOnQuestion; self.outcome = outcome
            self.plan = plan; self.reports = reports
        }
    }

    public static let stageCount = Stage.allCases.count
    /// A run that has just started.
    public static let initial = HirdProgress(Input())

    /// The stage the run is at now; a finished run is at the last one.
    public let stage: Stage
    public let condition: Condition
    /// One state per stage, in order.
    public let stages: [StageState]
    /// The command that put the run at `stage`, when a command did.
    public let basis: String?
    public let checks: Tally

    public let plannedStages: [PlannedStage]
    public let planChanges: [PlanChange]

    public var stageIndex: Int {
        guard !plannedStages.isEmpty else { return stage.rawValue + 1 }
        let index = plannedStages.firstIndex { $0.state == .active }
            ?? plannedStages.firstIndex { $0.state == .pending }
            ?? plannedStages.indices.last
        return index.map { $0 + 1 } ?? 1
    }
    /// Only an explicit start report identifies a current planned stage.
    public var reportedStageIndex: Int? { plannedStages.firstIndex { $0.state == .active }.map { $0 + 1 } }
    public var reportedCompleteCount: Int { plannedStages.filter { $0.state == .done }.count }
    public var planSummary: String {
        let prefix = "작업 계획 \(plannedStages.count)개"
        if let index = reportedStageIndex {
            let label = condition == .running ? "진행 보고" : "마지막 보고"
            return prefix + " · " + label + ": " + plannedStages[index - 1].title
        }
        return prefix + (reportedCompleteCount > 0 ? " · 완료 보고 \(reportedCompleteCount)개" : " · 진행 보고 없음")
    }
    public var stageCount: Int { plannedStages.isEmpty ? Self.stageCount : plannedStages.count }
    public var titles: [String] { plannedStages.isEmpty ? Stage.allCases.map(\.title) : plannedStages.map(\.title) }
    public var currentStageKey: String { plannedStages.isEmpty ? stage.key : plannedStages[stageIndex - 1].id }
    public var currentStageTitle: String { plannedStages.isEmpty ? stage.title : plannedStages[stageIndex - 1].title }

    /// The current step waits (amber) or stops (red), without changing the Hird's reported state.
    public var steps: [HirdStep] {
        if !plannedStages.isEmpty {
            return plannedStages.map {
                HirdStep(title: $0.title, state: Self.stepState($0.state, condition: condition),
                         sourceStatus: $0.verified.map { $0 ? "verified" : "unverified" })
            }
        }
        return zip(Stage.allCases, stages).map {
            HirdStep(title: $0.title, state: Self.stepState($1, condition: condition))
        }
    }

    private static func stepState(_ state: StageState, condition: Condition) -> HirdStep.State {
        switch state {
        case .done: .done
        case .pending: .pending
        case .active:
            switch condition {
            case .running, .done: .active
            case .waitingQuestion: .blocked
            case .stopped: .failed
            }
        }
    }

    /// An issue can wait on an earlier Hird without losing the furthest run's recorded stage.
    init(waitingOnQuestion progress: HirdProgress) {
        stage = progress.stage
        condition = .waitingQuestion
        stages = progress.stages
        basis = progress.basis
        checks = progress.checks
        plannedStages = progress.plannedStages
        planChanges = progress.planChanges
    }

    public init(_ input: Input) {
        // Checks arrive in the order they were saved; the finish time is the truth when they disagree.
        let ordered = input.checks.enumerated()
            .sorted { ($0.element.finishedAt, $0.offset) < ($1.element.finishedAt, $1.offset) }.map(\.element)
        let rules = ordered.map { Self.rule(of: $0.command) }
        let firstFailure = ordered.indices.firstIndex { rules[$0] == .filterTest && (ordered[$0].exitCode ?? 0) != 0 }

        var reached = Stage.prepare
        var basis: String?
        /// A later proof at the same stage replaces the command it is based on; proof without a command never erases it.
        func note(_ stage: Stage, _ command: String?) {
            if stage.rawValue > reached.rawValue || (stage == reached && command != nil) { reached = stage; basis = command }
        }

        for (index, check) in ordered.enumerated() {
            switch rules[index] {
            case .prepare: note(.prepare, check.command)
            case .finalCheck: note(.finalCheck, check.command)
            case .filterTest:
                if let firstFailure, index > firstFailure { note(.implement, check.command) }
                else if index == firstFailure || check.exitCode == nil { note(.failingTest, check.command) }
            case nil: break
            }
        }

        var runningNow = 0
        if let command = input.currentCommand {
            switch Self.rule(of: command) {
            case .prepare: note(.prepare, command)
            case .filterTest: note(firstFailure == nil ? .failingTest : .implement, command); runningNow = 1
            case .finalCheck: note(.finalCheck, command); runningNow = 1
            case nil: if firstFailure != nil, Self.isFileChange(command) { note(.implement, nil) }
            }
        }
        if let firstFailure, let edit = input.lastEditAt, edit > ordered[firstFailure].finishedAt { note(.implement, nil) }
        // Chat between tool calls is saved as a report as well, so only a report after a passing final check counts.
        if input.hasReport, let passed = ordered.indices.last(where: { rules[$0] == .finalCheck && ordered[$0].exitCode == 0 }) {
            note(.report, ordered[passed].command)
        }

        checks = Tally(passed: ordered.filter { $0.exitCode == 0 }.count,
                       failed: ordered.filter { $0.exitCode.map { $0 != 0 } ?? false }.count,
                       running: ordered.filter { $0.exitCode == nil }.count + runningNow)
        self.basis = basis
        switch input.outcome {
        case .done:
            stage = reached; condition = .done
            // Ending a run is not proof that every inferred legacy stage was performed.
            stages = Stage.allCases.map { $0.rawValue < reached.rawValue ? .done : .pending }
        case .stopped, .active:
            stage = reached
            condition = input.outcome == .stopped ? .stopped : input.waitingOnQuestion ? .waitingQuestion : .running
            stages = Stage.allCases.map { $0.rawValue < reached.rawValue ? .done : $0 == reached ? .active : .pending }
        }
        (plannedStages, planChanges) = Self.projectPlan(input.plan, reports: input.reports)
    }

    private static func projectPlan(_ initial: [IssueStage], reports: [StageReport]) -> ([PlannedStage], [PlanChange]) {
        // The saved plan is authoritative even when the worker has not reported any stage.
        guard !initial.isEmpty else { return ([], []) }
        var plan = initial
        var states: [String: StageState] = [:]
        var confirmations: [String: Bool] = [:]
        var notes: [String: String] = [:]
        var changes: [PlanChange] = []
        // The durable event order is authoritative, including equal timestamps.
        for report in reports {
            switch report.action {
            case .replanned:
                guard let next = report.plan, !next.isEmpty else { continue }
                let ids = Set(next.map(\.id))
                states = states.filter { ids.contains($0.key) }
                confirmations = confirmations.filter { ids.contains($0.key) }
                notes = notes.filter { ids.contains($0.key) }
                plan = next
                changes.append(.init(at: report.at, reason: report.reason ?? "", titles: next.map(\.title)))
            case .started, .completed:
                guard plan.contains(where: { $0.id == report.stageID }) else { continue }
                if report.action == .started {
                    for (id, state) in states where state == .active { states[id] = .pending }
                    states[report.stageID] = .active
                    confirmations[report.stageID] = nil
                } else {
                    states[report.stageID] = .done
                    confirmations[report.stageID] = report.verified ?? false
                }
                if let note = report.note { notes[report.stageID] = note }
            }
        }
        return (plan.map {
            .init(id: $0.id, title: $0.title, evidence: $0.evidence, criterion: $0.criterion,
                  state: states[$0.id] ?? .pending, verified: confirmations[$0.id], note: notes[$0.id])
        }, changes)
    }

    // MARK: Command rules

    private enum Rule: Int, Comparable {
        case prepare, filterTest, finalCheck
        static func < (a: Rule, b: Rule) -> Bool { a.rawValue < b.rawValue }
    }

    /// Tools whose call changes files. Their activity text is the tool's name, not a command line.
    public static func isFileChange(_ command: String) -> Bool {
        ["edit", "write", "ast_edit"].contains(command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The strongest rule any command of the line matches (`cd x && swift test --no-parallel` is a final check).
    private static func rule(of command: String) -> Rule? {
        var found: Rule?
        for segment in segments(of: command) {
            var words = segment[...]
            while let first = words.first, ["time", "env", "nice"].contains(first) || isAssignment(first) { words = words.dropFirst() }
            guard let head = words.first else { continue }
            let rest = words.dropFirst()
            let rule: Rule?
            switch head {
            case "swift":
                if rest.first != "test" { rule = nil }
                else if rest.contains(where: { $0.hasPrefix("--filter") }) { rule = .filterTest }
                else if rest.contains("--no-parallel") { rule = .finalCheck }
                else { rule = nil }
            case "git":
                let switchesToNewBranch = rest.first == "switch" && (rest.contains("-c") || rest.contains("--create"))
                rule = rest.first == "status" || switchesToNewBranch ? .prepare : nil
            case "bash", "sh", "zsh", "python", "python3":
                rule = rest.first(where: { !$0.hasPrefix("-") }).map(isBuildScript) == true ? .finalCheck : nil
            default:
                rule = isBuildScript(head) ? .finalCheck : nil
            }
            if let rule, found.map({ rule > $0 }) ?? true { found = rule }
        }
        return found
    }

    /// Commands joined by `&&`, `||`, `;`, `|` or a newline, each split into words.
    private static func segments(of command: String) -> [[Substring]] {
        var text = command
        for separator in ["&&", "||", ";", "|"] { text = text.replacingOccurrences(of: separator, with: "\n") }
        return text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }.filter { !$0.isEmpty }
    }

    private static func isAssignment(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `scripts/build-app.sh`, `build-app`, `scripts/qa-build-app.py`: what the scripts are called, not what they mention.
    private static func isBuildScript(_ word: Substring) -> Bool {
        let name = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).split(separator: "/").last.map(String.init) ?? ""
        let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
        return stem == "build-app" || stem == "qa-build-app"
    }
}

extension PersistedRun {
    /// The run's progress as it stands, from its saved result and its own state.
    public var stageProgress: HirdProgress {
        let checks = (result?.verifications ?? []).filter { !$0.isInspection }.map {
            HirdProgress.Check(command: $0.command.joined(separator: " "), exitCode: $0.exitCode, finishedAt: $0.finishedAt)
        }
        let outcome: HirdProgress.Outcome = switch state {
        case .working, .waitingOnHuman: .active
        case .succeeded: .done
        case .failed, .cancelled, .interrupted: .stopped
        }
        return HirdProgress(.init(checks: checks, currentCommand: hird.currentCommand, lastEditAt: hird.lastEditAt,
                                  hasReport: result?.reportPath != nil, waitingOnQuestion: state == .waitingOnHuman,
                                  outcome: outcome, plan: stagePlan ?? [], reports: stageReports ?? []))
    }
}
