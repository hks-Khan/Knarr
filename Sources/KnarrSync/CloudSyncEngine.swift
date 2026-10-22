import CloudKit
import Foundation

/// Talks to the `Knarr` zone in the person's private database. Used by both the Mac and the phone.
/// All record traffic is change-driven: a fetch happens on launch, on a push, or when the person pulls to refresh.
public actor CloudSyncEngine {
    public struct Fetched: Sendable {
        public var saved: [MobileRecord]
        public var deleted: [String]
        public var latestChange: Date?
    }

    public enum SubscriptionID {
        /// Mac: silent push when the phone writes a request.
        public static let macRequests = "knarr-mac-requests"
        /// Phone: visible notification per new alert.
        public static let phoneAlerts = "knarr-phone-alerts"
        /// Phone: silent push for any change, to refresh an open app.
        public static let phoneChanges = "knarr-phone-changes"
    }

    /// Throwaway zone for `seedSchema`, so seeding never touches the real records.
    public static let schemaSeedZone = "KnarrSchemaSeed"

    public let database: CKDatabase
    public let zoneID = CKRecordZone.ID(zoneName: MobileZone.name, ownerName: CKCurrentUserDefaultName)
    private let container: CKContainer
    private let defaults: UserDefaults
    private let tokenKey: String
    private var zoneReady = false

    /// - Parameters:
    ///   - role: separates the stored change token of the Mac and the phone ("mac", "phone").
    ///   - defaultsSuite: where the change token is kept; nil for the app's standard defaults.
    public init(containerIdentifier: String = MobileZone.container, role: String, defaultsSuite: String? = nil) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        tokenKey = "knarr.cloud.\(role).zoneToken"
    }

    public func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }

    public func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    /// Saves and deletes in batches CloudKit accepts. Saves overwrite the fields they carry without a change-tag check:
    /// the Mac owns every record type it writes, and the phone only creates requests.
    public func upload(saving records: [MobileRecord], deleting names: [String]) async throws {
        try await ensureZone()
        let saves = records.map { $0.cloudRecord(in: zoneID) }
        let deletes = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        var index = 0
        let batch = 300
        while index < max(saves.count, deletes.count) {
            let s = Array(saves[min(index, saves.count)..<min(index + batch, saves.count)])
            let d = Array(deletes[min(index, deletes.count)..<min(index + batch, deletes.count)])
            let result = try await withZoneRecovery {
                try await self.database.modifyRecords(saving: s, deleting: d, savePolicy: .changedKeys, atomically: false)
            }
            for (_, outcome) in result.saveResults { if case .failure(let error) = outcome { throw error } }
            for (_, outcome) in result.deleteResults {
                if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem { throw error }
            }
            index += batch
        }
    }

    /// Everything that changed in the zone since the last successful fetch on this device.
    public func fetchChanges() async throws -> Fetched {
        try await ensureZone()
        var token = storedToken()
        var fetched = Fetched(saved: [], deleted: [], latestChange: nil)
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                store(token: nil)
                continue
            } catch let error as CKError where error.code == .zoneNotFound {
                zoneReady = false
                try await ensureZone()
                continue
            }
            for (_, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result,
                      let record = try? MobileRecord(cloudRecord: modification.record) else { continue }
                fetched.saved.append(record)
                if record.kind != .activityDevice, let at = modification.record.modificationDate { fetched.latestChange = max(fetched.latestChange ?? at, at) }
            }
            fetched.deleted += changes.deletions.map(\.recordID.recordName)
            token = changes.changeToken
            store(token: token)
            if !changes.moreComing { break }
        }
        return fetched
    }

    /// Forget the change token so the next fetch returns the whole zone.
    public func resetChangeToken() { store(token: nil) }

    /// Creates every record type and field in this environment's schema by saving `MobileRecord.schemaSamples`
    /// into a throwaway zone, then deletes that zone. Only Development accepts new types this way.
    public func seedSchema() async throws {
        let zone = CKRecordZone.ID(zoneName: Self.schemaSeedZone, ownerName: CKCurrentUserDefaultName)
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        let result = try await database.modifyRecords(saving: MobileRecord.schemaSamples.map { $0.cloudRecord(in: zone) },
                                                      deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, outcome) in result.saveResults { if case .failure(let error) = outcome { throw error } }
        _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
        // Query subscription types must exist in Development before schema deployment.
        // Merely seeding record types leaves Production subscription creation rejected.
        try await subscribeMacToRequests()
        try await subscribeMacToActivityDevices()
        try await subscribePhone()
    }

    public func subscribeMacToRequests() async throws {
        let subscription = CKQuerySubscription(recordType: MobileRecord.Kind.request.rawValue, predicate: NSPredicate(value: true),
                                               subscriptionID: SubscriptionID.macRequests, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        subscription.zoneID = zoneID
        try await save(subscription)
    }

    public func subscribeMacToActivityDevices() async throws {
        let devices = CKQuerySubscription(recordType: MobileRecord.Kind.activityDevice.rawValue,
            predicate: NSPredicate(value: true), subscriptionID: "knarr-mac-activity-devices",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let deviceInfo = CKSubscription.NotificationInfo(); deviceInfo.shouldSendContentAvailable = true
        devices.notificationInfo = deviceInfo; devices.zoneID = zoneID
        try await save(devices)
    }

    public func subscribePhone() async throws {
        let alerts = CKQuerySubscription(recordType: MobileRecord.Kind.alert.rawValue, predicate: NSPredicate(value: true),
                                         subscriptionID: SubscriptionID.phoneAlerts, options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        info.desiredKeys = [CloudWire.issueReferenceKey]
        alerts.notificationInfo = info
        alerts.zoneID = zoneID
        try await save(alerts)

        let changes = CKDatabaseSubscription(subscriptionID: SubscriptionID.phoneChanges)
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        changes.notificationInfo = silent
        try await save(changes)
    }

    private func save(_ subscription: CKSubscription) async throws {
        try await ensureZone()
        let result = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        try Self.checkSubscriptionSaved(id: subscription.subscriptionID, results: result.saveResults)
    }

    nonisolated static func checkSubscriptionSaved(id: CKSubscription.ID,
        results: [CKSubscription.ID: Result<CKSubscription, any Error>]) throws {
        // The operation can succeed while an individual subscription is rejected.
        guard let result = results[id] else {
            throw CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: "CloudKit returned no save result for subscription \(id)"])
        }
        _ = try result.get()
    }

    private func withZoneRecovery<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as CKError where error.code == .zoneNotFound
            || (error.code == .partialFailure && error.partialErrorsByItemID?.values.contains { ($0 as? CKError)?.code == .zoneNotFound } == true) {
            zoneReady = false
            try await ensureZone()
            return try await body()
        }
    }

    private func storedToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func store(token: CKServerChangeToken?) {
        if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            defaults.set(data, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
        }
    }
}
