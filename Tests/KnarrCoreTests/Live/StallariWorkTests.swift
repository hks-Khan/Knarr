import Foundation
import Testing
@testable import KnarrCore

struct StallariWorkTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func lifecycle(_ id: String, _ status: String, name: String? = nil) -> OMPJSON {
        var payload: [String: OMPJSON] = ["id": .string(id), "status": .string(status),
            "index": .number(0), "agent": .string("task"), "parentToolCallId": .string("spawn")]
        if let name { payload["name"] = .string(name) }
        return .object(["type": .string("subagent_lifecycle"), "payload": .object(payload)])
    }

    static func progress(_ id: String, _ status: String = "running", tool: String? = "read") -> OMPJSON {
        var progress: [String: OMPJSON] = ["id": .string(id), "status": .string(status), "toolCount": .number(1)]
        if let tool { progress["currentTool"] = .string(tool) }
        return .object(["type": .string("subagent_progress"), "payload": .object([
            "parentToolCallId": .string("spawn"), "task": .string("검사"), "progress": .object(progress)])])
    }

    @Test func duplicateStartsPreserveTimeAndOnlyRealChildProgressRefreshesActivity() throws {
        var state = OMPSubagentActivity()
        #expect(state.receive(Self.lifecycle("a", "started", name: "IntegrateTabs"), at: now) != nil)
        #expect(state.receive(Self.lifecycle("a", "started"), at: now.addingTimeInterval(10)) == nil)
        #expect(state.active.map(\.name) == ["IntegrateTabs"])
        #expect(state.active.first?.startedAt == now)
        #expect(state.receive(Self.progress("unknown"), at: now.addingTimeInterval(20)) == nil)
        #expect(state.receive(.object(["type": .string("tool_execution_start"), "toolName": .string("wait")]), at: now.addingTimeInterval(30)) == nil)
        #expect(state.active.first?.lastActivityAt == now)
        #expect(state.receive(Self.progress("a"), at: now.addingTimeInterval(60)) != nil)
        #expect(state.active.first?.currentCommand == "read")
        #expect(state.receive(Self.progress("a"), at: now.addingTimeInterval(120)) != nil)
        #expect(state.active.first?.lastActivityAt == now.addingTimeInterval(120))
        let work = try #require(state.active.first)
        #expect(IssueCards.quietLabel(for: work, now: now.addingTimeInterval(209)) == nil)
        #expect(IssueCards.quietLabel(for: work, now: now.addingTimeInterval(210)) == "1분째 조용함")
        #expect(IssueCards.elapsed(from: work.startedAt, to: now.addingTimeInterval(3599)) == "59분째")
        #expect(IssueCards.elapsed(from: work.startedAt, to: now.addingTimeInterval(3660)) == "1시간 1분째")
    }

    @Test(arguments: ["completed", "failed", "aborted"])
    func lifecycleAndProgressTerminalsRemoveOnlyTheirChildAndIgnoreLateProgress(status: String) {
        for terminal in [Self.lifecycle("a", status), Self.progress("a", status)] {
            var state = OMPSubagentActivity()
            _ = state.receive(Self.lifecycle("a", "started"), at: now)
            _ = state.receive(Self.lifecycle("b", "started"), at: now)
            #expect(state.receive(terminal, at: now.addingTimeInterval(1)) != nil)
            #expect(state.active.map(\.id) == ["b"])
            #expect(state.receive(Self.progress("a"), at: now.addingTimeInterval(2)) == nil)
            _ = state.receive(Self.lifecycle("b", status), at: now.addingTimeInterval(3))
            #expect(state.active.isEmpty)
        }
    }

    @Test func workCardSharesInProgressOrderingAndDisappearsWhenEmpty() {
        let fixture = IssueCardsTests()
        var running = fixture.issue("running")
        running.hirds = [.init(id: "r", name: "Hird", role: "", status: .working,
            steps: [], currentCommand: nil, lastActivityAt: now)]
        let issues = [running, fixture.issue("approval", state: .awaitingApproval), fixture.issue("input", state: .needsInput)]
        let work = SubagentWork(id: "IntegrateTabs", name: "IntegrateTabs", currentCommand: "read", startedAt: now, lastActivityAt: now)
        let cards = IssueCards(issues: issues, stallariWork: [work], scope: .allProjects)
        #expect(cards.entries.map(\.id) == ["issue:input", "issue:approval", "stallari-work", "issue:running"])
        #expect(IssueCards(issues: issues, scope: .allProjects).entries.map(\.id) == ["issue:input", "issue:approval", "issue:running"])
    }
}

