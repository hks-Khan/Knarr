import Foundation
import Testing
@testable import KnarrCore

/// Stage 2: the review survives compaction/restart without becoming a judgement, and changed
/// evidence is detected by the hash of the bytes that were actually delivered.
@Suite(.serialized) struct ReviewResumeTests {
    private func invoke(_ name: String, _ args: OMPJSON, _ stub: TestStallariRPC) async throws -> OMPJSON {
        let id = UUID().uuidString
        await stub.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<400 {
            if let reply = await stub.sent.first(where: { $0["id"]?.string == id }) {
                let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
                #expect(reply["isError"]?.bool != true, "\(text)")
                return reply["result"]?["details"] ?? .object(["error": .string(text)])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }

    private func setup(_ f: StallariFixture, criteria: [String] = ["합계 검사 통과", "문서 확인"]) async throws -> (issue: KnarrCore.Issue.ID, run: HirdRun.ID) {
        try await f.session.connect()
        let issue = try await f.legacyIssue(id: "t", title: "검토", criteria: criteria, instruction: "수정")
        let run = try await f.dispatch("r", issue: issue)
        let logs = f.directory.appendingPathComponent("checks")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        func record(_ id: String, _ command: [String], exit: Int32?) throws -> VerificationRecord {
            let path = logs.appendingPathComponent("\(id).log")
            try "log for \(id)\n".write(to: path, atomically: true, encoding: .utf8)
            return .init(id: id, command: command, workingDirectory: f.directory.path,
                         startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                         exitCode: exit, logPath: path.path, summary: "check")
        }
        let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil,
            summary: "결과", verifications: [try record("v1", ["swift", "test"], exit: 0),
                                             try record("v2", ["swift", "test", "--filter", "Other"], exit: 0)],
            reportPath: logs.appendingPathComponent("v1.log").path)
        _ = try await f.session.receive(.init(id: "finished", runID: run, at: .now,
            payload: .complete(result, notificationID: "notice")))
        return (issue, run)
    }

    @Test func parallelReviewNotesAndReadsKeepEveryRecord() async throws {
        let f = try await StallariFixture.make()
        do {
            let (_, run) = try await setup(f)
            async let first = f.session.performTool("save_review", arguments: .object([
                "runID": .string(run.rawValue), "note": .string("첫 메모")]))
            async let second = f.session.performTool("save_review", arguments: .object([
                "runID": .string(run.rawValue), "note": .string("둘째 메모")]))
            async let read = f.session.performTool("read_run_output", arguments: .object([
                "runID": .string(run.rawValue), "verificationID": .string("v1")]))
            _ = try await [first, second, read]
            let review = try #require(try await f.repository.readRun(run, includeHistory: false).review)
            #expect(Set(review.notes.map(\.text)) == ["첫 메모", "둘째 메모"])
            #expect(review.reads.contains { $0.verificationID == "v1" })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func staleWholeReviewCannotOverwriteANewerNote() async throws {
        let f = try await StallariFixture.make()
        do {
            let (_, run) = try await setup(f)
            _ = try await f.session.performTool("save_review", arguments: .object([
                "runID": .string(run.rawValue), "note": .string("기존 메모")]))
            let original = try #require(try await f.repository.readRun(run, includeHistory: false).review)
            var first = original; first.notes.append(.init(text: "첫 저장", criterion: nil, at: .now))
            _ = try await f.repository.saveReview(first, runID: run)
            var stale = original; stale.notes.append(.init(text: "오래된 저장", criterion: nil, at: .now))
            await #expect(throws: (any Error).self) { _ = try await f.repository.saveReview(stale, runID: run) }
            #expect(try await f.repository.readRun(run, includeHistory: false).review?.notes.contains { $0.text == "첫 저장" } == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func reviewStateSurvivesAReopenedStoreAndANewSessionConnection() async throws {
        let f = try await StallariFixture.make()
        let directory = f.directory
        let stub = TestStallariRPC()
        do {
            let (issue, run) = try await setup(f)
            try await f.session.connect()
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), f.rpc)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("v1은 합계 검사를 직접 확인함"), "criterion": .number(0),
                "openItems": .array([.string("이미지 확인 필요")]),
                "selectedVerificationIDs": .array([.string("v1")])]), f.rpc)
            let before = try await invoke("get_run", .object([
                "runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(before["review"]?["notes"]?.array?.count == 1)
            #expect(before["invalidations"]?["stale"]?.bool == false)
            let storedVersion = try #require(before["basis"]?["resultVersion"]?.string)

            // Real restart: close the old session and the store, then open the same database in
            // a fresh repository and a newly connected session on a separate RPC transport.
            _ = await f.session.shutdown()
            try await f.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("knarr.db"))
            let replacement = StallariSession(repository: reopened, rpc: stub, hird: f.hird)
            do {
                try await replacement.connect()
                let after = try await invoke("get_run", .object([
                    "runID": .string("r"), "view": .string("review")]), stub)
                #expect(after["basis"]?["resultVersion"]?.string == storedVersion)
                #expect(after["invalidations"]?["stale"]?.bool == false)
                #expect(after["review"]?["selectedVerificationIDs"]?.array == [.string("v1")])
                #expect(after["review"]?["notes"]?.array?.first?["text"] == .string("v1은 합계 검사를 직접 확인함"))
                #expect(after["review"]?["openItems"]?.array == [.string("이미지 확인 필요")])
                let reads = try #require(after["review"]?["reads"]?.array)
                #expect(reads.count == 1)
                #expect(reads[0]["verificationID"]?.string == "v1")
                #expect(reads[0]["segments"]?.array?.isEmpty == false)
                #expect(after["criteria"]?.array?.count == 2)
                #expect(try await reopened.snapshot().issues.first { $0.id == issue }?.state != .done)

                // A stale session's in-memory review cannot overwrite a newer stored one.
                var stale = try #require(try await reopened.readRun("r", includeHistory: false).review)
                stale.notes = [.init(text: "오래된 메모", criterion: nil, at: .now)]
                await #expect(throws: (any Error).self) {
                    _ = try await reopened.saveReview(stale, runID: "r", expectedResultVersion: "different")
                }
                #expect(try await reopened.readRun("r", includeHistory: false).review?.notes.first?.text
                        == "v1은 합계 검사를 직접 확인함")
                _ = await replacement.shutdown()
            } catch {
                _ = await replacement.shutdown(); try await reopened.close(); throw error
            }
            try await reopened.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            _ = await f.session.shutdown()
            try? await f.repository.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @Test func changedResultOrCriteriaInvalidateTheSavedReview() async throws {
        let f = try await StallariFixture.make()
        do {
            let (_, run) = try await setup(f)
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), f.rpc)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("확인"), "selectedVerificationIDs": .array([.string("v1")])]), f.rpc)
            let fresh = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(fresh["invalidations"]?["stale"]?.bool == false)

            let newer = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c2", diffPath: nil,
                summary: "두 번째", verifications: [.init(id: "v3", command: ["swift", "test"], workingDirectory: f.directory.path,
                    startedAt: .now, finishedAt: .now, exitCode: 0, logPath: fresh["review"]?["reads"]?.array?.first?["logPath"]?.string ?? "/x",
                    summary: "check")])
            _ = try await f.session.receive(.init(id: "saved-2", runID: run, at: .now, payload: .saveResult(newer)))
            let stale = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(stale["invalidations"]?["stale"]?.bool == true)
            let reasons = (stale["invalidations"]?["reasons"]?.array ?? []).compactMap(\.string)
            #expect(reasons.contains("resultChanged"))
            #expect(reasons.contains("selectedEvidenceMissing"))
            #expect(stale["invalidations"]?["missingSelection"]?.array?.first == .string("v1"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func changedCriteriaTextInvalidatesARecordedReview() async throws {
        let f = try await StallariFixture.make()
        do {
            let (issue, _) = try await setup(f)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("기준 확인")]), f.rpc)
            var value = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            value.acceptance[1].text = "바뀐 두 번째 조건"
            value.hirds = []; value.events = []
            try await f.repository.saveIssue(value, projectID: "p")
            let review = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            let reasons = (review["invalidations"]?["reasons"]?.array ?? []).compactMap(\.string)
            #expect(reasons.contains("criteriaChanged"))
            #expect(review["invalidations"]?["stale"]?.bool == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func changedLogBytesAreDetectedAndNotesSurviveTheChange() async throws {
        let f = try await StallariFixture.make()
        do {
            _ = try await setup(f)
            let read = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), f.rpc)
            let segment = try #require(read["segments"]?.array?.first)
            #expect(segment["sha256"]?.string?.isEmpty == false)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("원문 확인"),
                "openItems": .array([.string("재확인 필요")])]), f.rpc)

            // Same length, different bytes: a size check would miss this.
            let logPath = try #require(read["logPath"]?.string)
            let original = try String(contentsOfFile: logPath, encoding: .utf8)
            let rewritten = original.replacingOccurrences(of: "log", with: "LOG")
            #expect(rewritten.utf8.count == original.utf8.count)
            try rewritten.write(toFile: logPath, atomically: true, encoding: .utf8)

            let after = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(after["invalidations"]?["stale"]?.bool == true)
            let changedReads = (after["invalidations"]?["changedReads"]?.array ?? []).compactMap(\.string)
            let reasons = (after["invalidations"]?["reasons"]?.array ?? []).compactMap(\.string)
            #expect(changedReads.contains("v1"))
            #expect(reasons.contains("readLogChanged"))
            // The reviewer's own notes are preserved through the change.
            #expect(after["review"]?["notes"]?.array?.first?["text"] == .string("원문 확인"))
            #expect(after["review"]?["openItems"]?.array == [.string("재확인 필요")])

            // A search read records its actual match ranges, not a 0..0 placeholder.
            let big = f.directory.appendingPathComponent("big.log")
            try (String(repeating: "앞부분\n", count: 2000) + "ERROR: 가운데\n" + String(repeating: "뒷부분\n", count: 2000))
                .write(to: big, atomically: true, encoding: .utf8)
            let record = VerificationRecord(id: "v9", command: ["swift", "test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: big.path, summary: "check")
            let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c3", diffPath: nil,
                summary: "검색", verifications: [record], reportPath: big.path)
            _ = try await f.session.receive(.init(id: "saved-3", runID: "r", at: .now, payload: .saveResult(result)))
            let found = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v9"),
                "mode": .string("search"), "query": .string("error")]), f.rpc)
            let match = try #require(found["matches"]?.array?.first)
            let start = try #require(match["byteStart"]?.integer)
            let end = try #require(match["byteEnd"]?.integer)
            #expect(start > 0 && end > start)
            let stored = try await f.repository.readRun("r", includeHistory: false).review
            let searchRead = try #require(stored?.reads.first { $0.verificationID == "v9" })
            #expect(searchRead.mode == "search")
            #expect(searchRead.segments.contains { $0.start == start && $0.end == end })
            #expect(searchRead.segments.allSatisfy { $0.end > $0.start })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func changedMiddleOfALargeFileIsDetected() async throws {
        let f = try await StallariFixture.make()
        do {
            _ = try await setup(f)
            let big = f.directory.appendingPathComponent("large.log")
            let head = String(repeating: "A", count: 5 << 20)
            let middle = "가운데 표식\n"
            let tail = String(repeating: "B", count: 5 << 20)
            try (head + middle + tail).write(to: big, atomically: true, encoding: .utf8)
            let record = VerificationRecord(id: "v10", command: ["swift", "test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: big.path, summary: "check")
            let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c4", diffPath: nil,
                summary: "큰 파일", verifications: [record], reportPath: big.path)
            _ = try await f.session.receive(.init(id: "saved-4", runID: "r", at: .now, payload: .saveResult(result)))
            let read = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v10"),
                "mode": .string("search"), "query": .string("가운데 표식")]), f.rpc)
            // Sampled file hashing cannot see a middle change; the stored segment can.
            #expect(read["fileHashScope"]?.string == "sampled")
            #expect(read["matches"]?.array?.isEmpty == false)
            let staleCheck = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(staleCheck["invalidations"]?["stale"]?.bool == false)

            // Replace only the middle, keeping the length and both ends.
            var data = try Data(contentsOf: big)
            let needle = Data(middle.utf8)
            let range = try #require(data.range(of: needle))
            data.replaceSubrange(range, with: Data("가운데 표식".replacingOccurrences(of: "가운데", with: "중앙부").utf8))
            try data.write(to: big)
            let changed = try await invoke("get_run", .object(["runID": .string("r"), "view": .string("review")]), f.rpc)
            #expect(changed["invalidations"]?["stale"]?.bool == true)
            let changedReads = (changed["invalidations"]?["changedReads"]?.array ?? []).compactMap(\.string)
            #expect(changedReads.contains("v10"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func manifestMetadataChangeAloneInvalidatesTheCursorAndReview() async throws {
        let f = try await StallariFixture.make()
        do {
            let (_, run) = try await setup(f)
            let before = try StallariReview.version(of: try await f.repository.readRun(run, includeHistory: false).result)
            let cursor = try await invoke("get_run", .object([
                "runID": .string("r"), "order": .string("oldest"), "limit": .number(1)]), f.rpc)
            let stored = try await f.repository.readRun(run, includeHistory: false)
            let current = try #require(stored.result)
            let manifest = f.directory.appendingPathComponent("artifacts.json")
            try "{}".write(to: manifest, atomically: true, encoding: .utf8)
            let versioned = RunResult(worktreePath: current.worktreePath, branch: current.branch, commit: current.commit,
                diffPath: current.diffPath, summary: current.summary, verifications: current.verifications,
                reportPath: current.reportPath, artifactManifestPath: manifest.path,
                artifactManifestMetadata: .init(sha256: String(repeating: "a", count: 64), artifactCount: 7, totalBytes: 9_000))
            _ = try await f.session.receive(.init(id: "manifest", runID: run, at: .now, payload: .saveResult(versioned)))
            let after = try StallariReview.version(of: try await f.repository.readRun(run, includeHistory: false).result)
            #expect(before != after)
            let stale = try await invoke("get_run", .object([
                "runID": .string("r"), "order": .string("oldest"), "cursor": .string(try #require(cursor["nextCursor"]?.string))]), f.rpc)
            #expect(stale["changed"]?.bool == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func readAndNoteNeverBypassJudgementProtections() async throws {
        let f = try await StallariFixture.make()
        do {
            let (issue, run) = try await setup(f)
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), f.rpc)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("통과로 보임"),
                "selectedVerificationIDs": .array([.string("v1"), .string("v2")])]), f.rpc)
            #expect(try await f.repository.snapshot().issues.first { $0.id == issue }?.state != .done)

            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: issue, runID: "other-run", evidence: [
                    .init(criterionIndex: 0, verificationIDs: ["v1"], explanation: "a"),
                    .init(criterionIndex: 1, verificationIDs: ["v2"], explanation: "b")])
            }
            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: issue, runID: run, evidence: [
                    .init(criterionIndex: 0, verificationIDs: ["v1"], explanation: "a")])
            }
            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: issue, runID: run, evidence: [
                    .init(criterionIndex: 0, verificationIDs: ["v-other"], explanation: "a"),
                    .init(criterionIndex: 1, verificationIDs: ["v2"], explanation: "b")])
            }
            #expect(try await f.repository.snapshot().issues.first { $0.id == issue }?.state != .done)

            try await f.session.judge(issueID: issue, runID: run, evidence: [
                .init(criterionIndex: 0, verificationIDs: ["v1"], explanation: "검사 통과"),
                .init(criterionIndex: 1, verificationIDs: [], explanation: "문서 확인 불가", met: false)])
            let saved = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            #expect(saved.state == KnarrCore.IssueState.failed)
            let state = try await f.repository.readRun(run, includeHistory: false)
            #expect(state.review?.judgedAt != nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func aStaleReviewBlocksAnAllMetCompletionAndKeepsItsNotes() async throws {
        let f = try await StallariFixture.make()
        do {
            let (issue, run) = try await setup(f)
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationIDs": .array([.string("v1"), .string("v2")])]), f.rpc)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("이전 결과 기준"),
                "selectedVerificationIDs": .array([.string("v1"), .string("v2")])]), f.rpc)
            // The result changes after the review was formed.
            let stored = try await f.repository.readRun(run, includeHistory: false)
            let current = try #require(stored.result)
            let changed = RunResult(worktreePath: current.worktreePath, branch: current.branch, commit: "c9",
                diffPath: current.diffPath, summary: current.summary, verifications: current.verifications,
                reportPath: current.reportPath)
            _ = try await f.session.receive(.init(id: "saved-9", runID: run, at: .now, payload: .saveResult(changed)))

            // Every criterion is met by saved passing evidence, but the review was formed against
            // the superseded result, so the issue must not complete.
            await #expect(throws: (any Error).self) {
                try await f.session.judge(issueID: issue, runID: run, evidence: [
                    .init(criterionIndex: 0, verificationIDs: ["v1"], explanation: "검사 통과"),
                    .init(criterionIndex: 1, verificationIDs: ["v2"], explanation: "문서 확인")])
            }
            let savedIssue = try #require(try await f.repository.snapshot().issues.first { $0.id == issue })
            #expect(savedIssue.state != .done)
            #expect(savedIssue.completedAt == nil)
            let review = try #require(try await f.repository.readRun(run, includeHistory: false).review)
            // The old review still carries an older basis, so it cannot claim it was the
            // evidence for this judgement; its notes remain.
            #expect(review.resultVersion != StallariReview.version(of: changed))
            #expect(review.judgedAt == nil)
            #expect(review.notes.map(\.text) == ["이전 결과 기준"])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func reviewStateStaysSmallAndRejectsForeignIDs() async throws {
        let f = try await StallariFixture.make()
        do {
            _ = try await setup(f)
            let id = UUID().uuidString
            await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id),
                "toolName": .string("save_review"), "arguments": .object([
                    "runID": .string("r"), "selectedVerificationIDs": .array([.string("v-foreign")])])])))
            var rejection: OMPJSON?
            for _ in 0..<400 {
                if let reply = await f.rpc.sent.first(where: { $0["id"]?.string == id }) { rejection = .object(reply); break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(rejection?["isError"]?.bool == true)
            let saved = try await f.repository.readRun("r", includeHistory: false)
            #expect(saved.review == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
