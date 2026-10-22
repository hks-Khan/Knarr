import Foundation
import Testing
@testable import KnarrCore

/// A saved review that no longer matches the current result/criteria must not let a
/// met=true judgement complete the issue. These tests drive the real stored issue, the
/// completion delivery and the review state, not just intermediate values.
@Suite(.serialized) struct StaleReviewCompletionTests {
    private struct Fixture {
        let f: StallariFixture
        let issue: KnarrCore.Issue.ID
        let run: HirdRun.ID
        let logs: URL
        var v1: VerificationRecord { records[0] }
        var v2: VerificationRecord { records[1] }
        let records: [VerificationRecord]
    }

    private struct ToolFailure: Error { let message: String }

    private func invoke(_ name: String, _ args: OMPJSON, _ rpc: TestStallariRPC) async throws -> OMPJSON {
        let id = UUID().uuidString
        await rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<400 {
            if let reply = await rpc.sent.first(where: { $0["id"]?.string == id }) {
                let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
                if reply["isError"]?.bool == true { throw ToolFailure(message: text) }
                return reply["result"]?["details"] ?? .object(["error": .string(text)])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }

    private func make() async throws -> Fixture {
        let f = try await StallariFixture.make()
        try await f.session.connect()
        let issue = try await f.legacyIssue(id: "t", title: "검토", criteria: ["합계 검사 통과", "문서 확인"], instruction: "수정")
        let run = try await f.dispatch("r", issue: issue)
        let logs = f.directory.appendingPathComponent("checks")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        func record(_ id: String) throws -> VerificationRecord {
            let path = logs.appendingPathComponent("\(id).log")
            try "log for \(id)\n".write(to: path, atomically: true, encoding: .utf8)
            return .init(id: id, command: ["swift", "test"], workingDirectory: f.directory.path,
                         startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                         exitCode: 0, logPath: path.path, summary: "check")
        }
        let records = [try record("v1"), try record("v2")]
        let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil,
            summary: "결과", verifications: records, reportPath: records[0].logPath)
        _ = try await f.session.receive(.init(id: "finished", runID: run, at: .now,
            payload: .complete(result, notificationID: "notice")))
        return Fixture(f: f, issue: issue, run: run, logs: logs, records: records)
    }

    /// Both criteria have valid passing evidence, and the review is saved against result v1.
    private func reviewAgainstV1(_ fixture: Fixture) async throws {
        _ = try await invoke("read_run_output", .object([
            "runID": .string("r"), "verificationIDs": .array([.string("v1"), .string("v2")])]), fixture.f.rpc)
        _ = try await invoke("save_review", .object([
            "runID": .string("r"), "note": .string("v1 결과 기준 검토"),
            "openItems": .array([.string("문서 조건 재확인")]),
            "selectedVerificationIDs": .array([.string("v1"), .string("v2")])]), fixture.f.rpc)
    }

    private func saveNewResult(_ fixture: Fixture, commit: String, records: [VerificationRecord]? = nil) async throws {
        let current = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).result)
        let next = RunResult(worktreePath: current.worktreePath, branch: current.branch, commit: commit,
            diffPath: current.diffPath, summary: "결과 \(commit)",
            verifications: records ?? current.verifications, reportPath: current.reportPath)
        _ = try await fixture.f.session.receive(.init(id: "saved-\(commit)", runID: fixture.run, at: .now,
            payload: .saveResult(next)))
    }

    private func allMet(_ run: HirdRun.ID, ids: [String] = ["v1", "v2"]) -> [CriterionEvidence] {
        [.init(criterionIndex: 0, verificationIDs: [ids[0]], explanation: "검사 통과"),
         .init(criterionIndex: 1, verificationIDs: [ids[1]], explanation: "문서 확인")]
    }

    private func expectNotDone(_ fixture: Fixture, _ error: Error?, _ context: String,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(error != nil, "\(context): judgement should be rejected")
        let stored = try #require(try await fixture.f.repository.snapshot().issues.first { $0.id == fixture.issue })
        #expect(stored.state != .done, "\(context): issue must not be done", sourceLocation: sourceLocation)
        #expect(stored.state != KnarrCore.IssueState.failed, "\(context): no unmet record either", sourceLocation: sourceLocation)
        #expect(stored.completedAt == nil, "\(context): no completion time", sourceLocation: sourceLocation)
        let review = try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review
        #expect(review?.judgedAt == nil, "\(context): judgedAt must stay empty", sourceLocation: sourceLocation)
        // No completion delivery for this issue/run was created by a rejected judgement.
        let deliveries: [ThreadDelivery] = try await fixture.f.repository.pendingThreadDeliveries(threadID: ConversationThread.defaultID)
        #expect(!deliveries.contains { delivery in
            guard delivery.issueID == fixture.issue, delivery.runID == fixture.run else { return false }
            if case .completion = delivery.kind { return true }
            return false
        }, "\(context): rejected judgement must not queue a completion delivery", sourceLocation: sourceLocation)
    }

    // MARK: - Reproduction: stale review cannot complete

    @Test func staleResultVersionBlocksAllMetCompletion() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            // Same verification IDs, new result version.
            try await saveNewResult(fixture, commit: "c2")
            var failure: Error?
            do { try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run)) }
            catch { failure = error }
            try await expectNotDone(fixture, failure, "result changed")
            // The reviewer's notes and open items survive.
            let review = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(review.notes.map(\.text) == ["v1 결과 기준 검토"])
            #expect(review.openItems == ["문서 조건 재확인"])
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func changedCriteriaWordingBlocksAllMetCompletion() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            var issue = try #require(try await fixture.f.repository.snapshot().issues.first { $0.id == fixture.issue })
            issue.acceptance[1].text = "문서 확인(문구 변경)"
            issue.hirds = []; issue.events = []
            try await fixture.f.repository.saveIssue(issue, projectID: "p")
            var failure: Error?
            do { try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run)) }
            catch { failure = error }
            try await expectNotDone(fixture, failure, "criteria changed")
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func changedLogBytesAtTheSameLengthBlockAllMetCompletion() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            let path = fixture.v1.logPath
            let original = try String(contentsOfFile: path, encoding: .utf8)
            try original.replacingOccurrences(of: "log", with: "LOG").write(toFile: path, atomically: true, encoding: .utf8)
            var failure: Error?
            do { try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run)) }
            catch { failure = error }
            try await expectNotDone(fixture, failure, "log bytes changed")
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func missingSelectedEvidenceBlocksAllMetCompletion() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            // The selected v2 is no longer part of the saved result.
            try await saveNewResult(fixture, commit: "c3", records: [fixture.v1])
            var failure: Error?
            do { try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run)) }
            catch { failure = error }
            try await expectNotDone(fixture, failure, "selected evidence missing")
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    // MARK: - Stale stays visible through repeated reads and note saves

    @Test func staleStateSurvivesRepeatedReadsAndNoteSaves() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try await saveNewResult(fixture, commit: "c2")

            func staleState(_ context: String, reason: String) async throws {
                let view = try await invoke("get_run", .object([
                    "runID": .string("r"), "view": .string("review")]), fixture.f.rpc)
                #expect(view["invalidations"]?["stale"]?.bool == true, "\(context): stale must remain")
                let reasons = (view["invalidations"]?["reasons"]?.array ?? []).compactMap(\.string)
                #expect(reasons.contains(reason), "\(context): reason \(reason) reported")
                #expect(view["review"]?["notes"]?.array?.isEmpty == false, "\(context): notes kept")
            }

            // Before any rebase the record still names the old result.
            try await staleState("before note", reason: "resultChanged")
            for round in 1...2 {
                _ = try await invoke("save_review", .object([
                    "runID": .string("r"), "note": .string("메모 \(round)")]), fixture.f.rpc)
                try await staleState("after note \(round)", reason: "basisCarriedOver")
            }
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), fixture.f.rpc)
            try await staleState("after read", reason: "basisCarriedOver")
            let review = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(review.notes.map(\.text) == ["v1 결과 기준 검토", "메모 1", "메모 2"])
            #expect(review.openItems == ["문서 조건 재확인"])
            #expect(review.carriedFromVersion != nil)
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    // MARK: - Explicit re-review clears staleness

    @Test func explicitReReviewAllowsJudgementAndIsRequiredForCompletion() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try await saveNewResult(fixture, commit: "c2")

            // Without the explicit refresh, completion is refused.
            var blocked: Error?
            do { try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run)) }
            catch { blocked = error }
            try await expectNotDone(fixture, blocked, "before re-review")

            // The explicit refresh must re-read the current evidence and acknowledge the new basis.
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationIDs": .array([.string("v1"), .string("v2")])]), fixture.f.rpc)
            let refreshed = try await invoke("save_review", .object([
                "runID": .string("r"), "refresh": .bool(true),
                "note": .string("새 결과 기준으로 다시 확인"),
                "selectedVerificationIDs": .array([.string("v1"), .string("v2")])]), fixture.f.rpc)
            #expect(refreshed["status"]?.string == "saved")
            let view = try await invoke("get_run", .object([
                "runID": .string("r"), "view": .string("review")]), fixture.f.rpc)
            #expect(view["invalidations"]?["stale"]?.bool == false)
            #expect(view["review"]?["carriedFromVersion"] == .null)
            // The re-read is recorded under the new basis. Re-reading the same ranges replaces
            // the older record for that ID, so every stored read is current here.
            let reads = try #require(view["review"]?["reads"]?.array)
            #expect(!reads.isEmpty)
            #expect(reads.allSatisfy { $0["currentBasis"]?.bool == true })

            try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run))
            let stored = try #require(try await fixture.f.repository.snapshot().issues.first { $0.id == fixture.issue })
            #expect(stored.state == KnarrCore.IssueState.done)
            let review = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(review.judgedAt != nil)
            #expect(review.carriedFromVersion == nil)
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func refreshWithoutReReadingCurrentEvidenceIsRejected() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try await saveNewResult(fixture, commit: "c2")
            // Old evidence was read against the previous result only; a bare refresh cannot
            // claim the new result was examined.
            var failure: Error?
            do {
                _ = try await invoke("save_review", .object([
                    "runID": .string("r"), "refresh": .bool(true)]), fixture.f.rpc)
            } catch { failure = error }
            #expect(failure != nil, "refresh without current reads must be rejected")
            let stale = try await invoke("get_run", .object([
                "runID": .string("r"), "view": .string("review")]), fixture.f.rpc)
            #expect(stale["invalidations"]?["stale"]?.bool == true)
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func refreshRaceWithANewResultIsRejected() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try await saveNewResult(fixture, commit: "c2")
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationIDs": .array([.string("v1"), .string("v2")])]), fixture.f.rpc)
            // The result changes again between the read and the refresh save.
            let beforeAnother = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            let expected = beforeAnother.resultVersion
            try await saveNewResult(fixture, commit: "c3")
            var failure: Error?
            do {
                _ = try await fixture.f.repository.saveReview(beforeAnother, runID: fixture.run, expectedResultVersion: expected)
            } catch { failure = error }
            #expect(failure != nil, "a review formed against an older result must not overwrite")
            let current = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).result)
            let review = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(review.resultVersion != StallariReview.version(of: current))
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func logOnlyChangeCanBeExplicitlyReReviewedWithoutDiscardingHistory() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            let original = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            let originalHashes = original.reads.filter { $0.verificationID == "v1" }.flatMap { $0.segments.map(\.hash) }
            try "LOG for v1\n".write(toFile: fixture.v1.logPath, atomically: true, encoding: .utf8)
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1")]), fixture.f.rpc)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "note": .string("새 원문 확인")]), fixture.f.rpc)
            let before = try await invoke("get_run", .object([
                "runID": .string("r"), "view": .string("review")]), fixture.f.rpc)
            #expect(before["invalidations"]?["stale"]?.bool == true)
            _ = try await invoke("save_review", .object([
                "runID": .string("r"), "refresh": .bool(true)]), fixture.f.rpc)
            let refreshed = try await invoke("get_run", .object([
                "runID": .string("r"), "view": .string("review")]), fixture.f.rpc)
            #expect(refreshed["invalidations"]?["stale"]?.bool == false)
            let saved = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(saved.resultVersion == original.resultVersion)
            #expect(saved.reads.flatMap { $0.segments.map(\.hash) }.contains { originalHashes.contains($0) })
            #expect(saved.notes.map(\.text) == ["v1 결과 기준 검토", "새 원문 확인"])
            try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: allMet(fixture.run))
            #expect(try await fixture.f.repository.snapshot().issues.first { $0.id == fixture.issue }?.state == .done)
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    @Test func refreshRequiresTheChangedLogRangesToBeReadAgain() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try "LOG for v1\n".write(toFile: fixture.v1.logPath, atomically: true, encoding: .utf8)
            var blocked: Error?
            do { _ = try await invoke("save_review", .object([
                "runID": .string("r"), "refresh": .bool(true)]), fixture.f.rpc) }
            catch { blocked = error }
            #expect(blocked != nil, "A changed log cannot be refreshed without rereading its changed ranges")
            _ = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationID": .string("v1"),
                "offset": .number(4), "limit": .number(2)]), fixture.f.rpc)
            blocked = nil
            do { _ = try await invoke("save_review", .object([
                "runID": .string("r"), "refresh": .bool(true)]), fixture.f.rpc) }
            catch { blocked = error }
            #expect(blocked != nil, "Reading an unrelated fragment cannot retire the changed original span")
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }

    // MARK: - Unchanged contracts

    @Test func legacyJudgementWithoutAnyReviewStillCompletes() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.legacyIssue(id: "legacy", title: "검토", criteria: ["검사"], instruction: "수정")
            let run = try await f.dispatch("r", issue: issue)
            let log = f.directory.appendingPathComponent("legacy.log")
            try "ok\n".write(to: log, atomically: true, encoding: .utf8)
            let record = VerificationRecord(id: "v", command: ["swift", "test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: log.path, summary: "check")
            let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil,
                summary: "결과", verifications: [record], reportPath: log.path)
            _ = try await f.session.receive(.init(id: "end", runID: run, at: .now,
                payload: .complete(result, notificationID: "notice")))
            try await f.session.judge(issueID: issue, runID: run, evidence: [
                .init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            #expect(try await f.repository.snapshot().issues.first { $0.id == issue }?.state == .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func unmetJudgementIsStillRecordedDespiteAStaleReview() async throws {
        let fixture = try await make()
        do {
            try await reviewAgainstV1(fixture)
            try await saveNewResult(fixture, commit: "c2")
            try await fixture.f.session.judge(issueID: fixture.issue, runID: fixture.run, evidence: [
                .init(criterionIndex: 0, verificationIDs: ["v1"], explanation: "검사 통과"),
                .init(criterionIndex: 1, verificationIDs: [], explanation: "문서 확인 불가", met: false)])
            let stored = try #require(try await fixture.f.repository.snapshot().issues.first { $0.id == fixture.issue })
            #expect(stored.state == KnarrCore.IssueState.failed)
            #expect(stored.acceptance.map(\.state) == [.met, .unmet])
            let review = try #require(try await fixture.f.repository.readRun(fixture.run, includeHistory: false).review)
            #expect(review.notes.map(\.text) == ["v1 결과 기준 검토"])
            try await fixture.f.cleanup()
        } catch { try await fixture.f.cleanup(); throw error }
    }
}
