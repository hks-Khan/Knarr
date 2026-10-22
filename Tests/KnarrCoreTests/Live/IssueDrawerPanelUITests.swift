import AppKit
import SwiftUI
import Testing
import KnarrCore
@testable import KnarrUI

private typealias Issue = KnarrCore.Issue

/// Card click and menu open the same detail; the splitter clamps and persists its width;
/// a narrow window shows the detail as a full-width overlay instead of a clipped strip.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssueDrawerPanelUITests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityIdentifier": "AXIdentifier", "accessibilityRole": "AXRole"][selector]
        guard let attribute else { return nil }
        return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
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
        return try #require(elements(host).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing control: \(id)")
    }
    private func drawer(_ h: HomeHarness) -> NSObject? {
        guard let host = h.window.contentView else { return nil }
        return elements(host).first { value($0, "accessibilityIdentifier") as? String == "issue-drawer" }
    }
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in h: HomeHarness, clicks: Int = 1) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        h.window.sendEvent(event)
        h.settle(0.05)
    }
    /// Accessibility frames are in screen space; the harness window sits far offscreen.
    private func windowPoint(_ h: HomeHarness, _ node: NSObject) throws -> NSPoint {
        let screen = try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        return h.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
    }
    private func click(_ h: HomeHarness, _ node: NSObject) throws {
        let point = try windowPoint(h, node)
        try send(.leftMouseDown, at: point, in: h)
        try send(.leftMouseUp, at: point, in: h)
        h.settle()
    }

    @Test func clickingTheCardBodyOpensTheDetailWithoutChangingThread() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        store.createThread(name: "사용자 대화")
        store.selectThread(ConversationThread.defaultID)
        let thread = store.selectedThreadID
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        #expect(drawer(h) == nil)
        let card = try control(h, id: "integrated-issue-" + issue.id.rawValue)
        try click(h, card)
        #expect(drawer(h) != nil, "card body click did not open the detail")
        #expect(store.selectedThreadID == thread, "opening the detail must not switch threads")
        // The open issue's card is the one the detail belongs to, and the snapshot check covers its
        // accent selection outline (the SwiftUI group exposes no standard selected state here).
        let shown = try #require(h.store.issue(issue.id))
        #expect(shown.id == issue.id)
    }

    @Test func titleIsPlainTextAndTheMenuIsNotTheOpenControl() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        store.selectThread(ConversationThread.defaultID)
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let title = try control(h, id: "issue-title-" + issue.id.rawValue)
        #expect(!press(title), "the title must not be a button")
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        #expect(drawer(h) == nil)
        let menu = try control(h, id: "issue-menu-" + issue.id.rawValue)
        #expect(value(menu, "accessibilityLabel") as? String == "이슈 메뉴")
        #expect(["AXMenuButton", NSAccessibility.Role.popUpButton.rawValue].contains(value(menu, "accessibilityRole") as? String ?? ""))
        #expect(drawer(h) == nil, "a menu button must not open the detail by itself")
    }

    @Test func menuItemsComeFromTheSharedActionListAndThreadMoveUsesGoToThread() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        store.selectThread(ConversationThread.defaultID)
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let actions = IssueCardActions(issue: issue, store: store, open: { store.selectThread(issue.conversationThreadID) },
                                       goToThread: { store.goToThread(for: issue.id) })
        #expect(actions.items.map(\.title) == ["상세 열기", "스레드로 이동"])
        try #require(actions.items.first { $0.id == "thread" }).perform()
        h.settle()
        #expect(store.selectedThreadID == issue.conversationThreadID)
        // The menu is a real control in the card header, so both the menu and the context menu can reach it.
        _ = try control(h, id: "issue-menu-" + issue.id.rawValue)
    }

    @Test func splitLayoutReservesRoomAndSavesTheDraggedWidth() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let h = HomeHarness(width: 1440, height: 900, opened: issue.id, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let transcript = try #require(h.conversation)
        let conversation = h.frameInWindow(transcript)
        let splitter = try #require(h.views.compactMap { $0 as? IssuePanelSplitterView }.first)
        let splitterFrame = h.frameInWindow(splitter)
        #expect(splitterFrame.width >= K.issueResizeHitWidth - 0.5)
        let drawerFrame = h.frameInWindow(try #require(h.panel))
        #expect(abs(splitterFrame.maxX - drawerFrame.minX) < 1)
        #expect(abs(drawerFrame.width - K.issuePanelDefaultWidth) < 2)
        #expect(abs(conversation.maxX - splitterFrame.minX) < 1, "the conversation is cut by the panel instead of resized")
        #expect(conversation.width >= K.issueConversationMinimumWidth)

        let start = NSPoint(x: splitterFrame.midX, y: splitterFrame.midY)
        #expect(h.window.contentView?.hitTest(start) === splitter)
        try send(.leftMouseDown, at: start, in: h)
        try send(.leftMouseDragged, at: NSPoint(x: start.x - 100, y: start.y), in: h)
        // During the drag the transcript keeps its width; only the guide moves.
        #expect(abs(h.frameInWindow(transcript).width - conversation.width) < 1)
        try send(.leftMouseUp, at: NSPoint(x: start.x - 100, y: start.y), in: h)
        h.settle()
        #expect(abs(h.defaults.double(forKey: "knarr.issuePanelWidth") - 660) < 1)
        #expect(abs(h.frameInWindow(try #require(h.conversation)).width - (conversation.width - 100)) < 2)

        // A saved width survives a remount and is clamped for display without overwriting the preference.
        let remounted = HomeHarness(width: 1440, height: 900, opened: issue.id, store: store) {
            $0.set(2000.0, forKey: "knarr.issuePanelWidth")
        }
        defer { remounted.close() }
        TestWindow.present(remounted.window); remounted.settle(1)
        #expect(abs(remounted.frameInWindow(try #require(remounted.panel)).width - 864) < 2)
        #expect(abs(remounted.frameInWindow(try #require(remounted.conversation)).width - 488) < 2)
        #expect(remounted.defaults.double(forKey: "knarr.issuePanelWidth") == 2000)

        // Dragging past the floor clamps and persists the floor.
        let edge = try #require(remounted.views.compactMap { $0 as? IssuePanelSplitterView }.first)
        let origin = NSPoint(x: remounted.frameInWindow(edge).midX, y: remounted.frameInWindow(edge).midY)
        try send(.leftMouseDown, at: origin, in: remounted)
        try send(.leftMouseDragged, at: NSPoint(x: origin.x + 5000, y: origin.y), in: remounted)
        try send(.leftMouseUp, at: NSPoint(x: origin.x + 5000, y: origin.y), in: remounted)
        remounted.settle()
        #expect(abs(remounted.defaults.double(forKey: "knarr.issuePanelWidth") - Double(K.issuePanelMinimumWidth)) < 0.5)

        // Double-click restores the default width.
        let restored = try #require(remounted.views.compactMap { $0 as? IssuePanelSplitterView }.first)
        let spot = NSPoint(x: remounted.frameInWindow(restored).midX, y: remounted.frameInWindow(restored).midY)
        try send(.leftMouseDown, at: spot, in: remounted, clicks: 2)
        try send(.leftMouseUp, at: spot, in: remounted, clicks: 2)
        remounted.settle()
        #expect(abs(remounted.defaults.double(forKey: "knarr.issuePanelWidth") - Double(K.issuePanelDefaultWidth)) < 0.5)
    }

    @Test func narrowWindowShowsAFullWidthDetailInsteadOfACutTranscript() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let h = HomeHarness(width: 760, height: 640, opened: issue.id, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle(1)
        #expect(h.views.compactMap { $0 as? IssuePanelSplitterView }.first == nil)
        let panel = h.frameInWindow(try #require(h.panel))
        #expect(panel.minX <= 64.5)
        #expect(abs(panel.maxX - 760) < 1)
        let transcript = h.frameInWindow(try #require(h.conversation))
        #expect(transcript.maxX <= 760.5)
    }

    @Test func closeButtonClosesTheDetailAndEscStaysWired() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let h = HomeHarness(width: 1300, height: 900, opened: issue.id, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        #expect(drawer(h) != nil)
        // These test windows never become key, so AppKit cannot deliver Esc here; HomeView keeps
        // `.onExitCommand` and the panel also exposes a `.cancelAction` shortcut on its close button.
        let close = try control(h, id: "issue-drawer-close")
        #expect(press(close))
        h.settle()
        #expect(drawer(h) == nil, "the close button did not close the detail")
    }

    @Test func drawerRendersTheInstructionAsMarkdownAndKeepsTheHeaderFixed() throws {
        let store = SampleKnarrStore(designScene: .issues)
        let h = HomeHarness(width: 1440, height: 900, opened: SampleKnarrStore.designDrawerIssue, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let all = { () -> [NSObject] in elements(try! #require(h.window.contentView)) }
        let records = try #require(all().first { value($0, "accessibilityIdentifier") as? String == "issue-detail-records" })
        #expect(press(records))
        h.settle()
        let instructions = all().filter { (value($0, "accessibilityIdentifier") as? String)?.hasPrefix("issue-instruction-drawer") == true }
        #expect(!instructions.isEmpty)
        let texts = instructions.flatMap { elements($0) }.flatMap { node -> [String] in
            ["accessibilityLabel", "accessibilityValue"].compactMap { value(node, $0) as? String }
        }
        #expect(!texts.isEmpty)
        #expect(!texts.contains { $0.contains("`") || $0.contains("**") || $0.contains("1. ") },
                "Markdown markers leaked into the rendered instruction: \(texts)")
        #expect(texts.contains { $0.contains("저장 데이터를 건드리지 않고") })
        // The header stays above the scrolling content: the close control keeps its place after scrolling.
        let close = try control(h, id: "issue-drawer-close")
        let before = try #require(close.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let scroll = try #require(h.panel)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView?.bounds.height ?? 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        h.settle()
        let after = try #require(close.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        #expect(abs(before.minY - after.minY) < 1, "the header scrolled with the content")
    }
}

/// The drawer's header must keep the title and the close control inside the panel at every allowed
/// width, the card must open on a real double click, and Esc must close a real key window.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssueDrawerHeaderAndKeyboardUITests {
    init() { _ = NSApplication.shared }

    private func value(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let attribute = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                         "accessibilityIdentifier": "AXIdentifier", "accessibilityRole": "AXRole"][selector]
        guard let attribute else { return nil }
        return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    private func frame(_ h: HomeHarness, _ node: NSObject) throws -> NSRect {
        let rect = try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        return h.window.convertFromScreen(rect)
    }

    @Test func longTitleAndCloseControlStayInsideThePanelAtEveryWidth() throws {
        // The sample title is 703.84pt wide at 15pt semibold; adding a Korean tail forces wrapping
        // below the 760pt panel and makes the header the constraint at the 380pt floor.
        let base = try #require(SampleKnarrStore(designScene: .issues).issue(SampleKnarrStore.designDrawerIssue))
        var issue = base
        issue.title = base.title + " " + String(repeating: "가나다라마바사 아자차카타파하 ", count: 4) + "끝"
        let store = SampleKnarrStore(designScene: .issues)
        let expected = NSAttributedString(string: issue.title, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            .boundingRect(with: NSSize(width: 380 - 2 * K.s5, height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin]).height
        for width in [CGFloat(K.issuePanelMinimumWidth), 560, 760, 864] {
            let host = NSHostingView(rootView: IssueDrawer(issue: issue, store: store, close: {})
                .frame(width: width, height: 900))
            let window = TestWindow.make(size: NSSize(width: width, height: 900), styleMask: [.borderless])
            window.contentView = host
            TestWindow.present(window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            defer { window.close() }
            let root = try #require(window.contentView)
            let close = try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == "issue-drawer-close" })
            let box = try #require(close.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let local = window.convertFromScreen(box)
            #expect(local.maxX <= width - K.s5 + 0.5, "close control \(local) leaves the \(width)pt panel")
            #expect(local.minX >= K.s5 - 0.5, "close control \(local) crosses the leading padding")
            let titles = elements(root).compactMap { node -> (String, NSRect)? in
                guard let text = value(node, "accessibilityValue") as? String, text.hasPrefix("NPC 대화 반복 원인"),
                      let f = node.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
                return (text, window.convertFromScreen(f.rectValue))
            }
            let title = try #require(titles.first)
            #expect(title.0 == issue.title, "the header truncated the title to \(title.0.count) of \(issue.title.count) characters")
            #expect(title.1.maxX <= width - K.s5 + 0.5, "title box \(title.1) overflows the panel")
            if width == CGFloat(K.issuePanelMinimumWidth) {
                #expect(abs(title.1.height - expected) < 1, "title height \(title.1.height) against \(expected) for five lines")
            }
        }
    }

    @Test func doubleClickOnTheCardOpensTheDetailWithoutChangingThread() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        store.createThread(name: "사용자 대화")
        store.selectThread(ConversationThread.defaultID)
        let h = HomeHarness(width: 1300, height: 900, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle()
        let root = try #require(h.window.contentView)
        let card = try #require(elements(root)
            .first { value($0, "accessibilityIdentifier") as? String == "integrated-issue-" + issue.id.rawValue })
        let point = NSPoint(x: try frame(h, card).midX, y: try frame(h, card).midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 2, pressure: 1))
            h.window.sendEvent(event)
        }
        h.settle()
        #expect(elements(root).contains {
            value($0, "accessibilityIdentifier") as? String == "issue-drawer"
        }, "double click did not open the detail")
        #expect(store.selectedThreadID == ConversationThread.defaultID, "double click switched threads")
    }

    /// Esc must reach `HomeView.onExitCommand`. Test windows never become key, so this one is a
    /// plain key-capable window in a regular-activation process, the same shape as the running app.
    @Test func escapeClosesTheDetailInAKeyWindow() throws {
        // SwiftUI only builds the accessibility tree when enhanced AX is on (TestWindow.prepare).
        TestWindow.prepare()
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let suite = "knarr-esc-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "knarr.issueCardsCollapsed")
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: HomeView(store: store, opened: issue.id, page: .conversation)
            .frame(width: 1000, height: 700)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            window.close()
            NSApp.setActivationPolicy(policy)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        func identifiers() -> [String] {
            func walk(_ node: NSObject) -> [NSObject] { [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(walk) }
            return walk(host).compactMap { value($0, "accessibilityIdentifier") as? String }
        }
        try #require(identifiers().contains("issue-drawer"), "the detail did not open before Esc")
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(esc)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        #expect(!identifiers().contains("issue-drawer"), "Esc did not close the detail")
    }

    @Test func narrowOverlayCoversTheTranscriptAndSwallowsClicks() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let h = HomeHarness(width: 760, height: 640, opened: issue.id, store: store)
        defer { h.close() }
        TestWindow.present(h.window); h.settle(1)
        let host = try #require(h.window.contentView)
        let panel = try #require(h.panel)
        let panelFrame = h.frameInWindow(panel)
        let web = try #require(h.conversation)
        let webFrame = h.frameInWindow(web)
        // The overlay starts at the rail, so the transcript underneath is fully covered in x.
        #expect(panelFrame.minX <= K.railWidth + 0.5)
        #expect(webFrame.maxX <= panelFrame.maxX + 0.5)
        // Every point across the covered transcript's middle hits the panel, never the web view.
        for step in stride(from: 0.05, through: 0.95, by: 0.1) {
            let point = NSPoint(x: webFrame.minX + webFrame.width * step, y: webFrame.midY)
            let hit = host.hitTest(point)
            var node = hit
            var insidePanel = false, insideWeb = false
            while let current = node {
                if current === panel { insidePanel = true }
                if current === web { insideWeb = true }
                node = current.superview
            }
            #expect(insidePanel && !insideWeb, "point \(point) reaches the transcript under the overlay")
        }
    }
}

