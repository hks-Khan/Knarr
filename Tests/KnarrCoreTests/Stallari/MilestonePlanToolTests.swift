import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct MilestonePlanToolTests {
    private func tool(_ name: String) throws -> OMPJSON {
        try #require(StallariTools.definitions.first { $0["name"]?.string == name })
    }

    @Test func planToolsAreExposedWithShortDescriptions() throws {
        for name in ["list_milestones", "create_milestone", "update_milestone", "set_week_plan"] {
            #expect(StallariTools.names.contains(name))
            let definition = try tool(name)
            let description = try #require(definition["description"]?.string)
            #expect(description.contains("user asks") || name == "list_milestones")
        }
        #expect(try tool("create_milestone")["parameters"]?["required"]?.array == [.string("title")])
        #expect(try tool("update_milestone")["parameters"]?["required"]?.array == [.string("milestoneID")])
        #expect(try tool("set_week_plan")["parameters"]?["required"]?.array == [.string("plan")])
        let prompt = StallariTools.fixedInstructions
        #expect(prompt.contains("create_milestone"))
        #expect(prompt.contains("set_week_plan"))
    }

    @Test func createAndUpdateUseProjectAuthorityAndTheStoredValidation() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.appendingPathComponent("other").path))
        let archivedPath = f.directory.appendingPathComponent("archived").path
        try await f.repository.saveProject(.init(id: "gone", name: "보관", absolutePath: archivedPath, archivedAt: .now))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        do {
            // A project conversation can only write its own project.
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("create_milestone", arguments: .object([
                    "projectID": .string("other"), "title": .string("남의 단계")]))
            }
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("create_milestone", arguments: .object([
                    "projectID": .string("gone"), "title": .string("보관 단계")]))
            }
            let created = try await session.performTool("create_milestone", arguments: .object([
                "title": .string("첫 단계"),
                "criteria": .array([.string("테스트가 통과한다")]),
                "targetDate": .string("2026-12-01")]))
            let firstID = try #require(created["milestoneID"]?.string)
            #expect(created["status"]?.string == "planned")
            let second = try await session.performTool("create_milestone", arguments: .object([
                "title": .string("둘째 단계"), "prerequisites": .array([.string(firstID)])]))
            let secondID = try #require(second["milestoneID"]?.string)
            #expect(second["order"]?.integer == 1)

            // Reached without verified criteria is rejected by the stored rule.
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("update_milestone", arguments: .object([
                    "milestoneID": .string(firstID), "status": .string("reached")]))
            }
            // Unknown, foreign and cyclic prerequisites are rejected by the repository.
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("update_milestone", arguments: .object([
                    "milestoneID": .string(secondID), "prerequisites": .array([.string("missing")])]))
            }
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("update_milestone", arguments: .object([
                    "milestoneID": .string(firstID), "prerequisites": .array([.string(secondID)])]))
            }
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("update_milestone", arguments: .object([
                    "milestoneID": .string("nope"), "title": .string("없음")]))
            }

            // The update keeps fields the model did not mention.
            var stored = try #require(try await f.repository.milestone(.init(firstID)))
            stored.detail = "저장된 설명"
            stored.inScope = ["범위"]
            try await f.repository.saveMilestone(stored)
            let updated = try await session.performTool("update_milestone", arguments: .object([
                "milestoneID": .string(firstID),
                "criteria": .array([.string("테스트가 통과한다")]),
                "reachedEvidence": .array([.string("swift test → 0")]),
                "status": .string("reached")]))
            #expect(updated["status"]?.string == "reached")
            let saved = try #require(try await f.repository.milestone(.init(firstID)))
            #expect(saved.isReached)
            #expect(saved.detail == "저장된 설명")
            #expect(saved.inScope == ["범위"])
            #expect(saved.weeks.isEmpty)

            // Archived and foreign projects are not resolvable for the plan either.
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("list_milestones", arguments: .object([
                    "projectID": .string("gone")]))
            }
            // The list tool reports what was stored.
            let list = try await session.performTool("list_milestones", arguments: .object([:]))
            #expect(list["projectID"]?.string == "p")
            let titles = (list["milestones"]?.array ?? []).compactMap { $0["title"]?.string }
            #expect(titles == ["첫 단계", "둘째 단계"])
            #expect((list["milestones"]?.array ?? []).first?["status"]?.string == "reached")

            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }

    @Test func weekPlanToolWritesOnlyThisWeekForTheOwnedProject() async throws {
        let f = try await StallariFixture.make()
        try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: f.directory.appendingPathComponent("other").path))
        let thread = try await f.repository.createProjectConversation(projectID: "p")
        let session = StallariSession(repository: f.repository, rpc: TestStallariRPC(), hird: f.hird, threadID: thread.id)
        do {
            await #expect(throws: StallariError.self) {
                _ = try await session.performTool("set_week_plan", arguments: .object([
                    "projectID": .string("other"), "plan": .array([.string("남의 계획")])]))
            }
            let result = try await session.performTool("set_week_plan", arguments: .object([
                "plan": .array([.string("저장 계약"), .string("화면 연결")])]))
            #expect(result["projectID"]?.string == "p")
            let stored = try #require(try await f.repository.weekPlans(projectID: "p").first)
            #expect(stored.weekStart == ProjectWeek.start(containing: .now))
            #expect(stored.plan == ["저장 계약", "화면 연결"])
            let list = try await session.performTool("list_milestones", arguments: .object([:]))
            #expect(list["weekPlan"]?.array?.compactMap(\.string) == ["저장 계약", "화면 연결"])

            // Clearing is an empty complete list, not an omitted argument.
            _ = try await session.performTool("set_week_plan", arguments: .object(["plan": .array([])]))
            #expect(try await f.repository.weekPlans(projectID: "p").first?.plan.isEmpty == true)
            _ = await session.shutdown(); try await f.cleanup()
        } catch { _ = await session.shutdown(); try await f.cleanup(); throw error }
    }
}
