import AppKit
import SwiftUI
import Testing
@testable import KnarrCore
@testable import KnarrUI

/// The tab bar's working mark animates only while its thread is working, keeps a still dot under
/// Reduce Motion, and exposes "작업 중" to assistive technology.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct ThreadBarActivityUITests {
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
    private func label(_ root: NSObject, id: String) throws -> String {
        let node = try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing tab: \(id)")
        return try #require(value(node, "accessibilityLabel") as? String)
    }
    private func pulsingLayers(_ layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        let own = layer.animationKeys()?.contains("ring") == true ? [layer] : []
        return own + (layer.sublayers ?? []).flatMap(pulsingLayers)
    }
    /// The tab's own frame, in window coordinates, so a working mark may never resize or move it.
    private func frame(_ root: NSObject, id: String) throws -> NSRect {
        let node = try #require(elements(root).first { value($0, "accessibilityIdentifier") as? String == id }, "Missing tab: \(id)")
        return try #require(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    /// The halo's own color, sRGB hex, read from the layer the render server animates.
    private func haloHex(_ layer: CALayer) -> String {
        let color = layer.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    /// Runs the render loop until `settled` holds; returns whether it did before the deadline.
    private func settle(_ deadline: TimeInterval = 3, _ settled: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while !settled(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return settled()
    }
    /// Reads a tab's frame only after two consecutive layout passes agree, so a baseline is never
    /// taken mid-reflow (selection changes the title weight).
    private func stableFrame(_ root: NSObject, id: String) throws -> NSRect {
        var previous = try frame(root, id: id)
        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let next = try frame(root, id: id)
            if next == previous { return next }
            previous = next
        }
        throw CancellationError()
    }

    /// Hosts a view in an offscreen window for layout and drawing without taking focus.
    private func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let window = TestWindow.make(size: size, styleMask: [.borderless])
        window.contentView = host
        TestWindow.present(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        return (window, host)
    }

    @Test func unselectedWorkingTabPulsesAndIdleTabDoesNot() throws {
        let store = SampleKnarrStore(issueSessionScene: .tabs)
        #expect(store.selectedThreadID == ConversationThread.defaultID)
        #expect(store.isThreadWorking("issue-npc-repeat"))
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }

        #expect(try label(host, id: "thread-issue-npc-repeat").contains("작업 중"))
        #expect(try label(host, id: "thread-default").contains("작업 중") == false)

        let animated = try #require(pulsingLayers(host.layer).first, "No halo layer on the working tab")
        let start = try #require(animated.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let later = try #require(animated.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat)
        #expect(start != later, "Halo did not advance: \(start) → \(later)")
    }

    @Test func finishingWorkRemovesTheHaloImmediately() throws {
        // The plain sample binds its running issue to the main thread; this scene's only issue
        // stays a saved proposal, so the main thread starts idle.
        let store = SampleKnarrStore(issueSessionScene: .approval)
        store.isResponding = true
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }
        let id = "thread-" + ConversationThread.defaultID
        #expect(try label(host, id: id).contains("작업 중"))
        #expect(!pulsingLayers(host.layer).isEmpty)

        store.isResponding = false
        let clearedAt = Date()
        // Stage 1: the judgment itself flips synchronously, before any render pass.
        #expect(!store.isThreadWorking(ConversationThread.defaultID), "Store kept reporting work after the response finished")
        // Stage 2: the render pass, then stage 3: the layer tree it leaves behind.
        #expect(settle { (try? self.label(host, id: id))?.contains("작업 중") == false },
                "Working label stayed after the response finished")
        let labelCleared = Date().timeIntervalSince(clearedAt)
        #expect(settle { self.pulsingLayers(host.layer).isEmpty }, "Halo layer stayed after the response finished")
        let haloCleared = Date().timeIntervalSince(clearedAt)
        // A finished response must not leave the mark up for a later timer or animation cycle.
        #expect(labelCleared < 1, "Working label took \(labelCleared)s to clear")
        #expect(haloCleared < 1, "Halo took \(haloCleared)s to clear")
    }

    /// The gap mark on a selected main tab must never move or resize the tab or its neighbours.
    @Test func gapMarkKeepsTabLayoutOnSelectedMain() throws {
        let store = SampleKnarrStore(issueSessionScene: .approval)
        let issueTab = "thread-issue-session-proposal"
        let mainTab = "thread-" + ConversationThread.defaultID
        // Opening the issue tab adds it; the saved proposal itself is idle.
        store.goToThread(for: "session-proposal")
        store.selectThread(ConversationThread.defaultID)
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }
        #expect(try label(host, id: mainTab).contains("작업 중") == false)
        let idleMain = try stableFrame(host, id: mainTab)
        let idleIssue = try stableFrame(host, id: issueTab)

        store.isResponding = true
        #expect(settle { (try? self.label(host, id: mainTab))?.contains("작업 중") == true })
        #expect(pulsingLayers(host.layer).count == 1)
        #expect(try stableFrame(host, id: mainTab) == idleMain, "The gap mark moved or resized the tab")
        #expect(try stableFrame(host, id: issueTab) == idleIssue, "An idle tab moved while another tab worked")

        store.isResponding = false
        #expect(settle { self.pulsingLayers(host.layer).isEmpty })
        #expect(try stableFrame(host, id: mainTab) == idleMain, "Removing the gap mark moved or resized the tab")
    }

    /// The dot slot on a selected issue tab keeps its size and position while it pulses.
    @Test func dotSlotKeepsTabLayoutOnSelectedIssue() throws {
        let store = SampleKnarrStore(issueSessionScene: .approval)
        let issueTab = "thread-issue-session-proposal"
        let mainTab = "thread-" + ConversationThread.defaultID
        // Selection is fixed before hosting, so no reflow lands inside the measured window.
        store.goToThread(for: "session-proposal")
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }
        let idleIssue = try stableFrame(host, id: issueTab)
        let idleMain = try stableFrame(host, id: mainTab)

        store.isResponding = true
        #expect(settle { (try? self.label(host, id: issueTab))?.contains("작업 중") == true })
        #expect(pulsingLayers(host.layer).count == 1)
        #expect(try stableFrame(host, id: issueTab) == idleIssue, "The dot slot moved or resized the tab")
        #expect(try stableFrame(host, id: mainTab) == idleMain, "An idle tab moved while another tab worked")

        store.isResponding = false
        #expect(settle { self.pulsingLayers(host.layer).isEmpty })
        #expect(try stableFrame(host, id: issueTab) == idleIssue, "Removing the mark moved or resized the tab")
    }

    /// A question waiting on the person outranks running work, so its halo takes the amber token.
    @Test func questionWaitingTabUsesTheAmberToken() throws {
        let store = SampleKnarrStore(issueSessionScene: .question)
        store.goToThread(for: "testflight")
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }
        #expect(try label(host, id: "thread-issue-testflight").contains("작업 중"))
        let halo = try #require(pulsingLayers(host.layer).first, "No halo on the waiting tab")
        var amber = ""
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            let color = K.nsAmber.usingColorSpace(.sRGB) ?? .black
            amber = String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                           Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        #expect(haloHex(halo) == amber, "Waiting tab halo \(haloHex(halo)) is not the amber token \(amber)")
    }

    /// `accessibilityReduceMotion` is read-only, so the mark itself takes the flag directly.
    @Test func reduceMotionKeepsAStillActiveDot() throws {
        let (window, host) = host(ActivityDot(tint: .amber, reduceMotion: true).frame(width: 20, height: 20),
                                  size: NSSize(width: 40, height: 40))
        defer { window.contentView = nil; window.close() }
        #expect(pulsingLayers(host.layer).isEmpty, "Reduce Motion must not loop an animation")
    }

    @Test func activeDotPulsesWithoutReduceMotion() throws {
        let (window, host) = host(ActivityDot(tint: .accent, reduceMotion: false).frame(width: 20, height: 20),
                                  size: NSSize(width: 40, height: 40))
        defer { window.contentView = nil; window.close() }
        #expect(!pulsingLayers(host.layer).isEmpty, "The working mark drew no halo")
    }

    /// Two sampled frames of the halo. `cacheDisplay` renders model layers only, so the loop is read
    /// from the presentation layer the render server actually shows.
    @Test func haloAdvancesAcrossTwoFrames() throws {
        let store = SampleKnarrStore(issueSessionScene: .tabs)
        let (window, host) = host(ThreadBar(store: store).frame(width: 900, height: 60),
                                  size: NSSize(width: 900, height: 60))
        defer { window.contentView = nil; window.close() }
        let animated = try #require(pulsingLayers(host.layer).first, "No halo layer on the working tab")
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("outputs/evidence/thread-working", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func sample() -> (scale: CGFloat, opacity: CGFloat) {
            let layer = animated.presentation() ?? animated
            let scale = layer.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 0
            let opacity = CGFloat(layer.opacity)
            return (scale, opacity)
        }
        let first = sample()
        writeFrame(host, to: directory.appendingPathComponent("frame-a.png"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        let second = sample()
        writeFrame(host, to: directory.appendingPathComponent("frame-b.png"))
        #expect(first.scale != second.scale || first.opacity != second.opacity,
                "Halo did not advance: \(first) → \(second)")
    }

    private func writeFrame(_ host: NSView, to url: URL) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
