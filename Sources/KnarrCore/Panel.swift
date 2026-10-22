import Foundation

/// The panel uses the same open statuses as the cards, one section per status that has work.
public enum Panel {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case awaitingApproval, needsAnswer, inProgress, judging, awaitingIntegration, unmet, failed

        public var title: String { status.title }
        public var status: IssueStatus {
            switch self {
            case .awaitingApproval: .awaitingApproval
            case .needsAnswer: .needsAnswer
            case .inProgress: .inProgress
            case .judging: .judging
            case .awaitingIntegration: .awaitingIntegration
            case .unmet: .unmet
            case .failed: .failed
            }
        }
        public init(_ status: IssueStatus) {
            switch status {
            case .awaitingApproval: self = .awaitingApproval
            case .needsAnswer: self = .needsAnswer
            case .inProgress: self = .inProgress
            case .judging: self = .judging
            case .awaitingIntegration: self = .awaitingIntegration
            case .unmet: self = .unmet
            case .failed: self = .failed
            case .completed, .cancelled: self = .inProgress
            }
        }
    }

    public struct Section: Sendable, Hashable, Identifiable {
        public var kind: Kind
        public var issues: [Issue]
        public var id: Kind { kind }
    }

    /// Working order: an answer, then an approval, then finished work, then work in flight.
    public static let order: [Kind] = [.needsAnswer, .awaitingApproval, .unmet, .failed, .judging, .awaitingIntegration, .inProgress]

    public static func sections(for issues: [Issue], questions: [Question] = []) -> [Section] {
        let asking = Set(questions.lazy.filter(\.isPending).compactMap(\.issue))
        var grouped: [Kind: [Issue]] = [:]
        for issue in issues where issue.archivedAt == nil {
            let status = issue.presentationStatus(hasPendingQuestion: asking.contains(issue.id))
            switch status {
            case .completed, .cancelled: continue
            default: grouped[Kind(status), default: []].append(issue)
            }
        }
        return order.compactMap { kind in
            guard let list = grouped[kind], !list.isEmpty else { return nil }
            return Section(kind: kind, issues: list)
        }
    }
}

/// Whether a Hird is visibly alive. Based only on recorded activity, never on a guessed percentage.
public enum Liveness: Sendable, Hashable {
    case active(seconds: Int)
    case quiet(minutes: Int)
    case waitingOnHuman(minutes: Int)
    case stopped(at: Date)
    case finished(at: Date)

    /// Silence longer than this turns a working Hird grey.
    public static let quietAfter: TimeInterval = 90
}

extension HirdRun {
    public func liveness(now: Date) -> Liveness {
        switch status {
        case .working:
            let elapsed = max(0, now.timeIntervalSince(lastActivityAt))
            return elapsed < Liveness.quietAfter ? .active(seconds: Int(elapsed)) : .quiet(minutes: Int(elapsed / 60))
        case .waitingOnHuman(let since):
            return .waitingOnHuman(minutes: Int(max(0, now.timeIntervalSince(since)) / 60))
        case .failed(let at):
            return .stopped(at: at)
        case .done(let at):
            return .finished(at: at)
        }
    }
}

extension Issue {
    /// A running Issue is as alive as its liveliest Hird.
    public func liveness(now: Date) -> Liveness? {
        let all = hirds.map { $0.liveness(now: now) }
        if state == .running {
            let active = all.compactMap { if case .active(let s) = $0 { s } else { nil } }
            if let s = active.min() { return .active(seconds: s) }
            let quiet = all.compactMap { if case .quiet(let m) = $0 { m } else { nil } }
            if let m = quiet.min() { return .quiet(minutes: m) }
        }
        // Not running: the latest run tells how it ended.
        return all.last
    }

    public var allSteps: [HirdStep] { hirds.flatMap(\.displaySteps) }
}
