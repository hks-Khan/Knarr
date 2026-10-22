import AppKit
import SwiftUI
import KnarrCore
import KnarrUI

/// Native drag on the issue-detail splitter, then a separate process that reads the same isolated
/// preference suite without being handed a width. The project panel has the same smoke; this one
/// covers the issue panel's own `knarr.issuePanelWidth` key and its narrow-window overlay.
@MainActor enum IssuePanelWidthSmoke {
    struct Evidence: Codable {
        var suite: String
        var processID: Int32
        var eventPath: String
        var storedWidth: Double
        var renderedWidth: Double
        var defaultWidth: Double
        var overlayWidth: Double
        var overlaySplitter: Bool
        var preferenceAfterOverlay: Double
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Window: NSWindow { override var canBecomeKey: Bool { true } }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func settle(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
    }
    private static func splitter(_ host: NSView) -> NSView? {
        views(host).first { $0.accessibilityIdentifier() == "issue-panel-resize" }
    }
    /// The detail's scroll view: flush with the window's trailing edge and spanning the content's
    /// vertical middle. The transcript's scroll view ends at the splitter instead.
    private static func panel(_ host: NSView, windowWidth: CGFloat) throws -> NSScrollView {
        guard let scroll = views(host).compactMap({ $0 as? NSScrollView }).last(where: { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return abs(frame.maxX - windowWidth) < 1 && frame.minY <= host.bounds.midY && frame.maxY >= host.bounds.midY
        }) else { throw Failure(description: "상세 scroll view를 찾지 못했습니다") }
        return scroll
    }
    private static func capture(_ host: NSView, to url: URL) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(description: "화면 bitmap을 만들지 못했습니다")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "PNG를 만들지 못했습니다")
        }
        try png.write(to: url)
    }

    static func run(out: URL, restore: Bool) throws {
        let manifest = out.appendingPathComponent("issue-panel-resize-drag.json")
        let previous = restore ? try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: manifest)) : nil
        let suite = previous?.suite ?? "knarr-issue-panel-smoke-" + UUID().uuidString
        try require(suite.hasPrefix("knarr-issue-panel-smoke-"), "격리 smoke preferences만 사용할 수 있습니다")
        guard let preferences = UserDefaults(suiteName: suite) else {
            throw Failure(description: "격리 preferences를 만들지 못했습니다")
        }
        defer { if !restore { preferences.removePersistentDomain(forName: suite) } }
        preferences.set(false, forKey: "knarr.issueCardsCollapsed")
        // The restore process must not be handed a width: it reads only what the first process saved.
        try require(restore || preferences.object(forKey: "knarr.issuePanelWidth") == nil,
                    "초기 smoke가 너비를 미리 주입했습니다")
        let store = SampleKnarrStore(designScene: .issues)
        let root = HomeView(store: store, opened: SampleKnarrStore.designDrawerIssue, page: .conversation)
            .frame(minWidth: 720, minHeight: 540)
            .defaultAppStorage(preferences).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        settle(host)

        let first = try panel(host, windowWidth: 1440)
        let firstWidth = Double(first.bounds.width)
        if let previous {
            try require(previous.processID != ProcessInfo.processInfo.processIdentifier, "별도 프로세스가 아닙니다")
            try require(abs(firstWidth - previous.storedWidth) < 2,
                        "재실행 후 이슈 상세 폭이 복원되지 않았습니다: \(firstWidth), 저장 \(previous.storedWidth)")
            try require(abs(preferences.double(forKey: "knarr.issuePanelWidth") - previous.storedWidth) < 1,
                        "재실행이 저장 선호를 바꿨습니다")
            var restored = previous
            restored.processID = ProcessInfo.processInfo.processIdentifier
            restored.renderedWidth = firstWidth
            try JSONEncoder().encode(restored).write(to: out.appendingPathComponent("issue-panel-resize-restore.json"))
            try capture(host, to: out.appendingPathComponent("issue-panel-resize-restored.png"))
            print("이슈 상세 폭 재실행 복원 확인: \(firstWidth)pt, PID \(restored.processID), 저장값 재주입 없음")
            return
        }

        // Same default the token declares; no preference has been written yet.
        try require(abs(firstWidth - 560) < 2, "기본 상세 폭이 560pt가 아닙니다: \(firstWidth)")
        guard let handle = splitter(host) else { throw Failure(description: "실제 splitter를 찾지 못했습니다") }
        let frame: NSRect = handle.convert(handle.bounds, to: nil)
        let start = NSPoint(x: frame.midX, y: frame.midY)
        try require(host.hitTest(start) === handle, "핸들의 hit area가 마우스 이벤트를 받지 못합니다")
        func send(_ type: NSEvent.EventType, to point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure(description: "네이티브 mouse event 생성 실패")
            }
            window.sendEvent(event)
            settle(host)
        }
        let destination = NSPoint(x: start.x - 100, y: start.y)
        try send(.leftMouseDown, to: start)
        try send(.leftMouseDragged, to: destination)
        // The width commits on release, so the panel keeps its width during the drag.
        let duringDrag = Double(try panel(host, windowWidth: 1440).bounds.width)
        try require(abs(duringDrag - firstWidth) < 2, "드래그 중 상세 폭이 먼저 바뀌었습니다")
        try send(.leftMouseUp, to: destination)
        let stored = preferences.double(forKey: "knarr.issuePanelWidth")
        try require(abs(stored - 660) < 2, "mouseUp이 660pt 선호를 저장하지 않았습니다: \(stored)")
        let rendered = Double(try panel(host, windowWidth: 1440).bounds.width)
        try require(abs(rendered - stored) < 2, "mouseUp 후 상세 폭이 저장값과 다릅니다: \(rendered)")

        // 900pt leaves 836pt after the rail: an overlay, not a clamped split.
        window.setContentSize(NSSize(width: 900, height: 640)); settle(host)
        try require(splitter(host) == nil, "900pt 창이 분할 모드로 남았습니다")
        let overlay = try panel(host, windowWidth: 900)
        let overlayFrame: NSRect = overlay.convert(overlay.bounds, to: nil)
        // 900 − 64 rail = 836: the overlay takes the whole content area instead of a clamped split.
        try require(abs(Double(overlayFrame.width) - 836) < 2,
                    "오버레이 폭이 가용폭이 아닙니다: \(overlayFrame.width)")
        try require(overlayFrame.minX <= 65, "오버레이가 레일 뒤에서 시작하지 않습니다")
        try require(abs(preferences.double(forKey: "knarr.issuePanelWidth") - stored) < 1,
                    "오버레이 표시가 저장 선호를 덮어썼습니다")
        try capture(host, to: out.appendingPathComponent("issue-panel-overlay.png"))
        window.setContentSize(NSSize(width: 1440, height: 900)); settle(host)
        try require(abs(Double(try panel(host, windowWidth: 1440).bounds.width) - stored) < 2,
                    "창을 되돌려도 저장 폭이 돌아오지 않습니다")

        let evidence = Evidence(suite: suite, processID: ProcessInfo.processInfo.processIdentifier,
            eventPath: "NSEvent → NSWindow.sendEvent → IssuePanelSplitterView mouseDown/Dragged/Up (synthetic, not OS/CUA)",
            storedWidth: stored, renderedWidth: rendered, defaultWidth: firstWidth,
            overlayWidth: Double(overlayFrame.width), overlaySplitter: false,
            preferenceAfterOverlay: preferences.double(forKey: "knarr.issuePanelWidth"))
        try JSONEncoder().encode(evidence).write(to: manifest)
        preferences.synchronize()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [out.path, "issue-panel-resize-restore"]
        try child.run(); child.waitUntilExit()
        try require(child.terminationStatus == 0, "재실행 복원 subprocess 실패: \(child.terminationStatus)")
        preferences.removePersistentDomain(forName: suite)
        print("이슈 상세 drag 확인: \(firstWidth) → \(stored)pt, 오버레이 \(overlayFrame.width)pt, 저장 선호 유지")
    }
}
