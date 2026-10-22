import AppKit
import Foundation
@testable import KnarrUI

/// Window and UI tests are opt-in. They host real AppKit windows and WebKit views, so the default
/// `swift test` must not create or show them.
enum KnarrUITests {
    /// Set `KNARR_UI_TESTS=1` to run tests that create windows, WebKit views or accessibility trees.
    static var enabled: Bool { ProcessInfo.processInfo.environment["KNARR_UI_TESTS"] == "1" }
}

/// Test windows live outside every screen, never become key or main, and never activate the app.
/// A window still needs `orderFront` to lay out and drive WebKit, so tests call `present` instead of
/// `makeKeyAndOrderFront`.
@MainActor enum TestWindow {
    static let offscreenOrigin = NSPoint(x: -20000, y: -20000)

    /// The test process is normally already `.prohibited`; a host app may be regular. Accessibility
    /// is switched on here, once, because SwiftUI only builds the AX tree tests read with it enabled.
    static func prepare() {
        _ = NSApplication.shared
        if NSApp.activationPolicy() != .prohibited { _ = NSApp.setActivationPolicy(.prohibited) }
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        if NSApp.accessibilityAttributeValue(attribute) as? Bool != true {
            NSApp.accessibilitySetValue(true, forAttribute: attribute)
        }
        // Windows the UI opens itself (small conversations) use the same presenter.
        MessageConversationWindows.present = present
        MessageConversationWindows.testPresentation = true
    }

    static func make(size: NSSize, styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable],
                     dark: Bool = false, deferred: Bool = false) -> NSWindow {
        prepare()
        let window = Window(contentRect: NSRect(origin: offscreenOrigin, size: size),
                            styleMask: styleMask, backing: .buffered, defer: deferred)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return window
    }

    /// Shows a window for layout without giving it the person's screen or keyboard focus.
    static func present(_ window: NSWindow) {
        prepare()
        if window.frame.origin != offscreenOrigin { window.setFrameOrigin(offscreenOrigin) }
        window.orderFront(nil)
    }

    /// An `NSWindow` that refuses key/main status, so `makeKeyAndOrderFront` cannot take focus
    /// even when a view or manager asks for it. Modal flows inside it are not used by these tests.
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func makeKey() {}
        override func makeKeyAndOrderFront(_ sender: Any?) { orderFront(sender) }
        /// AppKit pulls a new window back onto a screen; these windows must stay offscreen.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
}
