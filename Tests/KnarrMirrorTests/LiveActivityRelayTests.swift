import Foundation
import KnarrSync
import Testing
@testable import KnarrMirror

private actor PushRecorder {
    var events: [LiveActivityPush.Event] = []
    var statuses: [LiveActivitySummary.Status] = []
    func append(_ push: LiveActivityPush) { events.append(push.event); statuses.append(push.content.status) }
}

@Suite @MainActor struct LiveActivityRelayTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    var records: [MobileRecord] {
        [.issue(.init(id: "t1", title: "이슈", project: "Knarr", state: .running, group: .working, headline: "", detail: "", criteria: [],
                      progress: nil, startedAt: at, updatedAt: at))]
    }
    func device(active: Bool = false) -> MobileRecord {
        .activityDevice(.init(id: "phone", environment: .sandbox, enabled: true, startToken: "fixture-start",
                            activityID: active ? "a" : nil, updateToken: active ? "fixture-update" : nil, updatedAt: at))
    }
    @Test func startRegistrationUpdateAndEndReachTheSenderOnlyOnce() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let relay = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        relay.ingest(saved: [device()], deleted: [])
        await relay.refresh(records: records)
        await relay.refresh(records: records)
        relay.ingest(saved: [device(active: true)], deleted: [])
        await relay.refresh(records: records)
        await relay.refresh(records: [])
        await relay.refresh(records: [])
        #expect(await recorder.events == [.start, .update, .end])
    }
    @Test func restartRestoresRegistrationAndPendingStartWithoutDuplicatingIt() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let relay = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        relay.ingest(saved: [device()], deleted: [])
        await relay.refresh(records: records)
        let restarted = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        await restarted.refresh(records: records)
        #expect(await recorder.events == [.start])
    }
    @Test func confirmedCompletionUsesACompletedFinalState() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let relay = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        relay.ingest(saved: [device(active: true)], deleted: [])
        await relay.refresh(records: records)
        let done = records.map { record -> MobileRecord in
            guard case .issue(var issue) = record else { return record }
            issue.state = .done; issue.group = .finished
            return .issue(issue)
        }
        await relay.refresh(records: done)
        #expect(await recorder.statuses.last == .completed)
    }

    @Test func fullDeviceSnapshotDropsARegistrationRemovedWhileMacWasOffline() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let original = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        original.ingest(saved: [device()], deleted: [])
        let restarted = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        restarted.ingest(saved: [], deleted: [], replacingDevices: true)
        await restarted.refresh(records: records)
        #expect(await recorder.events.isEmpty)
    }

    @Test func deletingADeviceStopsDelivery() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let relay = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        relay.ingest(saved: [device()], deleted: [])
        relay.ingest(saved: [], deleted: ["activityDevice-phone"])
        await relay.refresh(records: records)
        #expect(await recorder.events.isEmpty)
    }
    @Test func ambiguousStartFailureIsNotRepeatedAfterRestart() async {
        let suite = "knarr-liveactivity-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = PushRecorder()
        let relay = LiveActivityRelay(defaults: defaults) { push in
            await recorder.append(push); throw LiveActivityAPNs.Failure.transport
        }
        relay.ingest(saved: [device()], deleted: [])
        await relay.refresh(records: records)
        let restarted = LiveActivityRelay(defaults: defaults) { await recorder.append($0) }
        await restarted.refresh(records: records)
        #expect(await recorder.events == [.start])
    }
}