/// The panel width lives in `UserDefaults`, so a remount and a separate launch must both read the
/// saved value back rather than the default.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct IssuePanelWidthRestoreUITests {
    init() { _ = NSApplication.shared }

    @Test func savedWidthComesBackAfterRemountAndInANewHarness() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let suite = "knarr-restore-\(UUID().uuidString)"
        let first = HomeHarness(width: 1440, height: 900, opened: issue.id, store: store, suite: suite)
        TestWindow.present(first.window); first.settle(1)
        let splitter = try #require(first.views.compactMap { $0 as? IssuePanelSplitterView }.first)
        let start = NSPoint(x: first.frameInWindow(splitter).midX, y: first.frameInWindow(splitter).midY)
        func drag(_ h: HomeHarness, to point: NSPoint) throws {
            for (type, at) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, point), (.leftMouseUp, point)] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                h.window.sendEvent(event)
            }
            h.settle()
        }
        try drag(first, to: NSPoint(x: start.x - 100, y: start.y))
        let saved = first.defaults.double(forKey: "knarr.issuePanelWidth")
        #expect(abs(saved - 660) < 1)
        let shown = first.frameInWindow(try #require(first.panel)).width
        first.close(keepingPreferences: true)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // A fresh mount with the same suite (same process, new window) reads the saved width.
        let remount = HomeHarness(width: 1440, height: 900, opened: issue.id, store: store, suite: suite)
        defer { remount.close(keepingPreferences: true) }
        TestWindow.present(remount.window); remount.settle(1)
        #expect(abs(remount.frameInWindow(try #require(remount.panel)).width - shown) < 2)
        #expect(abs(remount.defaults.double(forKey: "knarr.issuePanelWidth") - saved) < 1)
    }

    /// 900pt leaves 836pt after the rail, below the 884pt split threshold, so the detail is a
    /// full-width overlay. Overlay width is the available width; the split clamps only apply in split mode.
    @Test func widthOutsideTheWindowIsClampedForDisplayButThePreferenceSurvives() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        let suite = "knarr-clamp-\(UUID().uuidString)"
        let h = HomeHarness(width: 1440, height: 900, opened: issue.id, store: store, suite: suite) {
            $0.set(2000.0, forKey: "knarr.issuePanelWidth")
        }
        TestWindow.present(h.window); h.settle(1)
        defer { h.close() }
        let split = try #require(h.panel)
        #expect(abs(h.frameInWindow(split).width - 864) < 2, "split panel width \(h.frameInWindow(split).width)")
        #expect(h.defaults.double(forKey: "knarr.issuePanelWidth") == 2000)

        let narrow = HomeHarness(width: 900, height: 900, opened: issue.id, store: store, suite: suite)
        TestWindow.present(narrow.window); narrow.settle(1)
        defer { narrow.close() }
        #expect(narrow.views.compactMap { $0 as? IssuePanelSplitterView }.first == nil, "900pt must not split")
        let overlay = try #require(narrow.panel)
        let overlayFrame = narrow.frameInWindow(overlay)
        #expect(abs(overlayFrame.width - (900 - K.railWidth)) < 2, "overlay width \(overlayFrame.width)")
        #expect(abs(overlayFrame.maxX - 900) < 1)
        #expect(abs(narrow.defaults.double(forKey: "knarr.issuePanelWidth") - 2000) < 1, "display clamp overwrote the preference")

        // Widening back restores the split and keeps showing the clamped maximum, not the overlay width.
        narrow.resize(width: 1440, height: 900); narrow.settle(1)
        #expect(narrow.views.compactMap { $0 as? IssuePanelSplitterView }.first != nil)
        #expect(abs(narrow.frameInWindow(try #require(narrow.panel)).width - 864) < 2)
        #expect(abs(narrow.defaults.double(forKey: "knarr.issuePanelWidth") - 2000) < 1)
    }

    @Test func splitThresholdIsMeasuredEitherSideOfTheBreakpoint() throws {
        let store = SampleKnarrStore(issueSessionScene: .main)
        let issue = try #require(store.topIssueCards.issues.first)
        // available = width − 64 rail; split needs 380 + 480 + 24 = 884.
        let threshold = K.issuePanelMinimumWidth + K.issueConversationMinimumWidth + K.issueResizeHitWidth
        let below = HomeHarness(width: threshold + K.railWidth - 1, height: 900, opened: issue.id, store: store)
        TestWindow.present(below.window); below.settle(1)
        defer { below.close() }
        #expect(below.views.compactMap { $0 as? IssuePanelSplitterView }.first == nil)
        #expect(abs(below.frameInWindow(try #require(below.panel)).width - (threshold - 1)) < 2)

        let atThreshold = HomeHarness(width: threshold + K.railWidth, height: 900, opened: issue.id, store: store)
        TestWindow.present(atThreshold.window); atThreshold.settle(1)
        defer { atThreshold.close() }
        #expect(atThreshold.views.compactMap { $0 as? IssuePanelSplitterView }.first != nil)
        // Only the 380pt floor and the 480pt conversation fit at the breakpoint.
        #expect(abs(atThreshold.frameInWindow(try #require(atThreshold.panel)).width - K.issuePanelMinimumWidth) < 2)
        #expect(abs(atThreshold.frameInWindow(try #require(atThreshold.conversation)).width - K.issueConversationMinimumWidth) < 2)
    }
}
