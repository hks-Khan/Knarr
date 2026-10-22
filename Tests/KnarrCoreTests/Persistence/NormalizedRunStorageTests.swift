import Foundation
import Testing
import CSQLite
@testable import KnarrCore

@Suite(.serialized) struct NormalizedRunStorageTests {
    @Test func progressPayloadIsBoundedAndEveryResultAndVerificationSurvivesReopen() async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.issue("normalized")
            let run = try await f.dispatch("normalized-run", issue: issue)
            let verification = VerificationRecord(id: "immutable-verification", command: ["swift test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: f.directory.appendingPathComponent("check.log").path,
                summary: String(repeating: "검증 원문 ", count: 300))
            var expected: [RunResult] = []
            for index in 0..<35 {
                let result = RunResult(worktreePath: f.directory.path, branch: "branch", commit: "commit", diffPath: nil,
                                       summary: "서로 다른 보고 \(index)", verifications: [verification])
                expected.append(result)
                _ = try await f.repository.recordEvent(id: "result-\(index)", runID: run, at: .now, payload: .saveResult(result))
            }
            let sql = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: SQLITE_OPEN_READONLY)
            let payload = try #require(try sql.rows("SELECT payload FROM runs WHERE id=?", [run.rawValue]).first?.first)
            #expect(payload.utf8.count < 5000, "A progress update must not rewrite accumulated result history")
            #expect(!payload.contains("검증 원문"))
            #expect(try sql.rows("SELECT COUNT(*) FROM run_verifications") == [["1"]])
            #expect(try sql.rows("SELECT COUNT(*) FROM run_results") == [["35"]])
            #expect(try sql.rows("SELECT COUNT(*) FROM run_result_history") == [["35"]])
            try sql.close()
            // JSON key order is immaterial; every actual value and verification order is retained.
            let data = try JSONEncoder().encode(expected.last!)
            let reordered = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted])
            let same = try JSONDecoder().decode(RunResult.self, from: reordered)
            _ = try await f.repository.recordEvent(id: "same-values", runID: run, at: .now, payload: .saveResult(same))
            _ = try await f.repository.recordEvent(id: "progress", runID: run, at: .now,
                payload: .activity(.init(at: .now, actor: "Hird", text: "다음 단계"), currentCommand: "read", steps: nil))
            #expect(try await f.repository.snapshot(includeHistory: false).runs.first?.resultHistory.isEmpty == true)
            #expect(try await f.repository.readRun(run).resultHistory == expected)
            let summary = try await f.session.getRun(run)
            #expect(summary.resultHistory.isEmpty)
            #expect(summary.savedResultCount == expected.count)
            _ = await f.session.shutdown()
            try await f.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await reopened.readRun(run).resultHistory == expected)
            #expect(try await reopened.readRun(run).result == expected.last)
            try await reopened.close()
            try FileManager.default.removeItem(at: f.directory)
        } catch { try await f.cleanup(); throw error }
    }

    @Test func failedCompletionInvalidatesWarmedCachesAndPreservesLedger() async throws {
        let f = try await StallariFixture.make()
        do {
            let firstIssue = try await f.issue("cache-first")
            let firstRun = try await f.dispatch("cache-first-run", issue: firstIssue)
            _ = try await f.repository.recordEvent(id: "cache-completed", runID: firstRun, at: .now,
                payload: .complete(f.result(), notificationID: "cache-notice"))
            let secondIssue = try await f.issue("cache-second")
            let secondRun = try await f.dispatch("cache-second-run", issue: secondIssue)
            _ = try await f.repository.recordEvent(id: "cache-progress", runID: secondRun, at: .now, payload: .saveResult(f.result()))
            let before = try await f.repository.snapshot()
            let runBefore = try await f.repository.readRun(secondRun)
            let sql = try SQLiteConnection(path: f.directory.appendingPathComponent("knarr.db").path, flags: SQLITE_OPEN_READONLY)
            let ledgerBefore = try sql.rows("SELECT id,payload,outcome FROM run_events ORDER BY rowid")
            let historyBefore = try sql.rows("SELECT run_id,ordinal,result_id FROM run_result_history ORDER BY run_id,ordinal")
            await #expect(throws: PersistenceError.self) {
                _ = try await f.repository.recordEvent(id: "cache-rejected", runID: secondRun, at: .now,
                    payload: .complete(f.result(passing: false), notificationID: "cache-notice"))
            }
            #expect(try await f.repository.readRun(secondRun) == runBefore)
            #expect(try await f.repository.snapshot() == before)
            #expect(try sql.rows("SELECT id,payload,outcome FROM run_events ORDER BY rowid") == ledgerBefore)
            #expect(try sql.rows("SELECT run_id,ordinal,result_id FROM run_result_history ORDER BY run_id,ordinal") == historyBefore)
            try sql.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(arguments: ["hash", "gap", "event"])
    func corruptNormalizedEvidenceIsRejectedBeforeRecoveryWrites(kind: String) async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.issue("corrupt")
            let run = try await f.dispatch("corrupt-run", issue: issue)
            _ = try await f.repository.recordEvent(id: "result", runID: run, at: .now, payload: .saveResult(f.result()))
            _ = await f.session.shutdown(); try await f.repository.close()
            let url = f.directory.appendingPathComponent("knarr.db")
            let writer = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READWRITE)
            if kind == "hash" { try writer.execute("UPDATE run_verifications SET payload=json_set(payload,'$.summary','changed')") }
            else if kind == "gap" { try writer.execute("UPDATE run_result_history SET ordinal=1") }
            else {
                let payload = try #require(try writer.rows("SELECT payload FROM run_events WHERE id='result'").first?.first)
                let stored = try JSONDecoder().decode(NormalizedRunEvent.self, from: Data(payload.utf8))
                let old = stored.metadata
                let wrong = RunResult(worktreePath: f.directory.path, branch: "changed", commit: "changed", diffPath: nil, summary: "변조", verifications: [])
                let edited = NormalizedRunEvent(metadata: .init(id: old.id, runID: old.runID, sequence: old.sequence, at: old.at, payload: .saveResult(wrong)), resultKey: stored.resultKey)
                try writer.execute("UPDATE run_events SET payload=? WHERE id='result'", [String(decoding: try JSONEncoder().encode(edited), as: UTF8.self)])
            }
            try writer.close()
            let original = try Data(contentsOf: url)
            await #expect(throws: PersistenceError.self) { _ = try await SQLiteKnarrRepository.open(at: url) }
            #expect(try Data(contentsOf: url) == original)
            try FileManager.default.removeItem(at: f.directory)
        } catch { try await f.cleanup(); throw error }
    }

    @Test func evidenceMigrationFailureRollsBackAllTablesAndOriginalPayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-normalized-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.db")
        try makeThreadV2Fixture(at: file)
        let at = Date(timeIntervalSinceReferenceDate: 12)
        var run = PersistedRun(hird: .init(id: "legacy-run", name: "Hird", role: "검사", status: .failed(at: at), steps: [], currentCommand: nil, lastActivityAt: at),
            issueID: "legacy", projectID: "p", ompSessionID: nil, ownershipToken: "legacy-owner", startedAt: .init(timeIntervalSinceReferenceDate: 10))
        run.state = .failed; run.endedAt = at
        let result = RunResult(worktreePath: "/tmp/legacy", branch: "branch", commit: "commit", diffPath: nil, summary: "원문", verifications: [])
        run.result = result; run.resultHistory = [result]
        let writer = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READWRITE)
        let payload = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        try writer.execute("INSERT INTO runs(id,issue_id,project_id,payload) VALUES(?,?,?,?)", [run.id.rawValue, "legacy", "p", payload])
        try writer.execute("CREATE TRIGGER reject_normalization BEFORE UPDATE ON runs BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try writer.close()
        await #expect(throws: PersistenceError.self) { _ = try await SQLiteKnarrRepository.open(at: file) }
        let after = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY)
        #expect(try after.rows("PRAGMA user_version") == [["2"]])
        #expect(try after.rows("SELECT payload FROM runs") == [[payload]])
        #expect(try after.rows("SELECT name FROM sqlite_master WHERE name IN ('threads','run_results','run_verifications','run_result_history')").isEmpty)
        try after.close()
    }

    @Test func publicationCoalescesBeforeBuildingAndStableEntitiesAreNotDecodedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-coalesced-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("fixture.db"))
        do {
            try await repo.saveProject(.init(id: "p", name: "저장 검사", absolutePath: root.path))
            let stream = try await repo.subscribe()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            let before = await repo.snapshotBuildCount
            for index in 0..<60 {
                try await repo.appendChat(.init(at: .now, kind: .user("원문 \(index) " + String(repeating: "보존", count: 200))), projectID: "p")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await repo.snapshotBuildCount - before < 10)
            let latest = try #require(await iterator.next()).snapshot
            #expect(latest.chat.count == 60)
            _ = try await repo.snapshot(includeHistory: false)
            let builds = await repo.snapshotBuildCount
            try await Task.sleep(for: .milliseconds(50))
            #expect(await repo.snapshotBuildCount == builds, "No idle publication work")
            let bytes = await repo.decodedPayloadBytes
            for _ in 0..<5 { _ = try await repo.snapshot(includeHistory: false) }
            #expect(await repo.decodedPayloadBytes == bytes, "Unchanged entities must reuse their decoded values")
            let writer = try SQLiteConnection(path: root.appendingPathComponent("fixture.db").path, flags: SQLITE_OPEN_READWRITE)
            try writer.execute("UPDATE projects SET payload=json_set(payload,'$.name','외부 변경') WHERE id='p'")
            #expect(try await repo.snapshot(includeHistory: false).projects.first?.name == "외부 변경")
            try writer.close()
            try await repo.close()
        } catch { try await repo.close(); throw error }
    }

    @Test func subscriptionWithoutInitialSnapshotNeverDeliversStateOlderThanTheCallersRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-fresh-subscribe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("fixture.db"))
        do {
            try await repo.saveProject(.init(id: "p", name: "저장 검사", absolutePath: root.path))
            // A store subscribes first and then reads. A thread created between the two must not be
            // erased when an older, queued snapshot is delivered afterwards.
            let stream = try await repo.subscribe(initial: false)
            var iterator = stream.makeAsyncIterator()
            let thread = try await repo.createProjectConversation(projectID: "p")
            #expect(try await repo.snapshot(includeHistory: false).threads.contains { $0.id == thread.id })
            try await repo.appendChat(.init(at: .now, kind: .user("새 대화")), projectID: "p", threadID: thread.id)
            let latest = try #require(await iterator.next()).snapshot
            #expect(latest.threads.contains { $0.id == thread.id })
            try await repo.close()
        } catch { try await repo.close(); throw error }
    }

    @Test @MainActor func publicationNeverDeliversAnOlderStateAfterANewerWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-monotonic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await SQLiteKnarrRepository.open(at: root.appendingPathComponent("fixture.db"))
        do {
            try await repo.saveProject(.init(id: "p", name: "순서 검사", absolutePath: root.path))
            let stream = try await repo.subscribe(initial: false)
            var revisions: [Int] = [], threadCounts: [Int] = []
            let consumer = Task {
                for await update in stream {
                    revisions.append(update.revision); threadCounts.append(update.snapshot.threads.count)
                }
            }
            // Writes land while a 25ms publication is in flight, the case that used to deliver a
            // value read before the write under the newer revision.
            for index in 0..<40 {
                try await repo.saveThread(.init(id: "t\(index)", name: "t\(index)"))
                try await Task.sleep(for: .milliseconds(7))
            }
            try await Task.sleep(for: .milliseconds(300))
            consumer.cancel()
            #expect(revisions == revisions.sorted(), "revisions=\(revisions)")
            #expect(threadCounts == threadCounts.sorted(), "counts=\(threadCounts)")
            #expect(threadCounts.last == 41, "counts=\(threadCounts)")
            try await repo.close()
        } catch { try await repo.close(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KNARR_STORAGE_FIXTURE"] != nil))
    func realLegacyCopyPreservesEvidenceAndMeasuresProgressCost() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KNARR_STORAGE_FIXTURE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-storage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("copy.db")
        try FileManager.default.copyItem(at: source, to: file)
        let before = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY)
        let decoder = JSONDecoder()
        let originalRuns = try before.rows("SELECT payload FROM runs ORDER BY rowid").map { try decoder.decode(PersistedRun.self, from: Data($0[0].utf8)) }
        let originalChats = try before.rows("SELECT id,payload FROM chat ORDER BY rowid")
        let originalEvents = try before.rows("SELECT id,payload,outcome FROM run_events ORDER BY rowid")
        let oldBytes = try before.rows("SELECT SUM(length(CAST(payload AS BLOB))) FROM runs")
        try before.close()
        // Seed an active legacy run with the largest real history before migration.
        // The real historical rows remain unchanged; the source DB is never opened writable.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func wire<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let seedProject = StoredProject(id: "storage-fixture", name: "격리 성능 검사", absolutePath: root.path)
        let seedIssue = KnarrCore.Issue(id: "storage-fixture", title: "격리 성능 검사", projectName: "격리 성능 검사", state: .running,
            headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
        var run = PersistedRun(hird: .init(id: "storage-fixture", name: "Hird", role: "진행 검사", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
                               issueID: "storage-fixture", projectID: "storage-fixture", ompSessionID: nil, ownershipToken: "fixture", startedAt: .now)
        let largest = originalRuns.max { $0.resultHistory.count < $1.resultHistory.count }
        run.resultHistory = largest?.resultHistory ?? []; run.result = run.resultHistory.last
        let seed = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READWRITE)
        try seed.execute("INSERT INTO projects(id,payload) VALUES(?,?)", [seedProject.id, try wire(seedProject)])
        try seed.execute("INSERT INTO issues(id,project_id,payload) VALUES(?,?,?)", [seedIssue.id.rawValue, seedProject.id, try wire(seedIssue)])
        try seed.execute("INSERT INTO runs(id,issue_id,project_id,payload) VALUES(?,?,?,?)", [run.id.rawValue, seedIssue.id.rawValue, seedProject.id, try wire(run)])
        try seed.close()
        let started = Date.timeIntervalSinceReferenceDate
        let repo = try await SQLiteKnarrRepository.open(at: file, probe: { run in
            run.id == "storage-fixture" ? .alive(ownershipToken: run.ownershipToken, ompSessionID: run.ompSessionID) : .unverified
        })
        let migrationMS = (Date.timeIntervalSinceReferenceDate - started) * 1000
        do {
            for old in originalRuns {
                let restored = try await repo.readRun(old.id)
                #expect(restored.resultHistory == old.resultHistory)
                #expect(restored.result == old.result)
            }
            _ = try await repo.snapshot(includeHistory: false)
            var timings: [Double] = []
            for index in 0..<30 {
                let start = Date.timeIntervalSinceReferenceDate
                _ = try await repo.recordEvent(id: "storage-event-\(index)", runID: run.id, at: .now,
                    payload: .activity(.init(at: .now, actor: "Hird", text: "진행 \(index)"), currentCommand: "read", steps: nil))
                _ = try await repo.snapshot(includeHistory: false)
                timings.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
            }
            let after = try SQLiteConnection(path: file.path, flags: SQLITE_OPEN_READONLY)
            #expect(try after.rows("SELECT id,payload FROM chat ORDER BY rowid") == originalChats)
            #expect(try after.rows("SELECT id,payload,outcome FROM run_events WHERE run_id != 'storage-fixture' ORDER BY rowid") == originalEvents)
            #expect(try after.rows("PRAGMA foreign_key_check").isEmpty)
            let newBytes = try after.rows("SELECT SUM(length(CAST(payload AS BLOB))) FROM runs")
            let originalCurrentBytes = try after.rows("SELECT SUM(length(CAST(payload AS BLOB))) FROM runs WHERE id != 'storage-fixture'")
            print("STORAGE_PROFILE runs=\(originalRuns.count) history=\(originalRuns.reduce(0) { $0 + $1.resultHistory.count }) oldRunBytes=\(oldBytes) currentRunBytesIncludingSynthetic=\(newBytes) original23CurrentRunBytes=\(originalCurrentBytes) migrationMS=\(migrationMS) progressMeanMS=\(timings.reduce(0,+)/Double(timings.count)) progressMaxMS=\(timings.max() ?? 0)")
            try after.close()
            try await repo.close()
            let reopenStart = Date.timeIntervalSinceReferenceDate
            let reopened = try await SQLiteKnarrRepository.open(at: file)
            do {
                for old in originalRuns {
                    let restored = try await reopened.readRun(old.id)
                    #expect(restored.resultHistory == old.resultHistory)
                    #expect(restored.result == old.result)
                }
                print("STORAGE_REOPEN preservedRuns=\(originalRuns.count) durationMS=\((Date.timeIntervalSinceReferenceDate-reopenStart)*1000)")
                try await reopened.close()
            } catch { try await reopened.close(); throw error }
        } catch { try await repo.close(); throw error }
    }
}
