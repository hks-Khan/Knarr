import Foundation
import OSLog

/// One app-owned service. Snapshot-driven, with no timer, polling or automatic retry loop.
@MainActor public final class DesktopNotificationService {
    private struct Ledger: Codable, Equatable {
        var baselined = false
        var suppressed: Set<String> = []
        var pending: [String: DesktopNotificationEvent.Target] = [:]
        // Persisted before add. A crash with no OS receipt is ambiguous, never permission to replay.
        var uncertain: [String: DesktopNotificationEvent.Target] = [:]
        var delivered: [String: DesktopNotificationEvent.Target] = [:]
    }
    private let client: any DesktopNotificationClient
    private let ledgerURL: URL
    private var ledger: Ledger
    private var savedLedger: Ledger
    private var events: [DesktopNotificationEvent] = []
    private var attempted: Set<String> = []
    private var latest: PersistenceSnapshot?
    private var queuedClicks: [String] = []
    private var authorization: DesktopNotificationAuthorization?
    private var draining = false
    private var dirty = false
    private let logger = Logger(subsystem: "com.kyen.knarr", category: "desktop-notifications")
    public private(set) var status: DesktopNotificationStatus = .notDetermined {
        didSet { if oldValue != status { statusChanged?(status) } }
    }
    public var statusChanged: ((DesktopNotificationStatus) -> Void)?
    public var currentSnapshot: (() async throws -> PersistenceSnapshot)?
    public var activate: (() -> Void)?
    public var selectThread: ((String) -> Void)?
    public var observed: ((String) -> Void)?
    public var deliveredIDs: Set<String> { Set(ledger.delivered.keys) }

