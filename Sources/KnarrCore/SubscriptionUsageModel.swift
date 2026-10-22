import Foundation
import Observation

public enum UsageRefreshTrigger: Sendable { case stallariEnded, hirdEnded, detailOpened, manual }

// Adapted from JitdeckApp/SubscriptionUsageModel.swift. No start(), timer or idle polling.
@MainActor @Observable
public final class SubscriptionUsageModel {
    public private(set) var claude: SubscriptionUsageReading?
    public private(set) var codex: SubscriptionUsageReading?
    public private(set) var claudeFailed = false
    public private(set) var codexFailed = false
    public private(set) var now: Int64
    public private(set) var refreshing = false
    @ObservationIgnored private let reader: any SessionReading
    @ObservationIgnored private let clock: () -> Int64
    @ObservationIgnored private let sample: Bool
    @ObservationIgnored private var lastAttempt: Int64?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var completedRuns: Set<HirdRun.ID>?
    @ObservationIgnored private var closed = false

    public init(reader: any SessionReading = LocalSessionAPI(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                claude: SubscriptionUsageReading? = nil, codex: SubscriptionUsageReading? = nil, sample: Bool = false) {
        self.reader = reader; self.clock = clock; self.now = clock()
        self.claude = claude; self.codex = codex; self.sample = sample
    }
    public var headlines: [MenuBarUsageHeadline] {
        [.init(provider: .claude, text: MenuBarUsagePresentation.headline(claude, failed: claudeFailed, now: now)),
         .init(provider: .codex, text: MenuBarUsagePresentation.headline(codex, failed: codexFailed, now: now))]
    }
    public var details: [MenuBarUsageDetail] {
        [MenuBarUsagePresentation.detail(name: "Claude", reading: claude, failed: claudeFailed, now: now),
         MenuBarUsagePresentation.detail(name: "Codex", reading: codex, failed: codexFailed, now: now)]
    }
    public func refresh(_ trigger: UsageRefreshTrigger) async {
        requestRefresh(trigger)
        await refreshTask?.value
    }
    public func requestRefresh(_ trigger: UsageRefreshTrigger) {
        guard !closed else { return }
        now = clock()
        guard !sample, refreshTask == nil,
              trigger == .manual || (lastAttempt.map { now - $0 >= 180 || now < $0 } ?? true) else { return }
        lastAttempt = now; refreshing = true
        refreshTask = Task { [self] in
            defer { now = clock(); refreshing = false; refreshTask = nil }
            // Sequential quota reads: each bridge and child has exited before the next starts.
            for provider in ["claude", "codex"] {
                guard !Task.isCancelled, !closed else { return }
                do {
                    let result = try await reader.query(.object(["provider": .string(provider), "operation": .string("usage")]))
                    guard !Task.isCancelled, !closed else { return }
                    let data = try JSONEncoder().encode(result)
                    let reading = provider == "claude" ? SubscriptionUsageReading.ompClaude(data: data) : SubscriptionUsageReading.codex(data: data, observedAt: clock())
                    guard let reading else { throw SessionAPIError.failed("invalid_response") }
                    if provider == "claude" { claude = reading; claudeFailed = false }
                    else { codex = reading; codexFailed = false }
                } catch {
                    guard !Task.isCancelled, !closed else { return }
                    if provider == "claude" { claudeFailed = true } else { codexFailed = true }
                }
            }
        }
    }
    public func observeStallariFrame(_ frame: OMPJSON) {
        guard frame["type"]?.string == "agent_end",
              frame["isTerminal"]?.bool != false || frame["yielded"]?.bool == true else { return }
        requestRefresh(.stallariEnded)
    }
    public func observeHirdRuns(_ runs: [PersistedRun]) {
        let ended = Set(runs.filter { $0.processEndedAt != nil }.map(\.id))
        defer { completedRuns = ended }
        // Loading historical runs is not a completion event. Cancellation admission isn't process exit.
        guard let previous = completedRuns, !ended.subtracting(previous).isEmpty else { return }
        requestRefresh(.hirdEnded)
    }
    public func whenIdle() async { await refreshTask?.value }
    public func shutdown() async {
        closed = true
        let task = refreshTask
        task?.cancel()
        await task?.value
    }
}
