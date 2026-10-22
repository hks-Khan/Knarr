import Foundation
import KnarrSync
import os

/// Mac-side delivery state. Device tokens stay in private CloudKit and local app storage,
/// and are never included in diagnostics. Only ActivityKit traffic uses this sender.
@MainActor
public final class LiveActivityRelay {
    private struct Stored: Codable {
        var devices: [String: MobileActivityDevice] = [:]
        var plans: [String: LiveActivityDeliveryPlan] = [:]
    }
    private static let key = "knarr.activity.relay.v1"
    private let defaults: UserDefaults
    private let send: @Sendable (LiveActivityPush) async throws -> Void
    private let log = Logger(subsystem: "com.kyen.knarr", category: "liveactivity")
    private var stored: Stored
    private var summary: LiveActivitySummary?
    private var trackedIDs = Set<String>()
    private var allCompleted = false
    private var running = false
    private var again = false
    private var retries = 0
    private var retryTask: Task<Void, Never>?

    public init(defaults: UserDefaults, send: @escaping @Sendable (LiveActivityPush) async throws -> Void) {
        self.defaults = defaults; self.send = send
        stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public func ingest(saved: [MobileRecord], deleted: [String], replacingDevices: Bool = false) {
        if replacingDevices {
            let present = Set(saved.compactMap { if case .activityDevice(let d) = $0 { d.id } else { nil } })
            stored.devices = stored.devices.filter { present.contains($0.key) }
            stored.plans = stored.plans.filter { present.contains($0.key) }
        }
        for record in saved {
            guard case .activityDevice(let device) = record else { continue }
            if let existing = stored.devices[device.id], existing.updatedAt > device.updatedAt { continue }
            stored.devices[device.id] = device
        }
        for name in deleted where name.hasPrefix("activityDevice-") {
            let id = String(name.dropFirst("activityDevice-".count))
            stored.devices[id] = nil; stored.plans[id] = nil
        }
        retries = 0
        persist()
    }

    public func refresh(records: [MobileRecord]) async {
        let issues = records.compactMap { if case .issue(let t) = $0 { t } else { nil } }
        let questions = records.compactMap { if case .question(let q) = $0 { q } else { nil } }
        let latest = LiveActivitySummary.make(issues: issues, questions: questions)
        if latest != nil {
            if summary == nil { trackedIDs = [] }
            trackedIDs.formUnion(issues.filter { $0.group != .finished }.map(\.id))
        }
        allCompleted = !trackedIDs.isEmpty && trackedIDs.allSatisfy { id in issues.contains { $0.id == id && $0.state == .done } }
        if summary != latest { retries = 0 }
        summary = latest
        await deliver()
    }

    public func stop() { retryTask?.cancel(); retryTask = nil }

    private func deliver() async {
        if running { again = true; return }
        running = true
        retryTask?.cancel(); retryTask = nil
        defer { running = false }
        var retry = false
        repeat {
            again = false
            for id in stored.devices.keys.sorted() {
                guard let device = stored.devices[id] else { continue }
                var plan = stored.plans[id] ?? LiveActivityDeliveryPlan()
                if summary == nil, device.activityID == nil { plan.pendingStartToken = nil }
                guard var push = plan.next(device: device, summary: summary, now: .now) else {
                    stored.plans[id] = plan; continue
                }
                if push.event == .end, allCompleted { push.content = push.content.ending(completed: true, at: .now) }
                plan.reserve(push)
                stored.plans[id] = plan
                persist() // Reserve starts before I/O; a lost response must not create duplicate activities.
                do {
                    try await send(push)
                    plan.commit(push)
                } catch let failure as LiveActivityAPNs.Failure {
                    switch failure {
                    case .invalidToken: plan.invalidToken = push.token
                    case .transport: retry = retry || push.event != .start
                    case .response(let status):
                        if status == 429 || status >= 500 {
                            plan.pendingStartToken = nil; retry = true
                        }
                    case .invalidConfiguration: break
                    }
                    log.error("Live Activity push was not confirmed")
                } catch {
                    log.error("Live Activity payload could not be delivered")
                }
                // The phone may delete its registration while a send is in flight.
                if stored.devices[id] != nil { stored.plans[id] = plan }
                persist()
            }
        } while again
        persist()
        if retry, retries < 3 {
            retries += 1
            let delay = 30 * (1 << (retries - 1))
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.retryTask = nil
                await self?.deliver()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }
}
