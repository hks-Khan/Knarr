import Foundation
import Testing
@testable import KnarrCore

/// Focused checks for the review-readback fixes: cursor extremes, the shared byte budget,
/// byte-exact search, exact inspection semantics, and segment-backed invalidation.
@Suite(.serialized) struct ReviewSearchEdgeTests {
    private func raw(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> (isError: Bool, details: OMPJSON, text: String) {
        let id = UUID().uuidString
        await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<400 {
            if let reply = await f.rpc.sent.first(where: { $0["id"]?.string == id }) {
                return (reply["isError"]?.bool == true,
                        reply["result"]?["details"] ?? .null,
                        reply["result"]?["content"]?.array?.first?["text"]?.string ?? "")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }

    private func invoke(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> OMPJSON {
        let call = try await raw(name, args, f)
        #expect(!call.isError, "\(call.text)")
        return call.details
    }

    private func setup(_ f: StallariFixture, records: [VerificationRecord]) async throws -> HirdRun.ID {
        try await f.session.connect()
        let issue = try await f.issue("t")
        let run = try await f.dispatch("r", issue: issue)
        let result = RunResult(worktreePath: f.directory.path, branch: "b", commit: "c", diffPath: nil,
            summary: "결과", verifications: records, reportPath: records.first?.logPath)
        _ = try await f.session.receive(.init(id: "end", runID: run, at: .now,
            payload: .complete(result, notificationID: "notice")))
        return run
    }

    private func record(_ f: StallariFixture, _ id: String, command: [String] = ["swift", "test"],
                        exit: Int32? = 0, log: String = "ok\n", kind: VerificationRecord.Kind? = nil) throws -> VerificationRecord {
        let path = f.directory.appendingPathComponent("\(id).log")
        try log.write(to: path, atomically: true, encoding: .utf8)
        return .init(id: id, command: command, workingDirectory: f.directory.path,
                     startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                     exitCode: exit, logPath: path.path, summary: "check", kind: kind)
    }

    // MARK: - Cursor extremes

    @Test func cursorRejectsNegativeAndMalformedOffsets() async throws {
        let f = try await StallariFixture.make()
        do {
            let records = try (0..<5).map { try record(f, "v\($0)") }
            _ = try await setup(f, records: records)
            let first = try await invoke("get_run", .object([
                "runID": .string("r"), "order": .string("oldest"), "limit": .number(2)]), f)
            let cursor = try #require(first["nextCursor"]?.string)
            let parts = cursor.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            #expect(parts.count == 4)

            // A valid shape with a negative offset must be refused, not indexed.
            let negative = [parts[0], parts[1], "-1", parts[3]].joined(separator: ".")
            let negativeCall = try await raw("get_run", .object(["runID": .string("r"), "cursor": .string(negative)]), f)
            #expect(negativeCall.isError)
            #expect(negativeCall.text.contains("커서"))

            for bad in ["", "c1", "c1.x.y.z", "c2.\(parts[1]).0.\(parts[3])", "c1.\(parts[1]).abc.\(parts[3])",
                        "c1.\(parts[1]).99999999999999999999.\(parts[3])", "c1.\(parts[1]).0."] {
                let call = try await raw("get_run", .object(["runID": .string("r"), "cursor": .string(bad)]), f)
                #expect(call.isError, "cursor \(bad) should be rejected")
            }

            // An offset past the end returns an empty page instead of trapping.
            let beyond = try await invoke("get_run", .object([
                "runID": .string("r"), "order": .string("oldest"), "offset": .number(5_000), "limit": .number(5)]), f)
            #expect(beyond["verifications"]?.array?.isEmpty == true)
            #expect(beyond["nextCursor"] == .null)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    // MARK: - Shared budget

    @Test func batchReadNeverExceedsTheSharedByteBudget() async throws {
        let f = try await StallariFixture.make()
        do {
            let body = String(repeating: "검사 로그 줄\n", count: 400)
            let records = try (0..<8).map { try record(f, "v\($0)", log: body) }
            _ = try await setup(f, records: records)
            let ids = records.map(\.id)
            for limit in [512, 900, 4000] {
                for mode in ["tail", "range"] {
                    let page = try await invoke("read_run_output", .object([
                        "runID": .string("r"), "verificationIDs": .array(ids.map(OMPJSON.string)),
                        "mode": .string(mode), "limit": .number(Double(limit))]), f)
                    let logs = try #require(page["logs"]?.array)
                    let returned = logs.reduce(0) { $0 + ($1["returnedBytes"]?.integer ?? 0) }
                    #expect(returned <= limit, "\(mode) limit=\(limit) returned=\(returned)")
                    #expect(page["returnedBytes"]?.integer == returned)
                    let omitted = page["omittedVerificationIDs"]?.array?.compactMap(\.string) ?? []
                    #expect(logs.count + omitted.count == ids.count,
                            "every requested ID is either read or listed as omitted")
                    for entry in logs {
                        #expect((entry["returnedBytes"]?.integer ?? 0) > 0)
                    }
                }
            }
            // A limit too small to hold anything reports every ID as omitted rather than
            // silently inflating the response.
            let tiny = try await invoke("read_run_output", .object([
                "runID": .string("r"), "verificationIDs": .array(ids.map(OMPJSON.string)),
                "mode": .string("tail"), "limit": .number(1)]), f)
            #expect(tiny["returnedBytes"]?.integer == 0)
            #expect(tiny["omittedVerificationIDs"]?.array?.count == ids.count)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    // MARK: - Search byte ranges

    @Test func searchReportsEveryMatchWithExactByteRanges() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: path) }
        let text = "빌드 시작\nERROR: 하나\n중간 줄\nError: 둘\n한글 😀 끼어 있음\nerror: 셋\n끝\n"
        try text.write(to: path, atomically: true, encoding: .utf8)
        let raw = [UInt8](try Data(contentsOf: path))

        let found = try StallariReadback.search(path.path, text: "error", maxMatches: 8, context: 30, limit: 4096)
        let matches = found.matchedLines
        #expect(matches.count == 3)
        for match in matches {
            let start = try #require(match["byteStart"]?.integer)
            let end = try #require(match["byteEnd"]?.integer)
            let matchStart = try #require(match["matchStart"]?.integer)
            let matchEnd = try #require(match["matchEnd"]?.integer)
            #expect(start <= matchStart && matchEnd <= end)
            // Byte ranges point at the original case-insensitive occurrence.
            let original = String(decoding: Data(raw[matchStart..<matchEnd]), as: UTF8.self)
            #expect(original.lowercased() == "error")
            // The returned context decodes as UTF-8 from exactly those bytes.
            let context = String(decoding: Data(raw[start..<end]), as: UTF8.self)
            #expect(match["text"]?.string == context)
            #expect(context.lowercased().contains("error"))
        }

        // A budget smaller than the context window still returns exact ranges and stays in budget.
        let tight = try StallariReadback.search(path.path, text: "ERROR", maxMatches: 8, context: 200, limit: 40)
        #expect(tight.totalBytes <= 40)
        #expect(!tight.matchedLines.isEmpty)
        for match in tight.matchedLines {
            let start = try #require(match["byteStart"]?.integer)
            let end = try #require(match["byteEnd"]?.integer)
            #expect(end > start)
            #expect(end - start <= 40)
            #expect(match["byteStart"] != .null && match["byteEnd"] != .null)
            #expect(String(decoding: Data(raw[start..<end]), as: UTF8.self) == match["text"]?.string)
        }
    }

    // MARK: - Image evidence stays real pixels

    @Test func imageInspectionStaysAnActualImageRead() async throws {
        let f = try await StallariFixture.make()
        do {
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            let image = f.directory.appendingPathComponent("screen.png")
            try Data(base64Encoded: png)!.write(to: image)
            let log = f.directory.appendingPathComponent("inspection.log")
            try "Observed image: \(image.path)\n".write(to: log, atomically: true, encoding: .utf8)
            let record = VerificationRecord(id: "shot", command: ["read", "screen.png"],
                workingDirectory: f.directory.path,
                startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                exitCode: nil, logPath: log.path, summary: "실제로 읽은 문서·화면 근거",
                kind: .inspection, attachmentPaths: [image.path])
            _ = try await setup(f, records: [record])

            // The list marks it eligible, and the evidence is still the actual image bytes.
            let page = try await invoke("get_run", .object(["runID": .string("r")]), f)
            #expect(page["verifications"]?.array?.first?["usableAsProof"]?.bool == true)
            let stored = try Data(contentsOf: image)
            #expect(stored == Data(base64Encoded: png))
            let text = try StallariReadback.readRange(log.path, offset: 0, limit: 300)
            let referenced = try #require(text.text.components(separatedBy: "Observed image: ").last)
            let referencedBytes = try Data(contentsOf: URL(fileURLWithPath: referenced.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(referencedBytes == Data(base64Encoded: png))

            // A cited image inspection still satisfies the judge, and a text-only "claim" cannot.
            try await f.session.judge(issueID: "t", runID: "r", evidence: [
                .init(criterionIndex: 0, verificationIDs: ["shot"], explanation: "실제 화면 픽셀 확인")])
            #expect(try await f.repository.snapshot().issues.first?.state == KnarrCore.IssueState.done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func inspectionEligibilityReadsTheWholeFileLikeTheJudge() async throws {
        let f = try await StallariFixture.make()
        do {
            // Blank head, real content later: the judge accepts it, so the list must too.
            let blankHead = f.directory.appendingPathComponent("blank-head.log")
            try (String(repeating: "\n", count: 4000) + "실제 내용\n").write(to: blankHead, atomically: true, encoding: .utf8)
            // Large file whose visible text is only at the end.
            let tailOnly = f.directory.appendingPathComponent("tail-only.log")
            try (String(repeating: "\n", count: 200_000) + "끝의 내용\n").write(to: tailOnly, atomically: true, encoding: .utf8)
            // Invalid UTF-8 after a valid prefix: the judge rejects it, so the list must too.
            let broken = f.directory.appendingPathComponent("broken.log")
            var data = Data("앞부분은 정상\n".utf8)
            data.append(contentsOf: [0xFF, 0xFE, 0xFD])
            try data.write(to: broken)
            // Whitespace only.
            let blank = f.directory.appendingPathComponent("blank.log")
            try "   \n\n".write(to: blank, atomically: true, encoding: .utf8)

            func inspection(_ id: String, _ path: URL) -> VerificationRecord {
                .init(id: id, command: ["read", path.lastPathComponent], workingDirectory: f.directory.path,
                      startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                      exitCode: nil, logPath: path.path, summary: "inspection", kind: .inspection)
            }
            let records = [inspection("blank-head", blankHead), inspection("tail-only", tailOnly),
                           inspection("broken", broken), inspection("blank", blank)]
            _ = try await setup(f, records: records)

            let page = try await invoke("get_run", .object(["runID": .string("r"), "limit": .number(20)]), f)
            let projected = Dictionary(uniqueKeysWithValues: (page["verifications"]?.array ?? []).map {
                ($0["verificationID"]?.string ?? "", $0["usableAsProof"]?.bool)
            })
            #expect(projected["blank-head"] == true)
            #expect(projected["tail-only"] == true)
            #expect(projected["broken"] == false)
            #expect(projected["blank"] == false)

            // The judge agrees on every case: same eligible IDs, same rejections.
            for record in records {
                let expected = record.id == "blank-head" || record.id == "tail-only"
                let outcome: Bool
                do {
                    _ = try await f.session.judge(issueID: "t", runID: "r", evidence: [
                        .init(criterionIndex: 0, verificationIDs: [record.id], explanation: "확인")])
                    outcome = true
                } catch { outcome = false }
                #expect(outcome == expected, "judge and list disagree for \(record.id)")
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
