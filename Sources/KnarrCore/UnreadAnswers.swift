import Foundation

/// Which transcript rows count as a tab's new answers.
///
/// Policy: one countable row per user-visible Stallari answer, keyed by the message's stable id.
/// Tool/reasoning records (`activity`), user messages, app cards, and answers inside a focused
/// `conversationRootID` conversation never count. Streaming and the committed answer share one id,
/// so a reply that grows while it streams stays a single unread answer; text that grows after the
/// person read the answer keeps it read.
public enum UnreadAnswers {
    public static func isCountable(_ item: ChatItem) -> Bool {
        answer(item) != nil
    }

    /// The stable id and first-text time of one countable answer, or nil for anything else.
    public static func answer(_ item: ChatItem) -> UnreadAnswer? {
        guard item.activity == nil, item.conversationRootID == nil, !item.isConversationLink else { return nil }
        guard case .stallari(let text, _) = item.kind else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return UnreadAnswer(id: item.id, at: item.at)
    }

    /// The number shown beside the tab title; assistive labels carry the exact count instead.
    public static func badgeText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

/// One answer a tab may need to report: its stable message id and the time its text began.
public struct UnreadAnswer: Hashable, Sendable {
    public let id: UUID
    public let at: Date
    public init(id: UUID, at: Date) { self.id = id; self.at = at }
}

/// Per-tab read marks.
///
/// `readThrough` is an exclusive boundary for the contiguous read prefix, so ordinary reading
/// stores no per-answer ids. Every read answer past a gap keeps its own id in `readMarks`: that is
/// what stops an older answer from being marked read because a newer one was on screen, and what
/// keeps a streamed answer read when its text grows after the boundary advanced. The id list is
/// capped; only a conversation with hundreds of separate read/unread gaps could drop a mark, and a
/// dropped mark merely counts that answer again rather than hiding it.
public struct UnreadAnswerLedger: Codable, Equatable, Sendable {
    public var readThrough: Date
    public var readMarks: [ReadMark]

    public struct ReadMark: Codable, Equatable, Sendable {
        public var id: UUID
        public var at: Date
        public init(id: UUID, at: Date) { self.id = id; self.at = at }
    }

    static let maximumMarks = 512

    public init(readThrough: Date = .distantPast, readMarks: [ReadMark] = []) {
        self.readThrough = readThrough
        self.readMarks = readMarks
    }

    /// The first application reads existing history as the starting point; nothing from before
    /// this ledger existed is reported as a new answer.
    public init(baselining answers: [UnreadAnswer]) {
        self.init()
        guard let newest = answers.map(\.at).max() else { return }
        readThrough = newest
        readMarks = answers.filter { $0.at >= newest }.map { .init(id: $0.id, at: $0.at) }
    }

    public func isRead(_ answer: UnreadAnswer) -> Bool {
        answer.at < readThrough || readMarks.contains { $0.id == answer.id }
    }

    /// Marks the answers the person actually saw. `answers` is every countable answer of the tab,
    /// used to collapse a fully read prefix into the boundary instead of keeping one id per row.
    public mutating func markRead(_ read: [UnreadAnswer], among answers: [UnreadAnswer]) {
        var marks = readMarks
        for answer in read where !marks.contains(where: { $0.id == answer.id }) { marks.append(.init(id: answer.id, at: answer.at)) }
        let ordered = answers.sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        for answer in ordered where answer.at >= readThrough {
            guard marks.contains(where: { $0.id == answer.id }) else { break }
            readThrough = max(readThrough, answer.at)
        }
        marks.removeAll { $0.at < readThrough }
        marks.sort { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        if marks.count > Self.maximumMarks { marks.removeFirst(marks.count - Self.maximumMarks) }
        readMarks = marks
    }
}

/// Persists one ledger per conversation, so restarting the app keeps what the person already saw.
public struct UnreadAnswerBook {
    private let preferences: UserDefaults
    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    private func key(_ thread: String) -> String {
        "knarr.unread.v1." + Data(thread.utf8).base64EncodedString()
    }

    public func ledger(thread: String) -> UnreadAnswerLedger? {
        preferences.data(forKey: key(thread)).flatMap { try? JSONDecoder().decode(UnreadAnswerLedger.self, from: $0) }
    }

    public func save(_ ledger: UnreadAnswerLedger, thread: String) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        preferences.set(data, forKey: key(thread))
    }
}
