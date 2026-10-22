import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct IssueReadbackSizeTests {
    private func invoke(_ name: String, _ args: OMPJSON, _ f: StallariFixture) async throws -> OMPJSON {
        let id = UUID().uuidString
        await f.rpc.emit(.frame(.object(["type": .string("host_tool_call"), "id": .string(id), "toolName": .string(name), "arguments": args])))
        for _ in 0..<300 {
            if let reply = await f.rpc.sent.first(where: { $0["id"]?.string == id }) {
                #expect(reply["isError"]?.bool != true)
                let details = try #require(reply["result"]?["details"])
                #expect(reply["result"]?["content"]?.array?.first?["text"]?.string == String(decoding: try details.jsonLine().dropLast(), as: UTF8.self))
                return details
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OMPRPCError.timedOut
    }
    @Test func statusOmitsDetailedChecksButPreservesApprovalAndPagedEvidence() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            let criterion = String(repeating: "완료 조건 ", count: 800)
            let instruction = String(repeating: "정확한 승인 지시 ", count: 800)
            let issue = try await f.legacyIssue(id: "t", title: "상태 조회", criteria: [criterion], instruction: instruction)
            let run = try await f.dispatch("r", issue: issue)
            let checks = (0..<205).map { i in VerificationRecord(id: "v-\(i)", command: ["swift", "test"], workingDirectory: f.directory.path,
                startedAt: .now, finishedAt: .now, exitCode: 0, logPath: "/log/\(i)", summary: String(repeating: "상세 기록", count: 100)) }
            let result = RunResult(worktreePath: f.directory.path, branch: "branch", commit: "commit", diffPath: "/diff", summary: "결과 요약", verifications: checks, reportPath: "/report")
            _ = try await f.session.receive(.init(id: "saved", runID: run, at: .now, payload: .saveResult(result)))
            let before = try await f.repository.snapshot().issues[0]
            let details = try await invoke("get_issue", .object(["issueID": .string("t")]), f)
            let compact = try #require(details["issue"])
            #expect(compact["latestResult"]?["verifications"] == nil)
            #expect(compact["latestResult"]?["verificationCount"]?.integer == 205)
            #expect(compact["latestResult"]?["reportAvailable"]?.bool == true)
            #expect(compact["latestResult"]?["commit"]?.string == "commit")
            #expect(compact["proposal"]?["instruction"]?.string == instruction)
            #expect(compact["proposal"]?["version"]?.integer == before.proposal?.version)
            #expect(compact["proposal"]?["model"]?.string == before.proposal?.model)
            #expect(compact["acceptance"]?.array?.first?["text"]?.string == criterion)
            #expect(compact["approval"] != nil)
            #expect(details["runs"]?.array?.first?["runID"]?.string == "r")
            let fullSize = try JSONEncoder().encode(before).count
            #expect(try compact.jsonLine().count < fullSize / 2)
            var offset = 0, ids: [String] = []
            repeat {
                let page = try await invoke("get_run", .object(["runID": .string("r"), "offset": .number(Double(offset)), "limit": .number(20)]), f)
                ids += page["verifications"]?.array?.compactMap { $0["verificationID"]?.string } ?? []
                guard let next = page["nextOffset"]?.integer else { break }
                #expect(next > offset); if next <= offset { break }; offset = next
            } while true
            #expect(ids == checks.map(\.id))
            #expect(try await f.repository.snapshot().issues[0].latestResult == result)
            print("READBACK_BYTES full=\(fullSize) compact=\(try compact.jsonLine().count)")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
