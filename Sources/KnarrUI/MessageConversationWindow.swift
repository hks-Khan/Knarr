import AppKit
import SwiftUI
import Observation
import QuickLook
import KnarrCore

private struct OpenMessageConversationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}
extension EnvironmentValues {
    var openMessageConversation: (@MainActor (UUID) -> Void)? {
        get { self[OpenMessageConversationKey.self] }
        set { self[OpenMessageConversationKey.self] = newValue }
    }
}

/// Attachment intake is shared with the main composer, including file drops and image paste.
enum ComposerAttachments {
    static func adding(_ files: [URL], to existing: [URL]) -> [URL] {
        var result = existing
        for file in files where file.isFileURL && !result.contains(file) { result.append(file) }
        return result
    }
    static func saveImage(_ data: Data, rulesPath: String?) throws -> URL {
        let base = rulesPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Knarr-clipboard")
        let folder = base.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("스크린샷-" + UUID().uuidString + ".png")
        try data.write(to: file, options: .atomic)
        return file
    }
}

@MainActor @Observable final class MessageConversationDraft {
    let rootID: UUID
    let threadID: String
    var draft: ChatDraft { didSet { reportBusy() } }
    var error: String?
    private(set) var sending = false { didSet { reportBusy() } }
    @ObservationIgnored private let busyChanged: (Bool) -> Void
    @ObservationIgnored private var isClosed = false
    private func reportBusy() { busyChanged(sending || (!isClosed && !draft.isEmpty)) }
    func windowClosed() { isClosed = true; draft = ChatDraft(conversationRootID: rootID) }
    init(rootID: UUID, threadID: String, busyChanged: @escaping (Bool) -> Void = { _ in }) {
        self.busyChanged = busyChanged
        self.rootID = rootID; self.threadID = threadID
        draft = ChatDraft(conversationRootID: rootID)
    }
    func isAvailable(_ store: any KnarrStore) -> Bool {
        store.selectedThreadID == threadID && store.chat.contains { $0.id == rootID && $0.isConversationLink }
    }
    func add(_ files: [URL]) { draft.attachments = ComposerAttachments.adding(files, to: draft.attachments) }
    func paste(_ data: Data, store: any KnarrStore) {
        do { add([try ComposerAttachments.saveImage(data, rulesPath: store.responseRulesPath)]) }
        catch { self.error = "붙여넣은 이미지를 저장하지 못했어요. 다시 시도해 주세요." }
    }
    func restore(_ saved: ChatDraft) {
        guard draft.isEmpty || draft == saved else { error = "작성 중인 내용이 있어요. 보낸 뒤 다시 불러와 주세요."; return }
        draft = saved; draft.conversationRootID = rootID; error = nil
    }
    /// Short status copy for the composer: sending now, or waiting behind the running response.
    /// A focused send is admitted only after the current answer finishes, so the wait must be visible.
    func statusText(_ store: any KnarrStore) -> String? {
        guard sending else { return nil }
        return store.isResponding || store.isSubmitting ? "보내는 중 · 답이 끝나면 보내요" : "보내는 중"
    }
    func submit(_ store: any KnarrStore) async {
        guard isAvailable(store), !ChatWebBridge.isReadOnly(store), !draft.isEmpty, !sending else { return }
        if store.isStopping {
            error = "응답을 중지하는 중이에요. 끝난 뒤에 보내 주세요."
            return
        }
        let sent = draft
        sending = true; error = nil
        // Clear the input now: a send that is waiting behind a response must not leave the same
        // text in place, where another press looks like the only way to make anything happen.
        draft = ChatDraft(conversationRootID: rootID)
        defer { sending = false }
        do {
            try await store.submit(sent)
        } catch {
            guard !isClosed else { return }
            // A read-only conversation refuses the send outright; restoring the text would invite
            // another press that cannot work either.
            guard !ChatWebBridge.isReadOnly(store) else {
                self.error = "닫힌 이슈의 대화는 읽기 전용이에요"
                return
            }
            // Keep the unsent text and attachments for a retry without discarding edits typed meanwhile.
            draft.text = draft.text.isEmpty ? sent.text : draft.text
            for url in sent.attachments.reversed() where !draft.attachments.contains(url) { draft.attachments.insert(url, at: 0) }
            self.error = (error as? ChatAttachmentError)?.localizedDescription
                ?? "전송하지 못했어요. 작성한 내용은 그대로 보관돼 있어요."
        }
    }
}

