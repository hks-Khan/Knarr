import Foundation
import Testing
import CSQLite
@testable import KnarrCore

@Suite(.serialized) struct ActivityHistoryCacheTests {
    // Buffer reuse is the performance contract: Array equality can skip unchanged histories.
    private func sharesStorage(_ lhs: [ActivityEvent], _ rhs: [ActivityEvent]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }
    private func events(_ snapshot: PersistenceSnapshot, _ issue: KnarrCore.Issue.ID) throws -> [ActivityEvent] {
        try #require(snapshot.issues.first { $0.id == issue }).events
    }
    private func fixture(_ body: (StallariFixture) async throws -> Void) async throws {
        let f = try await StallariFixture.make()
        do { try await body(f); try await f.cleanup() }
        catch { try await f.cleanup(); throw error }
    }

    @Test func unrelatedWritesReuseHistoryWithoutLosingIssueUpdates() async throws {
        try await fixture { f in
            let id = try await f.issue("history")
            let entry = ActivityEvent(at: .now, actor: "Hird", text: "saved")
            try await f.repository.appendActivity(entry, issueID: id)
            let before = try await f.repository.snapshot(includeHistory: false)
            var issue = try #require(before.issues.first)
            issue.events = []; issue.headline = "changed metadata"
            try await f.repository.saveIssue(issue, projectID: "p")
            let after = try await f.repository.snapshot(includeHistory: false)
            #expect(after.issues.first?.headline == "changed metadata")
            #expect(try events(after, id) == [entry])
            #expect(try sharesStorage(events(before, id), events(after, id)))
            let repeated = try await f.repository.snapshot(includeHistory: false)
            #expect(try sharesStorage(events(after, id), events(repeated, id)))
        }
    }

    @Test func appendingOnlyRebuildsChangedIssueAndPreservesOlderSnapshots() async throws {
        try await fixture { f in
            let a = try await f.issue("a"), b = try await f.issue("b")
            let first = ActivityEvent(at: Date(timeIntervalSince1970: 20), actor: "Hird", text: "first")
            let second = ActivityEvent(at: Date(timeIntervalSince1970: 10), actor: "Hird", text: "inserted later")
            try await f.repository.appendActivity(first, issueID: a)
            try await f.repository.appendActivity(.init(at: .now, actor: "Hird", text: "unchanged"), issueID: b)
            let before = try await f.repository.snapshot(includeHistory: false)
            try await f.repository.appendActivity(second, issueID: a)
            let after = try await f.repository.snapshot(includeHistory: false)
            #expect(try events(before, a) == [first])
            #expect(try events(after, a) == [first, second], "Keep insertion order, including late timestamps")
            #expect(try sharesStorage(events(before, b), events(after, b)))
            try await f.repository.appendActivity(second, issueID: a)
            let duplicate = try await f.repository.snapshot(includeHistory: false)
            #expect(try sharesStorage(events(after, a), events(duplicate, a)))
        }
    }

    @Test func externalEditsMovesAndDeletesInvalidateHistory() async throws {
        try await fixture { f in
            let a = try await f.issue("a"), b = try await f.issue("b")
            let first = ActivityEvent(at: .now, actor: "Hird", text: "before")
            let second = ActivityEvent(at: .now, actor: "Hird", text: "remove")
            try await f.repository.appendActivity(first, issueID: a)
            try await f.repository.appendActivity(second, issueID: a)
            let before = try await f.repository.snapshot(includeHistory: false)
            let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: SQLITE_OPEN_READWRITE)
            do {
                try writer.execute("UPDATE activities SET issue_id=?, payload=json_set(payload,'$.text','edited') WHERE id=?", [b.rawValue, first.id.uuidString])
                let moved = try await f.repository.snapshot(includeHistory: false)
                #expect(try events(moved, a) == [second])
                #expect(try events(moved, b).map(\.text) == ["edited"])
                #expect(try events(before, a) == [first, second])
                try writer.execute("DELETE FROM activities WHERE id=?", [second.id.uuidString])
                let deleted = try await f.repository.snapshot(includeHistory: false)
                #expect(try events(deleted, a).isEmpty)
                #expect(try events(deleted, b).count == 1)
                try writer.close()
            } catch { try writer.close(); throw error }
        }
    }

    @Test func failedWriteAndChangeTrackingOverflowPreserveEveryEvent() async throws {
        try await fixture { f in
            let id = try await f.issue("overflow")
            let first = ActivityEvent(at: .now, actor: "Hird", text: "original")
            try await f.repository.appendActivity(first, issueID: id)
            _ = try await f.repository.snapshot(includeHistory: false)
            var collision = first; collision.text = "must not persist"
            await #expect(throws: PersistenceError.self) {
                try await f.repository.appendActivity(collision, issueID: id)
            }
            #expect(try events(await f.repository.snapshot(includeHistory: false), id) == [first])
            var expected = [first]
            // Exceed SQLiteConnection's bounded changed-row tracking, exercising a full reload.
            for index in 0..<2050 {
                let entry = ActivityEvent(at: first.at, actor: "Hird", text: "event-\(index)")
                expected.append(entry)
                try await f.repository.appendActivity(entry, issueID: id)
            }
            let after = try await f.repository.snapshot(includeHistory: false)
            #expect(try events(after, id) == expected)
            let repeated = try await f.repository.snapshot(includeHistory: false)
            #expect(try sharesStorage(events(after, id), events(repeated, id)))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_ACTIVITY_CACHE_PROFILE"] == "1"))
    func profileSeventyFiveThousandEventsWithRepeatedConversationComparisons() async throws {
        try await fixture { f in
            for index in 0..<50 { _ = try await f.issue("history-\(index)") }
            let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: SQLITE_OPEN_READWRITE)
            do {
                try writer.transaction {
                    try writer.execute("""
                        WITH RECURSIVE seq(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM seq WHERE x<74999)
                        INSERT INTO activities(id,issue_id,payload)
                        SELECT printf('00000000-0000-0000-0000-%012d',x), 'history-'||(x/1500),
                          json_object('id',printf('00000000-0000-0000-0000-%012d',x),
                                      'at',0,'actor','Hird','text','activity-'||x) FROM seq
                        """)
                }
                try writer.close()
            } catch { try writer.close(); throw error }
            let clock = ContinuousClock()
            var previous = try await f.repository.snapshot(includeHistory: false)
            #expect(previous.issues.reduce(0) { $0 + $1.events.count } == 75000)
            var snapshotMS: [Double] = [], comparisonMS: [Double] = []
            for index in 0..<8 {
                try await f.repository.appendActivity(.init(at: .now, actor: "Hird", text: "new-\(index)"), issueID: .init("history-49"))
                let start = clock.now
                let next = try await f.repository.snapshot(includeHistory: false)
                snapshotMS.append(milliseconds(start.duration(to: clock.now)))
                let compare = clock.now
                // Each open conversation checks all issues. Check all pairs deliberately so a
                // changed issue cannot hide costs in the other 49 histories by short-circuiting.
                for _ in 0..<12 {
                    var changed = 0
                    for (old, new) in zip(previous.issues, next.issues) { if old != new { changed += 1 } }
                    #expect(changed == 1)
                }
                comparisonMS.append(milliseconds(compare.duration(to: clock.now)))
                previous = next
            }
            #expect(previous.issues.reduce(0) { $0 + $1.events.count } == 75008)
            print("ACTIVITY_CACHE_PROFILE snapshotMS=\(snapshotMS) comparisonMS=\(comparisonMS)")
        }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
