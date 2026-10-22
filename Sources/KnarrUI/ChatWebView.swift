import AppKit
import SwiftUI
import WebKit
import KnarrCore

/// One request to show a focused conversation inside the transcript. The token makes a repeated
/// request for the same root expand again after the person closed the canvas.
public struct MessageConversationCanvasRequest: Equatable, Sendable {
    public let root: UUID
    public let token: UUID
    public init(root: UUID, token: UUID = UUID()) { self.root = root; self.token = token }
}

/// Main-thread cost of the transcript refresh. The probe test reads it before and after a change so
/// a stall is a measured number, not a guess; the app never reads it.
@MainActor enum ChatWebDiagnostics {
    static var flushCount = 0
    static var flushMilliseconds: [Double] = []
    static var rowsBuilt = 0
    static var stalls: [Double] { flushMilliseconds.filter { $0 > 100 } }
    static func reset() { flushCount = 0; flushMilliseconds = []; rowsBuilt = 0; ChatWebProjection.resetBuildCount() }
    static func record(milliseconds: Double) { flushCount += 1; flushMilliseconds.append(milliseconds) }
}

private struct ChatWebPreferencesKey: EnvironmentKey {
    static var defaultValue: UserDefaults { .standard }
}
private struct ChatWebPasteboardKey: EnvironmentKey {
    static var defaultValue: NSPasteboard { .general }
}
public extension EnvironmentValues {
    var chatWebPreferences: UserDefaults {
        get { self[ChatWebPreferencesKey.self] }
        set { self[ChatWebPreferencesKey.self] = newValue }
    }
    var chatWebPasteboard: NSPasteboard {
        get { self[ChatWebPasteboardKey.self] }
        set { self[ChatWebPasteboardKey.self] = newValue }
    }
}

