import CloudKit
import Foundation
import KnarrSync
import Testing
@testable import KnarrMirror

/// Advances receiver deadlines only when the test asks; sleep registration is the drain-completion gate.
@MainActor private final class InboxClock {
    private struct Sleep {
        let deadline: ContinuousClock.Instant
        let reply: CheckedContinuation<Void, any Error>
    }
    private(set) var now = ContinuousClock.now
    private(set) var registrations = 0
    private var sleeps: [UUID: Sleep] = [:]
    private var waiters: [UUID: (count: Int, reply: CheckedContinuation<Bool, Never>)] = [:]
    var nextDeadline: ContinuousClock.Instant? { sleeps.values.map(\.deadline).min() }
    var pendingCount: Int { sleeps.count }
    var pendingWaiterCount: Int { waiters.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
                sleeps[id] = Sleep(deadline: deadline, reply: reply)
                registrations += 1
                let ready = waiters.filter { $0.value.count <= registrations }
                for (id, waiter) in ready {
                    waiters.removeValue(forKey: id)
                    waiter.reply.resume(returning: true)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func waitForSleep(_ count: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard registrations < count else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                guard !Task.isCancelled else { reply.resume(returning: false); return }
                waiters[id] = (count, reply)
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.reply.resume(returning: false) }
        }
    }

    func advance(to instant: ContinuousClock.Instant) {
        precondition(instant >= now)
        now = instant
        let ready = sleeps.filter { $0.value.deadline <= now }
        for (id, sleep) in ready {
            sleeps.removeValue(forKey: id)
            sleep.reply.resume()
        }
    }

    func advance(by duration: Duration) { advance(to: now + duration) }
    private func cancel(_ id: UUID) { sleeps.removeValue(forKey: id)?.reply.resume(throwing: CancellationError()) }
}

