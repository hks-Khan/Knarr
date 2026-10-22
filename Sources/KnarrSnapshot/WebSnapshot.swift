import AppKit
import WebKit

/// Capture the real web process surface; AppKit's bitmap cache omits WKWebView layers.
@MainActor enum WebSnapshot {
    static func prepare(_ host: NSView) throws -> [(WKWebView, NSImage)] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return try walk(host).compactMap { $0 as? WKWebView }.map { web in
            let deadline = Date().addingTimeInterval(10)
            var ready = false
            while !ready && Date() < deadline {
                var replied = false
                web.evaluateJavaScript("window.knarr?.ready === true && document.querySelector('.viewport') !== null") { value, _ in
                    ready = value as? Bool == true; replied = true
                }
                while !replied && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard ready else { throw CocoaError(.coderReadCorrupt) }
            // Let the first measured virtual rows settle before taking the actual WebKit surface.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            var captured: NSImage?, failure: Error?, finished = false
            web.takeSnapshot(with: nil) { image, error in captured = image; failure = error; finished = true }
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if let failure { throw failure }
            guard let captured else { throw CocoaError(.fileReadUnknown) }
            return (web, captured)
        }
    }

    /// The part of a web surface a person can actually see and click. `cacheDisplay` leaves WebKit
    /// layers blank, so they are painted afterwards; anything drawn above them (the issue detail
    /// overlaying a narrow window, the composer) must not be painted over, or the capture shows a
    /// transcript inside a panel that covers it. Hit testing is the same z-order the person sees,
    /// so the visible trailing edge is found with it instead of assuming the whole view is exposed.
    static func visibleRect(of web: WKWebView, in host: NSView) -> NSRect {
        let frame = host.convert(web.bounds, from: web)
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let midY = frame.midY
        func exposed(_ x: CGFloat) -> Bool {
            let point = NSPoint(x: x, y: midY)
            let hitPoint = host.superview?.convert(point, from: host) ?? point
            guard let hit = host.hitTest(hitPoint) else { return false }
            var node: NSView? = hit
            while let current = node {
                if current === web { return true }
                node = current.superview
            }
            return false
        }
        guard exposed(frame.minX + 0.5) else { return .zero }
        if exposed(frame.maxX - 0.5) { return frame }
        // Binary search the uncovered width; the drawer and composer cover a contiguous trailing band.
        var low: CGFloat = 1, high: CGFloat = frame.width
        while high - low > 1 {
            let mid = (low + high) / 2
            if exposed(frame.minX + mid) { low = mid } else { high = mid }
        }
        return NSRect(x: frame.minX, y: frame.minY, width: low, height: frame.height)
    }

    /// Expands the focused conversation in place the way the page does on a click, then lets it settle.
    static func expandCanvas(_ host: NSView) throws {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        guard let web = walk(host).compactMap({ $0 as? WKWebView }).first else { throw CocoaError(.fileReadUnknown) }
        let deadline = Date().addingTimeInterval(10)
        var clicked = false
        while !clicked && Date() < deadline {
            var replied = false
            web.evaluateJavaScript("(()=>{const b=document.querySelector('.conversation-card-open');if(!b)return false;b.click();return true;})()") { value, _ in
                clicked = value as? Bool == true; replied = true
            }
            while !replied && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if !clicked { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        guard clicked else { throw CocoaError(.coderReadCorrupt) }
        var opened = false
        while !opened && Date() < deadline {
            var replied = false
            web.evaluateJavaScript("document.querySelector('.conversation-canvas') !== null") { value, _ in
                opened = value as? Bool == true; replied = true
            }
            while !replied && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if !opened { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        guard opened else { throw CocoaError(.coderReadCorrupt) }
        // The panel is docked below the transcript, outside the scroller, so it is already in view.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    static func composite(_ captures: [(WKWebView, NSImage)], host: NSView, bitmap: NSBitmapImageRep) {
        guard !captures.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        // The bitmap context already uses its logical size; applying backing scale again doubles the web surface.
        for (web, image) in captures {
            var rect = host.convert(web.bounds, from: web)
            if host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
            let visible = visibleRect(of: web, in: host)
            guard visible.width > 0, visible.height > 0 else { continue }
            // Source rect in image points: the same fraction of the surface that stays exposed.
            let scale = image.size.width / max(rect.width, 1)
            let source = NSRect(x: 0, y: 0, width: visible.width * scale, height: image.size.height)
            var target = rect
            target.size.width = visible.width
            image.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
        }
    }
}
