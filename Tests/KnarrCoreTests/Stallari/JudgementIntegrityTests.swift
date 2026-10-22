import Foundation
import Testing
@testable import KnarrCore

// Issue 7: the 2026-10-08 real-app run judged "all existing tests pass" as met
// from one `cat …; python3 -m unittest; git diff; python -c …` record whose exit
// code only reflected the last step.
@Suite(.serialized) struct JudgementIntegrityTests {
    private func record(_ id: String, _ command: [String], exit: Int32?, log: String = "ok", in f: StallariFixture) throws -> VerificationRecord {
        let path = f.directory.appendingPathComponent("\(id).log")
        try log.write(to: path, atomically: true, encoding: .utf8)
        return .init(id: id, command: command, workingDirectory: f.directory.path,
                     startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                     exitCode: exit, logPath: path.path, summary: "check")
    }

    private func complete(_ f: StallariFixture, run: HirdRun.ID, records: [VerificationRecord]) async throws {
        let result = RunResult(worktreePath: f.directory.path, branch: "test", commit: "fixture-commit", diffPath: nil,
                               summary: "add 수정", verifications: records)
        _ = try await f.session.receive(.init(id: "end-\(run.rawValue)", runID: run, at: Date(timeIntervalSince1970: 20),
                                              payload: .complete(result, notificationID: "notice-\(run.rawValue)")))
    }

    @Test func onlyOneCheckPerCommandCountsAsEvidence() {
        func single(_ command: [String]) -> Bool {
            VerificationRecord(id: "v", command: command, workingDirectory: "/", startedAt: .now, finishedAt: .now,
                               exitCode: 0, logPath: "/x", summary: "").isSingleCheck
        }
        #expect(single(["python3 -m unittest -v"]))
        #expect(single(["swift", "test"]))
        #expect(single(["cd project && python3 -m unittest"]))
        #expect(!single(["cat calc.py; python3 -m unittest; git diff"]))
        #expect(!single(["python3 -m unittest 2>&1 | tail -5"]))
        #expect(!single(["python3 -m unittest || true"]))
        #expect(!single(["python3 -m unittest\ngit diff"]))
        #expect(!single(["python3 -m unittest & sleep 1"]))
        #expect(single(["swift test --filter 'Alpha|Beta'"]))
        #expect(single(["/usr/bin/grep -E \"foo|bar\" file.swift"]))
        #expect(single(["/usr/bin/grep -E 'foo;bar&baz' file.swift"]))
        #expect(!single(["/usr/bin/grep -E 'foo|bar' file.swift | cat"]))
        #expect(!single(["sh -c 'swift test; true'"]))
        #expect(!single(["printf \"$(swift test)\""]))
    }

    @Test func combinedCommandCannotProveACriterion() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            let combined = try record("v", ["cat calc.py; python3 -m unittest; git diff calc.py; python3 -c 'print(1)'"], exit: 0, in: f)
            try await complete(f, run: r, records: [combined])
            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "통과")])
            }
            #expect(try await f.repository.snapshot().issues[0].state != .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func failingRecordCannotBeCitedAsMet() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            try await complete(f, run: r, records: [try record("v", ["python3 -m unittest"], exit: 1, in: f)])
            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "통과")])
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func unmetCriterionStopsTheIssueWithItsReason() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.legacyIssue(id: "calc", title: "add 수정",
                                          criteria: ["add(2, 3) == 5", "기존 테스트 전체 통과"], instruction: "add를 고치고 검사해요")
            let r = try await f.dispatch("r", issue: t)
            try await complete(f, run: r, records: [
                try record("add", ["python3 -m unittest test_calc.CalcTests.test_add"], exit: 0, in: f),
                try record("all", ["python3 -m unittest"], exit: 1, log: "ZeroDivisionError: division by zero\nFAILED (errors=1)", in: f),
            ])
            try await f.session.judge(issueID: t, runID: r, evidence: [
                .init(criterionIndex: 0, verificationIDs: ["add"], explanation: "add 테스트 통과"),
                .init(criterionIndex: 1, verificationIDs: ["all"], explanation: "average([])가 ZeroDivisionError로 실패", met: false),
            ])
            let saved = try #require(try await f.repository.snapshot().issues.first { $0.id == t })
            #expect(saved.state == .failed)
            #expect(saved.acceptance.map(\.state) == [.met, .unmet])
            #expect(saved.acceptance[1].evidence.contains("ZeroDivisionError"))
            #expect(saved.headline == "완료 조건 미충족 1개")
            #expect(saved.confirmed == false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func unmetCriterionStillNeedsAnExplanation() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            try await complete(f, run: r, records: [try record("v", ["python3 -m unittest"], exit: 1, in: f)])
            await #expect(throws: StallariError.self) {
                try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: [], explanation: " ", met: false)])
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func failedHirdRunIsReportedToStallari() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            let before = await f.rpc.prompts.count
            #expect(try await f.session.receive(.init(id: "fail-r", runID: r, at: Date(timeIntervalSince1970: 30), payload: .fail("OMP 실행이 실패했어요"))) == .applied)
            let prompts = await f.rpc.prompts
            #expect(prompts.count == before + 1)
            let message = prompts.last?["message"]?.string ?? ""
            #expect(message.contains("runID=r") && message.contains("OMP 실행이 실패했어요"))
            // A replayed failure is not reported twice.
            #expect(try await f.session.receive(.init(id: "fail-r", runID: r, at: Date(timeIntervalSince1970: 30), payload: .fail("OMP 실행이 실패했어요"))) == .duplicate)
            #expect(await f.rpc.prompts.count == before + 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func logTailKeepsOnlyTheEnd() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-tail-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: path) }
        try (1...10).map { "line \($0)" }.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        let r = VerificationRecord(id: "v", command: ["x"], workingDirectory: "/", startedAt: .now, finishedAt: .now,
                                   exitCode: 1, logPath: path.path, summary: "")
        #expect(r.logTail(maxLines: 3) == "line 8\nline 9\nline 10")
        let missing = VerificationRecord(id: "m", command: ["x"], workingDirectory: "/", startedAt: .now, finishedAt: .now,
                                         exitCode: 1, logPath: "/nonexistent/knarr.log", summary: "")
        #expect(missing.logTail(maxLines: 3) == nil)
    }
}