@MainActor @Suite(.serialized) struct StallariWorkConversationTests {
    @Test func mainAndIssueWorkStayWithTheirConversationAndAreNotRestored() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-stallari-work-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        f.store.setThreadFactory { thread in
            let rpc = LiveTestRPC()
            return LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: rpc, hird: f.hird, threadID: thread.id),
                rpc: rpc, hird: f.hird, threadID: thread.id, preferences: preferences)
        }
        do {
            _ = try await f.session.createIssue(id: "work-owner", title: "작업 범위", criteria: ["검사"], instruction: "검사", projectID: "p")
            try await f.store.whenIdle()
            await f.store.observe(frame: StallariWorkTests.lifecycle("MainResearch", "started"))
            f.store.goToThread(for: "work-owner")
            try await f.store.whenIdle()
            let issueThread = try #require(f.store.selectedIssue?.conversationThreadID)
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: StallariWorkTests.lifecycle("IntegrateTabs", "started"), threadID: issueThread)
            await f.store.observe(frame: StallariWorkTests.progress("MainResearch", tool: "grep"))
            #expect(f.store.stallariWork.map(\.id) == ["IntegrateTabs"])
            f.store.selectThread(ConversationThread.defaultID)
            try await f.store.whenIdle()
            #expect(f.store.stallariWork.map(\.id) == ["MainResearch"])
            #expect(f.store.stallariWork.first?.currentCommand == "grep")
            await f.store.observe(frame: StallariWorkTests.lifecycle("MainResearch", "completed"))
            #expect(!f.store.topIssueCards.entries.contains { $0.id == "stallari-work" })
            f.store.selectThread(issueThread)
            try await f.store.whenIdle()
            #expect(f.store.stallariWork.map(\.id) == ["IntegrateTabs"])
            let freshRPC = LiveTestRPC()
            let fresh = LiveConversation(repository: f.repository,
                session: StallariSession(repository: f.repository, rpc: freshRPC, hird: f.hird, threadID: issueThread),
                rpc: freshRPC, hird: f.hird, threadID: issueThread, preferences: preferences)
            try await fresh.connect()
            #expect(fresh.stallariWork.isEmpty)
            _ = await fresh.shutdown(includeSharedHird: false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func restartGenerationExitAndShutdownClearEphemeralWork() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.store.observe(frame: .object(["type": .string("knarr_rpc_ready"), "generation": .string("old")]))
            await f.store.observe(frame: StallariWorkTests.lifecycle("old-child", "started"))
            await f.store.observe(frame: .object(["type": .string("knarr_rpc_restarting")]))
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: StallariWorkTests.lifecycle("late-child", "started"))
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: .object(["type": .string("knarr_rpc_ready"), "generation": .string("new")]))
            guard case .object(var stale) = StallariWorkTests.lifecycle("stale", "started") else { return }
            stale["knarrRPCGeneration"] = .string("old")
            await f.store.observe(frame: .object(stale))
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: StallariWorkTests.lifecycle("live-child", "started"))
            await f.rpc.terminate()
            for _ in 0..<200 {
                if f.store.stallariWork.isEmpty { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: .object(["type": .string("knarr_rpc_ready"), "generation": .string("third")]))
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: StallariWorkTests.lifecycle("shutdown-child", "started"))
            _ = await f.store.shutdown()
            #expect(f.store.stallariWork.isEmpty)
            await f.store.observe(frame: StallariWorkTests.lifecycle("after-close", "started"))
            #expect(f.store.stallariWork.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
