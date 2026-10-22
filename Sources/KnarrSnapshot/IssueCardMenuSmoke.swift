import AppKit
import SwiftUI
import KnarrCore
import KnarrUI

/// Runs outside XCTest: AppKit menu tracking must not inherit another UI test's application state.
@MainActor enum IssueCardMenuSmoke {
    struct Item: Codable, Equatable {
        var title: String
        var enabled: Bool
        var submenu: [Item]?
    }
    struct Result: Codable {
        var issue: String
        var popup: [Item]
        var context: [Item]
        var detailTitle: String
        var threadID: String
        /// True when a finished or judged card offered no user review, merge or revision command.
        var hidesReviewCommands: Bool
        var proposalVersion: Int
        var closeReason: String
    }
    struct Evidence: Codable {
        var processID: Int32
        var parentProcessID: Int32
        var completedScenarios: Int
        var result: Result
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Window: NSWindow { override var canBecomeKey: Bool { true } }
    private final class Tracking: @unchecked Sendable {
        var menu: NSMenu?
        var rows: [Item] = []
        var selected = false
        var failure: String?
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }
        return value
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func value(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector) { return node.perform(selector)?.takeUnretainedValue() }
        let names = ["accessibilityIdentifier": "AXIdentifier", "accessibilityChildren": "AXChildren",
                     "accessibilityValue": "AXValue", "accessibilityLabel": "AXDescription"]
        guard let attribute = names[name] else { return nil }
        return node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
    }
    private static func nodes(_ node: NSObject) -> [NSObject] {
        [node] + ((value(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(nodes)
    }
    private static func element(_ host: NSView, _ id: String) throws -> NSObject {
        try required(nodes(host).first { value($0, "accessibilityIdentifier") as? String == id }, "요소 없음: \(id)")
    }
    private static func frame(_ node: NSObject, in window: NSWindow) throws -> NSRect {
        let screen = try required(node.value(forKey: "accessibilityFrame") as? NSValue, "AX frame 없음").rectValue
        return window.convertFromScreen(screen)
    }
    private static func settle(_ host: NSView, _ seconds: Double = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }
    private static func rows(_ menu: NSMenu) -> [Item] {
        menu.items.compactMap { item in
            // NSPopUpButton inserts a blank, actionless first display row. No command is discarded.
            if item.isSeparatorItem || (item.title.isEmpty && item.action == nil && item.submenu == nil) { return nil }
            return Item(title: item.title, enabled: item.isEnabled, submenu: item.submenu.map(rows))
        }
    }
    private static func press(_ node: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        try check(node.responds(to: selector), "press 지원 안 함")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try check(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector), "press 실패")
    }
    static func expandIssueRecords(in host: NSView) throws {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        host.window?.orderFront(nil)
        defer { host.window?.orderOut(nil) }
        settle(host)
        try press(element(host, "issue-detail-records"))
        settle(host)
        _ = try element(host, "issue-instruction-drawer")
    }
    private static func capture(_ window: NSWindow, to url: URL, stalledFixture: Bool = false) throws {
        let process = Process()
        let out = url.deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: stalledFixture ? CommandLine.arguments[0] : "/usr/sbin/screencapture")
        let frame = window.frame
        let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
        var rect = CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height)
        // Native menus are separate windows and can extend beyond the hosting window.
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows where (info[kCGWindowOwnerPID as String] as? Int32) == getpid() {
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let menuRect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                rect = rect.union(menuRect)
            }
        }
        process.arguments = stalledFixture ? [out.path, "issue-card-menu-internal-capture"] :
            ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", url.path]
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? MenuSmokeLifetime.exited(process, out: out)
        }
        try MenuSmokeLifetime.record(process.processIdentifier, role: "capture", out: out)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try check(!process.isRunning, "메뉴 화면 캡처 시간 초과 pid=\(process.processIdentifier)")
        try check(process.terminationStatus == 0, "메뉴 화면 캡처 실패: \(process.terminationStatus)")
    }

    /// The actual popup belongs to this card's AX menu frame, not the first popup in the window.
    private static func popup(_ host: NSView, issue: KnarrCore.Issue, window: NSWindow) throws -> NSPopUpButton {
        let card = try frame(element(host, "integrated-issue-" + issue.id.rawValue), in: window)
        let menu = try frame(element(host, "issue-menu-" + issue.id.rawValue), in: window)
        let matches = views(host).compactMap { $0 as? NSPopUpButton }.filter {
            let rect = $0.convert($0.bounds, to: nil)
            return card.contains(NSPoint(x: rect.midX, y: rect.midY)) && rect.intersects(menu)
        }
        try check(matches.count == 1, "카드 메뉴 매칭 수: \(issue.id) \(matches.count)")
        return try required(matches.first, "카드 popup 없음")
    }

    /// Observe a displayed menu, select its actual NSMenuItem, then let its tracking loop unwind.
    /// A parent-process deadline also covers AppKit failing to enter the tracking run loop at all.
    private static func choose(_ path: [String], host: NSView, window: NSWindow,
                               screenshot: URL? = nil, open: () throws -> Void) throws -> [Item] {
        let state = Tracking()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: nil) { note in
            // AppKit delivers menu tracking notifications synchronously on its main thread.
            let observed = Tracking()
            observed.menu = note.object as? NSMenu
            MainActor.assumeIsolated { state.menu = observed.menu }
        }
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.15, repeats: true) { timer in
            if state.selected || state.failure != nil { timer.invalidate(); return }
            MainActor.assumeIsolated {
                if Date() >= deadline {
                    state.failure = "메뉴 추적 시간 초과: \(path), 표시 항목=\(state.menu?.items.map(\.title) ?? [])"
                    state.menu?.cancelTracking()
                    return
                }
                guard let menu = state.menu else { return }
                guard menu.items.contains(where: { $0.title == path.first }) else { return }
                state.rows = rows(menu)
                do {
                    if let screenshot { try capture(window, to: screenshot) }
                    var selectedMenu = menu
                    for title in path.dropLast() {
                        selectedMenu = try required(selectedMenu.items.first { $0.title == title }?.submenu, "하위 메뉴 없음: \(title)")
                    }
                    let index = try required(selectedMenu.items.firstIndex { $0.title == path.last }, "선택 항목 없음: \(path)")
                    try check(selectedMenu.items[index].isEnabled, "선택 항목 비활성: \(path)")
                    selectedMenu.performActionForItem(at: index)
                    state.selected = true
                } catch { state.failure = String(describing: error) }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            state.menu?.cancelTracking()
        }
        try open()
        settle(host)
        if let failure = state.failure { throw Failure(description: failure) }
        try check(state.selected, "메뉴 표시/선택이 관측되지 않음: \(path)")
        return state.rows
    }

    /// Read a card's menu rows without selecting anything, so an absent command can be checked.
    private static func menuRows(_ host: NSView, issue: KnarrCore.Issue, window: NSWindow) throws -> [Item] {
        let state = Tracking()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: nil) { note in
            // AppKit delivers menu tracking notifications synchronously on its main thread.
            let observed = Tracking()
            observed.menu = note.object as? NSMenu
            MainActor.assumeIsolated { state.menu = observed.menu }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.15, repeats: true) { timer in
            if state.selected || state.failure != nil { timer.invalidate(); return }
            MainActor.assumeIsolated {
                if Date() >= deadline {
                    state.failure = "메뉴 추적 시간 초과"
                    state.menu?.cancelTracking()
                    return
                }
                guard let menu = state.menu else { return }
                state.rows = rows(menu)
                state.selected = true
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        try popup(host, issue: issue, window: window).performClick(nil)
        settle(host)
        if let failure = state.failure { throw Failure(description: failure) }
        try check(state.selected, "메뉴 표시가 관측되지 않음: \(issue.id)")
        return state.rows
    }

    private static func context(_ path: [String], host: NSView, window: NSWindow,
                                issue: KnarrCore.Issue) throws -> [Item] {
        let card = try frame(element(host, "integrated-issue-" + issue.id.rawValue), in: window)
        let point = NSPoint(x: card.midX, y: card.midY)
        let hitPoint = host.superview?.convert(point, from: nil) ?? point
        let hit = try required(host.hitTest(hitPoint), "우클릭 hit 없음")
        try check(!String(describing: type(of: hit)).contains("Popup"), "우클릭이 메뉴 버튼에 닿음")
        let down = try required(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1), "우클릭 생성 실패")
        return try choose(path, host: host, window: window) { hit.rightMouseDown(with: down) }
    }

    /// The supervisor never enters AppKit's modal loop and owns the worker's preferences.
    /// Its deadline also covers AppKit not entering the tracking run loop at all.
    static func supervise(out: URL, fault: String? = nil) throws {
        let suite = "knarr-issue-menu-smoke-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let identity = try MenuSmokeLifetime.record(getpid(), role: "supervisor", out: out)
        let context = MenuSmokeLifetime.Context(supervisor: identity, suite: suite, fault: fault)
        try JSONEncoder().encode(context).write(to: out.appendingPathComponent("menu-lifetime.json"), options: .atomic)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [out.path, "issue-card-menu-worker", suite] + (fault.map { [$0] } ?? [])
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning { kill(pid, SIGKILL) }
            child.waitUntilExit()
            try? MenuSmokeLifetime.exited(child, out: out)
        }
        var reason = "workerExit"
        let outcome: Swift.Result<Void, Error> = Swift.Result {
            try MenuSmokeLifetime.record(pid, role: "worker", out: out)
            print("MENU SUPERVISOR pid=\(getpid()) child=\(pid) suite=\(suite)")
            fflush(stdout)
            if fault == "external-deadline" {
                // Exercise the caller's hard-stop fallback, not this supervisor's cooperative exit.
                signal(SIGTERM, SIG_IGN)
                while true { Thread.sleep(forTimeInterval: 0.05) }
            }
            let deadline = Date().addingTimeInterval(fault == "no-menu-tracking" ? 3 : 45)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning {
                reason = "workerDeadline"
                throw Failure(description: "메뉴 worker 시간 초과 pid=\(pid)")
            }
            child.waitUntilExit()
            print("MENU WORKER END pid=\(pid) exit=\(child.terminationStatus)")
            try check(child.terminationStatus == 0, "메뉴 worker 실패: \(child.terminationStatus)")
            let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: out.appendingPathComponent("issue-card-menu.json")))
            try check(evidence.completedScenarios == 6 && evidence.processID == pid && evidence.parentProcessID == getpid(),
                      "메뉴 worker 완료 요약/소유권 불일치")
            reason = "completed"
        }
        // Keep the worker's Process owner alive while reclaiming any recorded capture first.
        _ = try MenuSmokeLifetime.reclaim(out: out, external: false, reason: reason)
        try outcome.get()
        print("MENU VERIFIED completedScenarios=6 residual=0")
    }

    static let faults = ["no-menu-tracking", "capture-timeout", "worker-exit", "external-deadline"]

    static func stalledCapture(out: URL) throws -> Never {
        signal(SIGTERM, SIG_IGN)
        print("MENU FAULT CAPTURE pid=\(getpid()) ppid=\(getppid())")
        fflush(stdout)
        try Data().write(to: out.appendingPathComponent("menu-capture-ready"), options: .atomic)
        while true { Thread.sleep(forTimeInterval: 0.05) }
    }

    static func runFault(out: URL, suite: String, fault: String) throws {
        try check(faults.contains(fault), "알 수 없는 내부 fault")
        let preferences = try required(UserDefaults(suiteName: suite), "fault preferences 생성 실패")
        preferences.set(true, forKey: "menu-fault-sentinel")
        preferences.synchronize()
        if fault == "capture-timeout" {
            let window = Window(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            try capture(window, to: out.appendingPathComponent("unused.png"), stalledFixture: true)
            throw Failure(description: "capture timeout이 발생하지 않음")
        }
        signal(SIGTERM, SIG_IGN)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        capture.arguments = [out.path, "issue-card-menu-internal-capture"]
        try capture.run()
        // Deliberately no defer here: the fault must exercise the parent's orphan recovery.
        try MenuSmokeLifetime.record(capture.processIdentifier, role: "capture", out: out)
        let ready = out.appendingPathComponent("menu-capture-ready")
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try check(FileManager.default.fileExists(atPath: ready.path), "fault capture 시작 실패")
        if fault == "worker-exit" { exit(42) }
        let host = NSHostingView(rootView: Text("menu lifecycle fixture"))
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        _ = try choose(["상세 열기"], host: host, window: window) {
            // No menu notification or tracking run loop: the actual parent deadline must recover us.
            try Data().write(to: out.appendingPathComponent("menu-open-entered"), options: .atomic)
            while true { Thread.sleep(forTimeInterval: 0.05) }
        }
    }

    static func run(out: URL, suite: String) throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(policy) }
        let preferences = try required(UserDefaults(suiteName: suite), "preferences 생성 실패")
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "knarr.issueCardsCollapsed")
        let store = SampleKnarrStore(issueSessionScene: .main)
        store.createThread(name: "다른 대화")
        store.selectThread(ConversationThread.defaultID)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let size = NSSize(width: min(1440, visible.width - 40), height: min(900, visible.height - 80))
        let root = AnyView(HomeView(store: store, page: .conversation).frame(width: size.width, height: size.height)
            .defaultAppStorage(preferences).environment(\.colorScheme, .light))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        let window = Window(contentRect: NSRect(origin: NSPoint(x: visible.minX + 20, y: visible.minY + 20), size: size),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        settle(host, 1)
        print("MENU START pid=\(ProcessInfo.processInfo.processIdentifier) ppid=\(getppid()) suite=\(suite)")

        let running = try required(store.topIssueCards.issues.first { $0.hasActiveHird }, "실행 중 카드 없음")
        let runningPopup = try popup(host, issue: running, window: window)
        let popupItems = try choose(["상세 열기"], host: host, window: window,
                                   screenshot: out.appendingPathComponent("issue-card-menu-open.png")) {
            runningPopup.performClick(nil)
        }
        let drawer = try element(host, "issue-drawer")
        let drawerTexts = nodes(drawer).compactMap { value($0, "accessibilityValue") as? String }
        try check(drawerTexts.contains(running.title), "상세가 선택한 카드와 다름: \(drawerTexts)")
        try check(store.selectedThreadID == ConversationThread.defaultID, "상세 열기가 스레드를 바꿈")
        try press(element(host, "issue-drawer-close")); settle(host)
        let contextRows = try context(["상세 열기"], host: host, window: window, issue: running)
        try check(contextRows == popupItems, "우클릭/...의 명령·enabled·사유·하위 메뉴 불일치")
        _ = try element(host, "issue-drawer")
        let close = try required(popupItems.first { $0.title == "이슈 닫기" }?.submenu, "닫기 사유 없음")
        try check(close.count == IssueCloseReason.allCases.count && close.allSatisfy {
            !$0.enabled && $0.title.contains("실행 중에는 닫을 수 없어요")
        }, "닫기 비활성 사유 누락")
        try press(element(host, "issue-drawer-close")); settle(host)
        _ = try choose(["스레드로 이동"], host: host, window: window) {
            try popup(host, issue: running, window: window).performClick(nil)
        }
        try check(store.selectedThreadID == running.conversationThreadID, "명시적 스레드 이동 실패")
        let selectedThread = store.selectedThreadID
        store.selectThread(ConversationThread.defaultID); settle(host)

        // A judged or integrated result shows no review, merge, revision or resume command to the person.
        let finishedCards = store.topIssueCards.issues.filter {
            [.judging, .awaitingIntegration, .unmet, .failed].contains($0.displayStatus)
        }
        try check(!finishedCards.isEmpty, "판정·통합 카드 없음")
        for judged in finishedCards {
            let rows = try menuRows(host, issue: judged, window: window)
            for row in rows {
                try check(!["수정 요청", "결과 확인", "결과 반영", "다시 시작", "이어서 실행"].contains(row.title),
                          "판정·통합 카드에 사용자 검토 명령이 남음: \(row.title)")
                try check(!row.title.contains("합치") && !row.title.contains("보관"),
                          "판정·통합 카드에 통합 명령이 남음: \(row.title)")
            }
        }

        let proposal = try required(store.topIssueCards.issues.first { $0.state == .awaitingApproval && $0.proposal != nil }, "승인 카드 없음")
        let version = try required(proposal.proposal?.version, "제안 버전 없음")
        _ = try choose(["제안 v\(version) 실행"], host: host, window: window) {
            try popup(host, issue: proposal, window: window).performClick(nil)
        }
        try check(store.issue(proposal.id)?.approval?.version == version, "메뉴 승인 버전 미적용")

        let closable = try required(store.topIssueCards.issues.first {
            !$0.hasActiveHird && $0.id != running.id && $0.state != .awaitingApproval
        }, "닫을 카드 없음")
        let reason = IssueCloseReason.allCases[0]
        _ = try context(["이슈 닫기", reason.title], host: host, window: window, issue: closable)
        try check(store.issue(closable.id)?.archiveReason == reason.rawValue && store.issue(closable.id)?.archivedAt != nil, "닫기 사유 store action 미적용")
        let result = Result(issue: running.id.rawValue, popup: popupItems, context: contextRows,
                            detailTitle: running.title, threadID: selectedThread, hidesReviewCommands: true,
                            proposalVersion: version, closeReason: reason.rawValue)
        let evidence = Evidence(processID: ProcessInfo.processInfo.processIdentifier, parentProcessID: getppid(),
                                completedScenarios: 6, result: result)
        try JSONEncoder().encode(evidence).write(to: out.appendingPathComponent("issue-card-menu.json"))
        print("MENU COMPLETE 6/6: popup, right-click, thread, hidden-review-commands, proposal-version, close-reason")
    }
}
