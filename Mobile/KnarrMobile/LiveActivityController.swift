import ActivityKit
import KnarrSync
import UIKit
import os

/// Owns a single aggregate activity. All calls are serialized on the main actor;
/// repeated refreshes coalesce, and an activity dismissed by the person stays dismissed.
@MainActor
final class LiveActivityController {
    typealias KnarrActivity = Activity<KnarrActivityAttributes>
    private let defaults: UserDefaults
    private let sample: Bool
    private let log = Logger(subsystem: "com.kyen.knarr.mobile", category: "liveactivity")
    private var observers: [Task<Void, Never>] = []
    private var watched = Set<String>()
    private var ending = Set<String>()
    private var summary: LiveActivitySummary?
    private var remote = false
    private var reconciling = false
    private var again = false
    private var canReconcile = false
    private var trackedIDs = Set<String>()
    private var allCompleted = false
    private var lastPublished: MobileActivityDevice?
    private var publishing = false
    private var publishAgain = false
    private var publish: ((MobileActivityDevice) async -> Bool)?
    private var startToken: String?
    private var policy: LiveActivityPolicy
    private let deviceID: String

    init(sample: Bool, defaults: UserDefaults = .standard) {
        self.sample = sample; self.defaults = defaults
        deviceID = defaults.string(forKey: "knarr.activity.device") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "knarr.activity.device")
        policy = LiveActivityPolicy(dismissedAt: defaults.object(forKey: "knarr.activity.dismissed") as? Date)
    }

    func start(publish: @escaping (MobileActivityDevice) async -> Bool) {
        guard observers.isEmpty else { return }
        self.publish = publish
        for activity in KnarrActivity.activities { watch(activity) }
        observers.append(Task { [weak self] in
            for await activity in KnarrActivity.activityUpdates {
                guard let self, !Task.isCancelled else { return }
                self.watch(activity)
                await self.reconcile()
                await self.publishDevice()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard let self, !Task.isCancelled else { return }
                await self.reconcile(); await self.publishDevice()
            }
        })
        if !sample, #available(iOS 17.2, *) {
            observers.append(Task { [weak self] in
                for await token in KnarrActivity.pushToStartTokenUpdates {
                    guard let self, !Task.isCancelled else { return }
                    self.startToken = token.map { String(format: "%02x", $0) }.joined()
                    await self.publishDevice()
                }
            })
        }
    }

    func update(issues: [MobileIssue], questions: [MobileQuestion], remoteEnabled: Bool) async {
        let latest = LiveActivitySummary.make(issues: issues, questions: questions)
        if latest != nil {
            if summary == nil { trackedIDs = [] }
            trackedIDs.formUnion(issues.filter { $0.group != .finished }.map(\.id))
        }
        summary = latest
        allCompleted = !trackedIDs.isEmpty && trackedIDs.allSatisfy { id in issues.contains { $0.id == id && $0.state == .done } }
        if #available(iOS 17.2, *) { remote = remoteEnabled && startToken != nil } else { remote = false }
        canReconcile = true // Never end a restored activity before the first successful data fetch.
        await reconcile()
    }

    func publishCurrentDevice() async { await publishDevice() }

    private var current: KnarrActivity? {
        KnarrActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
            .sorted { $0.id < $1.id }.first
    }

    private func reconcile() async {
        guard canReconcile else { return }
        if reconciling { again = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            again = false
            let activity = current
            // A foreground start can race a previously sent APNs start. Retain one activity.
            for duplicate in KnarrActivity.activities where duplicate.id != activity?.id &&
                (duplicate.activityState == .active || duplicate.activityState == .stale) {
                ending.insert(duplicate.id)
                await Self.end(id: duplicate.id, final: nil, immediately: true)
            }
            let decision = policy.decision(summary: summary, hasActivity: activity != nil,
                                           foreground: UIApplication.shared.applicationState == .active,
                                           remote: remote, authorized: ActivityAuthorizationInfo().areActivitiesEnabled)
            switch decision {
            case .none: break
            case .start:
                guard let summary else { continue }
                do {
                    let started = try KnarrActivity.request(attributes: .init(sessionID: UUID().uuidString),
                        content: ActivityContent(state: summary, staleDate: .now.addingTimeInterval(900)),
                        pushType: sample ? nil : .token)
                    watch(started)
                    log.info("aggregate activity started")
                } catch {
                    log.error("activity could not start") // Do not log payloads or push tokens.
                }
            case .update:
                if let activity, let summary {
                    await Self.update(id: activity.id, summary: summary)
                }
            case .end:
                if let activity {
                    ending.insert(activity.id)
                    let final = activity.content.state.ending(completed: allCompleted, at: .now)
                    await Self.end(id: activity.id, final: final, immediately: false)
                    log.info("aggregate activity ended")
                }
            }
            await publishDevice()
        } while again
    }

    // ActivityKit's SDK object is not Sendable. Transfer only values across the async boundary
    // and resolve an activity locally in the executor that performs the SDK call.
    private nonisolated static func update(id: String, summary: LiveActivitySummary) async {
        guard let activity = KnarrActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: summary, staleDate: .now.addingTimeInterval(900)))
    }

    private nonisolated static func end(id: String, final: LiveActivitySummary?, immediately: Bool) async {
        guard let activity = KnarrActivity.activities.first(where: { $0.id == id }) else { return }
        let content = final.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: immediately ? .immediate : .after(.now.addingTimeInterval(60)))
    }

    private func watch(_ activity: KnarrActivity) {
        guard watched.insert(activity.id).inserted else { return }
        observers.append(Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                if (state == .dismissed || state == .ended), !self.ending.contains(activity.id), !activity.content.state.isFinished {
                    self.policy.dismissedAt = .now
                    self.defaults.set(self.policy.dismissedAt, forKey: "knarr.activity.dismissed")
                }
                await self.publishDevice()
                if state == .ended || state == .dismissed { return }
            }
        })
        if !sample {
            observers.append(Task { [weak self] in
                for await _ in activity.pushTokenUpdates {
                    guard let self, !Task.isCancelled else { return }
                    await self.publishDevice()
                }
            })
        }
    }

    private func publishDevice() async {
        guard !sample else { return }
        if publishing { publishAgain = true; return }
        publishing = true
        defer { publishing = false }
        repeat {
        publishAgain = false
        let activity = current
        let environment: MobileActivityDevice.Environment
        #if DEBUG
        environment = .sandbox
        #else
        environment = .production
        #endif
        var value = MobileActivityDevice(id: deviceID, environment: environment,
            enabled: ActivityAuthorizationInfo().areActivitiesEnabled, startToken: startToken,
            activityID: activity?.id, updateToken: activity?.pushToken?.map { String(format: "%02x", $0) }.joined(),
            dismissedAt: policy.dismissedAt, content: activity?.content.state, updatedAt: .now)
        if let lastPublished {
            value.updatedAt = lastPublished.updatedAt
            if value == lastPublished { continue }
            value.updatedAt = .now
        }
        if await publish?(value) == true { lastPublished = value }
        } while publishAgain
    }
}
