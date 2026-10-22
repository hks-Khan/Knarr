import CloudKit
import Foundation
import KnarrSync

/// One serialized inbox reader. Pushes wake it immediately; a bounded fallback recovers missed pushes.
@MainActor final class MobileRequestReceiver {
    static let interval: Duration = .seconds(15)
    private let defaults: UserDefaults
    private let interval: Duration
    private let now: () -> ContinuousClock.Instant
    private let sleepUntil: (ContinuousClock.Instant) async throws -> Void
    private let fetch: () async throws -> [MobileRequest]
    private let reset: () async -> Void
    private let acknowledge: ([String]) async throws -> Void
    private let apply: (MobileRequest) async throws -> Void
    private let failed: (any Error) -> Void
    private var scheduled: Task<Void, Never>?
    private var operation: Task<Duration?, Never>?
    private var running = false
    private var again = false
    private var needsReplay = true
    private var retryDelay: Duration
    private var retryAfter: ContinuousClock.Instant?

    init(defaults: UserDefaults, interval: Duration = MobileRequestReceiver.interval,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         sleepUntil: @escaping (ContinuousClock.Instant) async throws -> Void = { try await ContinuousClock().sleep(until: $0) },
         fetch: @escaping () async throws -> [MobileRequest], reset: @escaping () async -> Void,
         acknowledge: @escaping ([String]) async throws -> Void,
         apply: @escaping (MobileRequest) async throws -> Void, failed: @escaping (any Error) -> Void) {
        self.defaults = defaults; self.interval = interval; self.retryDelay = interval
        self.now = now; self.sleepUntil = sleepUntil
        self.fetch = fetch; self.reset = reset; self.acknowledge = acknowledge
        self.apply = apply; self.failed = failed
    }

    func start() {
        guard !running else { return }
        running = true; needsReplay = true; retryAfter = nil
        schedule(after: .zero)
    }

    func stop() async {
        running = false
        let timer = scheduled, work = operation
        scheduled = nil; timer?.cancel(); work?.cancel()
        _ = await work?.value; await timer?.value
        operation = nil
    }

    func pull() async {
        guard running, !Task.isCancelled else { return }
        if let operation { again = true; _ = await operation.value; return }
        if let retryAfter, retryAfter > now() {
            schedule(after: now().duration(to: retryAfter)); return
        }
        scheduled?.cancel(); scheduled = nil
        let task = Task { await drain() }
        operation = task
        let delay = await task.value
        operation = nil
        if let delay, running { schedule(after: delay) }
    }

    private func schedule(after delay: Duration) {
        guard running, scheduled == nil else { return }
        let deadline = now() + delay, sleepUntil = self.sleepUntil
        scheduled = Task { [weak self] in
            do { if delay > .zero { try await sleepUntil(deadline) } } catch { return }
            guard !Task.isCancelled else { return }
            self?.scheduled = nil
            await self?.pull()
        }
    }

    private func checkRunning() throws {
        try Task.checkCancellation()
        if !running { throw CancellationError() }
    }

    private func drain() async -> Duration? {
        do {
            repeat {
                again = false
                try checkRunning()
                // Recover requests whose cloud cursor advanced before an interrupted apply/delete.
                if needsReplay { await reset(); needsReplay = false }
                let requests = try await fetch()
                try checkRunning()
                var order = defaults.stringArray(forKey: CloudMirror.appliedKey) ?? []
                var applied = Set(order)
                var done: [String] = []
                for request in requests.sorted(by: { $0.createdAt < $1.createdAt }) {
                    try checkRunning()
                    if !applied.contains(request.id) {
                        try await apply(request)
                        // Persist admission before cloud deletion, including a concurrent shutdown.
                        applied.insert(request.id); order.append(request.id)
                        defaults.set(order, forKey: CloudMirror.appliedKey)
                    }
                    done.append(MobileRecord.request(request).recordName)
                }
                try checkRunning()
                if !done.isEmpty { try await acknowledge(done) }
                // Only trim old receipt history after every deletion succeeded. Keep order deterministic.
                if order.count > 300 { defaults.set(Array(order.suffix(300)), forKey: CloudMirror.appliedKey) }
                retryDelay = interval; retryAfter = nil
            } while again
            return interval
        } catch {
            needsReplay = true
            guard running, !Task.isCancelled else { return nil }
            failed(error)
            let serverDelay = (error as? CKError)?.retryAfterSeconds.flatMap { $0.isFinite && $0 > 0 ? Duration.seconds($0) : nil }
            let delay = max(retryDelay, serverDelay ?? .zero)
            retryDelay = min(retryDelay * 2, .seconds(300))
            retryAfter = now() + delay
            return delay
        }
    }
}
