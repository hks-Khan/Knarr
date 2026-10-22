import Foundation
import Testing
import CSQLite
@testable import KnarrCore

@Suite(.serialized) struct SnapshotPerformanceTests {
    @Test func externalWritesInvalidateDecodedRunCache() async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.issue("cache")
            let run = try await f.dispatch("cache-run", issue: issue)
            _ = try await f.repository.snapshot()
            let writer = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: SQLITE_OPEN_READWRITE)
            do {
                try writer.execute("UPDATE runs SET payload=json_set(payload,'$.stopReason','external-change') WHERE id=?", [run.rawValue])
                #expect(try await f.repository.snapshot().runs.first?.stopReason == "external-change")
                try writer.close()
            } catch { try writer.close(); throw error }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_PERF_FIXTURE"] != nil))
    func compareColdAndCachedSnapshotsOnOwnedCopy() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["KNARR_PERF_FIXTURE"])
        #expect(path.contains("/outputs/performance/"))
        guard path.contains("/outputs/performance/") else { return }
        let repo = try await SQLiteKnarrRepository.open(at: URL(fileURLWithPath: path))
        let writer = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE)
        do {
            _ = try await repo.snapshot()
            var cold: [Double] = [], warm: [Double] = []
            for _ in 0..<8 {
                try writer.execute("UPDATE projects SET payload=payload || ' ' WHERE id=(SELECT id FROM projects LIMIT 1)")
                var start = Date.timeIntervalSinceReferenceDate
                let first = try await repo.snapshot()
                cold.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
                start = Date.timeIntervalSinceReferenceDate
                let second = try await repo.snapshot()
                warm.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
                #expect(first.runs == second.runs)
                #expect(first.issues == second.issues)
            }
            let result: [String: Any] = ["coldMs": cold, "cachedMs": warm,
                "coldMeanMs": cold.reduce(0,+)/Double(cold.count), "cachedMeanMs": warm.reduce(0,+)/Double(warm.count)]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("snapshot-timing.json"))
            print("SNAPSHOT_TIMING " + String(decoding: data, as: UTF8.self))
            try writer.close(); try await repo.close()
        } catch { try writer.close(); try await repo.close(); throw error }
    }
}
