import AppKit
import ImageIO
import Testing
@testable import KnarrUI

@MainActor struct MessageComposerTests {
    /// The main composer must clear the moment a send starts, say it is sending, and ignore repeat presses.
    @Test(.enabled(if: KnarrUITests.enabled)) func pressingEnterWhileSendingClearsInputShowsStatusAndSendsOnce() async throws {
        let store = ChangingCardsStore()
        let gate = SubmitGate()
        store.whileSubmitting = { await gate.wait() }
        let h = HomeHarness(width: 1200, height: 800, store: store)
        defer { h.close() }
        TestWindow.present(h.window)
        h.settle()
        let editor = try #require(h.composer)
        editor.insertText("한 번만 보낼 초안", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle()
        editor.keyDown(with: try enter())
        for _ in 0..<100 {
            if gate.entered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gate.entered)
        #expect(editor.string.isEmpty, "보내기를 누르면 전송이 끝나기 전에 입력창이 비워져야 해요")
        #expect(accessibilityTexts(try #require(h.window.contentView)).contains("보내는 중"), "보내는 동안 보내는 중 상태가 보여야 해요")
        // Pressing again while the first send is still in flight must not send a second copy.
        editor.keyDown(with: try enter())
        editor.keyDown(with: try enter())
        for _ in 0..<20 { await Task.yield() }
        #expect(store.submittedDrafts.isEmpty, "보내는 중에는 다시 보내지고 저장되지 않아야 해요")
        gate.open()
        for _ in 0..<100 {
            if !store.submittedDrafts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.submittedDrafts.map(\.text) == ["한 번만 보낼 초안"])
        #expect(editor.string.isEmpty)
    }

    /// Holds one send open so a test can watch the composer while the message is still in flight.
    @MainActor final class SubmitGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func attribute(_ node: NSObject, _ selector: String) -> Any? {
        let action = NSSelectorFromString(selector)
        if node.responds(to: action), let result = node.perform(action)?.takeUnretainedValue() { return result }
        let name = ["accessibilityChildren": "AXChildren", "accessibilityLabel": "AXDescription",
                    "accessibilityIdentifier": "AXIdentifier", "accessibilityValue": "AXValue"][selector]
        return name.flatMap { node.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: $0)) }
    }
    private func elements(_ node: NSObject) -> [NSObject] {
        [node] + ((attribute(node, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(elements)
    }
    /// Every text the screen announces: labels, identifiers and values of SwiftUI's accessibility nodes.
    private func accessibilityTexts(_ host: NSView) -> [String] {
        _ = descendants(host)
        return elements(host).flatMap { node in
            ["accessibilityLabel", "accessibilityIdentifier"].compactMap { attribute(node, $0) as? String }
                + [attribute(node, "accessibilityValue") as? String].compactMap { $0 }
        }
    }

    private func enter(_ modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 36) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
    }

    @Test func enterSubmitsAndShiftEnterKeepsMultilineText() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        var submitted: [String] = []
        editor.onSubmit = { submitted.append(editor.string) }
        editor.insertText("첫 줄", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try enter(.shift))
        editor.insertText("둘째 줄", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(submitted.isEmpty)
        #expect(editor.string == "첫 줄\n둘째 줄")
        editor.keyDown(with: try enter())
        #expect(submitted == ["첫 줄\n둘째 줄"])
        #expect(editor.string == "첫 줄\n둘째 줄")
    }

    @Test func markedKoreanEnterDoesNotSubmit() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: try enter())
        #expect(submissions == 0)
        editor.unmarkText()
        editor.keyDown(with: try enter())
        #expect(submissions == 1)
    }

    @Test func optionReturnStartsConversationAndShiftStillInsertsNewline() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        editor.string = "새 대화"
        var submitted = 0
        var conversations: [String] = []
        editor.onSubmit = { submitted += 1 }
        editor.onNewConversation = { conversations.append(editor.string) }
        editor.keyDown(with: try enter(.option))
        editor.keyDown(with: try enter(.option, keyCode: 76))
        #expect(conversations == ["새 대화", "새 대화"])
        #expect(submitted == 0)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: try enter([.option, .shift]))
        #expect(editor.string == "새 대화\n")
        #expect(conversations.count == 2)
    }

    @Test func optionReturnInWindowComposerFallsBackToOrdinarySubmit() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.keyDown(with: try enter(.option))
        editor.keyDown(with: try enter(.option, keyCode: 76))
        #expect(submissions == 2)
    }

    @Test func markedKoreanOptionReturnNeverStartsConversationOrSubmits() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        var submissions = 0
        var conversations = 0
        editor.onSubmit = { submissions += 1 }
        editor.onNewConversation = { conversations += 1 }
        for keyCode in [UInt16(36), UInt16(76)] {
            editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.hasMarkedText())
            editor.keyDown(with: try enter(.option, keyCode: keyCode))
        }
        #expect(submissions == 0)
        #expect(conversations == 0)
        editor.unmarkText()
        editor.keyDown(with: try enter(.option))
        #expect(conversations == 1)
    }

    @Test func disabledEditorRejectsSubmissionConversationAndAttachmentPasteButKeepsSelection() throws {
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.string = "읽기 전용"
        editor.isEditable = false
        var actions = 0
        editor.onSubmit = { actions += 1 }
        editor.onNewConversation = { actions += 1 }
        editor.onFiles = { _ in actions += 1 }
        editor.onImage = { _ in actions += 1 }
        editor.keyDown(with: try enter())
        editor.keyDown(with: try enter(.option))
        editor.keyDown(with: try enter(.shift))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data([137, 80, 78, 71]), forType: .png)
        editor.paste(from: board)
        #expect(actions == 0)
        #expect(editor.string == "읽기 전용")
        #expect(editor.isSelectable)
    }
    @Test func pasteRoutesImagesAndFilesWithoutReplacingText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.string = "기존 내용"
        var image: Data?
        var files: [URL] = []
        editor.onImage = { image = $0 }
        editor.onFiles = { files = $0 }
        let png = Data([137, 80, 78, 71])
        board.setData(png, forType: .png)
        editor.paste(from: board)
        #expect(image == png)
        #expect(editor.string == "기존 내용")
        board.clearContents()
        let file = URL(fileURLWithPath: "/tmp/knarr-paste-fixture.txt")
        board.writeObjects([file as NSURL])
        editor.paste(from: board)
        #expect(files == [file])
        #expect(editor.string == "기존 내용")
        board.clearContents()
        board.setString("첫 줄\n둘째 줄", forType: .string)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.paste(from: board)
        #expect(editor.string == "첫 줄\n둘째 줄")
    }

    /// AppKit validates and performs Paste against the general pasteboard. Point it at a private board
    /// so the real Edit menu path runs without reading or changing the user's clipboard.
    private func withGeneralPasteboard(_ board: NSPasteboard, _ body: () throws -> Void) throws {
        let method = try #require(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general)))
        let original = method_getImplementation(method)
        let replacement: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        defer { method_setImplementation(method, original) }
        try body()
    }

    /// ⌘V through an Edit menu like SwiftUI's: paste: auto-enabled by validateMenuItem, then sent on key equivalent.
    /// The test app never becomes active, so the item targets the window's first responder that nil-targeting resolves to.
    /// Returns whether AppKit enabled Paste; the callbacks show what the press did.
    @discardableResult
    private func pressCommandV(in window: NSWindow) -> Bool {
        let menu = NSMenu(title: "Edit")
        let item = menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item.target = window.firstResponder
        menu.update()
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else {
            Issue.record("⌘V event unavailable")
            return false
        }
        let enabled = item.isEnabled
        _ = menu.performKeyEquivalent(with: event)
        return enabled
    }

    private func hostWindow(with editor: ComposerTextView) -> NSWindow {
        let window = TestWindow.make(size: NSSize(width: 400, height: 100), styleMask: [.titled], deferred: true)
        window.contentView = editor
        window.makeFirstResponder(editor)
        #expect(window.firstResponder === editor)
        return window
    }

    private func image(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: type, properties: [:]))
    }

    private func heic() throws -> Data {
        let cg = try #require(NSBitmapImageRep(data: try image(.png))?.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test(.enabled(if: KnarrUITests.enabled)) func commandVAttachesImageOnlyClipboardsThroughEditMenu() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.string = "기존 내용"
        let window = hostWindow(with: editor)
        defer { window.close() }
        var images: [Data] = []
        var files: [URL] = []
        editor.onImage = { images.append($0) }
        editor.onFiles = { files = $0 }
        let screenshot = try image(.png)
        let samples: [(NSPasteboard.PasteboardType, Data)] = [
            (.png, screenshot), (.tiff, try image(.tiff)),
            (NSPasteboard.PasteboardType("public.jpeg"), try image(.jpeg)),
            (NSPasteboard.PasteboardType("public.heic"), try heic()),
        ]
        try withGeneralPasteboard(board) {
            for (type, data) in samples {
                board.clearContents()
                board.setData(data, forType: type)
                #expect(pressCommandV(in: window), "Paste disabled for \(type.rawValue)")
            }
            #expect(images.count == samples.count)
            #expect(images.first == screenshot)
            #expect(images.dropFirst().allSatisfy { NSBitmapImageRep(data: $0) != nil && $0.starts(with: [137, 80, 78, 71]) })
            #expect(editor.string == "기존 내용")

            board.clearContents()
            let file = URL(fileURLWithPath: "/tmp/knarr-paste-fixture.txt")
            board.writeObjects([file as NSURL])
            #expect(pressCommandV(in: window))
            #expect(files == [file])

            board.clearContents()
            board.setString("붙여넣은 글", forType: .string)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            #expect(pressCommandV(in: window))
            #expect(editor.string == "기존 내용붙여넣은 글")

            board.clearContents()
            #expect(pressCommandV(in: window) == false)
            #expect(images.count == samples.count)
        }
    }
}
