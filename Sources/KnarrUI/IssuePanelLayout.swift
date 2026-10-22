import AppKit
import SwiftUI

/// Width policy for the issue detail beside the conversation.
/// The detail stays between 380pt and 60% of the window; the conversation keeps 480pt.
enum IssuePanelLayout {
    /// Split needs the 380pt floor plus the conversation's 480pt and the splitter; anything narrower overlays.
    static func isSplit(available: CGFloat) -> Bool {
        available >= K.issuePanelMinimumWidth + K.issueConversationMinimumWidth + K.issueResizeHitWidth
    }

    /// The ceiling for the current window: 60% of the window, and never so wide that the
    /// conversation drops under its 480pt minimum.
    static func maximumWidth(available: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let byWindow = windowWidth * K.issuePanelMaximumFraction
        let byConversation = available - K.issueResizeHitWidth - K.issueConversationMinimumWidth
        return max(K.issuePanelMinimumWidth, min(byWindow, byConversation))
    }

    /// A saved width is a preference: display clamps it without overwriting what the person chose.
    static func width(available: CGFloat, windowWidth: CGFloat, preferred: Double) -> CGFloat {
        let resolved = preferred.isFinite && preferred > 0 ? CGFloat(preferred) : K.issuePanelDefaultWidth
        let maximum = maximumWidth(available: available, windowWidth: windowWidth)
        return min(maximum, max(K.issuePanelMinimumWidth, resolved))
    }
}

/// Only the guide moves during a drag. The conversation gets its new width on release.
struct IssuePanelSplitter: NSViewRepresentable {
    let width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let reset: CGFloat
    let preview: (CGFloat?) -> Void
    let commit: (CGFloat) -> Void

    func makeNSView(context: Context) -> IssuePanelSplitterView {
        let view = IssuePanelSplitterView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityOrientation(.vertical)
        view.setAccessibilityLabel("이슈 상세 너비")
        view.setAccessibilityHelp("왼쪽으로 끌면 이슈 상세가 넓어지고 오른쪽으로 끌면 좁아집니다. 놓으면 적용됩니다. 더블클릭하면 기본 너비로 돌아갑니다.")
        view.setAccessibilityIdentifier("issue-panel-resize")
        return view
    }

    func updateNSView(_ view: IssuePanelSplitterView, context: Context) {
        view.width = width; view.minimum = minimum; view.maximum = maximum; view.resetWidth = reset
        view.preview = preview; view.commit = commit
        view.setAccessibilityValue(width)
        view.setAccessibilityMinValue(minimum)
        view.setAccessibilityMaxValue(maximum)
        view.needsDisplay = true
    }
}

final class IssuePanelSplitterView: NSView {
    var width: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = 0
    var resetWidth: CGFloat = 0
    var preview: (CGFloat?) -> Void = { _ in }
    var commit: (CGFloat) -> Void = { _ in }
    private var start: (x: CGFloat, width: CGFloat)?

    // Clicking the divider must not take the composer's first responder.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(K.lineStrong).setFill()
        NSRect(x: bounds.midX - K.issueResizeLineWidth / 2, y: bounds.minY,
               width: K.issueResizeLineWidth, height: bounds.height).fill()
        NSColor(K.faint).setFill()
        let grip = NSRect(x: bounds.midX - K.issueResizeGripWidth / 2,
                          y: bounds.midY - K.issueResizeGripHeight / 2,
                          width: K.issueResizeGripWidth, height: K.issueResizeGripHeight)
        NSBezierPath(roundedRect: grip, xRadius: K.issueResizeGripWidth / 2,
                     yRadius: K.issueResizeGripWidth / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            start = nil
            commit(clamped(resetWidth))
            return
        }
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
    override func accessibilityPerformIncrement() -> Bool { adjust(by: K.issueResizeKeyboardStep) }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -K.issueResizeKeyboardStep) }

    private func clamped(_ value: CGFloat) -> CGFloat { min(maximum, max(minimum, value)) }
    private func adjust(by delta: CGFloat) -> Bool {
        let next = clamped(width + delta)
        guard next != width else { return false }
        commit(next)
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }
}
