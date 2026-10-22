import Foundation

// Ported from JitdeckUI/MenuBarUsagePresentation.swift: remaining %, tightest headline and countdown.
// Reset times mark an expired observation, not an invented fresh 100% allowance.
public struct MenuBarUsageWindowText: Equatable, Sendable {
    public let percentText: String
    public let resetText: String
}
public struct MenuBarUsageWindowRow: Equatable, Sendable {
    public let label: String
    public let text: MenuBarUsageWindowText
    public let remainingPercent: Double?
}
public struct MenuBarUsageDetail: Equatable, Sendable {
    public let name: String
    public let windows: [MenuBarUsageWindowRow]
    public let updatedText: String
}
public enum MenuBarUsageProvider: String, Sendable, Hashable { case claude, codex }
public struct MenuBarUsageHeadline: Equatable, Sendable {
    public let provider: MenuBarUsageProvider
    public let text: String
}
public enum MenuBarUsagePresentation {
    public static let staleAfter: Int64 = 180
    public static func isStale(_ reading: SubscriptionUsageReading?, failed: Bool, now: Int64) -> Bool {
        guard let reading else { return failed }
        return failed || (reading.capturedAt.map { now - $0 >= staleAfter } ?? true)
    }
    public static func headline(_ reading: SubscriptionUsageReading?, failed: Bool, now: Int64) -> String {
        let windows = [reading?.fiveHour, reading?.weekly].compactMap { $0 }
        let left = windows.filter { !$0.isReset(now: now) }.map(remaining).min()
        guard let left else { return windows.isEmpty ? "--" : "초기화" }
        return (isStale(reading, failed: failed, now: now) ? "~" : "") + percent(left)
    }
    public static func detail(name: String, reading: SubscriptionUsageReading?, failed: Bool, now: Int64) -> MenuBarUsageDetail {
        let stale = isStale(reading, failed: failed, now: now)
        let windows = [("5시간", reading?.fiveHour), ("주간", reading?.weekly)].compactMap { label, window -> MenuBarUsageWindowRow? in
            guard let window else { return nil }
            let reset = window.isReset(now: now)
            let left = reset ? nil : remaining(window)
            let resetText = reset ? "초기화됨 · 갱신 대기" : window.resetsAt.map { "\(countdown($0 - now)) 후 초기화" } ?? "초기화 시각 확인 불가"
            let percentText = left.map { (stale ? "이전 값 · " : "") + "\(percent($0)) 남음" } ?? "--"
            return .init(label: label, text: .init(percentText: percentText, resetText: resetText), remainingPercent: left)
        }
        let status = failed ? "조회 실패 · " : (stale ? "오래된 값 · " : "")
        return .init(name: name, windows: windows, updatedText: status + updatedText(reading))
    }
    private static func remaining(_ window: UsageWindowReading) -> Double { min(100, max(0, 100 - window.usedPercent)) }
    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    private static func countdown(_ seconds: Int64) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes >= 24 * 60 {
            let hours = (minutes % (24 * 60)) / 60
            return hours == 0 ? "\(minutes / (24 * 60))일" : "\(minutes / (24 * 60))일 \(hours)시간"
        }
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes / 60)시간 \(minutes % 60)분" }
        return "\(max(minutes, 1))분"
    }
    private static func updatedText(_ reading: SubscriptionUsageReading?) -> String {
        guard let at = reading?.capturedAt else { return "마지막 확인 시각 확인 불가" }
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        return "마지막 확인 · " + date.formatted(.dateTime.month().day().hour().minute().second())
    }
}
