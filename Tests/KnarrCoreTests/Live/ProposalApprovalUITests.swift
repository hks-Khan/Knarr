import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProposalApprovalUITests {
    private func fixture() -> ChangingCardsStore {
        let store = ChangingCardsStore()
        var issue = ChangingCardsStore.card("approval")
        issue.title = "승인 화면 합성 이슈"
        issue.state = .awaitingApproval
        issue.hirds = []
        issue.proposal = .init(version: 7, instruction: "격리 작업본에서 승인된 범위만 수정하세요", model: "openai-codex/gpt-6.1-sol", mode: .change, previousRunID: "prior-run")
        store.issues = [issue]
        store.chat = [ChatItem(at: .now, kind: .proposal(issue.id, version: 7))]
        return store
    }

    private func capture(_ h: HomeHarness, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["KNARR_REVIEW_SCREENSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try #require(h.window.contentView)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }

    // SwiftUI's accessibility nodes implement the Objective-C selectors without
    // declaring NSAccessibilityProtocol conformance. Traverse the real nodes, not views alone.
    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole", "accessibilityLabel": "AXDescription", "accessibilityIdentifier": "AXIdentifier"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func flag(_ node: NSObject, _ selector: String) -> Bool {
        let action = NSSelectorFromString(selector)
        guard node.responds(to: action) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Getter.self)(node, action)
    }
    private func button(_ h: HomeHarness, _ title: String, _ drawer: Bool) throws -> NSObject {
        let host = try #require(h.window.contentView)
        let review = try #require(elements(host).first { value($0, "accessibilityIdentifier") as? String == "proposal-review-\(drawer ? "drawer" : "card")" })
        return try #require(elements(review).first { value($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue && value($0, "accessibilityLabel") as? String == title })
    }
    private func webButton(_ title: String) -> String {
        let literal = String(decoding: try! JSONEncoder().encode(title), as: UTF8.self)
        return "[...document.querySelectorAll('.proposal button')].find(e=>e.textContent===\(literal))"
    }
    private func press(_ h: HomeHarness, _ title: String, _ drawer: Bool) async throws -> Bool {
        if drawer { return flag(try button(h, title, true), "accessibilityPerformPress") }
        await h.waitWeb()
        return await h.webJSON("(()=>{const b=\(webButton(title));if(!b||b.disabled)return false;b.click();return true;})()") as? Bool == true
    }
    private func enabled(_ h: HomeHarness, _ title: String, _ drawer: Bool) async throws -> Bool {
        if drawer { return flag(try button(h, title, true), "isAccessibilityEnabled") }
        return await h.webJSON("(()=>{const b=\(webButton(title));return !!b&&!b.disabled;})()") as? Bool == true
    }
    private func note(_ h: HomeHarness, _ text: String, _ drawer: Bool) async throws {
        if !drawer {
            await h.waitWeb()
            let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
            _ = await h.webJSON("(()=>{const e=document.querySelector('.proposal input');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,\(literal));e.dispatchEvent(new Event('input',{bubbles:true}));return true;})()")
            h.settle(0.1); return
        }
        let fields = h.views.compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "수정 요청 또는 거절 메모" }
        let field = try #require(drawer ? fields.last : fields.first)
        field.stringValue = text
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        h.settle(0.1)
    }

    @Test func appliedIssueStillOffersStopForItsActiveRun() throws {
        let store = ChangingCardsStore()
        var issue = ChangingCardsStore.card("stop-applied")
        issue.application = .applied(branch: "main", commit: "prior")
        store.issues = [issue]
        let h = HomeHarness(width: 1300, height: 1000, opened: issue.id, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let host = try #require(h.window.contentView)
        let stop = try #require(elements(host).first { value($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue && value($0, "accessibilityLabel") as? String == "멈추기" })
        #expect(flag(stop, "accessibilityPerformPress"))
        #expect(store.performed.count == 1)
        #expect(store.performed.first?.0 == .stop)
        #expect(store.performed.first?.1 == issue.id)
    }

    @Test(arguments: [false, true]) func approvalCapturesDisplayedVersionAndRearmsForNewProposal(drawer: Bool) async throws {
        let store = fixture()
        let h = HomeHarness(width: 1300, height: 1000, opened: drawer ? "approval" : nil, store: store)
        defer { h.close() }
        TestWindow.present(h.window)
        h.settle()
        #expect(store.issues[0].hirds.isEmpty)
        try capture(h, name: drawer ? "approval-drawer" : "approval-chat")
        #expect(try await press(h, "승인", drawer))
        h.settle(0.1)
        #expect(store.performed.map(\.0) == [.approveProposal(version: 7)])
        #expect(store.performed.allSatisfy { $0.1 == "approval" })
        #expect(try await !enabled(h, "승인", drawer))
        store.issues[0].proposal?.version = 8
        store.issues[0].proposal?.instruction = "새 제안의 지시"
        store.chat.append(ChatItem(at: .now, kind: .proposal("approval", version: 8)))
        h.settle()
        #expect(try await enabled(h, "승인", drawer))
        #expect(try await press(h, "승인", drawer))
        h.settle(0.1)
        #expect(store.performed.map(\.0) == [.approveProposal(version: 7), .approveProposal(version: 8)])
        store.issues[0].state = .running
        h.settle()
        #expect(!elements(try #require(h.window.contentView)).contains { value($0, "accessibilityLabel") as? String == "승인" })
        try capture(h, name: drawer ? "approved-drawer" : "approved-chat")
    }

    @Test(arguments: [false, true]) func revisionAndRejectionDeliverVersionAndNote(drawer: Bool) async throws {
        let store = fixture()
        let h = HomeHarness(width: 1300, height: 1000, opened: drawer ? "approval" : nil, store: store)
        defer { h.close() }
        TestWindow.present(h.window)
        h.settle()
        #expect(try await !enabled(h, "수정 요청", drawer))
        try await note(h, "  완료 조건을 구체화해 주세요  ", drawer)
        #expect(try await press(h, "수정 요청", drawer))
        h.settle(0.1)
        #expect(store.performed.map(\.0) == [.requestProposalChanges(version: 7, note: "완료 조건을 구체화해 주세요")])
        #expect(try await !enabled(h, "거절", drawer))
        store.issues[0].proposal?.version = 8
        store.chat.append(ChatItem(at: .now, kind: .proposal("approval", version: 8)))
        h.settle()
        try await note(h, "이번 제안은 하지 않습니다", drawer)
        #expect(try await press(h, "거절", drawer))
        h.settle(0.1)
        #expect(store.performed.map(\.0).last == .rejectProposal(version: 8, note: "이번 제안은 하지 않습니다"))
        store.issues[0].state = .rejected
        h.settle()
        #expect(!elements(try #require(h.window.contentView)).contains { value($0, "accessibilityLabel") as? String == "승인" })
    }

    @Test func drawerHidesLongReportUntilExpandedAndClosedIssuesStayFolded() async throws {
        let store = fixture()
        store.issues[0].state = .done
        store.issues[0].detail = "숨긴 결과 본문\n\n" + (1...12).map { "긴 보고서 항목 \($0): 검증 결과와 변경 내용을 기록합니다." }.joined(separator: "\n\n")
        store.issues[0].acceptance = [.init(text: "서랍에만 있는 완료 조건", state: .met, evidence: "exit 0")]
        store.issues[0].latestResult = .init(worktreePath: "/fixture", branch: "fixture", commit: nil, diffPath: nil, summary: "숨긴 결과 요약",
            verifications: [.init(id: "v", command: ["숨긴 명령"], workingDirectory: "/fixture", startedAt: .now, finishedAt: .now, exitCode: 0, logPath: "/fixture/log", summary: "통과")])
        var closed = ChangingCardsStore.card("closed")
        closed.title = "닫힌 이슈 제목"; closed.archivedAt = .now; closed.archiveReason = "대체됨"
        store.issues.append(closed)
        let h = HomeHarness(width: 1300, height: 1000, opened: "approval", store: store)
        defer { h.close() }
        let host = try #require(h.window.contentView)
        TestWindow.present(h.window); h.settle()
        let drawer = try #require(elements(host).first { value($0, "accessibilityIdentifier") as? String == "issue-drawer" })
        func labels(_ node: NSObject) -> [String] { elements(node).compactMap { value($0, "accessibilityValue") as? String ?? value($0, "accessibilityLabel") as? String } }
        #expect(!labels(drawer).contains("숨긴 결과 본문"))
        #expect(!labels(drawer).contains("숨긴 결과 요약"))
        #expect(!labels(drawer).contains { $0.contains("숨긴 명령") })
        #expect(!labels(host).contains("닫힌 이슈 제목"))
        try capture(h, name: "drawer-folded")
        func disclosure() throws -> NSObject {
            try #require(elements(drawer).first {
                value($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue
                    && value($0, "accessibilityIdentifier") as? String == "issue-detail-records"
            })
        }
        #expect(flag(try disclosure(), "accessibilityPerformPress"))
        h.settle()
        #expect(labels(drawer).contains("숨긴 결과 본문"))
        #expect(labels(drawer).contains("숨긴 결과 요약"))
        #expect(labels(drawer).contains { $0.contains("숨긴 명령") })
        #expect(!labels(host).contains("닫힌 이슈 제목"))
        try capture(h, name: "drawer-expanded")
        #expect(flag(try disclosure(), "accessibilityPerformPress"))
        h.settle()
        #expect(!labels(drawer).contains("숨긴 결과 본문"))
        #expect(!labels(drawer).contains("숨긴 결과 요약"))
        #expect(!labels(drawer).contains { $0.contains("숨긴 명령") })
        #expect(!labels(host).contains("닫힌 이슈 제목"))
        try capture(h, name: "drawer-refolded")
    }

    @Test func legacyIssueWithoutRunNeverShowsRunningBadgeInHomeView() async throws {
        let store = fixture()
        store.issues[0].state = .running; store.issues[0].proposal = nil
        store.chat = [.init(at: .now, kind: .issue("approval"))]
        let h = HomeHarness(width: 1300, height: 1000, opened: "approval", store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let nodes = elements(try #require(h.window.contentView))
        let labels = nodes.compactMap { value($0, "accessibilityValue") as? String ?? value($0, "accessibilityLabel") as? String }
        #expect(!labels.contains("Hird에게 한마디"))
        try capture(h, name: "legacy-no-run")
    }
}
