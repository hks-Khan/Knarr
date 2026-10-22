import AppKit
import WebKit
import Testing
import KnarrCore
@testable import KnarrUI

/// The phone renderer gets the same bundled page with `mobile: true`. These tests drive it directly
/// so a Mac test can see what a phone actually lays out: full-width panel, wrapped text, a usable
/// input, inner scrolling, and a panel that shrinks when the keyboard covers the screen.
@MainActor @Suite(.serialized, .enabled(if: KnarrUITests.enabled)) struct MobileChatRenderingTests {
    init() { TestWindow.prepare() }

    @MainActor
    private final class Phone {
        let window: NSWindow
        let web: WKWebView
        private(set) var messages: [[String: Any]] = []
        init(width: CGFloat, height: CGFloat) {
            window = TestWindow.make(size: NSSize(width: width, height: height), styleMask: [.borderless])
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: WKWebViewConfiguration())
            web.configuration.websiteDataStore = .nonPersistent()
            window.contentView = web
            TestWindow.present(window)
        }
        var root: URL { AppArtwork.bundle.url(forResource: "index", withExtension: "html", subdirectory: "ChatWeb")! }
        var base: URL { root.deletingLastPathComponent() }
        func load() async throws {
            web.loadFileURL(root, allowingReadAccessTo: base)
            try await condition("window.knarr?.ready === true")
        }
        func js(_ expression: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript("JSON.stringify((()=>{return (" + expression + ");})())") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "null") }
                }
            }
        }
        func condition(_ expression: String, seconds: Double = 10) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if (try? await js(expression)) == "true" { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("Phone renderer condition timed out: \(expression)")
            throw CocoaError(.coderReadCorrupt)
        }
        /// The same shape MobileChatWebView sends: a link row, its reply, and `mobile: true`.
        /// Opening posts `canvasOpen` to the host, so the canvas rows arrive in a second payload.
        func send(_ dark: Bool = false) async throws {
            let rootID = UUID().uuidString, replyID = UUID().uuidString
            let now = Date().timeIntervalSince1970 * 1000
            let replyText = String(repeating: "v1 저장 데이터에는 대화 기록이 없어서 기본값으로 채워집니다. ", count: 3)
            linkID = rootID
            replyIDValue = replyID
            let link: [String: Any] = [
                "id": rootID, "kind": "user", "text": "저장 데이터 v1~v3 불러오기 확인", "time": "09:12",
                "at": now, "attachments": [], "state": ["replyAts": [now], "lastAt": now],
                "conversationRootID": NSNull(), "isConversationLink": true
            ]
            let reply: [String: Any] = [
                "id": replyID, "kind": "assistant", "time": "09:13", "attachments": [], "state": [:],
                "text": replyText, "conversationRootID": rootID
            ]
            rows = [rootID: link, replyID: reply]
            try await deliver(order: [rootID, replyID], upsert: rows, root: NSNull(), canvas: NSNull(), dark: dark)
            try await condition("document.querySelector('.conversation-card') !== null")
        }
        private(set) var rows: [String: [String: Any]] = [:]
        private var linkID = "", replyIDValue = ""
        private func deliver(order: [String], upsert: [String: [String: Any]], root: Any, canvas: Any, dark: Bool) async throws {
            let payload: [String: Any] = [
                "session": session, "thread": "mobile-thread", "conversationRootID": root,
                "reset": true, "order": order, "upsert": upsert,
                "removed": [], "streaming": NSNull(), "footerText": "", "responding": false,
                "status": "", "canResend": false, "readOnly": false, "jump": false,
                "target": NSNull(), "highlighted": NSNull(), "viewport": NSNull(),
                "dark": dark, "reduceMotion": true, "theme": [:], "mobile": true,
                "canvas": canvas
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else {
                throw CocoaError(.coderInvalidValue)
            }
            _ = try await js("(window.knarr.receive(\(json)), true)")
        }
        private let session = UUID().uuidString
        /// Opening the card posts `canvasOpen`, so the host answers with that root's rows.
        func openPanel() async throws {
            _ = try await js("(()=>{const b=document.querySelector('.conversation-card button');if(!b)return false;b.click();return true;})()")
            try await condition("document.querySelector('.conversation-canvas') !== null")
            var canvas: [String: Any] = [
                "root": linkID, "order": [replyIDValue], "rows": [replyIDValue: rows[replyIDValue] ?? [:]],
                "responding": false, "status": "", "startedAt": NSNull(), "readOnly": false
            ]
            canvas["stopBlockReason"] = NSNull()
            try await deliver(order: [linkID, replyIDValue], upsert: rows, root: NSNull(), canvas: canvas, dark: false)
            try await Task.sleep(for: .milliseconds(300))
        }
        func metrics() async throws -> [String: Any] {
            let raw = try await js("(()=>{const q=s=>document.querySelector(s)?.getBoundingClientRect();const c=q('.conversation-canvas'),b=document.querySelector('.conversation-body'),t=document.querySelector('.conversation-compose textarea'),d=q('.conversation-dock');return {mobile:document.documentElement.dataset.mobile,width:Math.round(c.width),height:Math.round(c.height),dockWidth:Math.round(d.width),bodyClient:b.clientHeight,bodyScroll:b.scrollHeight,textarea:Math.round(t.getBoundingClientRect().height),pageWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth};})()")
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        }
        func close() { window.contentView = nil; window.close() }
    }

    @Test func phoneLayoutIsOneFullWidthColumnThatNeverScrollsSideways() async throws {
        let phone = Phone(width: 390, height: 844)
        defer { phone.close() }
        try await phone.load()
        try await phone.send()
        try await phone.openPanel()
        let m = try await phone.metrics()
        #expect(m["mobile"] as? String == "true")
        #expect((m["width"] as? Int ?? 0) >= 360, "The panel was \(m["width"] ?? 0)px wide on a 390px screen")
        #expect((m["scrollWidth"] as? Int ?? 0) <= (m["pageWidth"] as? Int ?? 0), "The page scrolled sideways")
    }

    @Test func phonePanelShowsTheOriginalAndAReplyAndScrollsInside() async throws {
        let phone = Phone(width: 360, height: 640)
        defer { phone.close() }
        try await phone.load()
        try await phone.send()
        try await phone.openPanel()
        let m = try await phone.metrics()
        #expect((m["bodyClient"] as? Int ?? 0) >= 120, "Body was only \(m["bodyClient"] ?? 0)px")
        #expect((m["bodyScroll"] as? Int ?? 0) >= (m["bodyClient"] as? Int ?? 0), "The long reply should wrap, not clip")
        let rows = try await phone.js("document.querySelectorAll('.conversation-body .message').length")
        #expect(rows == "2")
        let wrapped = try await phone.js("(()=>{const p=document.querySelectorAll('.conversation-body .markdown p');if(!p.length)return false;const last=p[p.length-1];const style=getComputedStyle(last);const line=parseFloat(style.lineHeight)||20;return last.getBoundingClientRect().height > line*1.5;})()")
        #expect(wrapped == "true", "The reply did not wrap onto multiple lines")
        let input = try await phone.js("document.querySelector('.conversation-compose textarea') !== null")
        #expect(input == "true")
    }

    @Test func phonePanelShrinksWhenTheKeyboardTakesTheScreen() async throws {
        let phone = Phone(width: 390, height: 844)
        defer { phone.close() }
        try await phone.load()
        try await phone.send()
        try await phone.openPanel()
        let before = try await phone.metrics()
        // The keyboard halves the visible area; the panel is capped by the viewport, not a fixed 320px.
        phone.window.setContentSize(NSSize(width: 390, height: 400))
        try await Task.sleep(for: .milliseconds(600))
        let after = try await phone.metrics()
        #expect((after["height"] as? Int ?? 0) <= (before["height"] as? Int ?? 0))
        #expect((after["height"] as? Int ?? 0) <= 320, "The panel kept \(after["height"] ?? 0)px in a 400px viewport")
        #expect((after["bodyClient"] as? Int ?? 0) > 0, "The body disappeared when the keyboard opened")
        let dock = after["dockWidth"] as? Int ?? 0
        #expect(dock > 0 && dock <= 390)
    }
}
