import AppKit
import Testing
import KnarrCore
@testable import KnarrUI

@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ProjectSessionUITests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityIdentifier": "AXIdentifier"][selector]
        return attribute.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func press(_ node: NSObject) -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: action) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: action), to: Press.self)(node, action)
    }
    private func control(_ h: HomeHarness, id: String) throws -> NSObject {
        let host = try #require(h.window.contentView)
        return try #require(elements(host).first {
            value($0, "accessibilityIdentifier") as? String == id
        })
    }
    private func label(_ h: HomeHarness, _ label: String) throws -> NSObject {
        let host = try #require(h.window.contentView)
        return try #require(elements(host).first {
            value($0, "accessibilityLabel") as? String == label
        })
    }
    private func expose(_ h: HomeHarness) {
        TestWindow.present(h.window)
        h.settle()
    }

    @Test func webTranscriptSurvivesProjectPanelBreakpointChanges() async throws {
        let store = SampleKnarrStore(projectSessionScene: .open)
        for i in 0..<24 { store.send("인계 앵커 \(i) " + String(repeating: "읽던 위치를 보존하는 긴 문장입니다. ", count: 8), about: nil) }
        let h = HomeHarness(width: 1720, height: 900, page: .projects, store: store) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
            $0.set(640.0, forKey: "knarr.projectSessionWidth")
        }
        defer { h.close() }
        await h.waitWeb()
        let web = try #require(h.conversation)
        let id = try #require(await h.revealMessage("인계 앵커 12 "))
        await h.alignMessage(id, offset: 40)
        try await Task.sleep(for: .milliseconds(80))
        let before = try #require(await h.messageOffset(id))
        _ = await h.webJSON("(()=>{window.__panelFrames=[];window.__panelTimer=setInterval(()=>{const v=document.querySelector('.viewport'),a=document.querySelector('[data-message=\"\(id)\"]');window.__panelFrames.push({time:performance.now(),width:innerWidth,height:v.clientHeight,scrollTop:v.scrollTop,total:v.scrollHeight,anchor:a?.getBoundingClientRect().top??null});},16);return true;})()")
        for width: CGFloat in [720, 1000, 1720] {
            h.resize(width: width, height: 900)
            let actualWidth = try #require(await h.webJSON("innerWidth") as? NSNumber).doubleValue
            #expect(actualWidth >= 360 && actualWidth <= 640)
            #expect(h.conversation === web, "Panel resize must retain the same web document and draft")
            try await Task.sleep(for: .milliseconds(100))
            #expect(abs((await h.messageOffset(id) ?? -10000) - before) <= 2)
        }
        _ = await h.webJSON("(()=>{clearInterval(window.__panelTimer);return true;})()")
        let frames = await h.webJSON("window.__panelFrames") as? [[String: Any]] ?? []
        #expect(frames.count > 3)
        if let directory = ProcessInfo.processInfo.environment["KNARR_WEB_EVIDENCE"] {
            let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["policy":"16ms DOM layout samples across native window transitions; not hardware compositor frames", "anchorBefore":before, "frames":frames], options: [.sortedKeys]).write(to: root.appendingPathComponent("panel-frames.json"))
        }
    }

    @Test func projectTalkOpensPanelFocusesEditorAndHomeReusesItsConversation() async throws {
        let store = SampleKnarrStore()
        let h = HomeHarness(width: 1440, height: 900, page: .projects, store: store)
        defer { h.close() }
        expose(h)
        #expect(press(try label(h, "이 프로젝트로 말하기")))
        h.settle()
        _ = try control(h, id: "project-session-panel-gamza")
        let editor = try #require(h.composer)
        // Unlike RunLoop settling, suspending the MainActor lets the native focus request run.
        let focusDeadline = ContinuousClock.now + .seconds(20)
        while h.window.firstResponder !== editor && ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(h.window.firstResponder === editor)
        #expect(store.composerDraft.project == "gamza")
        let projectThread = store.selectedThreadID
        #expect(projectThread != ConversationThread.defaultID)
        h.resize(width: 720, height: 540)
        let composerScroll = try #require(h.composer?.enclosingScrollView)
        let composerFrame = h.frameInWindow(composerScroll)
        #expect(composerFrame.minX >= 0)
        #expect(composerFrame.maxX <= 720)
        #expect(composerFrame.minY >= 0)
        #expect(composerFrame.maxY <= 540)
        #expect(press(try label(h, "홈")))
        h.settle()
        #expect(store.selectedThreadID == projectThread)
        let ids = elements(try #require(h.window.contentView)).compactMap { value($0, "accessibilityIdentifier") as? String }
        #expect(ids.contains("thread-" + projectThread))
        #expect(ids.contains("thread-" + ConversationThread.defaultID))
    }

    @Test func projectCardsStayScopedAndIssueNavigationKeepsHomeIssueTab() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let h = HomeHarness(width: 1440, height: 900, page: .projects, store: store)
        defer { h.close() }
        expose(h)
        #expect(press(try label(h, "이 프로젝트로 말하기")))
        h.settle()
        let ids = elements(try #require(h.window.contentView)).compactMap { value($0, "accessibilityIdentifier") as? String }
        let projectCards = store.issues(inProject: "gamza").filter {
            $0.archivedAt == nil && $0.displayStatus != .completed && $0.displayStatus != .cancelled
        }
        for issue in projectCards { #expect(ids.contains("integrated-issue-" + issue.id.rawValue)) }
        for issue in store.issues(inProject: "knarr") { #expect(!ids.contains("integrated-issue-" + issue.id.rawValue)) }
        let issue = try #require(projectCards.first)
        // The title is plain text now: the card opens the detail, and thread navigation is a menu item.
        let projectThread = store.selectedThreadID
        #expect(!press(try control(h, id: "issue-title-" + issue.id.rawValue)))
        h.settle()
        #expect(store.selectedThreadID == projectThread)
        let threadItem = try #require(IssueCardActions(issue: issue, store: store, open: {}, goToThread: {
            store.goToThread(for: issue.id)
        }).items.first { $0.id == "thread" })
        threadItem.perform()
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
        _ = try control(h, id: "thread-" + issue.conversationThreadID)
        #expect(press(try label(h, "홈")))
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
    }

    @Test func projectPanelRestoresPreferredWidthAndOffersResizeHandle() throws {
        let h = HomeHarness(width: 1720, height: 900, page: .projects) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
            $0.set(640.0, forKey: "knarr.projectSessionWidth")
        }
        defer { h.close() }
        expose(h)
        let transcript = try #require(h.conversation)
        #expect(abs(h.frameInWindow(transcript).width - 640) < 2)
        _ = try control(h, id: "project-session-resize-gamza")
        #expect(press(try label(h, "홈")))
        h.settle()
        #expect(press(try label(h, "프로젝트")))
        h.settle()
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 640) < 2)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, in h: HomeHarness) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        h.window.sendEvent(event)
        h.settle(0.05)
    }

    @Test func nativePanelDragCommitsOncePreservesStreamingFocusAndRestoresAfterWindowResize() throws {
        let store = SampleKnarrStore(projectSessionScene: .open)
        store.composerDraft.text = "드래그 중 유지할 초안"
        store.isResponding = true
        store.streamingText = String(repeating: "긴 답변이 계속 도착합니다. ", count: 120)
        let h = HomeHarness(width: 1720, height: 900, page: .projects, store: store) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
            $0.set(640.0, forKey: "knarr.projectSessionWidth")
        }
        defer { h.close() }
        expose(h)
        let editor = try #require(h.composer)
        #expect(h.window.makeFirstResponder(editor))
        let transcript = try #require(h.conversation)
        let splitter = try #require(h.views.compactMap { $0 as? ProjectPanelSplitterView }.first)
        let frame = h.frameInWindow(splitter)
        #expect(frame.width >= 24)
        let start = NSPoint(x: frame.midX, y: frame.midY)
        #expect(h.window.contentView?.hitTest(start) === splitter)
        try sendMouse(.leftMouseDown, at: start, in: h)
        for distance in stride(from: 20.0, through: 120.0, by: 20.0) {
            store.streamingText += "새 조각 "
            try sendMouse(.leftMouseDragged, at: NSPoint(x: start.x - distance, y: start.y), in: h)
            #expect(abs(h.frameInWindow(transcript).width - 640) < 2)
            #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 640)
            #expect(h.window.firstResponder === editor)
        }
        try sendMouse(.leftMouseUp, at: NSPoint(x: start.x - 120, y: start.y), in: h)
        h.settle()
        #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 760)
        #expect(abs(h.frameInWindow(transcript).width - 760) < 2)
        #expect(h.window.firstResponder === editor)
        #expect(editor.string == "드래그 중 유지할 초안")
        #expect(store.streamingText.hasSuffix("새 조각 "))
        h.resize(width: 1300, height: 900)
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 484) < 2)
        #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 760)
        h.resize(width: 720, height: 540)
        let narrow = h.frameInWindow(try #require(h.composer?.enclosingScrollView))
        #expect(narrow.minX >= 0 && narrow.maxX <= 720)
        #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 760)
        h.resize(width: 1720, height: 900)
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 760) < 2)
        // Exercise both drag boundaries through NSWindow, not a direct preference mutation.
        for (distance, expected) in [(5000.0, 904.0), (-5000.0, 360.0)] {
            let currentSplitter = try #require(h.views.compactMap { $0 as? ProjectPanelSplitterView }.first)
            let currentEditor = try #require(h.composer)
            #expect(h.window.makeFirstResponder(currentEditor))
            let edge = h.frameInWindow(currentSplitter)
            let origin = NSPoint(x: edge.midX, y: edge.midY)
            try sendMouse(.leftMouseDown, at: origin, in: h)
            let end = NSPoint(x: origin.x - distance, y: origin.y)
            try sendMouse(.leftMouseDragged, at: end, in: h)
            try sendMouse(.leftMouseUp, at: end, in: h)
            h.settle()
            #expect(abs(h.frameInWindow(try #require(h.conversation)).width - expected) < 2)
            #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == expected)
            #expect(h.window.firstResponder === currentEditor)
        }
    }

    @Test func sharedPanelPreferenceClampsWithoutChangingSplitModeOrSavedWidth() throws {
        let h = HomeHarness(width: 1440, height: 900, page: .projects) {
            $0.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
            $0.set(2000.0, forKey: "knarr.projectSessionWidth")
        }
        defer { h.close() }
        expose(h)
        // The detail keeps its 480pt beside a clamped panel, not an overlay chosen by preference.
        let splitter = try #require(h.views.compactMap { $0 as? ProjectPanelSplitterView }.first)
        #expect(h.frameInWindow(splitter).minX >= 64 + 248 + 480)
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 624) < 2)
        #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 2000)
        #expect(splitter.accessibilityPerformDecrement())
        h.settle()
        #expect(h.defaults.double(forKey: "knarr.projectSessionWidth") == 600)
        let project = try #require(h.store.project("knarr"))
        let counts = IssueCounts(issues: h.store.issues(inProject: project.id), questions: h.store.questions)
        #expect(press(try label(h, "\(project.name), \(counts.summary)")))
        h.settle()
        #expect(press(try label(h, "이 프로젝트로 말하기")))
        h.settle()
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 600) < 2)
        h.defaults.set(1.0, forKey: "knarr.projectSessionWidth")
        h.settle()
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - 360) < 2)
    }

    @Test func closingProjectPanelPersistsAcrossPageRemount() throws {
        let h = HomeHarness(width: 1440, height: 900, page: .projects)
        defer { h.close() }
        expose(h)
        #expect(press(try label(h, "이 프로젝트로 말하기")))
        h.settle()
        #expect(press(try control(h, id: "project-session-close-gamza")))
        h.settle()
        #expect(h.defaults.bool(forKey: "knarr.projectSessionCollapsed.gamza"))
        #expect(h.composer == nil)
        #expect(press(try label(h, "홈")))
        h.settle()
        #expect(press(try label(h, "프로젝트")))
        h.settle()
        _ = try control(h, id: "project-session-open-gamza")
        #expect(h.composer == nil)
    }
}
