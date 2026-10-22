import Foundation
import Testing
@testable import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized) struct ChatWebBridgeTests {
    private func event(_ bridge: ChatWebBridge, _ store: any KnarrStore, _ item: ChatItem, action: String, fields: [String: OMPJSON] = [:]) -> OMPJSON {
        .object(fields.merging(["session": .string(bridge.session), "thread": .string(store.selectedThreadID),
            "message": .string(item.id.uuidString), "action": .string(action)]) { _, new in new })
    }
    @Test func copyAndEditUseNativeMessageRatherThanUntrustedPayload() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        let item = ChatItem(at: .now, kind: .user("실제 사용자 메시지")); store.chat = [item]
        guard case .copy(let text) = bridge.command(event(bridge, store, item, action: "copy"), store: store) else { Testing.Issue.record("copy missing"); return }
        #expect(text == "실제 사용자 메시지")
        guard case .edit(let draft) = bridge.command(event(bridge, store, item, action: "edit", fields: ["text": .string("위조")]), store: store) else { Testing.Issue.record("edit missing"); return }
        #expect(draft.text == "실제 사용자 메시지")
    }
    @Test func nativeConversationCommandsRequireCurrentUserRootAndLink() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        var root = ChatItem(at: .now, kind: .user("별도 창의 주제"))
        var reply = ChatItem(at: .now, kind: .user("창 안의 후속 메시지"))
        reply.conversationRootID = root.id
        let assistant = ChatItem(at: .now, kind: .stallari("답변", project: nil))
        store.chat = [root, reply, assistant]
        guard case .startConversation(let id) = bridge.command(event(bridge, store, root, action: "startConversation"), store: store) else {
            Testing.Issue.record("native conversation start missing"); return
        }
        #expect(id == root.id)
        #expect(bridge.command(event(bridge, store, root, action: "openConversation"), store: store) == nil)
        #expect(bridge.command(event(bridge, store, assistant, action: "startConversation"), store: store) == nil)
        #expect(bridge.command(event(bridge, store, reply, action: "startConversation"), store: store) == nil)
        root.isConversationLink = true; store.chat[0] = root
        guard case .openConversation(let linkedID) = bridge.command(event(bridge, store, root, action: "openConversation"), store: store) else {
            Testing.Issue.record("native conversation open missing"); return
        }
        #expect(linkedID == root.id)
        store.chat[0].isConversationLink = false
        #expect(bridge.command(event(bridge, store, root, action: "openConversation"), store: store) == nil)
    }
    @Test func replyEditingIsRestrictedToItsNativeConversationScope() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        var root = ChatItem(at: .now, kind: .user("주제")); root.isConversationLink = true
        var reply = ChatItem(at: .now, kind: .user("실제 답장"))
        reply.conversationRootID = root.id
        reply.attachments = [URL(fileURLWithPath: "/tmp/reply.txt")]
        store.chat = [root, reply]
        let scoped = event(bridge, store, reply, action: "edit", fields: [
            "conversationRootID": .string(root.id.uuidString), "text": .string("위조")])
        #expect(bridge.command(scoped, store: store) == nil)
        #expect(bridge.command(event(bridge, store, reply, action: "edit"), store: store, conversationRootID: root.id) == nil)
        guard case .edit(let draft) = bridge.command(scoped, store: store, conversationRootID: root.id) else {
            Testing.Issue.record("scoped reply edit missing"); return
        }
        #expect(draft.text == "실제 답장")
        #expect(draft.attachments == reply.attachments)
        #expect(draft.conversationRootID == root.id)
        #expect(bridge.command(event(bridge, store, reply, action: "startConversation", fields: [
            "conversationRootID": .string(root.id.uuidString)]), store: store, conversationRootID: root.id) == nil)
        #expect(bridge.command(event(bridge, store, root, action: "edit", fields: ["conversationRootID": .string(root.id.uuidString)]),
            store: store, conversationRootID: root.id) == nil)
        #expect(bridge.command(scoped, store: store, conversationRootID: UUID()) == nil)
        store.chat[0].isConversationLink = false
        #expect(bridge.command(scoped, store: store, conversationRootID: root.id) == nil)
    }
    @Test func canvasCommandsRequireTheCurrentLinkRootAndItsOwnRunningResponse() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        var root = ChatItem(at: .now, kind: .user("집중 대화")); root.isConversationLink = true
        var other = ChatItem(at: .now, kind: .user("다른 대화")); other.isConversationLink = true
        store.chat = [root, other]
        // A reply needs the link root and a non-empty body.
        #expect(bridge.command(event(bridge, store, root, action: "canvasSend", fields: ["text": .string("   ")]), store: store) == nil)
        guard case .canvasSend(let id, let text) = bridge.command(event(bridge, store, root, action: "canvasSend",
            fields: ["text": .string("이어서")]), store: store) else { Testing.Issue.record("canvas send missing"); return }
        #expect(id == root.id && text == "이어서")
        // Inside a separate window the canvas is not the surface, so a reply cannot be re-scoped.
        #expect(bridge.command(event(bridge, store, root, action: "canvasSend", fields: ["text": .string("이어서")]),
            store: store, conversationRootID: root.id) == nil)
        // Stopping needs the root whose own answer is in flight, not merely a waiting root.
        #expect(bridge.command(event(bridge, store, root, action: "canvasStop"), store: store) == nil)
        store.stoppableRoots = [other.id]
        #expect(bridge.command(event(bridge, store, root, action: "canvasStop"), store: store) == nil)
        store.waitingRoots = [other.id]
        #expect(bridge.command(event(bridge, store, other, action: "canvasStop"), store: store) == nil)
        store.waitingRoots = []
        store.respondingRoots = [other.id]
        guard case .canvasStop(let stoppedID) = bridge.command(event(bridge, store, other, action: "canvasStop"), store: store) else {
            Testing.Issue.record("canvas stop missing"); return
        }
        #expect(stoppedID == other.id)
        store.stopping = true
        #expect(bridge.command(event(bridge, store, other, action: "canvasStop"), store: store) == nil)
        store.stopping = false
        store.chat[0].isConversationLink = false
        #expect(bridge.command(event(bridge, store, root, action: "canvasStop"), store: store) == nil)
        // The window action stays a separate command for the same link.
        store.chat[0].isConversationLink = true
        guard case .openConversationWindow(let windowID) = bridge.command(event(bridge, store, root, action: "canvasWindow"), store: store) else {
            Testing.Issue.record("canvas window missing"); return
        }
        #expect(windowID == root.id)
    }

    @Test func reportCardCommandsMatchTheStoredReportAndItsState() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        let period = WorkReportPeriod(kind: .daily, start: .now.addingTimeInterval(-86_400), end: .now, timeZoneID: "Asia/Seoul")
        var report = WorkReport(period: period, generatedAt: .now, items: [], time: WorkReportTime(total: 0, elapsed: 0),
                                failures: [:], plans: [])
        report.analysisState = .failed
        report.analysisError = "연결 실패"
        store.workReports = [report]
        let card = ChatItem(id: WorkReportCards.messageID(for: report), at: report.generatedAt, kind: .report(report.id))
        store.chat = [card]
        // A forged report id, or another card's id, cannot reach a report.
        #expect(bridge.command(event(bridge, store, card, action: "reportOpen", fields: ["report": .string("other")]), store: store) == nil)
        guard case .openReport(let opened) = bridge.command(event(bridge, store, card, action: "reportOpen",
            fields: ["report": .string(report.id)]), store: store) else { Testing.Issue.record("report open missing"); return }
        #expect(opened == report.id)
        guard case .retryReport(let retried) = bridge.command(event(bridge, store, card, action: "reportRetry",
            fields: ["report": .string(report.id)]), store: store) else { Testing.Issue.record("report retry missing"); return }
        #expect(retried == report.id)
        // Only a failed analysis can be retried, and only while no analysis is running.
        store.workReports[0].analysisState = .ready
        #expect(bridge.command(event(bridge, store, card, action: "reportRetry", fields: ["report": .string(report.id)]), store: store) == nil)
        store.workReports[0].analysisState = .generating
        #expect(bridge.command(event(bridge, store, card, action: "reportOpen", fields: ["report": .string(report.id)]), store: store) == nil)
        // The card row is derived, so the row id must match the report card, not a stored chat item.
        let row = ChatWebProjection.row(card, store: store, state: .object([:]))
        #expect(row["kind"]?.string == "report")
        #expect(row["report"]?["state"]?.string == "generating")
        #expect(row["report"]?["id"]?.string == report.id)
        guard case .number(let at)? = row["at"] else { Testing.Issue.record("report row needs a millisecond time"); return }
        #expect(at == report.generatedAt.timeIntervalSince1970 * 1000)
    }

    @Test func editKeepsUserOnlyAndReadOnlyBoundariesWhileCopyRemainsAvailable() throws {
        let mutable = ChangingCardsStore(), bridge = ChatWebBridge()
        let assistant = ChatItem(at: .now, kind: .stallari("합성 답변", project: nil))
        mutable.chat = [assistant]
        #expect(bridge.command(event(bridge, mutable, assistant, action: "edit"), store: mutable) == nil)
        let user = ChatItem(at: .now, kind: .user("진행 중에도 편집만 준비"))
        mutable.chat = [user]; mutable.isResponding = true
        #expect(bridge.command(event(bridge, mutable, user, action: "edit"), store: mutable) != nil)

        let project = SampleKnarrStore(projectSessionScene: .open)
        let projectID = try #require(project.threads.first { $0.id == project.selectedThreadID }?.projectID)
        project.send("보관할 합성 프로젝트 메시지", about: nil, project: projectID, attachments: [])
        let projectMessage = try #require(project.chat.first { if case .user = $0.kind { true } else { false } })
        #expect(bridge.command(event(bridge, project, projectMessage, action: "edit"), store: project) != nil)
        #expect(bridge.command(event(bridge, project, projectMessage, action: "startConversation"), store: project) != nil)
        project.setProjectArchived(projectID, true)
        #expect(bridge.command(event(bridge, project, projectMessage, action: "edit"), store: project) == nil)
        #expect(bridge.command(event(bridge, project, projectMessage, action: "startConversation"), store: project) == nil)
        #expect(bridge.command(event(bridge, project, projectMessage, action: "copy"), store: project) != nil)

        let issueStore = SampleKnarrStore(issueSessionScene: .conversation)
        let issue = try #require(issueStore.issues.first)
        issueStore.goToThread(for: issue.id)
        issueStore.send("보관할 합성 이슈 메시지", about: issue.id, project: nil, attachments: [])
        let issueMessage = try #require(issueStore.chat.first { if case .user = $0.kind { true } else { false } })
        #expect(bridge.command(event(bridge, issueStore, issueMessage, action: "edit"), store: issueStore) != nil)
        issueStore.perform(.closeIssue(reason: .applied), on: issue.id)
        issueStore.goToThread(for: issue.id)
        #expect(bridge.command(event(bridge, issueStore, issueMessage, action: "edit"), store: issueStore) == nil)
        #expect(bridge.command(event(bridge, issueStore, issueMessage, action: "startConversation"), store: issueStore) == nil)
        #expect(bridge.command(event(bridge, issueStore, issueMessage, action: "copy"), store: issueStore) != nil)
    }
    @Test func foreignSessionThreadAndMissingMessageCannotAct() {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        let item = ChatItem(at: .now, kind: .user("test")); store.chat = [item]
        #expect(bridge.command(.object(["session": .string("old"), "thread": .string(store.selectedThreadID), "message": .string(item.id.uuidString), "action": .string("edit")]), store: store) == nil)
        #expect(bridge.command(.object(["session": .string(bridge.session), "thread": .string("foreign"), "message": .string(item.id.uuidString), "action": .string("edit")]), store: store) == nil)
        store.chat = []
        #expect(bridge.command(event(bridge, store, item, action: "copy"), store: store) == nil)
    }
    @Test func approvalChecksDisplayedVersionAndRejectsDuplicateClicks() throws {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        var issue = ChangingCardsStore.card("approval"); issue.state = .awaitingApproval; issue.hirds = []
        issue.proposal = .init(version: 7, instruction: "승인된 작업", model: "test")
        store.issues = [issue]
        let item = ChatItem(at: .now, kind: .proposal(issue.id, version: 7)); store.chat = [item]
        #expect(bridge.command(event(bridge, store, item, action: "approve", fields: ["version": .number(6)]), store: store) == nil)
        let request = event(bridge, store, item, action: "approve", fields: ["version": .number(7)])
        guard case .perform(.approveProposal(let version), let id) = bridge.command(request, store: store) else { Testing.Issue.record("approval missing"); return }
        #expect(version == 7 && id == issue.id)
        #expect(bridge.command(request, store: store) == nil)
        store.issues[0].proposal?.version = 8
        #expect(ChatWebBridge().command(request, store: store) == nil)
    }
    @Test func answeredQuestionsAndUnknownAttachmentsAreRejected() {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        let q = Question(id: "q", issue: "i", run: "r", asker: "Hird", prompt: "선택", options: ["예", "아니요"], askedAt: .now)
        store.questions = [q]
        let item = ChatItem(at: .now, kind: .question(q.id)); store.chat = [item]
        #expect(bridge.command(event(bridge, store, item, action: "answer", fields: ["selected": .array([.string("위조")])]), store: store) == nil)
        guard case .answer(let id, let answer) = bridge.command(event(bridge, store, item, action: "answer", fields: ["selected": .array([.string("예")])]), store: store) else { Testing.Issue.record("answer missing"); return }
        #expect(id == q.id && answer.selectedOptions == ["예"])
        store.questions[0].state = .answered(answer)
        #expect(bridge.command(event(bridge, store, item, action: "cancelQuestion"), store: store) == nil)
        #expect(bridge.command(event(bridge, store, item, action: "preview", fields: ["index": .number(0)]), store: store) == nil)
    }
    @Test func bothUIFencesCanContinueAndQuestionFailureCanReleaseTheLock() {
        let store = ChangingCardsStore(), bridge = ChatWebBridge()
        for fence in ["```openui", "~~~openui-lang"] {
            let item = ChatItem(at: .now, kind: .stallari(fence + "\nroot = Text(\"test\")", project: nil)); store.chat = [item]
            #expect(bridge.command(event(bridge, store, item, action: "continue", fields: ["text": .string("계속")]), store: store) != nil)
        }
        let q = Question(id: "retry", issue: "above", run: "r", asker: "Hird", prompt: "진행할까요?", options: ["예"], askedAt: .now)
        store.questions = [q]
        let item = ChatItem(at: .now, kind: .question(q.id)); store.chat = [item]
        let request = event(bridge, store, item, action: "answer", fields: ["selected": .array([.string("예")])])
        #expect(bridge.command(request, store: store) != nil)
        #expect(bridge.command(request, store: store) == nil)
        bridge.release(message: item.id)
        #expect(bridge.command(request, store: store) != nil)
        #expect(ChatWebProjection.row(item, store: store, state: .object([:]))["question"]?["issueTitle"]?.string == "합성 작업 above")
    }
    @Test func modelReceivesTheExactShippedUILibraryAndInlineProtocol() {
        #expect(StallariTools.fixedInstructions.contains("Slider("))
        #expect(StallariTools.fixedInstructions.contains("openui"))
        #expect(StallariTools.fixedInstructions.contains("Knarr owns those versioned cards"))
    }
    @Test func webStateSurvivesRecreationAndIsScopedAndSizeBounded() throws {
        let suite = "knarr-web-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), state: OMPJSON = .object(["slider": .number(42), "text": .string("작성 중")])
        #expect(ChatWebStateStore(preferences: defaults).save(state, thread: "a", message: id))
        #expect(ChatWebStateStore(preferences: defaults).load(thread: "a", message: id) == state)
        #expect(ChatWebStateStore(preferences: defaults).load(thread: "b", message: id) == .object([:]))
        #expect(!ChatWebStateStore(preferences: defaults).save(.object(["huge": .string(String(repeating: "x", count: 131_073))]), thread: "a", message: id))
        #expect(ChatWebStateStore(preferences: defaults).load(thread: "a", message: id) == state)
    }
    @Test func projectionServesLocalImagesAndBridgeOpensOnlyDisplayedOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-bridge-image-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shot = root.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 16).write(to: shot)
        let store = ChangingCardsStore()
        let item = ChatItem(at: .now, kind: .stallari("보세요 ![화면](\(shot.path))", project: nil))
        store.chat = [item]
        let resolver = ChatImageResolver()
        let row = ChatWebProjection.row(item, store: store, state: .object([:]), images: resolver)
        let shown = try #require(row["text"]?.string)
        let address = try #require(shown.split(separator: "(").dropFirst().first.map { String($0.prefix(while: { $0 != ")" })) })
        #expect(address.hasPrefix("chat-image://image/"))
        #expect(!shown.contains(shot.path))
        #expect(ChatWebProjection.row(item, store: store, state: .object([:]))["text"]?.string?.contains(shot.path) == true)
        let bridge = ChatWebBridge()
        let open = event(bridge, store, item, action: "imagePreview", fields: ["text": .string(address)])
        guard case .imagePreview(let served) = bridge.command(open, store: store) else {
            Issue.record("표시된 이미지를 열 수 있어야 해요"); return
        }
        #expect(served == address)
        #expect(bridge.command(event(bridge, store, item, action: "imagePreview", fields: ["text": .string("https://example.com/a.png")]), store: store) == nil)
        let user = ChatItem(at: .now, kind: .user("사용자 메시지")); store.chat = [user]
        #expect(bridge.command(event(bridge, store, user, action: "imagePreview", fields: ["text": .string(address)]), store: store) == nil)
    }
}
