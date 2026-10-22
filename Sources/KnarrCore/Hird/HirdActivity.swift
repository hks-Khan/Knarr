import Foundation

/// What one Hird is doing right now, as one display line. Only the kind, a short target and a
/// count are kept; reasoning content never reaches storage or the screens.
public struct HirdActivity: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case thinking, writing, read, edit, search, command, subagents, waitingQuestion, idle
    }

    public var kind: Kind
    /// Distinct recent states kept per run; the card and drawer show up to this many lines.
    public static let maximumRecent = 5
    /// A file name, search target or command summary. Never a full path, prompt or output body.
    public var target: String?
    /// Active child count for `.subagents`.
    public var count: Int?
    public var at: Date

    public init(kind: Kind, target: String? = nil, count: Int? = nil, at: Date = .now) {
        self.kind = kind
        self.target = target
        self.count = count
        self.at = at
    }

    /// Two observations of the same state. The timestamp is not part of the state, so repeated
    /// deltas of one thinking block or the same tool call read as one line.
    public func sameState(as other: HirdActivity) -> Bool {
        kind == other.kind && target == other.target && count == other.count
    }

    /// The one line shown on issue cards and in the drawer.
    public var displayText: String {
        switch kind {
        case .thinking: "생각 중"
        case .writing: "답변 작성 중"
        case .read: Self.withTarget("읽는 중", target)
        case .edit: Self.withTarget("편집 중", target)
        case .search: Self.withTarget("검색 중", target)
        case .command: Self.withTarget("명령 실행", target)
        case .subagents: "하위 작업 \(max(1, count ?? 1))개"
        case .waitingQuestion: "질문 답변 대기"
        case .idle: "대기 중"
        }
    }

    /// A tool call as the activity it represents. `read`, `edit`, `write`, `grep`, `glob` and
    /// `bash` map to their own line; everything else runs a command through that tool.
    public static func tool(_ name: String, arguments: OMPJSON, at: Date) -> HirdActivity {
        let path = arguments["path"]?.string ?? arguments["file_path"]?.string ?? arguments["file"]?.string
        switch name {
        case "read", "lsp":
            return .init(kind: .read, target: path.map(fileName), at: at)
        case "edit", "write", "ast_edit":
            return .init(kind: .edit, target: path.map(fileName), at: at)
        case "grep", "glob", "ls", "find":
            let pattern = arguments["pattern"]?.string ?? arguments["query"]?.string ?? path
            return .init(kind: .search, target: pattern.map { short($0) }, at: at)
        case "bash":
            let command = arguments["command"]?.string ?? "bash"
            return .init(kind: .command, target: short(command), at: at)
        case "task", "agent":
            return .init(kind: .subagents, count: 1, at: at)
        case "ask":
            return .init(kind: .waitingQuestion, at: at)
        default:
            return .init(kind: .command, target: short(name), at: at)
        }
    }

    public static func subagents(_ count: Int, at: Date) -> HirdActivity {
        .init(kind: .subagents, count: count, at: at)
    }

    /// The last path component, so a line names the file and not the checkout.
    public static func fileName(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.isEmpty ? path : name
    }

    /// Collapses whitespace and elides the middle of long text, keeping both ends readable.
    public static func short(_ text: String, limit: Int = 48) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit, limit > 3 else { return collapsed }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(collapsed.prefix(head)) + "…" + String(collapsed.suffix(tail))
    }

    /// How long ago this state began, for the line beside it.
    public func relativeLabel(now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(at))
        if seconds < 5 { return "방금" }
        if seconds < 60 { return "\(Int(seconds))초 전" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전" }
        return "\(Int(seconds / 3600))시간 전"
    }

    private static func withTarget(_ label: String, _ target: String?) -> String {
        guard let target, !target.isEmpty else { return label }
        return label + " · " + target
    }
}

/// Coalesces rapid state changes into at most one ledger write per interval. The newest
/// observation is kept as `pending`, so a burst of alternating states ends with the true last
/// state written; nothing is dropped just because it was older than the interval.
public struct HirdActivityCoalescer: Sendable {
    /// One write per interval per run. Fast enough that the card never lags by more than a second.
    public static let defaultInterval: TimeInterval = 0.75
    public let interval: TimeInterval
    /// The last state actually written.
    public private(set) var written: HirdActivity?
    public private(set) var writtenAt: Date?
    /// The newest state that arrived inside the interval and is waiting for the next write.
    public private(set) var pending: HirdActivity?

    public init(interval: TimeInterval = HirdActivityCoalescer.defaultInterval) {
        self.interval = max(0, interval)
    }

    public var deadline: Date? {
        guard pending != nil, let writtenAt else { return nil }
        return writtenAt.addingTimeInterval(interval)
    }

    /// Accepts one observation. Returns the state to write now, or nil when it was a repeat
    /// (`pending`/`written` unchanged) or has to wait for the interval (`pending` updated).
    public mutating func offer(_ activity: HirdActivity, at now: Date) -> HirdActivity? {
        if written?.sameState(as: activity) == true {
            // Back to what the ledger already shows: a held-back state is now stale.
            pending = nil
            return nil
        }
        if pending?.sameState(as: activity) == true { return nil }
        guard let writtenAt else {
            write(activity, at: now); return activity
        }
        if activity.kind == .waitingQuestion || activity.kind == .idle || now.timeIntervalSince(writtenAt) >= interval {
            write(activity, at: now); return activity
        }
        pending = activity
        return nil
    }

    /// Writes the latest pending state, if any. Called by the timer and on teardown.
    public mutating func flush(at now: Date) -> HirdActivity? {
        guard let pending else { return nil }
        write(pending, at: now)
        return pending
    }

    /// Drops a held-back state, e.g. when the run is cancelled and the line no longer matters.
    public mutating func discardPending() { pending = nil }

    private mutating func write(_ activity: HirdActivity, at now: Date) {
        pending = nil; written = activity; writtenAt = now
    }
}

extension HirdRun {
    /// Waiting for a person wins over the last tool; a legacy run without saved activity still
    /// gets a readable line from `currentCommand`.
    public func activityLine(now: Date) -> HirdActivity {
        switch status {
        case .waitingOnHuman(let since):
            return HirdActivity(kind: .waitingQuestion, at: since)
        case .failed(let at), .done(let at):
            // A finished worker has no current state; its last distinct states stay in the history.
            return HirdActivity(kind: .idle, at: at)
        case .working:
            if let currentActivity { return currentActivity }
            if let command = currentCommand, !command.isEmpty {
                return HirdActivity(kind: .command, target: HirdActivity.short(command), at: lastActivityAt)
            }
            return HirdActivity(kind: .idle, at: lastActivityAt)
        }
    }

    /// The latest distinct lines, newest first, including the state running now.
    public func recentActivityLines(limit: Int = 5) -> [HirdActivity] {
        var lines: [HirdActivity] = []
        let current = activityLine(now: lastActivityAt)
        lines.append(current)
        for activity in (recentActivities ?? []).reversed() where activity.kind != .idle && lines.count < limit {
            if lines.last.map({ $0.sameState(as: activity) }) == true { continue }
            lines.append(activity)
        }
        return lines
    }
}
