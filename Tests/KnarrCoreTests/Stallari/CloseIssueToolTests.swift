import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct CloseIssueToolTests {
    @Test func closesLegacyIssueWithoutGrantingExecutionAndPreservesHistory() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = KnarrCore.Issue.ID("legacy")
            let issue = KnarrCore.Issue(id: id, title: "예전 실행 없음", projectName: "project", state: .running,
                headline: "실행 중", detail: "보존된 기록", acceptance: [.init(text: "검사", state: .pending, evidence: "")],
                hirds: [], events: [], startedAt: .now)
            try await f.repository.saveIssue(issue, projectID: "p")
            let replacement = try await f.issue("replacement")
            let before = try await f.repository.snapshot()
            let result = try await f.session.performTool("close_issue", arguments: .object([
                "issueID": .string(id.rawValue), "reason": .string("superseded"),
                "note": .string("새 제안으로 대체해 주세요"), "supersededBy": .string(replacement.rawValue)]))
            #expect(result["status"]?.string == "closed")
            let after = try await f.repository.snapshot()
            let closed = try #require(after.issues.first { $0.id == id })
            #expect(closed.archivedAt != nil)
            #expect(closed.acceptance == issue.acceptance)
            #expect(closed.state == .running)
            #expect(Panel.sections(for: after.issues).flatMap(\.issues).allSatisfy { $0.id != id })
            #expect(after.runs == before.runs)
            #expect(after.chat == before.chat)
            #expect(closed.archiveNote == "새 제안으로 대체해 주세요")
            #expect(closed.supersededBy == replacement)
            #expect(try await f.session.getRuntime()["capabilities"]?.array?.contains(.string("close_issue")) == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func activeRunAndInvalidReplacementRejectClosure() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("active")
            _ = try await f.session.approveIssue(issueID: id, version: 1)
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("close_issue", arguments: .object([
                    "issueID": .string(id.rawValue), "reason": .string("cancelled"), "note": .string("닫기")]))
            }
            let other = try await f.issue("other")
            await #expect(throws: (any Error).self) {
                _ = try await f.session.performTool("close_issue", arguments: .object([
                    "issueID": .string(other.rawValue), "reason": .string("superseded"), "note": .string("대체"), "supersededBy": .string("missing")]))
            }
            #expect(try await f.repository.snapshot().issues.allSatisfy { $0.archivedAt == nil })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
