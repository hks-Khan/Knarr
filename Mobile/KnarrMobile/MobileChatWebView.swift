import SwiftUI
import UIKit
import WebKit
import KnarrSync

/// The same bundled React/OpenUI document as the Mac; native code owns transport and authority.
struct MobileChatWebView: UIViewRepresentable {
    let store: PhoneStore
    let thread: String?
    let messages: [MobileMessage]
    let issues: [MobileIssue]
    let questions: [MobileQuestion]
    let pending: [MobileRequest]
    let responding: Bool
    let target: String?
    let jump: Int
    let edit: (String) -> Void
    let preview: (Data) -> Void
    let reached: () -> Void
    let following: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.flush()
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "knarr")
        view.stopLoading(); view.navigationDelegate = nil
        coordinator.view = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKURLSchemeHandler {
        var parent: MobileChatWebView
        weak var view: WKWebView?
        var ready = false
        var session = UUID().uuidString
        var scope = ""
        var sentIDs = Set<String>()
        var lastData: Data?
        var lastJump = 0
        var images: [String: (Data, String)] = [:]
        var sending = false
        var queued = false
        #if DEBUG
        var probeStarted = false
        #endif
        let preferences: UserDefaults
        let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ChatWeb")
        init(_ parent: MobileChatWebView) {
            self.parent = parent
            preferences = parent.store.isSample ? UserDefaults(suiteName: "knarr.mobile.web.sample")! : .standard
        }
        func makeView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(self, name: "knarr")
            config.setURLSchemeHandler(self, forURLScheme: "chat-image")
            let web = WKWebView(frame: .zero, configuration: config)
            web.isOpaque = false; web.backgroundColor = .clear
            web.scrollView.backgroundColor = .clear
            // Keep native pan recognition enabled for the React overflow scroller on iOS.
            web.scrollView.alwaysBounceVertical = false
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.navigationDelegate = self
            web.accessibilityLabel = "대화 기록"
            web.isInspectable = parent.store.isSample
            view = web
            if let index { web.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent()) }
            return web
        }
        func key(_ message: String) -> String {
            let safe = Data(scope.utf8).base64EncodedString()
            return "knarr.mobile.chat.web.v1.\(safe).\(message)"
        }
        func state(_ message: String) -> [String: Any] {
            guard let bytes = preferences.data(forKey: key(message)), bytes.count <= 131_072,
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
            return value
        }
        func flush() {
            guard ready, let view else { return }
            if sending { queued = true; return }
            let nextScope = parent.thread ?? "all"
            let reset = scope != nextScope || lastData == nil
            if scope != nextScope { scope = nextScope; session = UUID().uuidString; sentIDs = [] }
            images = [:]
            var rows: [String: [String: Any]] = [:]
            var order: [String] = []
            var lastDay = ""
            for message in parent.messages {
                let day = ChatView.dayLabel(Calendar.current.startOfDay(for: message.at))
                if day != lastDay {
                    let id = "day-" + day; order.append(id)
                    rows[id] = ["id": id, "kind": "day", "text": day, "time": "", "attachments": [], "state": [:]]
                    lastDay = day
                }
                order.append(message.id); rows[message.id] = row(message)
            }
            for request in parent.pending {
                let text: String
                switch request.kind {
                case .message(let body, _), .threadMessage(let body, _, _, _): text = body
                default: continue
                }
                order.append(request.id)
                rows[request.id] = ["id": request.id, "kind": "pending", "text": text, "time": "",
                                    "attachments": [], "state": [:], "pendingCount": request.kind.attachments.count]
            }
            let ids = Set(order)
            let jump = parent.jump != lastJump
            var payload: [String: Any] = [
                "session": session, "thread": scope, "conversationRootID": NSNull(), "reset": reset,
                "order": order, "upsert": rows, "removed": Array(sentIDs.subtracting(ids)),
                "streaming": NSNull(), "footerText": "", "responding": parent.responding,
                "status": parent.responding ? "응답 중" : "", "canResend": false, "readOnly": false,
                "jump": jump, "target": parent.target as Any? ?? NSNull(), "highlighted": parent.target as Any? ?? NSNull(),
                "viewport": reset ? state(MobileWebBridge.viewportID) as Any : NSNull(),
                "dark": parent.colorScheme == .dark, "reduceMotion": parent.reduceMotion,
                "theme": theme(), "mobile": true,
            ]
            if parent.store.isSample { payload["responding"] = false }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), data != lastData else { return }
            lastData = data; sentIDs = ids; lastJump = parent.jump; sending = true
            view.callAsyncJavaScript("window.knarr.receive(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
                guard let self else { return }; self.sending = false
                if case .failure = result { self.lastData = nil }
                if self.queued { self.queued = false; self.flush() }
                #if DEBUG
                self.startProbeIfRequested()
                #endif
            }
        }
        #if DEBUG
        func evaluateProbe(_ script: String) async throws -> String {
            guard let view else { throw URLError(.cancelled) }
            return try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "")
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        /// Isolated, opt-in sample QA: exercises the shipped renderer without CloudKit or production data.
        func startProbeIfRequested() {
            guard !probeStarted, parent.store.isSample, ProcessInfo.processInfo.arguments.contains("-web-probe"),
                  parent.messages.contains(where: { $0.id == "openui-sample" }) else { return }
            probeStarted = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                var report: [String: Any] = ["thread": self.scope]
                do {
                    try await Task.sleep(for: .seconds(2))
                    guard self.view != nil else { return }
                    let before = try await self.evaluateProbe("""
                    const slider = document.querySelector('.generated-ui input[type=range]');
                    return JSON.stringify({slider: slider?.value ?? null, text: document.querySelector('.generated-ui')?.innerText ?? null,
                            rawSource: document.body.innerText.includes('root = Stack'),
                            rows: document.querySelectorAll('[data-message]').length});
                    """)
                    report["before"] = String(describing: before)
                    _ = try await self.evaluateProbe("""
                    const slider = document.querySelector('.generated-ui input[type=range]');
                    if (!slider) throw new Error('Slider missing');
                    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(slider, slider.value === '7' ? '6' : '7');
                    slider.dispatchEvent(new Event('input', {bubbles:true}));
                    slider.dispatchEvent(new Event('change', {bubbles:true}));
                    """)
                    try await Task.sleep(for: .milliseconds(250))
                    let after = try await self.evaluateProbe("""
                    return JSON.stringify({slider:document.querySelector('.generated-ui input[type=range]')?.value ?? null,
                            text:document.querySelector('.generated-ui')?.innerText ?? null});
                    """)
                    report["after"] = String(describing: after)
                    _ = try await self.evaluateProbe("""
                    const button = [...document.querySelectorAll('.generated-ui button')].find(e => e.textContent === '이 계획으로 진행');
                    if (!button) throw new Error('OpenUI button missing');
                    button.click();
                    """)
                    try await Task.sleep(for: .milliseconds(300))
                    report["requests"] = self.parent.store.model.pendingRequests.compactMap { request -> [String: String]? in
                        if case .threadMessage(let text, let thread, _, _) = request.kind { return ["text": text, "thread": thread] }
                        return nil
                    }
                    report["finished"] = true
                } catch { report["error"] = String(describing: error) }
                if JSONSerialization.isValidJSONObject(report), let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                   let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? bytes.write(to: folder.appendingPathComponent("web-probe.json"), options: .atomic)
                }
            }
        }
        #endif

        func row(_ message: MobileMessage) -> [String: Any] {
            var value: [String: Any] = ["id": message.id, "time": message.at.formatted(date: .omitted, time: .shortened),
                "text": message.text, "attachments": message.attachments?.map(\.name) ?? [], "state": state(message.id)]
            let kind: String
            switch message.role {
            case .stallari: kind = "assistant"
            case .user: kind = "user"
            case .issue: kind = "issue"
            case .question: kind = "question"
            case .notice: kind = "notice"
            case .autoCheck: kind = "autoCheck"
            case .report: kind = "report"
            }
            value["kind"] = kind; value["project"] = message.project
            if let activity = message.activity {
                value["kind"] = "activity"
                value["activity"] = ["kind": activity.kind, "title": activity.title, "state": activity.state,
                                     "label": activity.label,
                                     "startedAt": activity.startedAt.timeIntervalSince1970 * 1000,
                                     "updatedAt": activity.updatedAt.timeIntervalSince1970 * 1000] as [String: Any]
            }
            if let report = message.report {
                value["report"] = ["id": message.id, "title": report.title, "state": report.state,
                                   "lines": report.lines, "error": report.error as Any? ?? NSNull(),
                                   "retryable": false, "busy": false] as [String: Any]
            }
            var previews: [String] = []
            for (i, file) in (message.attachments ?? []).enumerated() {
                guard let data = file.data, data.count <= MobileLimits.attachmentBytes, UIImage(data: data) != nil else { previews.append(""); continue }
                let id = Data("\(message.id):\(i)".utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
                let address = "chat-image://image/" + id
                images[address] = (data, file.type); previews.append(address)
            }
            value["attachmentImages"] = previews
            if let id = message.issue, let issue = parent.issues.first(where: { $0.id == id }) {
                value["issue"] = ["id": id, "title": issue.title, "status": Palette.label(issue.state),
                    "met": issue.criteria.filter { $0.state == .met }.count, "total": issue.criteria.count,
                    "headline": issue.headline, "detail": issue.detail, "state": issue.state.rawValue,
                    "steps": issue.runs.flatMap(\.steps).map { ["title": $0.title, "state": $0.state.rawValue] }, "hirds": []] as [String: Any]
            }
            if let id = message.question, let q = parent.questions.first(where: { $0.id == id }) {
                let waiting = parent.store.model.isAwaitingMac(question: id)
                value["question"] = ["id": id, "asker": q.asker, "prompt": q.prompt, "options": q.options,
                    "multiple": q.allowsMultiple, "status": waiting ? "answered" : q.state.rawValue,
                    "summary": waiting ? "전달 대기" : q.answer ?? (q.state == .cancelled ? "질문 닫음" : ""),
                    "placeholder": "추가 내용 (선택)"] as [String: Any]
            }
            if (message.role == .issue && value["issue"] == nil) || (message.role == .question && value["question"] == nil) {
                value["kind"] = "archived"
                value["title"] = message.role == .issue ? "이슈" : "질문"
            }
            if message.role == .notice { value["title"] = "알림"; value["tone"] = "faint" }
            if message.role == .autoCheck {
                let lines = message.text.components(separatedBy: "\n")
                value["text"] = lines.first ?? "검증"; value["lines"] = Array(lines.dropFirst())
            }
            return value
        }
        func theme() -> [String: String] {
            var tokens: [String: String] = [:]
            let colors: [String: Color] = ["ink": Palette.ink, "muted": Palette.muted, "faint": Palette.faint,
                "surface": Palette.page, "sunken": Palette.sunken, "line": Palette.line, "lineStrong": Palette.lineStrong,
                "accent": Palette.accent, "accentSoft": Palette.accentSoft, "red": Palette.red, "amber": Palette.amber,
                "green": Palette.green, "codeChip": Palette.codeChip, "synKeyword": Palette.synKeyword,
                "synString": Palette.synString, "synNumber": Palette.synNumber]
            let traits = UITraitCollection(userInterfaceStyle: parent.colorScheme == .dark ? .dark : .light)
            for (key, color) in colors {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                tokens[key] = "rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(a))"
            }
            tokens["onInk"] = parent.colorScheme == .dark ? "#181818" : "#ffffff"
            let base: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 16
            let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: base)
            for (key, value) in ["s1": 4.0, "s2": 8, "s3": 12, "s4": 16, "s5": 20, "s6": 28,
                                  "rSmall": 5, "rCard": 7, "column": 740, "controlHeight": 32,
                                  "body": body, "caption": body - 2, "secondary": body - 1, "title": body + 1] {
                tokens[key] = "\(value)px"
            }
            return tokens
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; lastData = nil; flush() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; lastData = nil; webView.reload() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.standardizedFileURL == index?.standardizedFileURL ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, let (data, type) = images[url.absoluteString] else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == index?.standardizedFileURL,
                  let raw = message.body as? [String: Any], let action = raw["action"] as? String else { return }
            if action == "ready" { ready = true; lastData = nil; flush(); return }
            guard raw["session"] as? String == session, raw["thread"] as? String == scope else { return }
            if action == "viewport" {
                if let bytes = MobileWebBridge.viewportData(raw, session: session, thread: scope) {
                    preferences.set(bytes, forKey: key(MobileWebBridge.viewportID))
                    if let state = raw["state"] as? [String: Any], let following = state["following"] as? Bool {
                        parent.following(following)
                    }
                }
                return
            }
            if action == "targetReached" { parent.reached(); return }
            if action == "imagePreview", let address = raw["text"] as? String, let image = images[address] { parent.preview(image.0); return }
            guard let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 160_000,
                  let event = try? JSONDecoder().decode(MobileWebEvent.self, from: data),
                  let command = MobileWebBridge.command(event, session: session, thread: scope, model: parent.store.model) else {
                result(raw, error: "현재 상태에서 처리할 수 없어요."); return
            }
            switch command {
            case .send(let text, let thread, let project): parent.store.send(text: text, project: project, thread: thread)
            case .answer(let id, let selected, let text): parent.store.send(.answer(question: id, options: selected, text: text))
            case .cancelQuestion(let id): parent.store.send(.cancelQuestion(id))
            case .open(let id): parent.store.openIssue = id
            case .copy(let text): UIPasteboard.general.string = text
            case .edit(let text): parent.edit(text)
            case .preview(let id, let index):
                if let data = parent.store.model.messageByID[id]?.attachments?[index].data { parent.preview(data) }
            case .cancelPending(let id): if let request = parent.store.model.requestByID[id] { parent.store.cancel(request) }
            case .link(let url): UIApplication.shared.open(url)
            case .state(let id):
                guard let state = raw["state"] as? [String: Any],
                      let bytes = try? JSONSerialization.data(withJSONObject: state), bytes.count <= 131_072 else { return }
                preferences.set(bytes, forKey: key(id))
            }
            result(raw, error: nil)
        }
        func result(_ raw: [String: Any], error: String?) {
            guard let id = raw["message"] as? String else { return }
            view?.callAsyncJavaScript("window.knarr.result(id, error, request)",
                arguments: ["id": id, "error": error as Any? ?? NSNull(), "request": raw["request"] as? String as Any? ?? NSNull()],
                in: nil, in: .page, completionHandler: nil)
        }
    }
}
