import Foundation
import CoreFoundation

// Ported from JitdeckDomain/SubscriptionUsage.swift and CodexUsageAnalytics.swift.
// Only Claude and Codex subscription windows; no per-call token/cost estimates.
public struct UsageWindowReading: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Int64?
    public init(usedPercent: Double, resetsAt: Int64?) {
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public func isReset(now: Int64) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

public struct SubscriptionUsageReading: Equatable, Sendable {
    public let fiveHour: UsageWindowReading?
    public let weekly: UsageWindowReading?
    public let capturedAt: Int64?
    /// OMP may report several subscription accounts. Each displayed window is the tightest reported one.
    public let accountCount: Int
    public init(fiveHour: UsageWindowReading?, weekly: UsageWindowReading?, capturedAt: Int64?, accountCount: Int = 1) {
        self.fiveHour = fiveHour; self.weekly = weekly; self.capturedAt = capturedAt; self.accountCount = accountCount
    }
    public func ageMinutes(now: Int64) -> Int? { capturedAt.map { Int(max(0, now - $0) / 60) } }

    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func timestamp(_ value: Any?, milliseconds: Bool = false) -> Int64? {
        guard let value = numeric(value), value >= 0 else { return nil }
        let seconds = milliseconds ? value / 1000 : value
        guard seconds < Double(Int64.max) else { return nil }
        return Int64(seconds)
    }

    /// Official OMP 18.7.0 `usage --json --provider anthropic`. Header-derived reports keep their own fetchedAt.
    public static func ompClaude(data: Data) -> Self? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reports = root["reports"] as? [[String: Any]] else { return nil }
        var five: UsageWindowReading?, weekly: UsageWindowReading?, capture: Int64?
        var accountCount = 0
        var unknownCapture = false
        for report in reports where report["provider"] as? String == "anthropic" {
            guard let limits = report["limits"] as? [[String: Any]] else { continue }
            var hasWindow = false
            for limit in limits {
                guard let id = limit["id"] as? String, ["anthropic:5h", "anthropic:7d"].contains(id),
                      let amount = limit["amount"] as? [String: Any], let fraction = numeric(amount["usedFraction"]),
                      (0...1).contains(fraction) else { continue }
                let reset = (limit["window"] as? [String: Any]).flatMap { timestamp($0["resetsAt"], milliseconds: true) }
                let window = UsageWindowReading(usedPercent: fraction * 100, resetsAt: reset)
                if id == "anthropic:5h" {
                    if five == nil || window.usedPercent > five!.usedPercent { five = window }
                } else if weekly == nil || window.usedPercent > weekly!.usedPercent { weekly = window }
                hasWindow = true
            }
            if hasWindow {
                accountCount += 1
                // An unknown capture time must not be replaced with the command's generation time.
                if let at = timestamp(report["fetchedAt"], milliseconds: true) {
                    capture = capture.map { min($0, at) } ?? at
                } else { unknownCapture = true }
            }
        }
        guard five != nil || weekly != nil else { return nil }
        return .init(fiveHour: five, weekly: weekly, capturedAt: unknownCapture ? nil : capture, accountCount: accountCount)
    }

    /// Jitdeck bucket conversion: prefer the codex limit; preserve weekly-only plans and native snake-case.
    public static func codex(data: Data, observedAt: Int64) -> Self? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let limits: [String: Any]
        if let byID = root["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            guard let key = byID["codex"] != nil ? "codex" : byID.keys.sorted().first,
                  let selected = byID[key] as? [String: Any] else { return nil }
            limits = selected["rateLimits"] as? [String: Any] ?? selected
        } else if let native = root["rate_limits"] as? [String: Any] { limits = native }
        else if let legacy = root["rateLimits"] as? [String: Any] { limits = legacy }
        else { return nil }
        var five: UsageWindowReading?, weekly: UsageWindowReading?
        for name in ["primary", "secondary"] {
            guard let object = limits[name] as? [String: Any],
                  let percent = numeric(object["usedPercent"] ?? object["used_percent"]), (0...100).contains(percent) else { continue }
            let window = UsageWindowReading(usedPercent: percent, resetsAt: timestamp(object["resetsAt"] ?? object["resets_at"]))
            let duration = numeric(object["windowDurationMins"] ?? object["window_minutes"])
            let isWeekly = duration.map { $0 >= 7 * 24 * 60 } ?? (name != "primary")
            if isWeekly { if weekly == nil { weekly = window } }
            else if five == nil { five = window }
        }
        guard five != nil || weekly != nil else { return nil }
        return .init(fiveHour: five, weekly: weekly, capturedAt: observedAt)
    }
}