private final class MessageConversationWindow: NSWindow {
    /// Tests keep these windows offscreen and non-key so a run cannot take the person's screen or
    /// keyboard focus. Production leaves it false and keeps its normal title-bar behavior.
    static var testPresentation = false
    override var canBecomeKey: Bool { !Self.testPresentation && super.canBecomeKey }
    override var canBecomeMain: Bool { !Self.testPresentation && super.canBecomeMain }
    /// AppKit pulls a shown window back onto a screen; tests need it to stay where they put it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.testPresentation ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class MessageConversationWindows: NSObject, NSWindowDelegate {
    /// How a conversation window reaches the screen. Production makes it key; tests replace this
    /// with the offscreen, non-key presenter so a test run cannot take the person's focus.
    static var present: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    /// Tests also keep the windows themselves offscreen and non-key. Production never sets this.
    static var testPresentation: Bool {
        get { MessageConversationWindow.testPresentation }
        set { MessageConversationWindow.testPresentation = newValue }
    }
    private let preferences: UserDefaults
    private var windows: [UUID: NSWindow] = [:]
    private var models: [UUID: MessageConversationDraft] = [:]
    private weak var mainWindow: NSWindow?
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    func window(for root: UUID) -> NSWindow? { windows[root] }
    private func key(_ root: UUID) -> String { "knarr.message-conversation.frame." + root.uuidString }
    func open(_ root: UUID, store: any KnarrStore, revealIssue: @escaping (KnarrCore.Issue.ID) -> Void = { _ in }) {
        guard let source = store.chat.first(where: { $0.id == root && $0.isConversationLink }) else { return }
        if let window = windows[root] { Self.present(window); return }
        if let key = NSApp.keyWindow, !(key is MessageConversationWindow) { mainWindow = key }
        let window = MessageConversationWindow(contentRect: NSRect(origin: .zero, size: K.conversationWindowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = K.conversationWindowMinimumSize
        switch source.kind {
        case .user(let text), .stallari(let text, _): window.title = String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        default: window.title = "작은 대화"
        }
        if window.title.isEmpty { window.title = "작은 대화" }
        window.center()
        if let value = preferences.string(forKey: key(root)) {
            let frame = NSRectFromString(value)
            if frame.width.isFinite, frame.height.isFinite,
               frame.width >= window.minSize.width, frame.height >= window.minSize.height,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                let visible = screen.visibleFrame
                let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
                let origin = NSPoint(x: max(visible.minX, min(frame.minX, visible.maxX - size.width)),
                                     y: max(visible.minY, min(frame.minY, visible.maxY - size.height)))
                window.setFrame(NSRect(origin: origin, size: size), display: false)
            }
        } else {
            window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(windows.count) * K.s5,
                                          y: window.frame.minY - CGFloat(windows.count) * K.s5))
        }
        let composerID = UUID()
        let model = MessageConversationDraft(rootID: root, threadID: store.selectedThreadID,
            busyChanged: { [weak store] busy in store?.setAuxiliaryComposerBusy(composerID, busy: busy) })
        models[root] = model
        window.contentView = NSHostingView(rootView: MessageConversationContent(store: store, model: model,
            open: { [weak self] id in self?.mainWindow.map { Self.present($0) }; revealIssue(id) },
            close: { [weak self] in self?.close(root) })
            .environment(\.chatWebPreferences, preferences))
        windows[root] = window
        Self.present(window)
    }
    func close(_ root: UUID) { windows[root]?.close() }
    func closeAll() { for window in Array(windows.values) { window.close() } }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let root = windows.first(where: { $0.value === window })?.key else { return }
        preferences.set(NSStringFromRect(window.frame), forKey: key(root))
        models.removeValue(forKey: root)?.windowClosed()
        windows.removeValue(forKey: root)
        window.contentView = nil
        mainWindow.map { Self.present($0) }
    }
    func windowDidMove(_ notification: Notification) { saveFrame(notification) }
    func windowDidResize(_ notification: Notification) { saveFrame(notification) }
    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let root = windows.first(where: { $0.value === window })?.key else { return }
        preferences.set(NSStringFromRect(window.frame), forKey: key(root))
    }
}