/// One web document owns transcript layout and scrolling; the composer remains native.
struct ChatWebView: View {
    let store: any KnarrStore
    let highlighted: UUID?
    let following: Bool
    let jumpToLatest: Bool
    let target: UUID?
    let open: (Issue.ID) -> Void
    let restore: (ChatDraft) -> Void
    let preview: (URL) -> Void
    let followingChanged: (Bool) -> Void
    let targetReached: () -> Void
    var resend: (() -> Void)?
    var conversationRootID: UUID? = nil
    var openConversation: ((UUID) -> Void)? = nil
    var openConversationWindow: ((UUID) -> Void)? = nil
    /// Native requests to expand a canvas (a new focused conversation, or an explicit caller).
    var canvasRequest: MessageConversationCanvasRequest? = nil
    /// Reports whether a focused conversation panel is on screen, so native chrome can yield height to it.
    var canvasVisibilityChanged: ((Bool) -> Void)? = nil
    /// Opens one generated report from its main-conversation card.
    var openWorkReport: ((String) -> Void)? = nil
    var navigateTransfer: ((ProjectTransfer, Bool) -> Void)? = nil
    @Environment(\.chatWebPreferences) private var preferences
    @Environment(\.chatWebPasteboard) private var pasteboard
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Surface(parent: self, inputs: Inputs(store: store), dark: colorScheme == .dark, reduceMotion: reduceMotion)
    }
    // Reading the observed values in body makes native changes invalidate the web projection.
    private struct Inputs {
        let chat: [ChatItem]
        let issues: [Issue]
        let questions: [Question]
        let transfers: [ProjectTransfer]
        let thread: String
        let streaming: String
        let streamingID: UUID?
        let responding: Bool
        let status: String
        let responseStartedAt: Date?
        let responseLastEventAt: Date?
        let readOnly: Bool
        /// Canvas and collapsed-card status come from this, so a change must reach the page.
        let respondingRoots: Set<UUID>
        /// Roots whose answer alone can be stopped; the canvas shows stop only for these.
        let stoppableRoots: Set<UUID>
        let waitingRoots: Set<UUID>
        /// Report analysis state changes the card's lines without a new report.
        let reports: [WorkReport]
        let reportBusy: Bool
        /// Re-activation must re-check what is visible even though the transcript itself is the same.
        let activation: Int
        @MainActor init(store: any KnarrStore) {
            chat = store.chat; issues = store.issues; questions = store.questions; thread = store.selectedThreadID
            transfers = store.projectTransfers
            streaming = store.streamingText; streamingID = store.streamingMessageID; responding = store.isResponding
            respondingRoots = store.respondingConversationRoots
            stoppableRoots = store.stoppableConversationRoots
            waitingRoots = store.waitingConversationRoots
            reports = store.workReports; reportBusy = store.workReportBusy
            responseStartedAt = store.responseStartedAt; responseLastEventAt = store.responseLastEventAt
            status = store.responseStatus; readOnly = ChatWebBridge.isReadOnly(store)
            activation = store.activationRevision
        }
    }
    private struct Surface: NSViewRepresentable {
        let parent: ChatWebView
        let inputs: Inputs
        let dark: Bool
        let reduceMotion: Bool
        func makeCoordinator() -> Coordinator { Coordinator(parent) }
        func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
        func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(parent, dark: dark, reduceMotion: reduceMotion) }
        static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.detach() }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
        var parent: ChatWebView
        var bridge = ChatWebBridge()
        let states: ChatWebStateStore
        /// Which local images this transcript was shown; the page only ever sees these addresses.
        let images = ChatImageResolver()
        weak var view: WKWebView?
        var ready = false
        var thread = ""
        var stateThread = ""
        var lastJump = false
        /// What each row was last built from; an unchanged value keeps the previous row untouched.
        var inputs: [UUID: ChatWebProjection.Inputs] = [:]
        var cache: [UUID: OMPJSON] = [:]
        var lastPayload: OMPJSON?
        var sending = false
        var pending = false
        var dark = false
        var reduceMotion = false
        var actionTasks: [UUID: Task<Void, Never>] = [:]
        /// Last canvas request delivered to the page, so a repeated token is not sent twice.
        var lastCanvasToken: UUID?
        /// Last activation revision the page was told about.
        var lastActivation = 0
        /// The root whose canvas the page currently shows; only its rows cross the bridge.
        var openCanvasRoot: UUID?
        /// Report cards already delivered, so a retry's pending/generating state keeps the same row.
        var shownReportIDs: Set<String> = []
        private let viewportID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        static var index: URL { AppArtwork.bundle.url(forResource: "index", withExtension: "html", subdirectory: "ChatWeb")! }
        init(_ parent: ChatWebView) { self.parent = parent; self.states = ChatWebStateStore(preferences: parent.preferences) }
        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.tabFocusesLinks = true
            config.userContentController.add(self, name: "knarr")
            config.setURLSchemeHandler(self, forURLScheme: ChatImageSource.scheme)
            let web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground")
            web.setAccessibilityLabel("대화 기록")
            view = web
            web.loadFileURL(Self.index, allowingReadAccessTo: Self.index.deletingLastPathComponent())
            return web
        }
        func update(_ parent: ChatWebView, dark: Bool, reduceMotion: Bool) {
            self.parent = parent; self.dark = dark; self.reduceMotion = reduceMotion
            pending = true; flush()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pending = true; flush() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; bridge = ChatWebBridge(); webView.reload() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.standardizedFileURL == Self.index.standardizedFileURL ? .allow : .cancel)
        }
        /// Reads the bytes for one validated image. The page never learns the path, only the address.
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let source = images.resolve(url),
                  let mime = ChatImageSource.mimeType(for: source), let data = try? Data(contentsOf: source) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func flush() {
            guard ready, !sending, pending, let view else { return }
            pending = false
            let clock = ProcessInfo.processInfo.systemUptime
            defer { ChatWebDiagnostics.record(milliseconds: (ProcessInfo.processInfo.systemUptime - clock) * 1000) }
            let store = parent.store
            let scope = store.selectedThreadID + (parent.conversationRootID.map { ":conversation:" + $0.uuidString } ?? "")
            let reset = stateThread != scope || cache.isEmpty
            if stateThread != scope {
                thread = store.selectedThreadID; stateThread = scope
                bridge = ChatWebBridge(); cache = [:]; inputs = [:]; lastPayload = nil
            }
            let items: [ChatItem]
            if let root = parent.conversationRootID { items = store.chat.filter { $0.conversationRootID == root } }
            else {
                shownReportIDs.formUnion(store.workReports.filter { WorkReportCards.isVisible($0) }.map(\.id))
                items = WorkReportCards.transcript(
                    ProjectTransfer.transcript(store.chat, transfers: store.projectTransfers, threadID: store.selectedThreadID),
                    reports: store.workReports, threadID: store.selectedThreadID, including: shownReportIDs)
            }
            let ids = items.map(\.id), valid = Set(ids)
            let removed = cache.keys.filter { !valid.contains($0) }
            // One lookup table per refresh: rows never re-scan issues, questions or transfers.
            let context = ChatWebProjection.Context(store: store)
            var changed: [String: OMPJSON] = [:]
            for item in items {
                let state = inputs[item.id]?.state ?? states.load(thread: thread, message: item.id)
                let next = context.inputs(item, state: state)
                if inputs[item.id] == next, cache[item.id] != nil { continue }
                let row = ChatWebProjection.row(next, images: images)
                inputs[item.id] = next
                if cache[item.id] != row { changed[item.id.uuidString] = row; cache[item.id] = row }
            }
            for id in removed { cache.removeValue(forKey: id); inputs.removeValue(forKey: id) }
            let jump = parent.jumpToLatest != lastJump; lastJump = parent.jumpToLatest
            let request = parent.canvasRequest
            let canvasToken = request?.token != lastCanvasToken ? request.flatMap { request in
                store.chat.contains { $0.id == request.root && $0.isConversationLink } ? request : nil
            } : nil
            if let canvasToken { lastCanvasToken = canvasToken.token }
            let roots = store.respondingConversationRoots
            let stoppable = store.stoppableConversationRoots
            // Collapsed cards need only when each conversation last answered; the canvas needs its rows.
            var summaries: [String: OMPJSON] = [:]
            for link in items where link.isConversationLink && link.conversationRootID == nil {
                let replies = store.chat.filter { $0.conversationRootID == link.id }
                let last = replies.compactMap { item -> (Date, ChatItem)? in
                    if case .stallari = item.kind { return (item.at, item) } else { return nil }
                }.max { $0.0 < $1.0 }?.1
                summaries[link.id.uuidString] = .object([
                    "at": .number((last?.at ?? link.at).timeIntervalSince1970 * 1000),
                    "time": .string((last?.at ?? link.at).formatted(date: .omitted, time: .shortened)),
                    "replyAts": .array(replies.compactMap { item -> OMPJSON? in
                        guard case .stallari = item.kind else { return nil }
                        return .number(item.at.timeIntervalSince1970 * 1000)
                    }),
                ])
            }
            let canvasRoot = openCanvasRoot.flatMap { root in
                store.chat.first { $0.id == root && $0.isConversationLink }?.id
            }
            let canvas: OMPJSON = canvasRoot.map { canvasRoot -> OMPJSON in
                let canvasItems = store.chat.filter { $0.conversationRootID == canvasRoot }
                    .sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
                let canvasRows: [String: OMPJSON] = Dictionary(uniqueKeysWithValues: canvasItems.map { item in
                    let state = cache[item.id]?["state"] ?? states.load(thread: thread, message: item.id)
                    return (item.id.uuidString, ChatWebProjection.row(item, store: store, state: state, images: images))
                })
                return .object(["root": .string(canvasRoot.uuidString),
                                "order": .array(canvasItems.map { .string($0.id.uuidString) }),
                                "rows": .object(canvasRows),
                                "responding": .bool(roots.contains(canvasRoot)),
                                "waiting": .bool(store.waitingConversationRoots.contains(canvasRoot)),
                                "stoppable": .bool(stoppable.contains(canvasRoot)),
                                "stopBlockReason": store.stopBlockReason(for: canvasRoot).map { .string($0) } ?? .null,
                                "status": .string(store.responseStatus),
                                "startedAt": store.responseStartedAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
                                "readOnly": .bool(ChatWebBridge.isReadOnly(store))])
            } ?? .null
            let payload: OMPJSON = .object(["session": .string(bridge.session), "thread": .string(thread), "reset": .bool(reset),
                "conversationRootID": parent.conversationRootID.map { .string($0.uuidString) } ?? .null,
                "order": .array(ids.map { .string($0.uuidString) }), "upsert": .object(changed), "removed": .array(removed.map { .string($0.uuidString) }),
                "streaming": store.streamingMessageID.map { .string($0.uuidString) } ?? .null,
                "footerText": .string(parent.conversationRootID == nil && store.streamingMessageID == nil ? store.streamingText : ""),
                "responding": .bool(store.isResponding), "status": .string(store.responseStatus),
                "responseStartedAt": store.responseStartedAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
                "responseLastEventAt": store.responseLastEventAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null, "canResend": .bool(parent.resend != nil),
                "respondingRoots": .array(roots.map { .string($0.uuidString) }),
                "stoppableRoots": .array(stoppable.map { .string($0.uuidString) }),
                "waitingRoots": .array(store.waitingConversationRoots.map { .string($0.uuidString) }),
                "summaries": .object(summaries),
                "canvas": canvas,
                "canvasRequest": canvasToken.map { .object(["root": .string($0.root.uuidString), "token": .string($0.token.uuidString)]) } ?? .null,
                "readOnly": .bool(ChatWebBridge.isReadOnly(store)), "jump": .bool(jump),
                "target": parent.target.map { .string($0.uuidString) } ?? .null,
                "highlighted": parent.highlighted.map { .string($0.uuidString) } ?? .null,
                "viewport": reset ? states.load(thread: stateThread, message: viewportID) : .null,
                "dark": .bool(dark), "reduceMotion": .bool(reduceMotion), "theme": .object(K.webTokens(dark: dark).mapValues(OMPJSON.string))])
            // Coming back from the background changes nothing in the payload, yet the answers the
            // person is looking at were refused while the app was inactive, so they must be offered
            // again before the identical-payload shortcut.
            if lastActivation != store.activationRevision {
                lastActivation = store.activationRevision
                view.callAsyncJavaScript("window.knarr.recheckVisibility?.()", arguments: [:], in: nil, in: .page, completionHandler: nil)
            }
            guard payload != lastPayload else { return }
            lastPayload = payload
            guard let bytes = try? JSONEncoder().encode(payload), let object = try? JSONSerialization.jsonObject(with: bytes) else { return }
            sending = true
            view.callAsyncJavaScript("window.knarr.receive(payload)", arguments: ["payload": object], in: nil, in: .page) { [weak self] result in
                guard let self else { return }; self.sending = false
                if case .failure = result { self.cache = [:]; self.inputs = [:]; self.lastPayload = nil }
                self.flush()
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == Self.index.standardizedFileURL,
                  JSONSerialization.isValidJSONObject(message.body), let data = try? JSONSerialization.data(withJSONObject: message.body), data.count <= 196_608,
                  let event = try? JSONDecoder().decode(OMPJSON.self, from: data) else { return }
            if event["action"]?.string == "ready" { ready = true; cache = [:]; inputs = [:]; lastPayload = nil; pending = true; flush(); return }
            guard event["session"]?.string == bridge.session, event["thread"]?.string == parent.store.selectedThreadID,
                  ChatWebBridge.matchesScope(event, conversationRootID: parent.conversationRootID) else { return }
            if event["action"]?.string == "viewport", let state = event["state"], case .object = state {
                states.save(state, thread: stateThread, message: viewportID)
                if let follows = state["following"]?.bool, follows != parent.following { parent.followingChanged(follows) }
                return
            }
            if event["action"]?.string == "targetReached", event["target"]?.string == parent.target?.uuidString { parent.targetReached(); return }
            // Reading is a visibility fact from the page, re-checked against this store before it counts.
            if event["action"]?.string == "answersSeen" {
                guard parent.conversationRootID == nil,
                      let ids = event["ids"]?.array?.compactMap({ $0.string.flatMap(UUID.init(uuidString:)) }),
                      !ids.isEmpty else { return }
                parent.store.markAnswersRead(ids, threadID: thread)
                return
            }
            // The page expands or collapses a canvas in place; native supplies and stops its rows.
            if event["action"]?.string == "canvasOpen" || event["action"]?.string == "canvasClose" {
                guard parent.conversationRootID == nil else { return }
                let root = event["action"]?.string == "canvasOpen" ? event["message"]?.string.flatMap(UUID.init(uuidString:)) : nil
                if event["action"]?.string == "canvasOpen" {
                    guard let root, parent.store.chat.contains(where: { $0.id == root && $0.isConversationLink }) else { return }
                }
                if openCanvasRoot != root {
                    openCanvasRoot = root
                    lastPayload = nil
                    pending = true
                    flush()
                    // The panel needs real height, so native chrome around the transcript can compress.
                    parent.canvasVisibilityChanged?(root != nil)
                }
                return
            }
            if event["action"]?.string == "resend", !parent.store.isResponding, parent.store.responseStatus == ResponseProgressView.stoppedStatus { parent.resend?(); return }
            guard let command = bridge.command(event, store: parent.store, conversationRootID: parent.conversationRootID) else { result(event, error: "현재 상태에서 처리할 수 없어요."); return }
            switch command {
            case .copy(let text):
                parent.pasteboard.clearContents()
                let copied = parent.pasteboard.setString(text, forType: .string)
                result(event, error: copied ? nil : "복사하지 못했어요.")
            case .edit(let draft): parent.restore(draft)
            case .preview(let url): parent.preview(url)
            case .imagePreview(let address):
                guard let address = URL(string: address), let url = images.resolve(address) else { result(event, error: "이미지를 열 수 없어요."); return }
                parent.preview(url)
            case .open(let id): parent.open(id)
            case .link(let url): NSWorkspace.shared.open(url)
            case .state(let id, let state):
                states.save(state, thread: thread, message: id)
                if case .object(var row) = cache[id] { row["state"] = state; cache[id] = .object(row) }
                inputs[id]?.state = state
            case .answer(let id, let answer): reply(id, answer: answer, event: event)
            case .cancel(let id): reply(id, answer: nil, event: event)
            case .openConversationWindow(let id): parent.openConversationWindow?(id)
            case .openConversation(let id):
                // The page expands the canvas in place; native supplies that root's rows. Calling the
                // open callback here would mint a new request token and re-expand forever.
                if openCanvasRoot != id {
                    openCanvasRoot = id
                    lastPayload = nil
                    pending = true
                    flush()
                    parent.canvasVisibilityChanged?(true)
                }
            case .canvasSend(let root, let text):
                let taskID = UUID(), store = parent.store, expectedThread = thread, session = bridge.session
                actionTasks[taskID] = Task { [weak self] in
                    defer { self?.actionTasks.removeValue(forKey: taskID) }
                    do {
                        guard !Task.isCancelled, store.selectedThreadID == expectedThread else { return }
                        try await store.submit(ChatDraft(text: text, project: store.composerDraft.project, conversationRootID: root))
                        guard let self, self.bridge.session == session,
                              store.selectedThreadID == expectedThread else { return }
                        self.result(event, error: nil)
                    } catch {
                        guard let self, self.bridge.session == session,
                              store.selectedThreadID == expectedThread else { return }
                        self.result(event, error: error.localizedDescription)
                    }
                }
            case .canvasStop(let root):
                // The admission check and the stop are not atomic: the answer may have finished and
                // another root or thread started in between. The bridge re-checks identity and stops.
                bridge.stop(root, store: parent.store, thread: thread, session: bridge.session)
            case .openReport(let id):
                guard let open = parent.openWorkReport else { result(event, error: "보고서를 열 수 없어요."); return }
                open(id)
            case .retryReport(let id): parent.store.retryWorkReport(id)
            case .navigateTransfer(let transfer, let main): parent.navigateTransfer?(transfer, main)
            case .startConversation(let id):
                guard parent.openConversation != nil else { result(event, error: "대화를 펼 수 없어요."); return }
                let taskID = UUID(), store = parent.store, expectedThread = thread, session = bridge.session
                actionTasks[taskID] = Task { [weak self] in
                    defer { self?.actionTasks.removeValue(forKey: taskID) }
                    do {
                        guard !Task.isCancelled, store.selectedThreadID == expectedThread else { throw CancellationError() }
                        try await store.linkMessageConversation(id)
                        guard !Task.isCancelled, let self, self.bridge.session == session,
                              store.selectedThreadID == expectedThread,
                              case .openConversation = self.bridge.command(.object([
                                "session": .string(session), "thread": .string(expectedThread),
                                "message": .string(id.uuidString), "action": .string("openConversation")
                              ]), store: store, conversationRootID: self.parent.conversationRootID) else { return }
                        self.parent.openConversation?(id)
                        self.result(event, error: nil)
                    } catch { self?.result(event, error: error.localizedDescription) }
                }
            case .continueConversation(let text):
                let taskID = UUID(), store = parent.store, expectedThread = thread,
                    draft = ChatDraft(text: text, project: parent.store.composerDraft.project, conversationRootID: parent.conversationRootID)
                actionTasks[taskID] = Task { [weak self] in
                    defer { self?.actionTasks.removeValue(forKey: taskID) }
                    do { guard !Task.isCancelled, store.selectedThreadID == expectedThread else { return }; try await store.submit(draft) }
                    catch { self?.result(event, error: error.localizedDescription) }
                }
            case .perform(let action, let id):
                switch action {
                case .approveProposal, .requestProposalChanges, .rejectProposal:
                    let taskID = UUID(), store = parent.store
                    actionTasks[taskID] = Task { [weak self] in
                        defer { self?.actionTasks.removeValue(forKey: taskID) }
                        do { guard !Task.isCancelled else { return }; try await store.reviewProposal(action, on: id, source: "chat"); self?.result(event, error: nil) }
                        catch { if let raw = event["message"]?.string, let message = UUID(uuidString: raw) { self?.bridge.release(message: message) }; self?.result(event, error: error.localizedDescription) }
                    }
                default: parent.store.perform(action, on: id)
                }
            }
        }
        private func reply(_ id: Question.ID, answer: QuestionAnswer?, event: OMPJSON) {
            let taskID = UUID(), store = parent.store, activeBridge = bridge
            actionTasks[taskID] = Task { [weak self] in
                defer { self?.actionTasks.removeValue(forKey: taskID) }
                do {
                    guard !Task.isCancelled else { return }
                    try await store.replyToQuestion(id, answer: answer)
                    self?.result(event, error: nil)
                } catch {
                    if let raw = event["message"]?.string, let message = UUID(uuidString: raw) { activeBridge.release(message: message) }
                    self?.result(event, error: error.localizedDescription)
                }
            }
        }
        private func result(_ event: OMPJSON, error: String?) {
            guard event["session"]?.string == bridge.session, let id = event["message"]?.string else { return }
            view?.callAsyncJavaScript("window.knarr.result(message, error, request)",
                arguments: ["message": id, "error": error as Any? ?? NSNull(),
                            "request": event["request"]?.string as Any? ?? NSNull()],
                in: nil, in: .page, completionHandler: nil)
        }
        func detach() {
            view?.stopLoading(); view?.navigationDelegate = nil
            view?.configuration.userContentController.removeScriptMessageHandler(forName: "knarr")
            for task in actionTasks.values { task.cancel() }; actionTasks = [:]
            view = nil; ready = false; cache = [:]; inputs = [:]
        }
    }
}
