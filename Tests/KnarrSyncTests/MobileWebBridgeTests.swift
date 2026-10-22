import Foundation
import Testing
@testable import KnarrSync

@Suite @MainActor struct MobileWebBridgeTests {
    let source = "```openui\nroot = Stack([Slider($hours, \"시간\", 1, 12, 1)])\n$hours = 4\n```"
    func model() -> MobileClientModel {
        let m = MobileClientModel()
        m.apply(saved: [
            .message(.init(id: "a", at: .now, role: .stallari, text: source, project: "P", thread: "t")),
            .message(.init(id: "b", at: .now, role: .stallari, text: "본문", project: "P", thread: "t")),
            .message(.init(id: "u", at: .now, role: .user, text: source, project: "P", thread: "t")),
            .message(.init(id: "qmsg", at: .now, role: .question, text: "질문", project: "P", issue: "i", question: "q", thread: "t")),
            .question(.init(id: "q", issue: "i", asker: "Hird", prompt: "선택", options: ["가", "나"], allowsMultiple: false,
                            state: .pending, answer: nil, askedAt: .now)),
        ], deleted: [])
        return m
    }
    func event(_ action: String, _ id: String = "a", text: String? = nil, selected: [String]? = nil) -> MobileWebEvent {
        .init(session: "s", thread: "t", action: action, message: id, text: text, selected: selected)
    }
    func resolve(_ e: MobileWebEvent, _ m: MobileClientModel? = nil) -> MobileWebCommand? {
        MobileWebBridge.command(e, session: "s", thread: "t", model: m ?? model())
    }
    @Test func openUIFollowupKeepsTheMessageDestination() {
        #expect(resolve(event("continue", text: "결과로 진행")) == .send(text: "결과로 진행", thread: "t", project: "P"))
    }
    @Test func staleWebDocumentAndOtherThreadCannotAct() {
        var e = event("continue", text: "전송")
        e.session = "old"; #expect(resolve(e) == nil)
        e.session = "s"; e.thread = "other"; #expect(resolve(e) == nil)
    }
    @Test func onlyAssistantOpenUICanSubmitFollowups() {
        #expect(resolve(event("continue", "b", text: "전송")) == nil)
        #expect(resolve(event("continue", "u", text: "전송")) == nil)
        #expect(resolve(event("continue", text: "  \n")) == nil)
        #expect(resolve(event("continue", text: String(repeating: "a", count: 40_000))) == nil)
    }
    @Test func questionUsesCurrentOptionsAndSelectionRules() {
        #expect(resolve(event("answer", "qmsg", text: "메모", selected: ["가"])) == .answer(question: "q", selected: ["가"], text: "메모"))
        #expect(resolve(event("answer", "qmsg", selected: ["가", "나"])) == nil)
        #expect(resolve(event("answer", "qmsg", selected: ["가", "가"])) == nil)
        #expect(resolve(event("answer", "qmsg", selected: ["외부"])) == nil)
        #expect(resolve(event("answer", "qmsg", selected: [])) == nil)
    }
    @Test func resolvedAndQueuedQuestionsCannotSubmitAgain() {
        let m = model()
        m.apply(saved: [.request(.init(id: "req", createdAt: .now, kind: .answer(question: "q", options: ["가"], text: nil)))], deleted: [])
        #expect(resolve(event("answer", "qmsg", selected: ["가"]), m) == nil)
        #expect(resolve(event("cancelQuestion", "qmsg"), m) == nil)
        m.forget(request: "req")
        var q = m.questions["q"]!; q.state = .answered
        m.apply(saved: [.question(q)], deleted: [])
        #expect(resolve(event("answer", "qmsg", selected: ["가"]), m) == nil)
    }
    @Test func genericWebButtonsCannotApproveOrExecuteWork() {
        for action in ["approve", "reject", "revise", "noticePrimary", "dispatch", "execute"] {
            #expect(resolve(event(action)) == nil)
        }
    }
    @Test func stateAndClipboardStayBoundToDisplayedMessages() {
        #expect(resolve(event("state")) == .state("a"))
        #expect(resolve(event("state", "missing")) == nil)
        #expect(resolve(event("copy", "b")) == .copy("본문"))
        #expect(resolve(event("edit", "u")) == .edit(source))
        #expect(resolve(event("edit", "a")) == nil)
    }
    @Test func pendingCancellationKeepsItsThread() {
        let m = model()
        m.apply(saved: [.request(.init(id: "pending", createdAt: .now, kind: .threadMessage(text: "대기", thread: "t", project: nil, attachments: nil)))], deleted: [])
        #expect(resolve(event("cancelPending", "pending"), m) == .cancelPending("pending"))
        m.apply(saved: [.request(.init(id: "pending", createdAt: .now, kind: .threadMessage(text: "대기", thread: "elsewhere", project: nil, attachments: nil)))], deleted: [])
        #expect(resolve(event("cancelPending", "pending"), m) == nil)
    }
    @Test func viewportEventsWithoutMessageAreScopedAndBounded() {
        let raw: [String: Any] = ["action": "viewport", "session": "s", "thread": "t",
                                  "state": ["following": false, "anchor": "a", "offset": 24.5]]
        let bytes = MobileWebBridge.viewportData(raw, session: "s", thread: "t")
        #expect(bytes != nil)
        let saved = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(saved?["anchor"] as? String == "a")
        #expect(MobileWebBridge.viewportData(raw, session: "old", thread: "t") == nil)
        #expect(MobileWebBridge.viewportData(raw, session: "s", thread: "other") == nil)
        var invalid = raw; invalid["state"] = ["following": false, "anchor": String(repeating: "x", count: 140_000)]
        #expect(MobileWebBridge.viewportData(invalid, session: "s", thread: "t") == nil)
    }

}