struct MessageConversationContent: View {
    let store: any KnarrStore
    @Bindable var model: MessageConversationDraft
    let open: (KnarrCore.Issue.ID) -> Void
    let close: () -> Void
    @State private var previewURL: URL?
    @State private var following = true
    @State private var focused = false
    @State private var dropping = false
    @State private var focusRequest = UUID()
    private var readOnly: Bool { ChatWebBridge.isReadOnly(store) }
    var body: some View {
        VStack(spacing: 0) {
            ChatWebView(store: store, highlighted: nil, following: following, jumpToLatest: false, target: nil,
                open: open, restore: { model.restore($0); focusRequest = UUID() }, preview: { previewURL = $0 },
                followingChanged: { following = $0 }, targetReached: {}, conversationRootID: model.rootID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if readOnly { Text("읽기 전용 대화").font(K.secondary).foregroundStyle(K.faint).padding(K.s3) }
            composer.disabled(readOnly || store.extensionPresentation.isReloading)
        }
        .background(K.surface).foregroundStyle(K.ink)
        .quickLookPreview($previewURL)
        .onExitCommand(perform: close)
        .onChange(of: model.isAvailable(store)) { if !model.isAvailable(store) { close() } }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            if let error = model.error { Text(error).font(K.secondary).foregroundStyle(K.red).textSelection(.enabled) }
            if let status = model.statusText(store) {
                Text(status).font(K.secondary).foregroundStyle(K.muted)
                    .accessibilityLabel(status)
            }
            if !model.draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: K.s2) {
                        ForEach(model.draft.attachments, id: \.self) { url in
                            AttachmentChip(url: url, preview: { previewURL = url }, remove: { model.draft.attachments.removeAll { $0 == url } })
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            MessageComposer(text: $model.draft.text, onSubmit: submit, onFiles: model.add,
                onImage: { model.paste($0, store: store) }, onFocus: { focused = $0 },
                placeholder: "이 주제로 대화하기", focusRequest: focusRequest)
            HStack(spacing: K.s2) {
                Button(action: attach) { Image(systemName: "plus").font(K.secondary).frame(width: K.chipHeight, height: K.chipHeight) }
                    .buttonStyle(.plain).help("파일 첨부").accessibilityLabel("파일 첨부")
                Spacer()
                if store.isResponding {
                    Button { store.stopResponse() } label: {
                        Image(systemName: "stop.fill").font(K.secondary).foregroundStyle(K.red)
                            .frame(width: K.sendButton, height: K.sendButton).background(K.sunken, in: Circle())
                    }.buttonStyle(.plain).disabled(store.isStopping).accessibilityLabel("답변 중지")
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(K.secondary.weight(.semibold)).foregroundStyle(K.onInk)
                        .frame(width: K.sendButton, height: K.sendButton)
                        .background(K.ink.opacity(model.draft.isEmpty ? 0.25 : 1), in: Circle())
                }.buttonStyle(.plain).disabled(model.draft.isEmpty || model.sending || store.isStopping)
                    .accessibilityLabel("보내기").help("Enter로 전송 · Shift+Enter로 줄바꿈")
            }
        }
        .padding(K.s3).background(K.surface, in: RoundedRectangle(cornerRadius: K.rLarge))
        .overlay(RoundedRectangle(cornerRadius: K.rLarge).strokeBorder(focused || dropping ? K.accent : K.lineStrong))
        .dropDestination(for: URL.self) { urls, _ in
            guard !readOnly else { return false }; model.add(urls); return urls.contains(where: \.isFileURL)
        } isTargeted: { dropping = $0 }
        .padding(K.s3)
    }
    private func submit() { Task { await model.submit(store) } }
    private func attach() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.prompt = "첨부"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }
}