@MainActor private final class InboxFixture {
    let suite = "knarr-inbox-" + UUID().uuidString
    lazy var defaults = UserDefaults(suiteName: suite)!
    let clock = InboxClock()
    var cloud: [MobileRequest] = []
    var cursor: Set<String> = []
    var applied: [String] = []
    var fetches = 0, resets = 0, deletions = 0
    var fetchFailures = 0, deleteFailures = 0
    var applicationBlocked = false, slowFetch = false, admissionCancelled = false
    var serverDelay: Double?
    var errors = 0
    var receiver: MobileRequestReceiver!
    func makeReceiver() {
        receiver = MobileRequestReceiver(defaults: defaults, interval: .milliseconds(20),
                                        now: { [clock] in clock.now },
                                        sleepUntil: { [clock] in try await clock.sleep(until: $0) },
                                        fetch: { [self] in
            fetches += 1
            if slowFetch { try await clock.sleep(until: clock.now + .seconds(5)) }
            if fetchFailures > 0 {
                fetchFailures -= 1
                throw CKError(.networkFailure, userInfo: serverDelay.map { [CKErrorRetryAfterKey: $0] } ?? [:])
            }
            let fresh = cloud.filter { !cursor.contains($0.id) }; cursor.formUnion(fresh.map(\.id)); return fresh
        }, reset: { [self] in resets += 1; cursor.removeAll() }, acknowledge: { [self] names in
            deletions += 1
            if deleteFailures > 0 { deleteFailures -= 1; throw CKError(.networkFailure) }
            cloud.removeAll { names.contains(MobileRecord.request($0).recordName) }
        }, apply: { [self] request in
            if admissionCancelled { throw CancellationError() }
            if applicationBlocked { throw CKError(.serviceUnavailable) }
            applied.append(request.id)
        }, failed: { [self] _ in errors += 1 })
    }
    func add(_ id: String) { cloud.append(.init(id: id, createdAt: .now, kind: .message(text: id, project: nil))) }
    func startAndWaitForSleep() async {
        let next = clock.registrations + 1
        receiver.start()
        #expect(await clock.waitForSleep(next))
    }
    func advanceToNextCheck() async throws {
        let deadline = try #require(clock.nextDeadline)
        let next = clock.registrations + 1
        clock.advance(to: deadline)
        #expect(await clock.waitForSleep(next))
    }
    func cleanup() async {
        await receiver.stop()
        #expect(clock.pendingCount == 0); #expect(clock.pendingWaiterCount == 0)
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor @Suite(.serialized) struct MobileRequestReceiverTests {
    @Test func missedPushIsRecoveredWithoutActivation() async throws {
        let f = InboxFixture(); f.makeReceiver(); f.receiver.start()
        do {
            // Startup may be queued beyond the old polling deadline without being a receiver failure.
            f.clock.advance(by: .seconds(4))
            #expect(await f.clock.waitForSleep(1))
            #expect(f.fetches == 1)
            #expect(f.clock.nextDeadline == f.clock.now + .milliseconds(20))
            f.add("late") // No push or manual pull.
            try await f.advanceToNextCheck()
            #expect(f.cloud.isEmpty); #expect(f.applied == ["late"]); #expect(f.fetches == 2)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func failedFetchRetriesWithoutAnotherPush() async throws {
        let f = InboxFixture(); f.fetchFailures = 1; f.add("retry"); f.makeReceiver()
        do {
            await f.startAndWaitForSleep()
            #expect(f.fetches == 1); #expect(f.errors == 1); #expect(f.cloud.count == 1)
            try await f.advanceToNextCheck()
            #expect(f.cloud.isEmpty)
            #expect(f.fetches == 2); #expect(f.resets == 2); #expect(f.applied == ["retry"])
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func failedAdmissionKeepsRequestAndReplaysAdvancedCursor() async throws {
        let f = InboxFixture(); f.applicationBlocked = true; f.add("pending"); f.makeReceiver()
        do {
            await f.startAndWaitForSleep()
            #expect(f.errors == 1); #expect(f.deletions == 0); #expect(f.cloud.count == 1)
            #expect((f.defaults.stringArray(forKey: CloudMirror.appliedKey) ?? []).isEmpty)
            f.applicationBlocked = false
            try await f.advanceToNextCheck()
            #expect(f.cloud.isEmpty); #expect(f.applied == ["pending"]); #expect(f.resets == 2)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func unavailableStoreCancellationDoesNotStopTheReceiver() async throws {
        let f = InboxFixture(); f.admissionCancelled = true; f.add("startup"); f.makeReceiver()
        do {
            await f.startAndWaitForSleep()
            #expect(f.errors == 1); #expect(f.applied.isEmpty); #expect(f.cloud.count == 1)
            f.admissionCancelled = false
            try await f.advanceToNextCheck()
            #expect(f.cloud.isEmpty); #expect(f.applied == ["startup"]); #expect(f.resets == 2)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func restartAfterDeleteFailureDoesNotResendAcceptedMessage() async {
        let f = InboxFixture(); f.deleteFailures = 100; f.add("once"); f.makeReceiver()
        await f.startAndWaitForSleep()
        #expect(f.deletions == 1)
        await f.receiver.stop()
        #expect(f.clock.pendingCount == 0); #expect(f.clock.pendingWaiterCount == 0)
        #expect(f.applied == ["once"]); #expect(f.cloud.count == 1)
        f.deleteFailures = 0; f.makeReceiver()
        await f.startAndWaitForSleep()
        #expect(f.cloud.isEmpty); #expect(f.applied == ["once"])
        await f.cleanup()
    }
    @Test func pushBurstHonorsServerBackoff() async throws {
        let f = InboxFixture(); f.fetchFailures = 1; f.serverDelay = 0.3; f.add("backoff"); f.makeReceiver()
        do {
            await f.startAndWaitForSleep()
            #expect(f.errors == 1)
            #expect(f.clock.nextDeadline == f.clock.now + .seconds(0.3))
            // Awaiting many pushes must not accidentally advance the server's deadline.
            for _ in 0..<20 { await f.receiver.pull() }
            #expect(f.fetches == 1)
            f.clock.advance(by: .milliseconds(299))
            await f.receiver.pull()
            #expect(f.fetches == 1); #expect(f.applied.isEmpty)
            try await f.advanceToNextCheck()
            #expect(f.cloud.isEmpty); #expect(f.applied == ["backoff"]); #expect(f.fetches == 2)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    @Test func stopCancelsFetchAndFutureChecks() async {
        let f = InboxFixture(); f.slowFetch = true; f.add("keep"); f.makeReceiver()
        await f.startAndWaitForSleep() // The controlled five-second fetch is now suspended.
        #expect(f.fetches == 1)
        await f.receiver.stop()
        let count = f.fetches
        #expect(f.clock.pendingCount == 0); #expect(f.clock.pendingWaiterCount == 0)
        f.clock.advance(by: .seconds(60))
        await f.receiver.pull()
        #expect(f.fetches == count); #expect(f.applied.isEmpty); #expect(f.deletions == 0)
        await f.cleanup()
    }
}
