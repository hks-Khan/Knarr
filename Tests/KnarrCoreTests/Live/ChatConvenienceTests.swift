import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct ChatConvenienceTests {
    @Test func sendingPreservesExplicitLowChoice() async throws {
        let f = try await LiveFixture.make()
        do {
            _ = await f.rpc.request("set_thinking_level", fields: ["level": .string("low")], timeout: .seconds(1))
            f.store.send("선택한 설정으로 답하기", about: nil, project: "p", attachments: [])
            try await f.store.whenIdle()
            #expect(await f.rpc.thinkingLevel == "low")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func unreadableImageDoesNotSilentlySendWithoutImage() async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("이미지 확인", about: nil, project: "p", attachments: [f.directory.appendingPathComponent("missing.png")])
            try await f.store.whenIdle()
            #expect(await f.rpc.prompts.isEmpty)
            #expect(f.store.lastError != nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func newHirdRunKeepsReasoningIndependentFromStallari() async throws {
        let f = try await LiveFixture.make()
        do {
            _ = await f.rpc.request("set_thinking_level", fields: ["level": .string("low")], timeout: .seconds(1))
            try await f.create()
            _ = await f.rpc.request("set_thinking_level", fields: ["level": .string("high")], timeout: .seconds(1))
            try await f.dispatch()
            #expect(try await f.repository.snapshot().runs.first?.requestedThinking == "xhigh")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func failedAdmissionKeepsEditableDraftAndAttachments() async throws {
        let f = try await LiveFixture.make()
        do {
            let draft = ChatDraft(text: "보존할 내용", attachments: [f.directory.appendingPathComponent("missing.png")], project: "p")
            f.store.composerDraft = draft
            await #expect(throws: ChatAttachmentError.self) { try await f.store.submit(draft) }
            #expect(f.store.composerDraft == draft)
            #expect(f.store.failedDraft == draft)
            #expect(!f.store.isResponding)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func draftSurvivesReopeningStore() throws {
        let name = "knarr-draft-test-" + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let first = LiveKnarrStore(preferences: prefs)
        let draft = ChatDraft(text: "아직 보내지 않은 내용", attachments: [URL(fileURLWithPath: "/tmp/screenshot.png")], project: "p")
        first.composerDraft = draft
        #expect(LiveKnarrStore(preferences: prefs).composerDraft == draft)
    }
    @Test func attachmentsRoundTripWithChatRecord() async throws {
        let f = try await LiveFixture.make()
        do {
            var item = ChatItem(at: .now, kind: .user("첨부"))
            item.attachments = [f.directory.appendingPathComponent("screenshot.png")]
            try await f.repository.appendChat(item, projectID: "p")
            #expect(try await f.repository.snapshot().chat.first(where: { $0.id == item.id })?.attachments == item.attachments)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func promptErrorBeforeAdmissionReplyRetainsRetryDraft() async throws {
        let f = try await LiveFixture.make()
        do {
            await f.rpc.onPromptReply { id in
                await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(id), "status": .string("error")]))
            }
            let draft = ChatDraft(text: "실패해도 다시 보낼 내용", project: "p")
            try await f.store.submit(draft)
            try await f.store.whenIdle()
            #expect(f.store.failedDraft == draft)
            #expect(!f.store.isResponding)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func stopTargetsOnlyStallariAndKeepsPartialReply() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.submit(.init(text: "요청", project: "p"))
            await f.store.observe(frame: .object(["type": .string("message_update"), "messageId": .string("partial"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("중지 전 답변")])])])]))
            f.store.stopResponse()
            for _ in 0..<100 { if !f.store.isStopping { break }; try await Task.sleep(for: .milliseconds(5)) }
            #expect(await f.rpc.requests.contains { $0.0 == "abort" })
            #expect(!f.store.isResponding)
            #expect(await f.hird.cancelled.isEmpty)
            #expect(try await f.repository.snapshot().chat.contains { $0.kind == .stallari("중지 전 답변", project: nil) })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func stopBeforeAnyReplyReportsStoppedAndAcceptsNextMessage() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.submit(.init(text: "답 전에 멈출 요청", project: "p"))
            #expect(f.store.isResponding)
            f.store.stopResponse()
            for _ in 0..<100 { if !f.store.isStopping { break }; try await Task.sleep(for: .milliseconds(5)) }
            // The transcript reads this status to say the reply was stopped.
            #expect(f.store.responseStatus == "중지됨")
            #expect(!f.store.isResponding)
            try await f.store.submit(.init(text: "다음 요청", project: "p"))
            #expect(await f.rpc.prompts.count == 2)
            #expect(f.store.responseStatus != "중지됨")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func contextUsageIsTakenFromRuntimeWithoutInventedCapacity() {
        #expect(ContextUsage(state: .object([:])) == nil)
        let usage = ContextUsage(state: .object(["contextUsage": .object(["tokens": .number(32000), "contextWindow": .number(128000)])]))
        #expect(usage?.fraction == 0.25)
    }

    @Test func authenticationFailureHasSafeActionableMessage() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.submit(.init(text: "검사", project: "p"))
            let id = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("error"), "message": .object(["role": .string("assistant"), "errorMessage": .string("401 Invalid API key sk-never-show-this"), "content": .array([])])]))
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(id), "status": .string("error")]))
            #expect(f.store.lastError?.contains("인증") == true)
            #expect(f.store.lastError?.contains("sk-never-show-this") == false)
            #expect(f.store.failedDraft?.text == "검사")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

}
