import AppKit
import SwiftUI
import KnarrCore

/// A status mark, 18pt high: a small dot and a word on a very light wash of the same meaning.
struct Badge: View {
    let text: String
    let fg: Color
    let bg: Color
    var dot = true

    var body: some View {
        HStack(spacing: K.s1) {
            if dot { Circle().fill(fg).frame(width: K.dot, height: K.dot) }
            ZStack { Text(text).id(text).transition(.textSwap) }
                .font(K.caption.weight(.medium)).lineLimit(1)
                .foregroundStyle(fg)
                .animation(Motion.textSwap, value: text)
        }
        .padding(.horizontal, K.s2)
        .frame(height: K.badgeHeight)
        .background(bg, in: RoundedRectangle(cornerRadius: K.rSmall))
        .fixedSize()
    }
}

struct IssueStatusBadge: View {
    let issue: Issue
    var hasPendingQuestion = false

    var body: some View {
        // The status itself carries "답변 필요"; a second badge would repeat it. A judged issue
        // names how many criteria failed, matching the detail and the status line.
        let status = issue.presentationStatus(hasPendingQuestion: hasPendingQuestion)
        Badge(text: status == .unmet && issue.unmetCount > 0 ? issue.statusLine : status.title,
              fg: status.tint.fg, bg: status.tint.bg)
    }
}

/// A neutral chip: a thin outline, no fill.
struct ProjectChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(K.caption.weight(.medium))
            .foregroundStyle(K.muted)
            .padding(.horizontal, K.s2)
            .frame(height: K.badgeHeight)
            .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.line))
    }
}

/// The two quiet rows an issue card shows under its title: who is alive, and how far along.
struct IssueMeta: View {
    let issue: Issue
    /// Someone on this issue is waiting for the person's answer.
    var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            HStack(spacing: K.s2) {
                IssueStatusBadge(issue: issue, hasPendingQuestion: asking)
                LivenessLabel { issue.liveness(now: $0) }
                Spacer(minLength: 0)
            }
            HStack(spacing: K.s2) {
                if !issue.allSteps.isEmpty { StepBar(steps: issue.allSteps) }
                else { Spacer(minLength: 0) }
                Text(IssueCards.acceptanceSummary(for: issue))
                    .font(K.caption).foregroundStyle(K.faint).monospacedDigit().fixedSize()
                    .contentTransition(.numericText()).animation(Motion.numberPop, value: issue.metCriteria)
            }
        }
    }
}

