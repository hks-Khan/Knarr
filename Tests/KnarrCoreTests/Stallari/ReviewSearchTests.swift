import Foundation
import Testing
@testable import KnarrCore

/// Stage 1: finding the needed check without paging the whole list, and keeping the original
/// text reachable for failed and unknown records.
@Suite(.serialized) struct ReviewSearchTests {
    private func raw(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> (reply: OMPJSON, details: OMPJSON, text: String) {
        let id = UUID().uuidString
        await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<400 {
            if let reply = await f.rpc.sent.first(where: { $0["id"]?.string == id }) {
                let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
                return (.object(reply), reply["result"]?["details"] ?? .object(["error": .string(text)]), text)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }

    private func invoke(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> OMPJSON {
        let call = try await raw(name, args, f)
        #expect(call.reply["isError"]?.bool != true, "\(call.text)")
        return call.details
    }

    private func rejected(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> String {
        let call = try await raw(name, args, f)
        #expect(call.reply["isError"]?.bool == true)
        return call.text
    }

    /// Mirrors the real case: hundreds of mixed records, few of which prove a criterion.
    private func records(_ f: StallariFixture, count: Int = 399) throws -> (records: [VerificationRecord], report: String) {
        let report = f.directory.appendingPathComponent("report.md")
        try "# 보고서\n검증 로그 원문\n".write(to: report, atomically: true, encoding: .utf8)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let values = (0..<count).map { i -> VerificationRecord in
            let path = f.directory.appendingPathComponent("log-\(i).log")
            let command: [String]
            let exit: Int32?
            switch i % 10 {
            case 0: command = ["swift", "test", "--filter", "Suite\(i)"]; exit = 0
            case 1: command = ["bash", "-lc", "npm run build | tee build.log"]; exit = 0
            case 2: command = ["npm", "run", "build"]; exit = 1
            case 3: command = ["sleep", "3 &"]; exit = nil
            default: command = ["cat", "src/File\(i).swift"]; exit = 0
            }
            let body = i % 10 == 2 ? "error: build failed at line \(i)\n" : "ok \(i)\n한글 로그 😀\n"
            try? body.write(to: path, atomically: true, encoding: .utf8)
            let kind: VerificationRecord.Kind = i % 20 == 5 ? .inspection : .command
            return VerificationRecord(id: "v-\(i)", command: command, workingDirectory: f.directory.path,
                startedAt: start.addingTimeInterval(Double(i)), finishedAt: start.addingTimeInterval(Double(i) + 1),
                exitCode: kind == .inspection ? nil : exit, logPath: path.path, summary: "check \(i)",
                kind: kind)
        }
        return (values, report.path)
    }

    private func save(_ f: StallariFixture, run: HirdRun.ID, _ records: [VerificationRecord], report: String) async throws {
        let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil,
                               summary: "결과", verifications: records, reportPath: report)
        _ = try await f.session.receive(.init(id: "saved", runID: run, at: .now, payload: .saveResult(result)))
    }

    @Test func searchFindsExactRecordsAndKeepsFailureAndUnknownTextReachable() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t"), run = try await f.dispatch("r-399", issue: issue)
            let fixture = try records(f)
            try await save(f, run: run, fixture.records, report: fixture.report)

            // A command search returns only the matching originals, newest first, and never
            // hides failed or unknown records behind a "successful" view.
            let build = try await invoke("get_run", .object([
                "runID": .string("r-399"), "query": .string("npm run build"), "order": .string("newest"),
                "limit": .number(20)]), f)
            let matched = try #require(build["verifications"]?.array)
            #expect(!matched.isEmpty)
            let expected = fixture.records.filter { $0.command.joined(separator: " ").contains("npm run build") }
            #expect(matched.compactMap { $0["verificationID"]?.string } == expected.map(\.id).reversed().prefix(20).map { $0 })
            #expect(build["matched"]?.integer == expected.count)
            #expect(build["total"]?.integer == 399)

            let failed = try await invoke("get_run", .object([
                "runID": .string("r-399"), "status": .string("failed"), "limit": .number(20)]), f)
            let failedRecords = fixture.records.filter { !$0.isInspection && $0.exitCode == 1 }
            #expect(failed["matched"]?.integer == failedRecords.count)
            #expect(failed["verifications"]?.array?.allSatisfy { $0["status"]?.string == "failed" } == true)

            let unknown = try await invoke("get_run", .object([
                "runID": .string("r-399"), "status": .string("unknown"), "limit": .number(5)]), f)
            let unknownRecords = fixture.records.filter { $0.isInspection || $0.exitCode == nil }
            #expect(unknown["matched"]?.integer == unknownRecords.count)
            let unknownID = try #require(unknown["verifications"]?.array?.first?["verificationID"]?.string)

            // Original text stays reachable for a record with no exit code.
            let original = try await invoke("read_run_output", .object([
                "runID": .string("r-399"), "verificationID": .string(unknownID)]), f)
            #expect(original["text"]?.string?.contains("한글 로그") == true)
            #expect(original["verificationID"]?.string == unknownID)
            #expect(original["fileHashScope"]?.string == "full")
            #expect(original["sourceIsUntrusted"]?.bool == true)

            // The failed log's exact error line is found by search with its byte range.
            let failedID = try #require(failed["verifications"]?.array?.first?["verificationID"]?.string)
            let hit = try await invoke("read_run_output", .object([
                "runID": .string("r-399"), "verificationID": .string(failedID),
                "mode": .string("search"), "query": .string("error: build failed")]), f)
            let match = try #require(hit["matches"]?.array?.first)
            #expect(match["text"]?.string?.contains("error: build failed") == true)
            #expect((match["byteStart"]?.integer ?? -1) >= 0)

            // Eligibility matches the judge rule, including composite commands.
            let ineligible = try await invoke("get_run", .object([
                "runID": .string("r-399"), "status": .string("ineligible"), "limit": .number(20)]), f)
            let reasons = Set((ineligible["verifications"]?.array ?? []).compactMap { $0["eligibilityReason"]?.string })
            #expect(reasons.contains("compositeCommand"))
            #expect(reasons.contains("nonzeroExit"))
            #expect(reasons.contains("exitCodeUnknown"))

            // The report itself is still readable in full.
            let report = try await invoke("read_run_output", .object(["runID": .string("r-399")]), f)
            #expect(report["text"]?.string?.contains("# 보고서") == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func cursorIsPinnedToTheResultVersionAndPagesDoNotRepeatTheWholeRun() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t"), run = try await f.dispatch("r-page", issue: issue)
            let fixture = try records(f, count: 60)
            try await save(f, run: run, fixture.records, report: fixture.report)

            let first = try await invoke("get_run", .object([
                "runID": .string("r-page"), "order": .string("oldest"), "limit": .number(10)]), f)
            let cursor = try #require(first["nextCursor"]?.string)
            #expect(first["run"]?["progress"] != nil)
            let second = try await invoke("get_run", .object([
                "runID": .string("r-page"), "order": .string("oldest"), "cursor": .string(cursor)]), f)
            #expect(second["changed"]?.bool == false)
            #expect(second["run"]?["progress"] == nil)
            #expect(second["run"]?["resultVersion"]?.string == first["resultVersion"]?.string)
            #expect(second["verifications"]?.array?.first?["verificationID"]?.string == "v-10")

            let firstPageBytes = try first.jsonLine().count
            let followPageBytes = try second.jsonLine().count
            #expect(followPageBytes < firstPageBytes)

            // A new saved result invalidates the cursor instead of mixing two snapshots.
            var changed = fixture.records
            changed.append(.init(id: "v-late", command: ["swift", "test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: fixture.records[0].logPath, summary: "late"))
            let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c2", diffPath: nil,
                                   summary: "결과2", verifications: changed, reportPath: fixture.report)
            _ = try await f.session.receive(.init(id: "saved-2", runID: run, at: .now, payload: .saveResult(result)))
            let stale = try await invoke("get_run", .object([
                "runID": .string("r-page"), "order": .string("oldest"), "cursor": .string(cursor)]), f)
            #expect(stale["changed"]?.bool == true)
            #expect(stale["run"]?["resultVersion"]?.string != first["resultVersion"]?.string)
            #expect(stale["verifications"]?.array?.first?["verificationID"]?.string == "v-0")

            let bad = try await rejected("get_run", .object([
                "runID": .string("r-page"), "cursor": .string("nonsense")]), f)
            #expect(bad.contains("커서"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func selectedLogsReadTogetherAndReportTheirExactSource() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t"), run = try await f.dispatch("r-batch", issue: issue)
            let fixture = try records(f, count: 20)
            try await save(f, run: run, fixture.records, report: fixture.report)
            let ids = ["v-1", "v-2", "v-3"]
            let logs = try await invoke("read_run_output", .object([
                "runID": .string("r-batch"), "verificationIDs": .array(ids.map(OMPJSON.string)),
                "mode": .string("tail"), "limit": .number(9000)]), f)
            let entries = try #require(logs["logs"]?.array)
            #expect(entries.count == 3)
            #expect(entries.compactMap { $0["verificationID"]?.string } == ids)
            #expect(entries.allSatisfy { ($0["logPath"]?.string?.isEmpty == false) && $0["fileHash"]?.string?.isEmpty == false })
            #expect(entries[0]["omittedBefore"]?.bool == false)
            #expect(entries[0]["text"]?.string?.contains("ok 1") == true)
            #expect(logs["run"]?["progress"] == nil)

            // Only this run's saved IDs are readable; a foreign ID is rejected, not silently empty.
            let foreign = try await rejected("read_run_output", .object([
                "runID": .string("r-batch"), "verificationIDs": .array([.string("v-1"), .string("v-foreign")])]), f)
            #expect(foreign.contains("v-foreign"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func judgeRulesAndEligibilityProjectionStayIdentical() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let issue = try await f.issue("t"), run = try await f.dispatch("r-judge", issue: issue)
            let fixture = try records(f, count: 40)
            try await save(f, run: run, fixture.records, report: fixture.report)
            let response = try await invoke("get_run", .object([
                "runID": .string("r-judge"), "limit": .number(20)]), f)
            for record in response["verifications"]?.array ?? [] {
                let id = try #require(record["verificationID"]?.string)
                let saved = try #require(fixture.records.first { $0.id == id })
                let projected = record["usableAsProof"]?.bool
                #expect(projected == StallariReadback.facts(saved).usableAsProof)
            }
            // Composite and non-zero records stay ineligible here exactly as judge_issue rejects them.
            await #expect(throws: StallariError.self) {
                _ = try await f.session.performTool("judge_issue", arguments: .object([
                    "issueID": .string("t"), "runID": .string("r-judge"),
                    "evidence": .array([.object(["criterionIndex": .number(0), "met": .bool(true),
                        "verificationIDs": .array([.string("v-1")]), "explanation": .string("복합 명령 통과")])])]))
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
