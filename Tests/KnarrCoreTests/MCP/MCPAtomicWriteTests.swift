import Foundation
import Testing
@testable import KnarrCore
import KnarrMCP

@MainActor @Suite(.serialized) struct MCPAtomicWriteTests {
    static func request(_ key: String) -> OMPJSON { .object([
        "projectID": .string("p"), "idempotencyKey": .string(key),
        "title": .string("정확한 재전송"), "criteria": .array([.string("첫 조건"), .string("둘째 조건")]),
        "instruction": .string("저장 경로 검사"), "handoffSummary": .string("원래 문맥")
    ]) }
    static func changing(_ request: OMPJSON, _ key: String, _ value: OMPJSON) -> OMPJSON {
        guard case .object(var fields) = request else { return request }
        fields[key] = value; return .object(fields)
    }
    @Test func createIdentityIncludesAllCallerCriteriaAndHandoff() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let original = Self.request("all-fields")
            _ = try f.payload(await f.tool("create_issue", original))
            for request in [Self.changing(original, "criteria", .array([.string("첫 조건")])),
                            Self.changing(original, "handoffSummary", .string("바뀐 문맥"))] {
                #expect(try f.errorCode(await f.tool("create_issue", request)) == "conflict")
            }
            #expect(try await f.snapshot().issues.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func simultaneousDifferentPayloadsWithOneKeyConflict() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let original = Self.request("different-concurrent")
            async let first = f.tool("create_issue", original, id: 41)
            async let second = f.tool("create_issue", Self.changing(original, "instruction", .string("다른 지시")), id: 42)
            let replies = await [first, second]
            #expect(replies.filter { $0["result"]?["isError"]?.bool == false }.count == 1)
            #expect(replies.filter { $0["result"]?["structuredContent"]?["error"]?["code"]?.string == "conflict" }.count == 1)
            #expect(try await f.snapshot().issues.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func freshAppServicePerCallStillCreatesExactlyOnce() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let lazy = LazyAdminService { f.store.adminService() }
            let original = Self.request("fresh-services")
            async let first = lazy.adminCall("create_issue", arguments: original)
            async let second = lazy.adminCall("create_issue", arguments: original)
            let replies = try await [first, second]
            #expect(replies.filter { $0["duplicate"]?.bool == false }.count == 1)
            #expect(replies.filter { $0["duplicate"]?.bool == true }.count == 1)
            #expect(try await f.snapshot().issues.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func closeRejectsVersionChangedAfterItsInitialRead() async throws {
        let f = try await MCPAdminFixture.make()
        do {
            let created = try f.payload(await f.tool("create_issue", Self.request("close-race")))
            let id = KnarrCore.Issue.ID(try #require(created["issueID"]?.string))
            let session = try await f.session(threadID: ConversationThread.defaultID)
            let service = KnarrAdminService(repository: f.repository) {
                try await session.updateIssueProposal(issueID: id, expectedVersion: 1, instruction: "동시 수정")
                return session
            }
            do {
                _ = try await service.adminCall("close_issue", arguments: .object([
                    "projectID": .string("p"), "issueID": .string(id.rawValue),
                    "expectedVersion": .number(1), "reason": .string("cancelled"), "note": .string("오래된 버전")]))
                Issue.record("stale close unexpectedly succeeded")
            } catch let error as KnarrAdminError { #expect(error.code == "conflict") }
            #expect(try await f.issue(id)?.archivedAt == nil)
            #expect(try await f.issue(id)?.proposal?.version == 2)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
