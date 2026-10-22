import CloudKit
import Foundation
import KnarrCore
import KnarrSync
import Observation
import os
import Security

/// Everything the phone projection reads, copied off the main thread once per sync. All values are
/// sendable, so the file reads and record building happen away from the screen.
public struct MobileProjectionSource: Sendable {
    public var issues: [Issue]
    public var questions: [Question]
    public var chat: [ChatItem]
    public var projects: [ProjectSummary]
    public var stallari: StallariInfo
    public var isResponding: Bool
    public var threads: [ConversationThread]
    public var chatByThread: [String: [ChatItem]]
    public var liveActivityRemoteEnabled: Bool
    public var keepMessages: Set<String>

    public init(issues: [Issue], questions: [Question], chat: [ChatItem], projects: [ProjectSummary],
                stallari: StallariInfo, isResponding: Bool, threads: [ConversationThread],
                chatByThread: [String: [ChatItem]], liveActivityRemoteEnabled: Bool = false,
                keepMessages: Set<String> = []) {
        self.issues = issues; self.questions = questions; self.chat = chat; self.projects = projects
        self.stallari = stallari; self.isResponding = isResponding; self.threads = threads
        self.chatByThread = chatByThread; self.liveActivityRemoteEnabled = liveActivityRemoteEnabled
        self.keepMessages = keepMessages
    }

    /// Builds every record the phone reads. Safe off the main thread: it only reads file paths
    /// already stored in the Issues.
    public func records(now: Date = .now) -> [MobileRecord] {
        MobileProjection.records(issues: issues, questions: questions, chat: chat, projects: projects,
            stallari: stallari, isResponding: isResponding, now: now, threads: threads,
            chatByThread: chatByThread, keepMessages: keepMessages).map { record in
                guard case .status(var value) = record else { return record }
                value.liveActivityRemoteEnabled = liveActivityRemoteEnabled
                return .status(value)
            }
    }
}

/// Keeps the phone in step with the Mac: uploads what changed after the store changes, and applies the
/// requests the phone writes. Pushes are immediate; a 15-second inbox check recovers missed pushes.
@MainActor @Observable
public final class CloudMirror {
    public enum State: Equatable, Sendable {
        case off(String)
        case starting
        case on(syncedAt: Date?)
        case failing(String)
    }

    public private(set) var state: State = .off("시작 전")

    @ObservationIgnored private let log = Logger(subsystem: "com.kyen.knarr", category: "mobile")
    @ObservationIgnored private var engine: CloudSyncEngine?
    @ObservationIgnored private var activityRelay: LiveActivityRelay?
    @ObservationIgnored private var replaceActivityDevices = false
    @ObservationIgnored private var plan = SyncPlan()
    @ObservationIgnored private var detector = MobileAlertDetector()
    @ObservationIgnored private var pendingAlerts: [MobileAlert] = []
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var retryDelay: Duration = .seconds(30)
    @ObservationIgnored private var receiver: MobileRequestReceiver?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var readStore: (() -> MobileProjectionSource)?
    @ObservationIgnored private var stallariState: (() -> ([Issue], [Question], [ChatItem]))?
    @ObservationIgnored private var applyRequest: ((MobileRequest) async throws -> Void)?
    @ObservationIgnored private var touchStore: (() -> Void)?
    /// Message IDs the phone asked to keep, i.e. older pages it has paged through.
    /// Older pages the phone has paged through; kept in CloudKit until the thread's limit pushes them out.
    @ObservationIgnored private var historyLedger = MobileHistoryLedger()
    @ObservationIgnored private var keptMessageIDs: Set<String> { historyLedger.messageIDs }
    /// Reads one page of a conversation's saved messages, oldest pages first.
    @ObservationIgnored private var historyPage: ((String, Date) async -> [MobileMessage])?
    static let historyKey = "knarr.cloud.mac.history"

