import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct MessageConversationLiveTests {
    func answer(_ store: LiveKnarrStore, id: String, text: String) async {
        await store.observe(frame: .object(["type": .string("message_end"), "messageId": .string(id), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]))
    }
    @Test func newConversationPersistsOneLinkedSourceBeforeFirstResponseAndKeepsAttachments() async throws {
        let f = try await LiveFixture.make()
        do {
            let attachment = f.directory.appendingPathComponent("source.png")
            let image = Data([137, 80, 78, 71])
            try image.write(to: attachment)
            let draft = ChatDraft(text: "  별도 대화 시작  ", attachments: [attachment], project: "p")
            f.store.composerDraft = draft
            await f.rpc.onPromptReply { _ in
                do {
                    let snapshot = try await f.repository.snapshot()
                    let root = try #require(snapshot.chat.first { $0.kind == .user("별도 대화 시작") })
                    #expect(root.isConversationLink)
                    #expect(root.conversationRootID == nil)
                    #expect(root.attachments == [attachment])
                    await f.store.observe(frame: .object(["type": .string("message_end"), "messageId": .string("first-root-response"),
                        "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("첫 답변")])])])]))
                } catch { Testing.Issue.record(error) }
            }
            let rootID = try await f.store.startMessageConversation(draft)
            try await f.store.whenIdle()
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.filter { $0.kind == .user("별도 대화 시작") }.map(\.id) == [rootID])
            #expect(snapshot.chat.first { $0.kind == .stallari("첫 답변", project: nil) }?.conversationRootID == rootID)
            #expect(snapshot.threads.count == 1)
            #expect(f.store.composerDraft == ChatDraft(project: "p"))
            #expect(await f.rpc.starts == 0)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("conversationRootID=\"\(rootID.uuidString)\"") == true)
            #expect(await f.rpc.prompts.last?["images"] == .array([.object([
                "type": .string("image"), "mimeType": .string("image/png"), "data": .string(image.base64EncodedString())
            ])]))
            let copy = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await copy.snapshot().chat.first { $0.kind == .stallari("첫 답변", project: nil) }?.conversationRootID == rootID)
            try await copy.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func newConversationAdmissionFailurePreservesMainDraftAndDoesNotPersistUnreadableAttachment() async throws {
        let f = try await LiveFixture.make()
        do {
            let draft = ChatDraft(text: "보존할 초안", attachments: [f.directory.appendingPathComponent("missing.png")], project: "p")
            f.store.composerDraft = draft
            await #expect(throws: (any Error).self) { try await f.store.startMessageConversation(draft) }
            #expect(f.store.composerDraft == draft)
            #expect(f.store.failedDraft == draft)
            #expect(try await !f.repository.snapshot().chat.contains { $0.kind == .user("보존할 초안") })
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func queuedNewRootAndMainSubmissionKeepFIFOOrder() async throws {
        let f = try await LiveFixture.make()
        var rootTask: Task<UUID, Error>?
        var mainTask: Task<Void, Error>?
        var createdRootID: UUID?
        do {
            try await f.store.submit(.init(text: "진행 중", project: "p"))
            let first = try #require(await f.rpc.promptIDs.last)
            rootTask = Task {
                try await f.store.startMessageConversation(.init(text: "새 주제", project: "p")) { id in
                    createdRootID = id
                    #expect(f.store.chat.first { $0.id == id }?.isConversationLink == true)
                }
            }
            for _ in 0..<200 {
                if createdRootID != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let createdID = try #require(createdRootID)
            mainTask = Task { try await f.store.submit(.init(text: "다음 메인", project: "p")) }
            for _ in 0..<20 { await Task.yield() }
            #expect(await f.rpc.promptIDs.count == 1)
            #expect(try await f.repository.snapshot().chat.filter { $0.kind == .user("새 주제") }.map(\.id) == [createdID])
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(first), "status": .string("success")]))
            let rootID = try await #require(rootTask).value
            #expect(rootID == createdID)
            #expect(await f.rpc.promptIDs.count == 2)
            await answer(f.store, id: "root-queued", text: "새 주제 답변")
            let second = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(second), "status": .string("success")]))
            try await mainTask?.value
            await answer(f.store, id: "main-queued", text: "다음 메인 답변")
            try await f.store.whenIdle()
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.first { $0.kind == .stallari("새 주제 답변", project: nil) }?.conversationRootID == rootID)
            #expect(snapshot.chat.first { $0.kind == .stallari("다음 메인 답변", project: nil) }?.conversationRootID == nil)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("다음 메인") == true)
            try await f.cleanup()
        } catch {
            try await f.cleanup()
            _ = await rootTask?.result
            _ = await mainTask?.result
            throw error
        }
    }

    @Test func userCanLinkExistingUserMessageWithoutPromptOrDuplicate() async throws {
        let f = try await LiveFixture.make()
        do {
            let source = ChatItem(at: .now, kind: .user("기존 메시지"))
            let assistant = ChatItem(at: .now, kind: .stallari("원본이 될 수 없음", project: nil))
            try await f.repository.appendChat(source, projectID: "p")
            try await f.repository.appendChat(assistant, projectID: "p")
            try await f.store.linkMessageConversation(source.id)
            try await f.store.linkMessageConversation(source.id)
            await #expect(throws: (any Error).self) { try await f.store.linkMessageConversation(assistant.id) }
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.filter { $0.id == source.id }.count == 1)
            #expect(f.store.chat.first { $0.id == source.id }?.isConversationLink == true)
            #expect(snapshot.chat.first { $0.id == assistant.id }?.isConversationLink == false)
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func sampleStoreKeepsSourceAndAttachmentRepliesInOneExistingThread() async throws {
        let store = SampleKnarrStore()
        let before = store.chat.count
        let file = URL(fileURLWithPath: "/tmp/sample-conversation.txt")
        let draft = ChatDraft(text: "새 예시 대화", attachments: [file], project: "knarr")
        store.composerDraft = draft
        var created: UUID?
        let rootID = try await store.startMessageConversation(draft) { id in
            created = id
            #expect(store.chat.first { $0.id == id }?.isConversationLink == true)
        }
        #expect(created == rootID)
        #expect(store.chat.count == before + 2)
        let root = try #require(store.chat.first { $0.id == rootID })
        #expect(root.kind == .user(draft.text))
        #expect(root.attachments == [file])
        #expect(root.conversationRootID == nil)
        try await store.submit(.init(text: "후속", attachments: [file], conversationRootID: rootID))
        #expect(store.chat.suffix(2).allSatisfy { $0.conversationRootID == rootID })
        #expect(store.chat.first { $0.kind == .user("후속") }?.attachments == [file])
        #expect(store.threads.count == 1)
        #expect(store.composerDraft.isEmpty)
        await #expect(throws: (any Error).self) { try await store.linkMessageConversation(store.chat.last!.id) }
        await #expect(throws: (any Error).self) {
            try await store.startMessageConversation(.init(text: "중첩 불가", conversationRootID: rootID))
        }
    }

    @Test func linkingSavedProjectSourceDoesNotStartItsLazyEngine() async throws {
        let f = try await LiveFixture.make()
        var opened = 0
        f.store.setThreadFactory { _ in
            opened += 1
            throw StallariError.closed
        }
        do {
            let thread = try await f.repository.createProjectConversation(projectID: "p", threadID: UUID().uuidString)
            let source = ChatItem(at: .now, kind: .user("아직 엔진을 열지 않은 기록"))
            try await f.repository.appendChat(source, projectID: "p", threadID: thread.id)
            try await f.store.whenIdle()
            f.store.selectProjectConversation("p")
            try await f.store.linkMessageConversation(source.id)
            #expect(f.store.selectedThreadID == thread.id)
            #expect(f.store.chat.first { $0.id == source.id }?.isConversationLink == true)
            #expect(opened == 0)
            #expect(await f.rpc.prompts.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func stoppingCancelsQueuedRootAdmissionButKeepsItsOneDurableSourceAndMainDraft() async throws {
        let f = try await LiveFixture.make()
        var queued: Task<UUID, Error>?
        var createdID: UUID?
        do {
            try await f.store.submit(.init(text: "기존 응답", project: "p"))
            let draft = ChatDraft(text: "대기하는 새 주제", project: "p")
            f.store.composerDraft = draft
            queued = Task { try await f.store.startMessageConversation(draft) { createdID = $0 } }
            for _ in 0..<200 {
                if createdID != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let rootID = try #require(createdID)
            f.store.stopResponse()
            for _ in 0..<100 {
                if !f.store.isStopping { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            if case .success = await queued?.result { Testing.Issue.record("Queued root admission should be cancelled") }
            #expect(await f.rpc.prompts.count == 1)
            #expect(f.store.composerDraft == draft)
            #expect(try await f.repository.snapshot().chat.filter { $0.id == rootID && $0.isConversationLink }.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); _ = await queued?.result; throw error }
    }

    @Test func focusedReplyAndQueuedMainReplyStayInTheirOwnPlaces() async throws {
        let f = try await LiveFixture.make()
        var queued: Task<Void, Error>?
        do {
            let source = ChatItem(at: .now, kind: .user("DeepSeek 연결"))
            try await f.repository.appendChat(source, projectID: "p")
            _ = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(source.id.uuidString)]))
            try await f.store.submit(.init(text: "내 키로 쓸게", project: "p", conversationRootID: source.id))
            let firstID = try #require(await f.rpc.promptIDs.last)
            let before = await f.rpc.promptIDs.count
            queued = Task { try await f.store.submit(.init(text: "메인 얘기 계속", project: "p")) }
            for _ in 0..<20 { await Task.yield() }
            #expect(await f.rpc.promptIDs.count == before)
            await answer(f.store, id: "focused", text: "키 연결 답변")
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(firstID), "status": .string("success")]))
            try await queued?.value
            await answer(f.store, id: "main", text: "메인 답변")
            let secondID = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(secondID), "status": .string("success")]))
            try await f.store.whenIdle()
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.first { $0.id == source.id }?.isConversationLink == true)
            #expect(snapshot.chat.first { $0.kind == .stallari("키 연결 답변", project: nil) }?.conversationRootID == source.id)
            #expect(snapshot.chat.first { $0.kind == .stallari("메인 답변", project: nil) }?.conversationRootID == nil)
            #expect(snapshot.chat.first { $0.kind == .user("내 키로 쓸게") }?.conversationRootID == source.id)
            #expect(snapshot.threads.count == 1)
            #expect(await f.rpc.starts == 0)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("conversationRootID=\"main\"") == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); _ = await queued?.result; throw error }
    }
    /// Sending from the small window waits behind the running answer and is delivered exactly once.
    @Test func focusedSendWhileAnsweringWaitsAndDeliversExactlyOnce() async throws {
        let f = try await LiveFixture.make()
        var waiting: Task<Void, Error>?
        do {
            let source = ChatItem(at: .now, kind: .user("대기 확인 주제"))
            try await f.repository.appendChat(source, projectID: "p")
            _ = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(source.id.uuidString)]))
            try await f.store.submit(.init(text: "먼저 답할 질문", project: "p"))
            let firstID = try #require(await f.rpc.promptIDs.last)
            let promptsWhileWaiting = await f.rpc.prompts.count
            waiting = Task { try await f.store.submit(.init(text: "대기 확인 전송", project: "p", conversationRootID: source.id)) }
            for _ in 0..<20 { await Task.yield() }
            // While the running answer holds the send back, nothing is persisted and nothing is prompted.
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await f.repository.snapshot().chat.filter { $0.kind == .user("대기 확인 전송") }.isEmpty)
            #expect(await f.rpc.prompts.count == promptsWhileWaiting)
            await answer(f.store, id: "first", text: "첫 답변")
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(firstID), "status": .string("success")]))
            for _ in 0..<200 {
                if try await f.repository.snapshot().chat.contains(where: { $0.kind == .user("대기 확인 전송") }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            // The waiting send is admitted once the answer ends, and it keeps its own conversation root.
            #expect(try await f.repository.snapshot().chat.filter { $0.kind == .user("대기 확인 전송") }.map(\.conversationRootID) == [source.id])
            try await waiting?.value
            await answer(f.store, id: "focused", text: "대기 답변")
            let secondID = try #require(await f.rpc.promptIDs.last)
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(secondID), "status": .string("success")]))
            try await f.store.whenIdle()
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.filter { $0.kind == .user("대기 확인 전송") }.count == 1)
            #expect(snapshot.chat.filter { $0.kind == .user("대기 확인 전송") }.allSatisfy { $0.conversationRootID == source.id })
            #expect(snapshot.chat.first { $0.kind == .stallari("대기 답변", project: nil) }?.conversationRootID == source.id)
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("대기 확인 전송") == true }.count == 1)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("conversationRootID=\"\(source.id.uuidString)\"") == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); _ = await waiting?.result; throw error }
    }
    /// A linked message conversation must not turn main input during a main answer into a waiting send.
    @Test func mainInputSteersMainAnswerEvenAfterAConversationIsLinked() async throws {
        let f = try await LiveFixture.make()
        var steering: Task<Void, Error>?
        do {
            let source = ChatItem(at: .now, kind: .user("연결된 주제"))
            try await f.repository.appendChat(source, projectID: "p")
            try await f.store.linkMessageConversation(source.id)
            try await f.store.submit(.init(text: "메인 첫 요청", project: "p"))
            #expect(f.store.isResponding)
            let count = await f.rpc.prompts.count
            steering = Task { try await f.store.submit(.init(text: "방향 바꿔 줘", project: "p")) }
            for _ in 0..<200 {
                if await f.rpc.prompts.count > count { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!f.store.isSubmissionWaiting)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("방향 바꿔 줘") == true)
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "steer")
            try await f.cleanup()
            _ = await steering?.result
        } catch { try await f.cleanup(); _ = await steering?.result; throw error }
    }
    /// Queue mode holds main input until the answer ends; switching back to steer sends it now.
    @Test func queueModeHoldsMainInputUntilSwitchedToSteer() async throws {
        let f = try await LiveFixture.make()
        var waiting: Task<Void, Error>?
        do {
            #expect(f.store.whileRespondingMode == .steer)
            f.store.setWhileRespondingMode(.queue)
            #expect(f.store.whileRespondingMode == .queue)
            try await f.store.submit(.init(text: "메인 첫 요청", project: "p"))
            let count = await f.rpc.prompts.count
            waiting = Task { try await f.store.submit(.init(text: "끝나면 볼 것", project: "p")) }
            for _ in 0..<200 { if f.store.isSubmissionWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            #expect(f.store.isSubmissionWaiting)
            #expect(await f.rpc.prompts.count == count)
            f.store.setWhileRespondingMode(.steer)
            for _ in 0..<200 {
                if await f.rpc.prompts.count > count { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!f.store.isSubmissionWaiting)
            #expect(f.store.isResponding)
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("끝나면 볼 것") == true }.count == 1)
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "steer")
            try await f.cleanup()
            _ = await waiting?.result
        } catch { try await f.cleanup(); _ = await waiting?.result; throw error }
    }
    /// Main input must not retarget an answer Stallari moved into a message conversation mid-turn.
    @Test func mainInputWaitsWhileTheAnswerContinuesInALinkedConversation() async throws {
        let f = try await LiveFixture.make()
        var waiting: Task<Void, Error>?
        do {
            try await f.store.submit(.init(text: "메인 첫 요청", project: "p"))
            let firstID = try #require(await f.rpc.promptIDs.last)
            let source = ChatItem(at: .now, kind: .user("도중에 연결한 주제"))
            try await f.repository.appendChat(source, projectID: "p")
            _ = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(source.id.uuidString)]))
            await f.rpc.setBusy()
            let count = await f.rpc.prompts.count
            waiting = Task { try await f.store.submit(.init(text: "메인 끼어들기", project: "p")) }
            for _ in 0..<200 { if f.store.isSubmissionWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            #expect(f.store.isSubmissionWaiting)
            #expect(await f.rpc.prompts.count == count)
            await f.rpc.setIdle()
            await answer(f.store, id: "linked", text: "연결된 답변")
            await f.store.observe(frame: .object(["type": .string("prompt_result"), "id": .string(firstID), "status": .string("success")]))
            try await waiting?.value
            try await f.store.whenIdle()
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.first { $0.kind == .stallari("연결된 답변", project: nil) }?.conversationRootID == source.id)
            #expect(snapshot.chat.filter { $0.kind == .user("메인 끼어들기") }.count == 1)
            #expect(await f.rpc.prompts.filter { $0["message"]?.string?.contains("메인 끼어들기") == true }.count == 1)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("conversationRootID=\"main\"") == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); _ = await waiting?.result; throw error }
    }
    @Test func stoppingCancelsWaitingFocusedInputWithoutSendingIt() async throws {
        let f = try await LiveFixture.make()
        var queued: Task<Void, Error>?
        do {
            let source = ChatItem(at: .now, kind: .user("다른 주제"))
            try await f.repository.appendChat(source, projectID: "p")
            _ = try await f.session.performTool("link_message_conversation", arguments: .object(["messageID": .string(source.id.uuidString)]))
            try await f.store.submit(.init(text: "메인 요청", project: "p"))
            let count = await f.rpc.prompts.count
            queued = Task { try await f.store.submit(.init(text: "대기 중 입력", project: "p", conversationRootID: source.id)) }
            for _ in 0..<20 { await Task.yield() }
            f.store.stopResponse()
            for _ in 0..<100 { if !f.store.isStopping { break }; try await Task.sleep(for: .milliseconds(5)) }
            if case .success = await queued?.result { Testing.Issue.record("Waiting message should be cancelled") }
            #expect(await f.rpc.prompts.count == count)
            #expect(!f.store.isResponding)
            try await f.cleanup()
        } catch { try await f.cleanup(); _ = await queued?.result; throw error }
    }

    /// Pressing send twice for the same message must persist and prompt it once, not once per press.
    @Test func repeatedSendOfTheSameDraftWhileAdmittingPersistsAndPromptsOnce() async throws {
        let f = try await LiveFixture.make()
        let suite = "knarr-duplicate-send-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = Gate()
        var conversation: LiveConversation?
        var rpc: LiveTestRPC?
        var first: Task<Void, Error>?
        do {
            f.store.setThreadFactory { thread in
                let local = LiveTestRPC()
                let session = StallariSession(repository: f.repository, rpc: local, hird: f.hird, threadID: thread.id)
                let live = LiveConversation(repository: f.repository, session: session, rpc: local, hird: f.hird,
                                            threadID: thread.id, preferences: preferences)
                // Hold the admission open so the second press lands while the first is still in flight.
                live.submissionHook = { await gate.wait() }
                conversation = live; rpc = local
                return live
            }
            f.store.selectProjectConversation("p")
            let draft = ChatDraft(text: "연타 확인", project: "p")
            first = Task { try await f.store.submit(draft) }
            for _ in 0..<200 {
                if gate.entered { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(gate.entered)
            let live = try #require(conversation)
            #expect(live.sendingDraft == draft)
            #expect(live.isSubmitting)
            // The second press is the same message still being admitted, so it is not sent again.
            try await f.store.submit(draft)
            #expect(await rpc?.prompts.filter { $0["message"]?.string?.contains("연타 확인") == true }.count == 0)
            #expect(try await f.repository.snapshot().chat.filter { $0.kind == .user("연타 확인") }.isEmpty)
            gate.open()
            try await first?.value
            try await f.store.whenIdle()
            #expect(await rpc?.prompts.filter { $0["message"]?.string?.contains("연타 확인") == true }.count == 1)
            #expect(try await f.repository.snapshot().chat.filter { $0.kind == .user("연타 확인") }.count == 1)
            #expect(live.sendingDraft == nil && !live.isSubmitting)
            try await f.cleanup()
        } catch {
            gate.open()
            _ = await first?.result
            try await f.cleanup()
            throw error
        }
    }

    /// Holds one admission open so a test can press send again while it is still in flight.
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }
}
