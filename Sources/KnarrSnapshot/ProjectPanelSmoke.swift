import AppKit
import SwiftUI
import KnarrCore
import KnarrUI

/// Sample data + isolated preferences only. Drives the real NSWindow mouse-event path,
/// then launches this executable again to prove restoration across processes.
@MainActor enum ProjectPanelSmoke {
    struct Evidence: Codable {
        var suite: String
        var processID: Int32
        var eventPath: String
        var preferredWidth: Double
        var renderedWidth: Double
        var dragWidths: [Double]
        var narrowWidth: Double
        var focusPreservedDuringDrag: Bool?
    }
    struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Window: NSWindow { override var canBecomeKey: Bool { true } }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private static func settle(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
    }
    private static func transcript(_ host: NSView) throws -> NSScrollView {
        guard let view = views(host).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView is NSTableView }) else {
            throw Failure(description: "대화 transcript를 찾지 못했습니다")
        }
        return view
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
        let manifest = out.appendingPathComponent("project-panel-resize-drag.json")
        let previous = restore ? try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: manifest)) : nil
        let suite = previous?.suite ?? "knarr-project-panel-smoke-" + UUID().uuidString
        try require(suite.hasPrefix("knarr-project-panel-smoke-"), "격리 smoke preferences만 사용할 수 있습니다")
        guard let preferences = UserDefaults(suiteName: suite) else {
            throw Failure(description: "격리 preferences를 만들지 못했습니다")
        }
        defer { if !restore { preferences.removePersistentDomain(forName: suite) } }
        preferences.set(false, forKey: "knarr.projectSessionCollapsed.gamza")
        if !restore { preferences.set(480.0, forKey: "knarr.projectSessionWidth") }
        let store = SampleKnarrStore(projectSessionScene: .open)
        for index in 0..<32 {
            store.send("메시지 \(index) " + String(repeating: "긴 대화를 읽으며 패널을 조절합니다. ", count: 20),
                       about: nil, project: "gamza", attachments: [])
        }
        store.composerDraft.text = "드래그와 재실행에서도 유지할 입력"
        store.isResponding = true
        store.streamingText = "계속 도착하는 답변입니다."
        let root = HomeView(store: store, page: .projects, project: "gamza")
            .frame(minWidth: 720, minHeight: 540)
            .defaultAppStorage(preferences).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 1720, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let initial = try transcript(host)
        if let previous {
            let width = Double(initial.bounds.width)
            try require(previous.processID != ProcessInfo.processInfo.processIdentifier, "별도 프로세스가 아닙니다")
            try require(abs(width - previous.preferredWidth) < 2, "재실행 후 대화 너비가 복원되지 않았습니다: \(width)")
            let evidence = Evidence(suite: suite, processID: ProcessInfo.processInfo.processIdentifier,
                eventPath: "새 프로세스의 persisted UserDefaults → HomeView", preferredWidth: previous.preferredWidth,
                renderedWidth: width, dragWidths: [], narrowWidth: 0, focusPreservedDuringDrag: nil)
            try JSONEncoder().encode(evidence).write(to: out.appendingPathComponent("project-panel-resize-restore.json"))
            try capture(host, to: out.appendingPathComponent("project-panel-resize-restored.png"))
            print("패널 너비 재실행 복원 확인: \(width)pt, PID \(evidence.processID)")
            return
        }
        guard let splitter = views(host).first(where: { $0.accessibilityIdentifier() == "project-session-resize-gamza" }),
              let editor = views(host).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }) else {
            throw Failure(description: "실제 splitter 또는 입력창을 찾지 못했습니다")
        }
        try require(window.makeFirstResponder(editor), "입력창 focus를 잡지 못했습니다")
        let frame = splitter.convert(splitter.bounds, to: nil)
        let start = NSPoint(x: frame.midX, y: frame.midY)
        try require(host.hitTest(start) === splitter, "핸들의 hit area가 마우스 이벤트를 받지 못합니다")
        func send(_ type: NSEvent.EventType, distance: CGFloat) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x - distance, y: start.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw Failure(description: "네이티브 mouse event 생성 실패")
            }
            window.sendEvent(event)
            settle(host)
        }
        let initialWidth = Double(initial.bounds.width)
        try require(abs(initialWidth - 480) < 2, "초기 대화 너비가 480pt가 아닙니다")
        try send(.leftMouseDown, distance: 0)
        var dragWidths: [Double] = []
        for distance in stride(from: 20.0, through: 160.0, by: 20.0) {
            store.streamingText += " 새 답변 조각"
            try send(.leftMouseDragged, distance: distance)
            dragWidths.append(Double(initial.bounds.width))
            try require(abs(Double(initial.bounds.width) - initialWidth) < 2, "드래그 중 transcript가 연속 reflow됐습니다")
            try require(window.firstResponder === editor, "드래그 중 입력 focus를 잃었습니다")
        }
        try send(.leftMouseUp, distance: 160)
        let preferred = preferences.double(forKey: "knarr.projectSessionWidth")
        try require(abs(preferred - 640) < 2, "mouseUp이 640pt 선호를 저장하지 않았습니다")
        try require(abs(Double(initial.bounds.width) - preferred) < 2, "mouseUp 후 실제 대화 너비가 바뀌지 않았습니다")
        try require(window.firstResponder === editor && editor.string == store.composerDraft.text, "드래그 후 입력 focus/초안이 손실됐습니다")
        try capture(host, to: out.appendingPathComponent("project-panel-resize-dragged.png"))
        window.setContentSize(NSSize(width: 720, height: 540)); settle(host)
        let narrow = Double(try transcript(host).bounds.width)
        try require(narrow <= 632 && narrow >= 360, "좁은 창에서 가용폭 clamp가 적용되지 않았습니다")
        try require(preferences.double(forKey: "knarr.projectSessionWidth") == preferred, "창 축소가 선호 너비를 덮어썼습니다")
        window.setContentSize(NSSize(width: 1720, height: 900)); settle(host)
        try require(abs(Double(try transcript(host).bounds.width) - preferred) < 2, "창을 복원해도 선호 너비가 돌아오지 않았습니다")
        let evidence = Evidence(suite: suite, processID: ProcessInfo.processInfo.processIdentifier,
            eventPath: "NSEvent → NSWindow.sendEvent → native splitter mouseDown/Dragged/Up (synthetic, not OS/CUA)",
            preferredWidth: preferred, renderedWidth: Double(try transcript(host).bounds.width),
            dragWidths: dragWidths, narrowWidth: narrow, focusPreservedDuringDrag: true)
        try JSONEncoder().encode(evidence).write(to: manifest)
        preferences.synchronize()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [out.path, "project-panel-resize-restore"]
        try child.run(); child.waitUntilExit()
        try require(child.terminationStatus == 0, "재실행 복원 subprocess 실패: \(child.terminationStatus)")
        print("네이티브 패널 drag 확인: \(initialWidth) → \(preferred)pt, streaming drag 중 폭 \(dragWidths), focus 보존")
    }
}
