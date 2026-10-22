import AppKit
import SwiftUI
import KnarrCore

struct ModelControls: View {
    let store: any KnarrStore
    var body: some View {
        Menu {
            Picker("모델", selection: Binding(get: { store.requestedModel ?? store.model ?? "" }, set: { store.selectModel($0) })) {
                ForEach(Self.groups(store.models), id: \.name) { group in
                    Section(group.name) { ForEach(group.models, id: \.self) { Text(Self.name($0)).tag($0) } }
                }
            }
            if !store.thinkingLevels.isEmpty {
                Divider()
                Picker("추론 수준", selection: Binding(get: { store.thinkingLevel ?? "" }, set: { store.selectThinking($0) })) {
                    ForEach(store.thinkingLevels, id: \.self) { Text($0).tag($0) }
                }.disabled(store.isResponding)
            }
        } label: {
            HStack(spacing: K.s1) {
                Text([Self.name(store.pendingModel ?? store.model ?? "모델 선택"), store.thinkingLevel].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                if store.pendingModel != nil { Image(systemName: "clock").help("다음 요청부터 적용") }
            }.font(K.caption).foregroundStyle(K.muted)
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(store.models.isEmpty)
        .accessibilityLabel("모델과 추론 수준 선택")
    }
    static func provider(_ m: String) -> String {
        let identifier = m.split(separator: "/", maxSplits: 1).first.map(String.init) ?? m
        switch identifier {
        case "anthropic": return "Claude"
        case "openai-codex", "openai": return "GPT"
        case "hive": return "Hive"
        default: return identifier
        }
    }
    static func name(_ m: String) -> String { m.split(separator: "/", maxSplits: 1).last.map(String.init) ?? m }

    /// Known providers first, then every other catalog provider; newest-looking models first.
    static func groups(_ models: [String]) -> [(name: String, models: [String])] {
        let grouped = Dictionary(grouping: models, by: provider)
        let known = ["Claude", "GPT", "Hive"]
        let unknown = grouped.keys.filter { !known.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (known + unknown).compactMap { name in
            guard let entries = grouped[name] else { return nil }
            let list = entries.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            return (name, list)
        }
    }
}

/// Chooses how main input sent during an answer is delivered; changing it applies to waiting input now.
struct WhileRespondingControl: View {
    let store: any KnarrStore
    var body: some View {
        Menu {
            Picker("답변 중 보내기", selection: Binding(get: { store.whileRespondingMode }, set: { store.setWhileRespondingMode($0) })) {
                ForEach(WhileRespondingMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: K.s1) {
                Image(systemName: Self.symbol(store.whileRespondingMode))
                Text(Self.title(store.whileRespondingMode)).lineLimit(1)
            }.font(K.caption).foregroundStyle(K.muted)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("답변 중에 보낸 메시지를 지금 답변에 바로 반영할지, 답이 끝난 뒤 보낼지 고릅니다")
        .accessibilityLabel("답변 중 보내기 방식")
        .accessibilityValue(Self.title(store.whileRespondingMode))
    }
    static func title(_ mode: WhileRespondingMode) -> String {
        switch mode {
        case .steer: return "바로 반영"
        case .queue: return "끝나면 보내기"
        }
    }
    static func symbol(_ mode: WhileRespondingMode) -> String {
        switch mode {
        case .steer: return "arrow.turn.down.right"
        case .queue: return "clock"
        }
    }
}

/// Listen only to user scrolling. Programmatic follow updates must not disable following.
/// Whenever the visible size or the transcript's height changes (window or task panel resize, a card or
/// status line changing height, new messages, streaming), the transcript keeps its place: the latest message
/// stays at the bottom while following; otherwise the message being read stays where it was.
/// Following is applied in the same layout pass, at most ten times a second while text streams.
struct ScrollTrackingView: NSViewRepresentable {
    var following: Bool
    let onFollowChange: (Bool) -> Void
    func makeNSView(context: Context) -> Tracker {
        let view = Tracker(); view.changed = onFollowChange; view.following = following; return view
    }
    func updateNSView(_ view: Tracker, context: Context) {
        view.changed = onFollowChange; view.following = following; view.attach()
    }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.detach() }
    @MainActor final class Tracker: NSView {
        var changed: (Bool) -> Void = { _ in }
        var following = true
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var viewport: NSSize = .zero
        private var contentWidth: CGFloat = 0
        private var contentHeight: CGFloat = 0
        /// When the bottom was last followed, for the ten-per-second limit; a later follow waits for its turn.
        private var lastFollow: TimeInterval = 0
        private var followPending = false
        /// A view near the top of the history being read, its distance above the visible top, and its height then.
        private weak var anchor: NSView?
        private var anchorOffset: CGFloat = 0
        private var anchorHeight: CGFloat = 0
        private var adjusting = false

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.attach() } }
        // SwiftUI may insert the tracker before the transcript's scroll view exists; attach once it is sized inside it.
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); attach() }
        func attach() {
            guard let target = enclosingScrollView, target !== scroll, let doc = target.documentView else { return }
            detach(); scroll = target
            let clip = target.contentView
            viewport = clip.bounds.size
            contentWidth = doc.frame.width
            contentHeight = doc.frame.height
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            doc.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            // Delivered on the main queue, so the handlers run synchronously before the next draw.
            observers = [
                center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: target, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readPosition() }
                },
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryChanged() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryChanged() }
                },
            ]
        }
        private func readPosition() {
            guard let scroll, let doc = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            let distance = doc.isFlipped ? doc.bounds.maxY - visible.maxY : visible.minY - doc.bounds.minY
            // Take the person's scroll at once; content arriving before SwiftUI passes it back must not pull them down.
            following = distance < 64
            changed(following)
        }
        /// Any scroll, by the person or by a jump: note what is being read once scrolling settles.
        private func scrolled() {
            guard !adjusting else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(captureAnchor), object: nil)
            perform(#selector(captureAnchor), with: nil, afterDelay: 0.1)
        }
        @objc private func captureAnchor() {
            anchor = nil
            guard !following, let scroll, let doc = scroll.documentView, doc.isFlipped else { return }
            let visible = scroll.documentVisibleRect
            // The tracker and its ancestors span the whole transcript; they say nothing about position.
            var excluded = Set<ObjectIdentifier>()
            var chain: NSView? = self
            while let view = chain, view !== doc { excluded.insert(ObjectIdentifier(view)); chain = view.superview }
            // Selectable message text is backed by text fields; prefer them, else any view that moves with the content.
            var bestText: (view: NSView, frame: NSRect)?
            var bestAny: (view: NSView, frame: NSRect)?
            func closer(_ frame: NSRect, than other: (view: NSView, frame: NSRect)?) -> Bool {
                other.map { abs(frame.minY - visible.minY) < abs($0.frame.minY - visible.minY) } ?? true
            }
            var pending = doc.subviews
            while let view = pending.popLast() {
                pending += view.subviews
                guard !view.isHidden, !excluded.contains(ObjectIdentifier(view)) else { continue }
                let frame = view.convert(view.bounds, to: doc)
                guard frame.height > 0, frame.width > 0, frame.maxY > visible.minY, frame.minY < visible.maxY else { continue }
                if view is NSTextField, closer(frame, than: bestText) { bestText = (view, frame) }
                if closer(frame, than: bestAny) { bestAny = (view, frame) }
            }
            guard let best = bestText ?? bestAny else { return }
            anchor = best.view
            anchorOffset = visible.minY - best.frame.minY
            anchorHeight = best.frame.height
        }
        private func geometryChanged() {
            guard !adjusting, let scroll, let doc = scroll.documentView else { return }
            let size = scroll.contentView.bounds.size
            let resized = size != viewport || doc.frame.width != contentWidth
            guard resized || doc.frame.height != contentHeight else { return }
            viewport = size
            contentWidth = doc.frame.width
            contentHeight = doc.frame.height
            if following && !resized { follow(); return }
            keepPlace()
            // Wrapping may settle in a later layout pass; check once more after it.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(keepPlace), object: nil)
            perform(#selector(keepPlace), with: nil, afterDelay: 0)
        }
        /// The transcript only got taller or shorter at the latest message: stay at the bottom,
        /// right away unless the bottom was already followed within the last tenth of a second.
        private func follow() {
            let wait = lastFollow + 0.1 - ProcessInfo.processInfo.systemUptime
            if wait <= 0 { followNow() }
            else if !followPending { followPending = true; perform(#selector(followNow), with: nil, afterDelay: wait) }
        }
        @objc private func followNow() {
            followPending = false
            // The person may have scrolled away while this waited.
            guard following else { return }
            lastFollow = ProcessInfo.processInfo.systemUptime
            keepPlace()
        }
        @objc private func keepPlace() {
            guard let scroll, let doc = scroll.documentView else { return }
            let clip = scroll.contentView
            let bottom = max(0, doc.frame.height - clip.bounds.height)
            var y: CGFloat
            if following {
                y = doc.isFlipped ? bottom : 0
            } else if let anchor, doc.isFlipped, anchor.isDescendant(of: doc) {
                let frame = anchor.convert(anchor.bounds, to: doc)
                // Inside a block that rewrapped, keep the same share of it above the visible top.
                let offset = anchorOffset > 0 && anchorHeight > 0 ? anchorOffset * frame.height / anchorHeight : anchorOffset
                y = frame.minY + offset
            } else { return }
            y = min(max(0, y), bottom)
            guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
            adjusting = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            adjusting = false
        }
        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            NSObject.cancelPreviousPerformRequests(withTarget: self)
            followPending = false
            scroll = nil
            anchor = nil
        }
    }
}
