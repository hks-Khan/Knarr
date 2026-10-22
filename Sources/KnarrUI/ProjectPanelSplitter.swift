import AppKit
import SwiftUI

/// Only the guide moves during a drag. The transcript gets one new width on release.
struct ProjectPanelSplitter: NSViewRepresentable {
    let projectID: String
    let width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let preview: (CGFloat?) -> Void
    let commit: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProjectPanelSplitterView {
        let view = ProjectPanelSplitterView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityOrientation(.vertical)
        view.setAccessibilityLabel("프로젝트 대화 너비")
        view.setAccessibilityHelp("왼쪽으로 끌면 대화가 넓어지고 오른쪽으로 끌면 좁아집니다. 놓으면 적용됩니다. 증가·감소 동작으로도 조절할 수 있습니다.")
        return view
    }

    func updateNSView(_ view: ProjectPanelSplitterView, context: Context) {
        view.width = width; view.minimum = minimum; view.maximum = maximum
        view.preview = preview; view.commit = commit
        view.setAccessibilityIdentifier("project-session-resize-" + projectID)
        view.setAccessibilityValue(width)
        view.setAccessibilityMinValue(minimum)
        view.setAccessibilityMaxValue(maximum)
        view.needsDisplay = true
    }
}

final class ProjectPanelSplitterView: NSView {
    var width: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = 0
    var preview: (CGFloat?) -> Void = { _ in }
    var commit: (CGFloat) -> Void = { _ in }
    private var start: (x: CGFloat, width: CGFloat)?

    // Clicking the divider must not take the composer's first responder.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(K.lineStrong).setFill()
        NSRect(x: bounds.midX - K.projectResizeLineWidth / 2, y: bounds.minY,
               width: K.projectResizeLineWidth, height: bounds.height).fill()
        NSColor(K.faint).setFill()
        let grip = NSRect(x: bounds.midX - K.projectResizeGripWidth / 2,
                          y: bounds.midY - K.projectResizeGripHeight / 2,
                          width: K.projectResizeGripWidth, height: K.projectResizeGripHeight)
        NSBezierPath(roundedRect: grip, xRadius: K.projectResizeGripWidth / 2,
                     yRadius: K.projectResizeGripWidth / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        start = (event.locationInWindow.x, width)
        preview(width)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        preview(clamped(start.width + start.x - event.locationInWindow.x))
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        commit(clamped(start.width + start.x - event.locationInWindow.x))
        preview(nil)
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(by: K.projectResizeKeyboardStep) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -K.projectResizeKeyboardStep) }

    private func clamped(_ value: CGFloat) -> CGFloat { min(maximum, max(minimum, value)) }
    private func adjust(by delta: CGFloat) -> Bool {
        let next = clamped(width + delta)
        guard next != width else { return false }
        commit(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
}