/// Thin segmented bar, one segment per step. The active segment breathes.
struct StepBar: View {
    let steps: [HirdStep]
    var labels = false

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: K.s1) {
                    Segment(color: step.state.colors.bar, breathing: step.state == .active)
                    if labels {
                        Text(step.state.mark.isEmpty ? step.title : "\(step.state.mark) \(step.title)")
                            .font(K.caption)
                            .foregroundStyle(step.state.colors.fg)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private struct Segment: View {
        let color: Color
        let breathing: Bool
        var body: some View {
            if breathing {
                // Core Animation runs this in the render server, so the app does not redraw every frame.
                PulseLayer(kind: .breathe).frame(height: K.bar)
            } else {
                Capsule().fill(color).frame(height: K.bar)
            }
        }
    }
}

/// "● 활동 4초 전", "12분째 조용함", "사람 기다림 · 3분": the dot carries the meaning, the words stay quiet. Ticks every second.
struct LivenessLabel: View {
    /// Words end at the right edge, the dot just before them, for a label that closes a row.
    var trailing = false
    let compute: (Date) -> Liveness?

    var body: some View {
        NativeLivenessLabel(compute: compute, trailing: trailing).fixedSize()
    }

    static func present(_ l: Liveness) -> (text: String, dot: Color, ink: Color, pulsing: Bool) {
        switch l {
        case .active(let s): ("활동 \(s)초 전", K.accent, K.muted, true)
        case .quiet(let m): ("\(m)분째 조용함", K.faint, K.faint, false)
        case .waitingOnHuman(let m): (m > 0 ? "사람 기다림 · \(m)분" : "사람 기다림", K.amber, K.amber, false)
        case .stopped(let at): ("\(at.formatted(date: .omitted, time: .shortened)) 중단", K.red, K.red, false)
        case .finished(let at): ("\(at.formatted(date: .omitted, time: .shortened)) 끝남", K.green, K.muted, false)
        }
    }
}

/// Updating the clock directly in AppKit keeps a one-second label tick out of
/// SwiftUI's whole-transcript layout. Terminal labels do not schedule a timer.
private struct NativeLivenessLabel: NSViewRepresentable {
    let compute: (Date) -> Liveness?
    var trailing = false
    func makeNSView(context: Context) -> ClockLabel { ClockLabel() }
    func updateNSView(_ view: ClockLabel, context: Context) { view.trailing = trailing; view.configure(compute: compute) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClockLabel, context: Context) -> CGSize? { nsView.intrinsicContentSize }
    static func dismantleNSView(_ view: ClockLabel, coordinator: ()) { view.stop() }

    final class ClockLabel: NSView {
        private let text = NSTextField(labelWithString: "")
        private let dot = CALayer()
        private var timer: Timer?
        private var compute: (Date) -> Liveness? = { _ in nil }
        private var measured = NSSize.zero
        var trailing = false { didSet { text.alignment = trailing ? .right : .left; needsLayout = true } }
        /// Space a label cell keeps on each side of its words.
        private let cellInset: CGFloat = 2
        /// Dot, then a gap, then the words.
        private let textInset = K.dot + K.s2
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            text.lineBreakMode = .byTruncatingTail
            text.maximumNumberOfLines = 1
            text.font = K.nsCaptionDigits
            addSubview(text); layer?.addSublayer(dot)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: NSSize { measured }
        override func layout() {
            super.layout()
            text.frame = NSRect(x: textInset, y: 0, width: max(0, bounds.width - textInset), height: bounds.height)
            var dotX: CGFloat = 0
            if trailing {
                let words = ceil((text.stringValue as NSString).size(withAttributes: [.font: K.nsCaptionDigits]).width)
                dotX = max(0, bounds.width - cellInset - words - textInset - cellInset)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.frame = CGRect(x: dotX, y: max(0, (bounds.height - K.dot) / 2), width: K.dot, height: K.dot)
            dot.cornerRadius = K.dot / 2
            CATransaction.commit()
        }
        func configure(compute: @escaping (Date) -> Liveness?) {
            self.compute = compute
            let value = compute(.now)
            let initial = value.map { LivenessLabel.present($0).text } ?? ""
            var candidates = [initial]
            if let value {
                switch value {
                case .active, .quiet: candidates += ["활동 59초 전", "999분째 조용함"]
                case .waitingOnHuman: candidates += ["사람 기다림 · 999분"]
                default: break
                }
            }
            let font = K.nsCaptionDigits
            let next = NSSize(width: initial.isEmpty ? 0 : textInset + K.s2 + ceil(candidates.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0),
                              height: ceil(font.ascender - font.descender) + 2)
            if measured != next { measured = next; invalidateIntrinsicContentSize() }
            tick()
            scheduleIfNeeded()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } else { tick(); scheduleIfNeeded() } }
        func stop() { timer?.invalidate(); timer = nil }
        private func scheduleIfNeeded() {
            guard window != nil, timer == nil, let value = compute(.now) else { return }
            switch value { case .finished, .stopped: return; default: break }
            let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            t.tolerance = 0.2; timer = t; RunLoop.main.add(t, forMode: .common)
        }
        @objc private func tick() {
            guard let value = compute(.now) else { text.stringValue = ""; stop(); return }
            let presentation = LivenessLabel.present(value)
            if text.stringValue != presentation.text { text.stringValue = presentation.text; if trailing { needsLayout = true } }
            text.textColor = NSColor(presentation.ink)
            setAccessibilityLabel(presentation.text)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.backgroundColor = NSColor(presentation.dot).cgColor
            CATransaction.commit()
            if presentation.pulsing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if dot.animation(forKey: "pulse") == nil {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 1; animation.toValue = 0.45; animation.duration = 1
                    animation.autoreverses = true; animation.repeatCount = .infinity
                    dot.add(animation, forKey: "pulse")
                }
            } else { dot.removeAnimation(forKey: "pulse") }
            switch value { case .finished, .stopped: stop(); default: break }
        }
    }
}

/// The looping animation of the active step bar segment, done with Core Animation.
/// Drawn in the accent, the only state that animates.
struct PulseLayer: NSViewRepresentable {
    enum Kind { case breathe, ring }
    enum Tint { case accent, amber }
    let kind: Kind
    var tint: Tint = .accent

