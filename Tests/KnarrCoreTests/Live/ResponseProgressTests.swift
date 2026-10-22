import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ResponseProgressTests {
    private func deliver(_ frame: OMPJSON, to store: LiveKnarrStore) async {
        await store.observe(frame: frame)
    }

    @Test func inspectionConfirmationAndRetryKeepReadOnlyMode() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.session.updateIssueProposal(issueID: "t", expectedVersion: 1, instruction: "읽기 전용 조사", mode: .inspect)
            try await f.dispatch()
            let report = f.directory.appendingPathComponent("inspection.md")
            try "조사 보고와 확인 근거".write(to: report, atomically: true, encoding: .utf8)
            let result = RunResult(worktreePath: f.directory.path, branch: nil, commit: nil, diffPath: nil,
                summary: "조사 결과", verifications: f.result().verifications, reportPath: report.path)
            _ = try await f.session.receive(.init(id: "inspection-complete", runID: "r", at: .now, payload: .complete(result, notificationID: "n")))
            try await f.session.judge(issueID: "t", runID: "r", evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "조사 근거 확인")])
            f.store.perform(.confirmResult, on: "t")
            try await f.store.whenIdle()
            let confirmed = try #require(try await f.repository.snapshot().issues.first)
            #expect(confirmed.confirmed)
            #expect(confirmed.application == nil) // No merge attempt for an inspection.
            f.store.perform(.requestChanges(note: ""), on: "t")
            try await f.store.whenIdle()
            #expect(try await f.repository.snapshot().runs.last?.mode == .inspect)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func responseRemainsVisibleThroughTextAndToolsUntilCorrelatedCompletion() async throws {
        let f = try await LiveFixture.make()
        do {
            #expect(!f.store.isResponding)
            f.store.send("설명해 주세요", about: nil)
            #expect(f.store.isResponding) // Before any suspension, persistence or first token.
            try await f.store.whenIdle()
            #expect(f.store.isResponding) // Admission is not completion.
            let id = try #require(await f.rpc.promptIDs.last)
            await deliver(.object(["type": .string("agent_start")]), to: f.store)
            await deliver(.object(["type": .string("message_update"), "messageId": .string("msg-1"), "message": .object([
                "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("부분 응답")])])
            ])]), to: f.store)
            #expect(f.store.streamingText == "부분 응답")
            #expect(f.store.isResponding)
            await deliver(.object(["type": .string("message_end"), "messageId": .string("msg-1"), "message": .object([
                "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("완성 본문")])])
            ])]), to: f.store)
            try await f.store.whenIdle()
            #expect(f.store.streamingText.isEmpty)
            #expect(f.store.chat.filter { $0.kind == .stallari("완성 본문", project: nil) }.count == 1)
            await deliver(.object(["type": .string("tool_execution_start")]), to: f.store)
            #expect(f.store.isResponding)
            await deliver(.object(["type": .string("agent_end")]), to: f.store)
            #expect(f.store.isResponding)
            await deliver(.object(["type": .string("prompt_result"), "id": .string(id), "status": .string("completed")]), to: f.store)
            #expect(!f.store.isResponding)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test(arguments: ["completed", "error", "aborted"])
    func terminalAndNextSend(status: String) async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("첫 요청", about: nil)
            try await f.store.whenIdle()
            let first = try #require(await f.rpc.promptIDs.last)
            await deliver(.object(["type": .string("agent_start")]), to: f.store)
            f.store.send("다음 요청", about: nil)
            await deliver(.object(["type": .string("prompt_result"), "id": .string(first), "status": .string(status)]), to: f.store)
            #expect(f.store.isResponding) // New submission has not even reached RPC yet.
            try await f.store.whenIdle()
            let second = try #require(await f.rpc.promptIDs.last)
            #expect(second != first)
            await deliver(.object(["type": .string("message_update"), "messageId": .string("msg-2"), "message": .object([
                "role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("종료 전 부분 본문")])])
            ])]), to: f.store)
            #expect(f.store.streamingText == "종료 전 부분 본문")
            await deliver(.object(["type": .string("session_settled")]), to: f.store)
            await deliver(.object(["type": .string("prompt_result"), "id": .string(first), "status": .string(status)]), to: f.store)
            #expect(f.store.isResponding)
            await deliver(.object(["type": .string("prompt_result"), "id": .string(second), "status": .string(status)]), to: f.store)
            #expect(!f.store.isResponding)
            #expect(f.store.streamingText.isEmpty)
            #expect(f.store.chat.contains { $0.kind == .stallari("종료 전 부분 본문", project: nil) })
            f.store.send("다시 시작", about: nil)
            #expect(f.store.isResponding)
            try await f.cleanup()
            #expect(!f.store.isResponding)
        } catch { try await f.cleanup(); throw error }
    }

    @Test func rejectedSendAndBlankInputDoNotLeaveIndicator() async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("  ", about: nil)
            #expect(!f.store.isResponding)
            f.store.send("실패", about: nil, project: "missing")
            #expect(f.store.isResponding)
            try await f.store.whenIdle()
            #expect(!f.store.isResponding)
            #expect(f.store.lastError != nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func completionBeforeAdmissionContinuationDoesNotStick() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.rpc.onPromptReply { [store = f.store] id in
                await store.observe(frame: .object(["type": .string("agent_start")]))
                await store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(id), "status": .string("aborted")]))
            }
            f.store.send("빠른 취소", about: nil)
            #expect(f.store.isResponding)
            try await f.store.whenIdle()
            #expect(!f.store.isResponding)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func processExitClearsIndicatorViaSubscribedEvents() async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("연결 종료", about: nil)
            try await f.store.whenIdle()
            #expect(f.store.isResponding)
            await f.rpc.terminate()
            for _ in 0..<200 {
                if !f.store.isResponding { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!f.store.isResponding)
            #expect(f.store.streamingText.isEmpty)
            #expect(f.store.stallari.engine == "OMP · 실행 종료")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