    public init(client: any DesktopNotificationClient, ledgerURL: URL) throws {
        self.client = client; self.ledgerURL = ledgerURL
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let values = try ledgerURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
            ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledgerURL))
        } else { ledger = Ledger() }
        savedLedger = ledger
    }
    private func save() throws {
        guard ledger != savedLedger else { return }
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        savedLedger = ledger
    }

    /// Binds committed snapshots and safe click navigation to the app's live store.
    public func connect(to store: LiveKnarrStore, activate: @escaping () -> Void) {
        self.activate = activate
        selectThread = { [weak store] in store?.openNotificationThread($0) }
        currentSnapshot = { [weak store] in
            guard let store else { throw StallariError.closed }
            return try await store.currentNotificationSnapshot()
        }
        statusChanged = { [weak store] in store?.desktopNotificationStatus = $0 }
        store.desktopNotificationStatus = status
        store.desktopNotificationSnapshot = { [weak self] snapshot in
            Task { await self?.observe(snapshot) }
        }
    }
    private func failed(_ error: any Error, operation: String) {
        status = .failed
        let error = error as NSError
        // Codes only: errors may carry paths, request content or other private userInfo.
        logger.error("\(operation, privacy: .public) failed domain=\(error.domain, privacy: .public) code=\(error.code)")
        observed?("\(operation)-failed:\(error.domain):\(error.code)")
    }

    public func observe(_ snapshot: PersistenceSnapshot) async {
        latest = snapshot
        events = DesktopNotificationEvent.events(in: snapshot)
        if !ledger.baselined {
            ledger.suppressed.formUnion(events.map(\.id))
            ledger.baselined = true
            do { try save(); observed?("startup-baseline") }
            catch { ledger.baselined = false; failed(error, operation: "baseline"); return }
        }
        let clicks = queuedClicks; queuedClicks.removeAll()
        for id in clicks { await open(id) }
        dirty = true
        await drain()
    }

    public func refreshAuthorization() async {
        let current = await client.authorizationStatus()
        let changed = current != authorization
        if changed { attempted.removeAll() }
        authorization = current
        if changed || status != .failed { updateStatus(current) }
        dirty = true
        await drain()
    }
    private func updateStatus(_ value: DesktopNotificationAuthorization) {
        switch value {
        case .authorized: status = .ready
        case .denied: status = .denied
        case .notDetermined: status = .notDetermined
        }
    }
    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while dirty {
            dirty = false
            guard latest != nil, ledger.baselined else { continue }
            let all = events
            // If final judgement arrived before posting, it replaces the run-complete banner.
            let finalIssues = Set(all.filter { $0.kind == .issueCompleted || $0.kind == .issueFailed }.map { $0.target.issueID })
            let superseded = all.filter { $0.kind == .hirdCompleted && finalIssues.contains($0.target.issueID) }
            ledger.suppressed.formUnion(superseded.map(\.id))
            let eligible = all.filter { !ledger.suppressed.contains($0.id) && ledger.delivered[$0.id] == nil }
            ledger.pending = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0.target) })
            do { try save() } catch { failed(error, operation: "outbox"); return }
            let candidates = eligible.filter { !attempted.contains($0.id) }
            guard !candidates.isEmpty else { continue }
            attempted.formUnion(candidates.map(\.id))
            var permission = await client.authorizationStatus()
            authorization = permission
            updateStatus(permission)
            if permission == .notDetermined {
                do { permission = try await client.requestAuthorization() ? .authorized : .denied }
                catch { failed(error, operation: "authorization"); continue }
                authorization = permission
                updateStatus(permission)
            }
            guard permission == .authorized else { continue }
            let accepted = await client.acceptedIdentifiers()
            for event in candidates {
                // Recheck after native awaits: resolved questions/revised proposals must not leak through.
                guard events.contains(event) else { continue }
                if event.kind == .hirdCompleted,
                   events.contains(where: { $0.target.issueID == event.target.issueID && ($0.kind == .issueCompleted || $0.kind == .issueFailed) }) { continue }
                let receiptTarget = ledger.uncertain[event.id] ?? event.target
                if !accepted.contains(event.id) {
                    if ledger.uncertain[event.id] != nil {
                        status = .failed
                        logger.error("Native send outcome is uncertain; refusing replay for \(event.id, privacy: .public)")
                        observed?("send-uncertain:\(event.id)")
                        continue
                    }
                    ledger.uncertain[event.id] = event.target
                    do { try save() }
                    catch { failed(error, operation: "send-intent"); continue }
                    do { try await client.send(event) }
                    catch {
                        ledger.uncertain.removeValue(forKey: event.id)
                        failed(error, operation: "send")
                        do { try save() }
                        catch { failed(error, operation: "send-failure-receipt") }
                        continue
                    }
                }
                ledger.delivered[event.id] = receiptTarget
                ledger.pending.removeValue(forKey: event.id)
                ledger.uncertain.removeValue(forKey: event.id)
                do { try save(); observed?("accepted:\(event.kind.rawValue):\(event.id)") }
                catch { failed(error, operation: "send-receipt") }
            }
        }
    }

    /// Called only for a verified native response; the payload is an opaque local ID, never an action.
    /// A cold-start click waits for the first committed repository snapshot and a mounted UI.
    /// A response also proves OS acceptance across an interrupted receipt write.
    public func open(_ id: String) async {
        guard let target = ledger.delivered[id] ?? ledger.uncertain[id] ?? ledger.pending[id] else { observed?("click-invalid"); return }
        guard let latest, let selectThread, let activate else {
            if !queuedClicks.contains(id) { queuedClicks.append(id) }
            return
        }
        let snapshot: PersistenceSnapshot
        do { snapshot = try await currentSnapshot?() ?? latest }
        catch { failed(error, operation: "click-snapshot"); return }
        guard let current = DesktopNotificationEvent.events(in: snapshot).first(where: { $0.id == id }),
              current.target == target else { observed?("click-stale"); return }
        if ledger.delivered[id] == nil {
            ledger.delivered[id] = target
            ledger.pending.removeValue(forKey: id)
            ledger.uncertain.removeValue(forKey: id)
            do { try save(); observed?("accepted-native-response:\(id)") }
            catch { failed(error, operation: "click-receipt"); return }
        }
        activate()
        selectThread(current.target.threadID)
        observed?("click-routed:\(id)")
    }
}