    /// How long sent alerts stay in the cloud; the push already went out when they were created.
    static let alertLifetime: TimeInterval = 6 * 3600
    static let appliedKey = "knarr.cloud.mac.appliedRequests"
    static let alertsKey = "knarr.cloud.mac.sentAlerts"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults; loadHistory() }

    /// Whether this build was signed with the iCloud container. `swift run` builds are not, and must not touch CloudKit.
    public nonisolated static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(MobileZone.container) == true
    }

    /// `KNARR_CLOUD_SEED_SCHEMA=1`: create the record types in this build's CloudKit environment, then quit.
    /// Run with a Development build before deploying the schema to Production.
    public nonisolated static func seedSchemaAndExit() -> Never {
        guard isEntitled else { print("iCloud 권한이 있는 서명 빌드가 아니에요"); exit(1) }
        let done = DispatchSemaphore(value: 0)
        let outcome = OSAllocatedUnfairLock<String?>(initialState: nil)
        Task.detached {
            do { try await CloudSyncEngine(role: "seed").seedSchema() } catch { outcome.withLock { $0 = String(describing: error) } }
            done.signal()
        }
        done.wait()
        if let error = outcome.withLock({ $0 }) { print("스키마 만들기 실패: \(error)"); exit(1) }
        print("스키마 만들기 완료: \(MobileRecord.Kind.allCases.map { CloudWire.recordType($0) }.joined(separator: ", "))")
        exit(0)
    }

    public func start(store: some KnarrStore) {
        guard engine == nil else { return }
        if ProcessInfo.processInfo.environment["KNARR_MOBILE"] == "0" { state = .off("KNARR_MOBILE=0으로 꺼져 있어요"); return }
        guard Self.isEntitled else { state = .off("iCloud 권한이 있는 서명 빌드가 아니에요"); return }
        readStore = { [unowned store, weak self] in
            MobileProjectionSource(issues: store.issues.filter { !store.preparationSourceIDs.contains($0.id) }, questions: store.questions, chat: store.chat,
                projects: store.projects, stallari: store.stallari, isResponding: store.isResponding,
                threads: store.threads, chatByThread: store.chatByThread,
                liveActivityRemoteEnabled: self?.activityRelay != nil,
                keepMessages: self?.keptMessageIDs ?? [])
        }
        stallariState = { [unowned store] in (store.issues.filter { !store.preparationSourceIDs.contains($0.id) }, store.questions, store.chat) }
        applyRequest = { [unowned store] request in
            try await MobileRequestApplier.apply(request.kind, to: store,
                                                 attachments: MobileRequestApplier.defaultAttachmentDirectory,
                                                 request: request.id)
        }
        historyPage = { [unowned store] thread, before in
            let titles = Dictionary(store.issues.map { ($0.id, $0.title) }, uniquingKeysWith: { $1 })
            return MobileProjection.history(items: store.chatByThread[thread] ?? [], thread: thread, before: before,
                                            titles: titles, questions: store.questions, reports: store.workReports)
        }
        touchStore = { [unowned store] in
            _ = store.issues; _ = store.preparationSourceIDs; _ = store.questions; _ = store.chat; _ = store.projects; _ = store.isResponding
        }
        let engine = CloudSyncEngine(role: "mac")
        self.engine = engine
        receiver = MobileRequestReceiver(defaults: defaults, fetch: { [weak self] in
            let fetched = try await engine.fetchChanges()
            self?.activityRelay?.ingest(saved: fetched.saved, deleted: fetched.deleted, replacingDevices: self?.replaceActivityDevices ?? false)
            self?.replaceActivityDevices = false
            if self?.activityRelay != nil { self?.scheduleSync(after: .zero) }
            return fetched.saved.compactMap { if case .request(let r) = $0 { r } else { nil } }
        }, reset: { await engine.resetChangeToken() }, acknowledge: { names in
            try await engine.upload(saving: [], deleting: names)
        }, apply: { [weak self] request in
            guard let self, let applyRequest = self.applyRequest else { throw CancellationError() }
            if case .loadOlder(let thread, let before) = request.kind {
                try await self.serveHistory(thread: thread, before: before)
                return
            }
            if let issue = request.kind.proposalIssue {
                // Keep the outcome across an upload failure or Mac restart. Retrying transport
                // must not turn an accepted review into a duplicate rejection.
                let key = "knarr.phoneProposalReceipts"
                var receipts = self.defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
                let receipt: MobileAlert
                if let data = receipts[request.id] {
                    receipt = try JSONDecoder().decode(MobileAlert.self, from: data)
                } else {
                    var failure: String?
                    do { try await applyRequest(request) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as StallariError {
                        if case .rejectedEvidence(let reason) = error { failure = reason }
                        else { failure = "제안의 버전·상태를 확인한 뒤 다시 요청해 주세요" }
                    }
                    catch let error as PersistenceError { failure = error.message }
                    catch { failure = error.localizedDescription }
                    receipt = MobileAlert(id: "proposal-result-\(request.id)", createdAt: .now,
                        title: failure == nil ? "제안 요청을 처리했어요" : "제안 요청을 처리하지 못했어요",
                        body: failure ?? "Mac에서 표시된 제안 버전의 요청을 처리했어요", issue: issue,
                        requestID: request.id, requestFailure: failure)
                    receipts[request.id] = try JSONEncoder().encode(receipt)
                    if receipts.count > 300 {
                        let oldest = receipts.compactMap { id, data -> (String, Date)? in
                            (try? JSONDecoder().decode(MobileAlert.self, from: data)).map { (id, $0.createdAt) }
                        }.sorted { $0.1 < $1.1 }
                        for (id, _) in oldest.prefix(receipts.count - 300) { receipts[id] = nil }
                    }
                    self.defaults.set(receipts, forKey: key)
                }
                try await engine.upload(saving: [.alert(receipt)], deleting: [])
            } else {
                try await applyRequest(request)
            }
            if case .message = request.kind { self.detector.expectReply() }
            if case .threadMessage = request.kind { self.detector.expectReply() }
            self.log.info("phone request accepted \(request.id, privacy: .public)")
        }, failed: { [weak self] error in self?.fail(error) })
        state = .starting
        startup = Task {
            var startupRetry: Duration = .seconds(15)
            while !Task.isCancelled {
                do {
                    let status = try await engine.accountStatus()
                    guard status == .available else { state = .off(Self.describe(status)); self.engine = nil; return }
                    try await engine.ensureZone()
                    try await engine.subscribeMacToRequests()
                    try Task.checkCancellation()
                    if let sender = LiveActivityAPNs.configured() {
                        do {
                            try await engine.subscribeMacToActivityDevices()
                            activityRelay = LiveActivityRelay(defaults: defaults) { try await sender.send($0) }
                            // Reconcile device registrations even if a previous Mac build advanced the zone cursor.
                            await engine.resetChangeToken()
                            replaceActivityDevices = true
                        } catch {
                            log.error("Live Activity device subscription is unavailable; phone sync remains active")
                        }
                    }
                    try Task.checkCancellation()
                    log.info("cloud mirror ready")
                    // Everything already in the cloud was written by an earlier run; upload the current snapshot whole.
                    plan.reset()
                    _ = detector.alerts(issues: store.issues.filter { !store.preparationSourceIDs.contains($0.id) }, questions: store.questions, chat: store.chat, now: .now)
                    observe()
                    receiver?.start()
                    scheduleSync(after: .zero)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    fail(error)
                    let delay = max(startupRetry, (error as? CKError)?.retryAfterSeconds.map { Duration.seconds($0) } ?? .zero)
                    do { try await Task.sleep(for: delay) } catch { return }
                    startupRetry = min(startupRetry * 2, .seconds(300))
                }
            }
        }
    }

    /// Called for CloudKit pushes and when Knarr comes to the front: apply any requests the phone sent.
    public func pullRequests() async { await receiver?.pull() }

    /// Called while Knarr quits: tell the phone the Mac is off, waiting at most three seconds.
    public func goOffline() async {
        startup?.cancel()
        await startup?.value
        startup = nil
        await receiver?.stop()
        receiver = nil
        scheduled?.cancel()
        guard let engine, let readStore else { return }
        let source = readStore()
        let offline = MobileRecord.status(MobileStatus(isResponding: false, engine: source.stallari.engine, macRunning: false))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await engine.upload(saving: [offline], deleting: []) }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
        scheduled?.cancel()
        self.engine = nil
    }

    private func observe() {
        withObservationTracking { touchStore?() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleSync(after: .seconds(2))
                self?.observe()
              }
        }
    }

    private func scheduleSync(after delay: Duration) {
        if syncing { dirty = true; return }
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        scheduled = nil
        guard let engine, let readStore, let stallariState else { return }
        syncing = true
        var retry: Duration?
        defer {
            syncing = false
            // A failed upload waits out its backoff; changes made meanwhile ride along with the retry.
            if let retry { dirty = false; scheduleSync(after: retry) } else if dirty { dirty = false; scheduleSync(after: .seconds(2)) }
        }
        let (issues, questions, chat) = stallariState()
        pendingAlerts += detector.alerts(issues: issues, questions: questions, chat: chat, now: .now)
        let source = readStore()
        // Report text and screenshot thumbnails are read from disk and JPEG-encoded. That work stays
        // on a background thread; only the plan and the upload talk to the main actor again.
        let records = await Task.detached(priority: .utility) { source.records() }.value
        let changes = plan.changes(to: records)
        let expired = expiredAlerts()
        guard !changes.isEmpty || !pendingAlerts.isEmpty || !expired.isEmpty else {
            await activityRelay?.refresh(records: records)
            return
        }
        let alerts = pendingAlerts
        do {
            try await engine.upload(saving: changes.saves + alerts.map(MobileRecord.alert), deleting: changes.deletes + expired)
            plan.commit(changes)
            pendingAlerts.removeAll { sent in alerts.contains(sent) }
            remember(sent: alerts, forgetting: expired)
            retryDelay = .seconds(30)
            state = .on(syncedAt: .now)
            await activityRelay?.refresh(records: records)
            log.info("cloud sync saved \(changes.saves.count + alerts.count, privacy: .public) deleted \(changes.deletes.count + expired.count, privacy: .public)")
        } catch {
            fail(error)
            retry = (error as? CKError)?.retryAfterSeconds.map { Duration.seconds($0) } ?? retryDelay
            retryDelay = min(retryDelay * 2, .seconds(600))
        }
    }

    /// Answers one page request: upload the older messages, remember them so the next snapshot keeps
    /// them, and delete the page that fell past the thread's limit. Re-answering the same page rewrites
    /// the same record names, so a retry cannot duplicate a message.
    private func serveHistory(thread: String, before: Date) async throws {
        guard let engine, let historyPage else { return }
        let page = await historyPage(thread, before)
        let dropped = historyLedger.retain(page, thread: thread)
        saveHistory()
        try await engine.upload(saving: page.map(MobileRecord.message), deleting: dropped.map { "message-\($0)" })
        scheduleSync(after: .zero)
        log.info("phone history page served \(page.count, privacy: .public)")
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Self.historyKey),
              let value = try? JSONDecoder().decode([String: [MobileHistoryLedger.Entry]].self, from: data) else { return }
        historyLedger = MobileHistoryLedger(byThread: value.mapValues { $0.map { ($0.id, $0.at) } })
    }

    private func saveHistory() {
        let value = historyLedger.byThread.mapValues { $0.map { MobileHistoryLedger.Entry(id: $0.id, at: $0.at) } }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    private func expiredAlerts() -> [String] {
        let sent = defaults.dictionary(forKey: Self.alertsKey) as? [String: Double] ?? [:]
        let cutoff = Date.now.addingTimeInterval(-Self.alertLifetime).timeIntervalSince1970
        return sent.filter { $0.value < cutoff }.map(\.key).sorted()
    }

    private func remember(sent alerts: [MobileAlert], forgetting expired: [String]) {
        var sent = defaults.dictionary(forKey: Self.alertsKey) as? [String: Double] ?? [:]
        for name in expired { sent[name] = nil }
        for alert in alerts { sent[MobileRecord.alert(alert).recordName] = alert.createdAt.timeIntervalSince1970 }
        defaults.set(sent, forKey: Self.alertsKey)
    }

    private func fail(_ error: any Error) {
        log.error("cloud sync failed: \(String(describing: error), privacy: .public)")
        state = .failing(error.localizedDescription)
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: "이 Mac에 iCloud 로그인이 없어요"
        case .restricted: "iCloud 사용이 제한돼 있어요"
        case .temporarilyUnavailable: "iCloud를 잠시 쓸 수 없어요"
        case .couldNotDetermine: "iCloud 상태를 확인하지 못했어요"
        case .available: "사용 가능"
        @unknown default: "알 수 없는 iCloud 상태"
        }
    }
}
