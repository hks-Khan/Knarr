import Foundation
import CryptoKit

/// A generated work report shown once in the main conversation. The row is a view of the saved
/// report, never a stored message: its identity comes from the report id, so a restart or a
/// regenerated analysis updates the same card instead of adding another.
public enum WorkReportCards {
    /// Stable across restarts; a report id maps to exactly one transcript row.
    public static func messageID(for report: WorkReport) -> UUID { messageID(reportID: report.id) }
    public static func messageID(reportID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("knarr-work-report-card:" + reportID).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The card appears once the analysis finishes, successfully or not; an unfinished analysis adds no row.
    public static func isVisible(_ report: WorkReport) -> Bool {
        switch report.analysisState {
        case .ready, .failed, .noActivity: true
        case .pending, .generating: false
        }
    }

    public static func item(for report: WorkReport) -> ChatItem? {
        guard isVisible(report) else { return nil }
        return ChatItem(id: messageID(for: report), at: report.generatedAt, kind: .report(report.id))
    }

    /// The card's own numbers, derived from saved data only; no analysis text is repeated here.
    public static func lines(for report: WorkReport) -> [String] {
        let items = report.items
        let done = items.filter { $0.outcome == "완료 조건 충족" }.count
        let running = items.filter { $0.outcome == "실행 중" || $0.outcome == "진행 중 기록 · 실행 종료 여부 확인 필요" }.count
        let needsAnswer = items.filter { $0.outcome == "답변 필요" || $0.outcome == "승인 대기" }.count
        var result = ["작업 \(items.count)개 · 실행 \(report.runCount)회 · 누적 " + WorkReportTime.text(report.time.total),
                      "완료 \(done) · 진행 중 \(running) · 답변 필요 \(needsAnswer)"]
        var attention: [String] = []
        if report.failedRunCount > 0 { attention.append("실패 종료 \(report.failedRunCount)회") }
        if report.retryCount > 0 { attention.append("이어받기 \(report.retryCount)회") }
        if !report.failures.isEmpty { attention.append("실패 원인 " + report.failures.keys.sorted().joined(separator: "·")) }
        if !attention.isEmpty { result.append("주의 · " + attention.joined(separator: " · ")) }
        return result
    }

    /// One row per visible report, placed at its generation time without disturbing saved order.
    /// `including` keeps rows that were already shown, so a retry does not briefly remove the card.
    public static func transcript(_ chat: [ChatItem], reports: [WorkReport], threadID: String,
                                  including shown: Set<String> = []) -> [ChatItem] {
        guard threadID == ConversationThread.defaultID else { return chat }
        let existing = Set(chat.map(\.id))
        var cards: [(item: ChatItem, end: Date)] = []
        cards.reserveCapacity(reports.count)
        for report in reports where isVisible(report) || shown.contains(report.id) {
            let id: UUID = messageID(reportID: report.id)
            guard !existing.contains(id) else { continue }
            cards.append((ChatItem(id: id, at: report.generatedAt, kind: .report(report.id)), report.period.end))
        }
        // Two reports generated together still read oldest period first, never in hash order.
        cards.sort { ($0.item.at, $0.end, $0.item.id.uuidString) < ($1.item.at, $1.end, $1.item.id.uuidString) }
        guard !cards.isEmpty else { return chat }
        var result: [ChatItem] = [], index = 0
        for item in chat {
            while index < cards.count && cards[index].item.at <= item.at {
                result.append(cards[index].item); index += 1
            }
            result.append(item)
        }
        result.append(contentsOf: cards[index...].map(\.item))
        return result
    }
}
