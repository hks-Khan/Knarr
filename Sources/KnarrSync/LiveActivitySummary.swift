import Foundation
#if os(iOS)
import ActivityKit
#endif

public struct KnarrActivityAttributes: Codable, Sendable, Hashable {
    public typealias ContentState = LiveActivitySummary
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}
#if os(iOS)
extension KnarrActivityAttributes: ActivityAttributes {}
#endif

public struct LiveActivitySummary: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case running, needsInput, review, stopped, completed, ended }
    public var status: Status
    public var title: String
    public var detail: String
    public var runningCount: Int
    public var attentionCount: Int
    public var startedAt: Date
    public var newestStartedAt: Date
    public var updatedAt: Date
    public var issueID: String?
    public var isFinished: Bool { status == .completed || status == .ended }

    public static func make(issues: [MobileIssue], questions: [MobileQuestion]) -> Self? {
        let pending = questions.filter { $0.state == .pending }.sorted { ($0.askedAt, $0.id) < ($1.askedAt, $1.id) }
        let pendingIDs = Set(pending.map(\.issue))
        let active = issues.filter { $0.group != .finished || pendingIDs.contains($0.id) }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        guard let first = active.first else { return nil }
        let running = active.filter { $0.state == .running && !pendingIDs.contains($0.id) }
        let waiting = active.filter { $0.state == .needsInput || pendingIDs.contains($0.id) }
        let review = active.filter { $0.state == .awaitingApproval || ($0.state == .done && $0.group == .mine) }
        let stopped = active.filter { $0.state == .failed || $0.state == .rejected }
        var result = Self(status: .running, title: "", detail: "", runningCount: running.count,
                          attentionCount: Set((waiting + review + stopped).map(\.id)).count,
                          startedAt: first.startedAt, newestStartedAt: active.map(\.startedAt).max()!,
                          updatedAt: (active.map(\.updatedAt) + pending.map(\.askedAt)).max()!, issueID: nil)
        if let target = pending.compactMap({ q in active.first { $0.id == q.issue } }).first ?? waiting.first {
            result.status = .needsInput; result.title = "답변이 필요해요"; result.detail = target.title; result.issueID = target.id
        } else if let target = review.first {
            // A finished result waits for Stallari's integration; the person is not asked to review it.
            result.status = .review
            result.title = target.state == .awaitingApproval ? "제안을 승인해 주세요" : "통합 대기 중인 결과가 있어요"
            result.detail = target.title; result.issueID = target.id
        } else if let target = stopped.first {
            result.status = .stopped; result.title = "멈춘 이슈가 있어요"; result.detail = target.title; result.issueID = target.id
        } else if active.count == 1 {
            result.title = first.title; result.detail = first.progress ?? "이슈 진행 중"; result.issueID = first.id
        } else {
            result.title = "이슈 \(running.count)개 진행 중"
            result.detail = running.first?.progress ?? "Knarr에서 진행 상황 확인"
        }
        // Bound by UTF-8 bytes too: grapheme clusters can contain many Unicode scalars.
        result.title = compact(result.title, bytes: 240)
        result.detail = compact(result.detail, bytes: 320)
        return result
    }

    private static func compact(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes - 3 else { break }
            result.append(character)
        }
        return result + "…"
    }

    public var url: URL {
        var parts = URLComponents(); parts.scheme = "knarr"; parts.host = "activity"
        if let issueID { parts.queryItems = [URLQueryItem(name: CloudWire.issueReferenceKey, value: issueID)] }
        return parts.url!
    }

    public func ending(completed: Bool, at: Date) -> Self {
        var value = self; value.status = completed ? .completed : .ended
        value.title = completed ? "이슈를 마쳤어요" : "이슈가 종료됐어요"
        value.detail = completed ? "완료" : "종료"
        value.runningCount = 0; value.attentionCount = 0; value.updatedAt = at
        return value
    }
}

public struct LiveActivityPolicy: Codable, Sendable {
    public enum Decision: Equatable { case none, start, update, end }
    public var dismissedAt: Date?
    public init(dismissedAt: Date? = nil) { self.dismissedAt = dismissedAt }
    public func decision(summary: LiveActivitySummary?, hasActivity: Bool, foreground: Bool, remote: Bool, authorized: Bool) -> Decision {
        guard authorized, let summary else { return hasActivity ? .end : .none }
        if hasActivity { return .update }
        guard foreground, !remote else { return .none }
        if let dismissedAt, summary.newestStartedAt <= dismissedAt { return .none }
        return .start
    }
}
