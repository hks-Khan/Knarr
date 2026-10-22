import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct MilestoneIssueTests {
    private func milestone(_ id: String, project: String = "p", status: Milestone.Status = .active,
                           title: String = "1차 정리") -> Milestone {
        var value = Milestone(id: .init(id), projectID: project, order: 0, title: title, status: status,
            targetDate: .now.addingTimeInterval(7 * 86400),
            criteria: status == .reached
                ? [.init(text: "확인했다", state: .met, evidence: "실행 기록")]
                : [.init(text: "확인했다", state: .pending, evidence: "")])
        if status == .reached { value.reachedAt = .now }
        return value
    }

    @Test func createIssueStoresTheNamedMilestoneAndRejectsForeignOrMissingOnes() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.path))
        try await f.repository.saveMilestone(milestone("m1"))
        try await f.repository.saveMilestone(milestone("foreign", project: "other"))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        do {
            let id = try await session.createIssue(id: "owned", title: "마일스톤 작업", criteria: ["검사"],
                instruction: "검사", milestoneID: .init("m1"))
            let saved = try #require(try await f.repository.snapshot().issues.first { $0.id == id })
            #expect(saved.milestoneID == Milestone.ID("m1"))
            // Replaying the same request returns the same issue; a different milestone conflicts.
            #expect(try await session.createIssue(id: "owned", title: "마일스톤 작업", criteria: ["검사"],
                instruction: "검사", milestoneID: .init("m1")) == id)
            await #expect(throws: StallariError.conflictingID) {
                _ = try await session.createIssue(id: "owned", title: "마일스톤 작업", criteria: ["검사"],
                    instruction: "검사", milestoneID: nil)
            }
            await #expect(throws: StallariError.self) {
                _ = try await session.createIssue(id: "foreign", title: "다른 프로젝트 마일스톤", criteria: ["검사"],
                    instruction: "검사", milestoneID: .init("foreign"))
            }
            await #expect(throws: StallariError.self) {
                _ = try await session.createIssue(id: "missing", title: "없는 마일스톤", criteria: ["검사"],
                    instruction: "검사", milestoneID: .init("nope"))
            }
            // Unassigned issues remain valid.
            let plain = try await session.createIssue(id: "plain", title: "연결 없는 작업", criteria: ["검사"], instruction: "검사")
            #expect(try await f.repository.snapshot().issues.first { $0.id == plain }?.milestoneID == nil)
            #expect(try await f.repository.snapshot().issues.count == 2)
            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func createIssueToolReportsTheStoredMilestoneID() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveMilestone(milestone("m1"))
        do {
            let result = try await f.session.performTool("create_issue", arguments: .object([
                "issueID": .string("tool-owned"), "title": .string("도구 작업"),
                "criteria": .array([.string("검사")]), "instruction": .string("검사"),
                "projectID": .string("p"), "milestoneID": .string("m1")
            ]))
            #expect(result["milestoneID"]?.string == "m1")
            await #expect(throws: StallariError.self) {
                _ = try await f.session.performTool("create_issue", arguments: .object([
                    "issueID": .string("tool-wrong"), "title": .string("잘못된 연결"),
                    "criteria": .array([.string("검사")]), "instruction": .string("검사"),
                    "projectID": .string("p"), "milestoneID": .string("nope")
                ]))
            }
            #expect(try await f.repository.snapshot().milestones.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func reachedMilestoneTakesNoNewIssue() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveMilestone(milestone("done", status: .reached, title: "끝난 단계"))
        do {
            await #expect(throws: StallariError.self) {
                _ = try await f.session.createIssue(id: "late", title: "지난 단계 작업", criteria: ["검사"],
                    instruction: "검사", milestoneID: .init("done"))
            }
            #expect(try await f.repository.snapshot().issues.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
