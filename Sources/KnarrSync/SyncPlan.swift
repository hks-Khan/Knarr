import Foundation

/// Decides which records to upload so an unchanged snapshot costs nothing.
/// Remembers what the cloud holds only after `commit`, i.e. after an upload succeeded.
public struct SyncPlan: Sendable {
    public struct Changes: Sendable, Equatable {
        public var saves: [MobileRecord]
        public var deletes: [String]
        public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
    }

    private var uploaded: [String: MobileRecord] = [:]

    public init() {}

    public func changes(to snapshot: [MobileRecord]) -> Changes {
        var seen = Set<String>()
        var saves: [MobileRecord] = []
        for record in snapshot {
            let name = record.recordName
            guard seen.insert(name).inserted else { continue }
            if uploaded[name] != record { saves.append(record) }
        }
        let deletes = uploaded.filter { !seen.contains($0.key) && $0.value.kind.isSnapshot }.map(\.key).sorted()
        return Changes(saves: saves, deletes: deletes)
    }

    public mutating func commit(_ changes: Changes) {
        for record in changes.saves { uploaded[record.recordName] = record }
        for name in changes.deletes { uploaded[name] = nil }
    }

    /// Forget everything, e.g. after the zone was reset, so the next snapshot is uploaded whole.
    public mutating func reset() { uploaded = [:] }
}
