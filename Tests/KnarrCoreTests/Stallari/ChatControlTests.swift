import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct ChatControlTests {
    @Test func fourProjectsCanRunTwoApprovedJobsEach() async throws {
        let f = try await StallariFixture.make()
        do {
            var ids: [KnarrCore.Issue.ID] = []
            for project in 0..<4 {
                let p = "parallel-project-\(project)"
                try await f.repository.saveProject(.init(id: p, name: p, absolutePath: f.directory.path))
                for n in 0..<2 {
                    ids.append(try await f.legacyIssue(id: .init("task-\(project)-\(n)"), title: "작업 \(project)-\(n)", criteria: ["검사"], instruction: "검사 실행", projectID: p))
                }
            }
            _ = try await f.session.send("전부 승인하고 실행해 주세요", about: nil)
            for id in ids {
                _ = try await f.session.performTool("approve_issue", arguments: .object(["issueID": .string(id.rawValue), "version": .number(1)]))
            }
            let runs = try await f.repository.snapshot().runs
            #expect(runs.count == 8)
            #expect(Dictionary(grouping: runs, by: \.projectID).values.allSatisfy { $0.count == 2 })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func thinkingChangeDuringResponseIsAppliedAtSettlement() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.session.connect()
            await f.rpc.setBusy(true)
            let queued = try await f.session.performTool("set_thinking", arguments: .object(["level": .string("off")]))
            #expect(queued["status"]?.string == "queued")
            #expect(await f.rpc.thinking == "high")
            await f.rpc.setBusy(false)
            await f.rpc.emit(.frame(.object(["type": .string("session_settled")])))
            for _ in 0..<100 {
                if await f.rpc.thinking == "off" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await f.rpc.thinking == "off")
            #expect(try await f.session.getRuntime()["hirdRequestedThinking"]?.string == "xhigh")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func legacyProposalUsesDisplayedFallbackAfterProjectSettingsChange() async throws {
        let f = try await StallariFixture.make()
        do {
            var issue = KnarrCore.Issue(id: "legacy-thinking", title: "예전 제안", projectName: "project", state: .awaitingApproval,
                headline: "", detail: "", acceptance: [.init(text: "검사", state: .pending, evidence: "")], hirds: [], events: [], startedAt: .now)
            issue.proposal = .init(instruction: "예전 지시", model: "openai-codex/fixture-model")
            try await f.repository.saveIssue(issue, projectID: "p")
            _ = try await f.session.performTool("set_project_settings", arguments: .object(["projectID": .string("p"), "hirdThinking": .string("low")]))
            let run = try await f.session.approveIssue(issueID: issue.id, version: 1)
            #expect(try await f.session.getRun(run).requestedThinking == "xhigh")
            let next = try await f.issue("new-thinking")
            let nextRun = try await f.session.approveIssue(issueID: next, version: 1)
            #expect(try await f.session.getRun(nextRun).requestedThinking == "low")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func projectSettingsChangeDoesNotChangeStallariOrLaunchWork() async throws {
        let f = try await StallariFixture.make()
        do {
            let result = try await f.session.performTool("set_project_settings", arguments: .object([
                "projectID": .string("p"), "maxHirds": .number(4), "hirdModel": .string("openai-codex/second-model"), "hirdThinking": .string("xhigh")]))
            #expect(result["before"]?["maxHirds"]?.integer == 2)
            #expect(result["after"]?["maxHirds"]?.integer == 4)
            #expect(try await f.repository.snapshot().projects.first?.settings.maxHirds == 4)
            #expect(try await f.session.getRuntime()["stallariThinking"]?.string == "high")
            #expect(await f.hird.runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func hirdThinkingIsIndependentAndFrozenWithProposal() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("independent")
            _ = try await f.session.selectThinking("off")
            let run = try await f.session.approveIssue(issueID: id, version: 1)
            #expect(try await f.session.getRun(run).requestedThinking == "xhigh")
            _ = try await f.session.selectModel("openai-codex/second-model")
            #expect(await f.hird.defaultModel == "openai-codex/fixture-model")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func explicitChatApprovalBindsSavedVersionAndIsIdempotent() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.issue("chat-approve")
            _ = try await f.session.send("합계 승인하고 실행해 주세요", about: nil)
            let arguments: OMPJSON = .object(["issueID": .string(id.rawValue), "version": .number(1)])
            let first = try await f.session.performTool("approve_issue", arguments: arguments)
            let again = try await f.session.performTool("approve_issue", arguments: arguments)
            #expect(first["runID"] == again["runID"])
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
