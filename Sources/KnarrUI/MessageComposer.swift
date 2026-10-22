import AppKit
import SwiftUI

/// A plain native editor keeps IME composition in AppKit rather than SwiftUI submit handling.
struct MessageComposer: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onNewConversation: (() -> Void)? = nil
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data) -> Void = { _ in }
    /// The editor gained or lost keyboard focus; the composer's outline follows it.
    var onFocus: (Bool) -> Void = { _ in }
    var placeholder: String?
    var focusRequest: UUID?

    @State private var editorHeight: CGFloat = 38
    var body: some View {
        ComposerEditor(text: $text, onSubmit: onSubmit, onNewConversation: onNewConversation, onFiles: onFiles, onImage: onImage, onFocus: onFocus,
                       onHeight: { editorHeight = $0 }, focusRequest: focusRequest)
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder ?? "Stallari에게 — 질문, 작업 맡기기, 결과 확인")
                        .font(K.body).foregroundStyle(K.faint)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct ComposerEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    var onSubmit: () -> Void
    var onNewConversation: (() -> Void)? = nil
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    var onHeight: (CGFloat) -> Void = { _ in }
    var focusRequest: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = K.nsBody
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.isEditable = isEnabled
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.allowsUndo = true
        editor.setAccessibilityLabel("Stallari에게 메시지")
        editor.setAccessibilityHelp(onNewConversation == nil
            ? "Enter로 전송, Shift+Enter로 줄바꿈"
            : "Enter로 전송, Option+Enter로 새 대화, Shift+Enter로 줄바꿈")
        editor.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.onNewConversation = onNewConversation
        editor.onFiles = onFiles
        editor.onImage = onImage
        editor.onFocus = onFocus
        editor.string = text
        editor.requestFocus(focusRequest)
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.isEditable = isEnabled
        editor.onSubmit = onSubmit
        editor.onNewConversation = onNewConversation
        editor.setAccessibilityHelp(onNewConversation == nil
            ? "Enter로 전송, Shift+Enter로 줄바꿈"
            : "Enter로 전송, Option+Enter로 새 대화, Shift+Enter로 줄바꿈")
        editor.onFiles = onFiles
        editor.onImage = onImage
        editor.onFocus = onFocus
        // Never replace the attributed marked range while Korean/Japanese composition is active.
        if !editor.hasMarkedText(), editor.string != text { editor.string = text }
        context.coordinator.measure(editor)
        // Measuring schedules the height update first; keyboard focus follows the final editor layout.
        editor.requestFocus(focusRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let editor = scroll.documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = min(114, max(38, ceil(layout.usedRect(for: container).height) + 4))
        return CGSize(width: width, height: height)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            let width = editor.enclosingScrollView?.contentSize.width ?? editor.bounds.width
            guard width > 0 else { return }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let height = min(160, max(38, ceil(layout.usedRect(for: container).height) + 6))
            let callback = parent.onHeight
            DispatchQueue.main.async { callback(height) }
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onNewConversation: (() -> Void)? = nil
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    private var pendingFocusRequest: UUID?
    private var appliedFocusRequest: UUID?

    func requestFocus(_ request: UUID?) {
        guard let request, request != appliedFocusRequest else { return }
        pendingFocusRequest = request
        applyRequestedFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRequestedFocus()
    }

    /// A pending request only takes focus when nothing else has it. Once the person clicks another
    /// control, a layout pass or a recreated view must not pull the caret back to the composer.
    private func applyRequestedFocus() {
        guard window != nil, let request = pendingFocusRequest else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRequest == request, let window = self.window else { return }
            let current = window.firstResponder
            guard current == nil || current === self || current === window else {
                // Someone else owns the caret now; the request is spent, not queued for later.
                self.pendingFocusRequest = nil
                self.appliedFocusRequest = request
                return
            }
            self.enclosingScrollView?.layoutSubtreeIfNeeded()
            guard window.makeFirstResponder(self) else { return }
            self.appliedFocusRequest = request
            self.pendingFocusRequest = nil
        }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus(false) }
        return resigned
    }
    /// Images other than PNG are converted to PNG before reaching the attachment path.
    private static let convertedImageTypes: [NSPasteboard.PasteboardType] = [
        .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("public.heif"),
    ]
    /// A plain-text NSTextView enables Paste only for text and file types, so ⌘V with an
    /// image-only clipboard (screenshots, Photos) never reached paste(_:).
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable,
           NSPasteboard.general.availableType(from: [.png] + Self.convertedImageTypes) != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    override func paste(_ sender: Any?) {
        paste(from: .general)
    }
    func paste(from board: NSPasteboard) {
        guard isEditable else { return }
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            onFiles(files)
        } else if let data = board.data(forType: .png) {
            onImage(data)
        } else if let type = board.availableType(from: Self.convertedImageTypes), let data = board.data(forType: type),
                  let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            onImage(png)
        } else if let text = board.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift) {
            insertNewline(nil)
        } else if event.modifierFlags.contains(.option) {
            (onNewConversation ?? onSubmit)()
        } else {
            onSubmit()
        }
    }
}