    func makeNSView(context: Context) -> PulseView { PulseView(kind: kind, tint: tint) }
    func updateNSView(_ view: PulseView, context: Context) { view.tint = tint }

    final class PulseView: NSView {
        private let kind: Kind
        var tint: Tint {
            didSet { if tint != oldValue { needsDisplay = true } }
        }
        private let base = CALayer()
        private let ring = CALayer()

        init(kind: Kind, tint: Tint) {
            self.kind = kind
            self.tint = tint
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(ring)
            layer?.addSublayer(base)
            layer?.masksToBounds = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var wantsUpdateLayer: Bool { true }

        override func layout() {
            super.layout()
            base.frame = bounds
            base.cornerRadius = min(bounds.width, bounds.height) / 2
            ring.frame = bounds
            ring.cornerRadius = base.cornerRadius
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func updateLayer() {
            var accent = NSColor.controlAccentColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                accent = (tint == .amber ? K.nsAmber : K.nsAccent).cgColor
            }
            base.backgroundColor = accent
            ring.backgroundColor = accent
            ring.isHidden = kind != .ring
            if kind == .breathe, base.animation(forKey: "breathe") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.45
                a.duration = 0.9
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                base.add(a, forKey: "breathe")
            }
            if kind == .ring, ring.animation(forKey: "ring") == nil {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1
                scale.toValue = 2.6
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.45
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 1.6
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.add(group, forKey: "ring")
            }
        }
    }
}

/// The app's one button. `primary` is ink with onInk text, `destructive` is the only red one.
struct KButton: View {
    enum Style { case primary, plain, link, destructive }
    let title: String
    var style: Style = .plain
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(K.secondary.weight(style == .link ? .regular : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, style == .link ? 2 : K.s3)
                .frame(minHeight: style == .link ? 0 : K.controlHeight)
                .background {
                    switch style {
                    case .primary: RoundedRectangle(cornerRadius: K.rSmall).fill(K.ink).opacity(hovering ? 0.85 : 1)
                    case .plain, .destructive:
                        RoundedRectangle(cornerRadius: K.rSmall).fill(hovering ? K.sunken : K.surface)
                            .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                    case .link: Color.clear
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && enabled }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch style {
        case .primary: K.onInk
        case .plain: K.ink
        case .link: K.accent
        case .destructive: K.red
        }
    }
}

/// An attachment as a small chip above a message or inside the composer: icon, file name, thin outline.
struct AttachmentChip: View {
    let url: URL
    var preview: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: K.s1) {
            Button { preview?() } label: {
                HStack(spacing: K.s1) {
                    Image(systemName: ConversationView.isImage(url) ? "photo" : "doc").foregroundStyle(K.faint)
                    Text(url.lastPathComponent).foregroundStyle(K.ink).lineLimit(1).truncationMode(.middle)
                }
                .font(K.caption)
            }
            .buttonStyle(.plain).help("첨부 미리보기")
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(K.caption.weight(.medium)).foregroundStyle(K.faint) }
                    .buttonStyle(.plain).accessibilityLabel("\(url.lastPathComponent) 첨부 제거")
            }
        }
        .padding(.horizontal, K.s2)
        .frame(height: K.controlHeight)
        .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.line))
        .frame(maxWidth: 200)
    }
}

/// A child at the trailing edge, no wider than `fraction` of the row; a short child keeps its natural width.
struct TrailingFraction: Layout {
    var fraction: CGFloat = 0.75

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let size = child.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// Two columns of facts: a faint key, its value. Replaces stacked "key · value" lines.
struct KeyValueRows: View {
    let rows: [(key: String, value: String, mono: Bool)]

    init(_ rows: [(String, String)]) { self.rows = rows.map { ($0.0, $0.1, false) } }
    init(mono rows: [(String, String)]) { self.rows = rows.map { ($0.0, $0.1, true) } }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: K.s4, verticalSpacing: K.s2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.key).font(K.secondary).foregroundStyle(K.faint).frame(width: K.s6 * 2 + K.s2, alignment: .leading)
                    Text(row.value).font(row.mono ? K.mono : K.secondary).foregroundStyle(K.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let next = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if next > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur = (cur.items + [i], next, max(cur.height, s.height))
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
