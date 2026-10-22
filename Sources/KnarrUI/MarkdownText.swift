import AppKit
import SwiftUI
import KnarrCore

/// Two sizes of running text: the chat body, and the denser secondary step used in notices and details.
enum TextScale: Equatable {
    case body, secondary

    var font: Font { self == .body ? K.body : K.secondary }
    /// Chat body gets a line height of about 1.45 × the size.
    var lineSpacing: CGFloat { self == .body ? K.bodyLineSpacing : K.s1 / 2 }
    var blockSpacing: CGFloat { self == .body ? K.s3 : K.s2 }
}

/// Stallari's Markdown, styled like a document: blocks from `MarkdownBlocks`,
/// inline marks via `AttributedString`, code colored by `CodeTokens`.
struct MarkdownText: View, Equatable {
    let text: String
    var scale: TextScale = .body

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlocks.parse(text), scale: scale)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown: bold/italic as written, `code` on a faint chip in the mono step, links in the accent.
    static func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: s, options: options) else { return Text(s) }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = K.mono
                attributed[run.range].foregroundColor = K.ink
                attributed[run.range].backgroundColor = K.codeChip
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = K.accent
                attributed[run.range].underlineStyle = .single
            }
        }
        return Text(attributed)
    }
}

struct MarkdownBlocksView: View, Equatable {
    let blocks: [MarkdownBlock]
    let scale: TextScale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, scale: scale, first: index == 0).equatable()
            }
        }
    }

}

/// Stable completed blocks keep their inline attributed text and nested view state
/// while a later streaming block changes. See the pinned MarkdownUI/Streamdown references.
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let scale: TextScale
    let first: Bool

    @ViewBuilder var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownText.inline(text)
                .font(level <= 2 ? K.title : K.body.weight(.semibold))
                .padding(.top, first ? 0 : [K.s4, K.s3, K.s2][min(level, 3) - 1])
        case .paragraph(let text):
            MarkdownText.inline(text).font(scale.font).lineSpacing(scale.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                markerView(marker).frame(minWidth: K.s4, alignment: .trailing)
                MarkdownText.inline(text).font(scale.font).lineSpacing(scale.lineSpacing)
                    .strikethrough(marker == .task(done: true), color: K.faint)
                    .foregroundStyle(marker == .task(done: true) ? K.muted : K.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * K.s4 + (level > 0 ? K.s1 : 0))
            .padding(.top, -K.s1)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows)
        case .quote(let inner):
            HStack(alignment: .top, spacing: K.s3) {
                Rectangle().fill(K.lineStrong).frame(width: 2)
                MarkdownBlocksView(blocks: inner, scale: scale).foregroundStyle(K.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        case .callout(let kind, let title, let folded, let body):
            CalloutView(kind: kind, title: title, startsFolded: folded, blocks: body, scale: scale)
        case .divider:
            Rectangle().fill(K.lineStrong).frame(height: 1).padding(.vertical, K.s1)
        }
    }

    @ViewBuilder
    private func markerView(_ marker: ListMarker) -> some View {
        switch marker {
        case .bullet:
            Circle().fill(K.muted).frame(width: K.s1, height: K.s1).offset(y: -2)
        case .number(let n):
            Text(n).font(scale.font.monospacedDigit()).foregroundStyle(K.muted)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(scale.font).foregroundStyle(done ? K.green : K.faint)
        }
    }
}

/// Fixed-width text with syntax colors, the language and a copy button at the top right, and sideways scrolling.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false
    @State private var overCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: K.s3) {
                Spacer()
                Text(language ?? "code").font(K.caption).foregroundStyle(K.faint)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(K.caption).foregroundStyle(copied ? K.green : (overCopy ? K.ink : K.faint))
                }
                .buttonStyle(.plain)
                .onHover { overCopy = $0 }
                .accessibilityLabel("코드 복사")
            }
            .padding(.horizontal, K.s3).padding(.top, K.s2)
            MarkdownHorizontalScroll {
                highlighted
                    .font(K.mono)
                    .lineSpacing(K.s1 / 2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, K.s3).padding(.top, K.s1).padding(.bottom, K.s3)
            }
        }
        .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    private var highlighted: Text {
        CodeTokens.tokenize(code, language: language).reduce(Text("")) { text, token in
            let piece = Text(token.text)
            switch token.kind {
            case .plain: return text + piece.foregroundColor(K.ink)
            case .keyword: return text + piece.foregroundColor(K.synKeyword).fontWeight(.medium)
            case .string: return text + piece.foregroundColor(K.synString)
            case .number: return text + piece.foregroundColor(K.synNumber)
            case .comment: return text + piece.foregroundColor(K.faint).italic()
            case .added: return text + piece.foregroundColor(K.green)
            case .removed: return text + piece.foregroundColor(K.red)
            }
        }
    }
}

/// No box: a lineStrong rule under the header, a faint rule between rows. Narrow tables stretch to the text
/// column; wide ones scroll sideways. Number columns sit on the right.
struct TableBlockView: View {
    let header: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
    /// The text column's width. A zero-height row this wide makes the grid at least that wide:
    /// a narrow table's columns share the extra space, a wider table is untouched and scrolls.
    @State private var columnWidth: CGFloat = 0

    var body: some View {
        MarkdownHorizontalScroll {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { Color.clear.frame(width: columnWidth, height: 0).gridCellColumns(max(1, header.count)) }
                GridRow {
                    ForEach(header.indices, id: \.self) { c in cell(header[c], column: c, header: true) }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Rectangle().fill(r == 0 ? K.lineStrong : K.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], column: c, header: false) }
                    }
                }
            }
            .fixedSize()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
    }

    private func cell(_ text: String, column: Int, header isHeader: Bool) -> some View {
        let alignment: Alignment = switch effectiveAlignment(column) { case .leading: .leading; case .center: .center; case .trailing: .trailing }
        return CappedWidth(maximum: 360) {
            MarkdownText.inline(text)
                .font(isHeader ? K.caption.weight(.semibold) : K.secondary)
                .foregroundStyle(isHeader ? K.muted : K.ink)
                .lineSpacing(K.s1 / 2)
        }
            .padding(.leading, column == 0 ? 0 : K.s3).padding(.trailing, column == header.count - 1 ? 0 : K.s3)
            .padding(.vertical, K.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// A column whose every cell is a number (with a short unit) reads on the right even when the Markdown did not say so.
    private func effectiveAlignment(_ column: Int) -> TableAlignment {
        guard alignments.indices.contains(column) else { return .leading }
        if alignments[column] != .leading { return alignments[column] }
        let cells = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
        let numeric = !cells.isEmpty && cells.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).range(of: #"^[~±+\-]?[0-9][0-9,.]*\s?[%a-zA-Z가-힣]{0,2}$"#, options: .regularExpression) != nil
        }
        return numeric ? .trailing : .leading
    }
}

/// Give the horizontal viewport its document's full height, rather than the
/// initially small vertical ideal size of SwiftUI's nested ScrollView.
private struct MarkdownHorizontalScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> MarkdownHorizontalScrollView {
        MarkdownHorizontalScrollView(content: root)
    }
    func updateNSView(_ scroll: MarkdownHorizontalScrollView, context: Context) {
        scroll.updateContent(root)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownHorizontalScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.documentSize.width, height: nsView.documentSize.height)
    }
    private var root: AnyView {
        AnyView(content.fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(K.ink).textSelection(.enabled).environment(\.colorScheme, colorScheme))
    }
}

/// A gesture chooses one owner until its momentum ends. Phase-less mouse wheels
/// choose independently; an ended touch phase must retain ownership for momentum.
struct MarkdownScrollRouting {
    enum Destination { case transcript, horizontal }
    private var destination: Destination?

    mutating func route(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase,
                        momentum: NSEvent.Phase, overflowing: Bool) -> Destination {
        if phase.contains(.began) || phase.contains(.mayBegin) { destination = nil }
        let phaseLess = phase.isEmpty && momentum.isEmpty
        if phaseLess { destination = nil }
        let chosen = destination ?? (overflowing && abs(dx) > abs(dy) ? .horizontal : .transcript)
        if dx != 0 || dy != 0 { destination = chosen }
        if phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
            destination = nil
        }
        return chosen
    }
}

@MainActor final class MarkdownHorizontalScrollView: NSScrollView {
    private let hosting: NSHostingView<AnyView>
    private var routing = MarkdownScrollRouting()
    private(set) var documentSize: CGSize = .zero

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        scrollerStyle = .overlay
        autohidesScrollers = true
        hosting.sizingOptions = .intrinsicContentSize
        documentView = hosting
        updateContent(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateContent(_ content: AnyView) {
        hosting.rootView = content
        documentSize = hosting.fittingSize
        hosting.setFrameSize(documentSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        hasHorizontalScroller = documentSize.width > contentSize.width + 0.5
        hosting.setFrameSize(documentSize)
    }
    override func scrollWheel(with event: NSEvent) {
        let destination = routing.route(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
            phase: event.phase, momentum: event.momentumPhase,
            overflowing: documentSize.width > contentSize.width + 0.5)
        switch destination {
        case .transcript:
            // NSScrollView also performs per-event axis arbitration. Remove the
            // unused x component so a diagonal momentum event cannot stall y.
            // Keep the original phase, momentum, timestamp and vertical delta.
            if let outer = enclosingScrollView {
                if event.scrollingDeltaX != 0, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY),
                   let cg = event.cgEvent?.copy() {
                    cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
                    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                    outer.scrollWheel(with: NSEvent(cgEvent: cg) ?? event)
                } else {
                    outer.scrollWheel(with: event)
                }
            } else { nextResponder?.scrollWheel(with: event) }
        case .horizontal:
            // AppKit otherwise re-decides the axis on later diagonal/momentum events.
            // Move only x: this viewport never owns vertical scrolling or elasticity.
            let maxX = max(0, documentSize.width - contentSize.width)
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
            contentView.scroll(to: NSPoint(x: min(max(0, contentView.bounds.minX - delta), maxX), y: 0))
            reflectScrolledClipView(contentView)
        }
    }
}

/// A callout: one of four meanings. No fill; a 2pt bar in the meaning's color, a 12pt icon, ink text, and an optional fold.
struct CalloutView: View {
    let kind: CalloutKind
    let title: String?
    let blocks: [MarkdownBlock]
    let scale: TextScale
    /// Declared with `> [!KIND]- title`; plain callouts never fold.
    let foldable: Bool
    @State private var folded: Bool

    init(kind: CalloutKind, title: String?, startsFolded: Bool, blocks: [MarkdownBlock], scale: TextScale) {
        self.kind = kind; self.title = title; self.blocks = blocks; self.scale = scale
        foldable = startsFolded
        _folded = State(initialValue: startsFolded)
    }

    var body: some View {
        let style = Self.style(kind)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(style.fg).frame(width: 2)
            HStack(alignment: .top, spacing: K.s2) {
                Image(systemName: style.symbol)
                    .font(K.secondary)
                    .foregroundStyle(style.fg)
                    .frame(width: K.s4)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: K.s1) {
                    if let title {
                        let heading = MarkdownText.inline(title).font(scale.font.weight(.semibold))
                            .foregroundStyle(K.ink).multilineTextAlignment(.leading)
                        if canFold {
                            Button { folded.toggle() } label: {
                                HStack(spacing: K.s2) {
                                    heading
                                    Image(systemName: "chevron.right")
                                        .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                                        .rotationEffect(.degrees(folded ? 0 : 90))
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            heading
                        }
                    }
                    if !(canFold && folded) {
                        MarkdownBlocksView(blocks: blocks, scale: scale)
                            .transition(.softReveal)
                    }
                }
            }
            .padding(.leading, K.s3).padding(.vertical, K.s1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .animation(Motion.disclosure, value: folded)
    }

    /// A fold needs a title to click and something to hide.
    private var canFold: Bool { foldable && title != nil && !blocks.isEmpty }

    static func style(_ kind: CalloutKind) -> (symbol: String, fg: Color) {
        switch kind {
        case .info: ("info.circle", K.faint)
        case .result: ("checkmark.circle", K.green)
        case .decide: ("questionmark.circle", K.accent)
        case .stop: ("exclamationmark.triangle", K.red)
        }
    }
}

/// Public entry for previews and the snapshot tool.
public struct MarkdownDocument: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        MarkdownText(text: text).padding(K.s5).frame(width: 796, alignment: .topLeading)
            .background(K.surface).foregroundStyle(K.ink)
    }

    /// Every element Stallari may use, for design review.
    public static let showcase = """
    > [!RESULT] `add`를 고쳤고 테스트가 통과했어요
    > 원본 `main`에는 아직 반영하지 않았어요. Stallari가 판정과 통합을 이어가요.

    ## 바뀐 것
    `calc.py`의 **add**가 빼기를 하고 있었어요. 한 줄만 고쳤고 `average`는 그대로예요.

    ```diff
    @@ -1,2 +1,2 @@
     def add(a, b):
    -    return a - b
    +    return a + b
    ```

    ## 확인
    | 확인 | 명령 | 결과 |
    |---|---|:---:|
    | add 테스트 | `python3 -m pytest -q test_calc.py::test_add` | ✓ 통과 |
    | 전체 테스트 | `python3 -m pytest -q` | ✗ 1개 실패 |
    | average 변경 없음 | `git diff -- calc.py` | ✓ |
    | 완료 조건 2 | add 테스트가 있고, 프로젝트 테스트 명령이 종료 코드 0으로 통과한다 — 아직 결과를 기다리는 중이라 판정하지 않았어요 | 대기 |

    > [!INFO]- 실행한 명령 7개
    > - `cat calc.py` · 통과
    > - `python3 -m pytest -q` · 종료 1
    > - `git diff -- calc.py` · 통과

    ### 남은 일
    1. Stallari 판정 · 통합 대기
       - 완료 조건 2의 판정 기록이 아직 없어요
    2. `average([])` 문제는 별도 이슈로
    - [x] add 수정
    - [ ] average 테스트 정리

    > 사용자 요구사항: "average는 건드리지 마." 자세한 기준은 [Knarr 문서](https://example.com/knarr)에 있어요.

    ```swift
    // 판정 근거는 명령 하나짜리 확인만 써요
    let passed = records.filter { $0.isSingleCheck && $0.exitCode == 0 }
    return "\\(passed.count)개 통과"
    ```

    > [!DECIDE] 전체 테스트를 통과시키려면 `average`도 고쳐야 해요
    > 지금 고칠까요, 별도 이슈로 둘까요?
    """
}

/// Natural width up to `maximum`, then wraps; the height follows the wrapped text.
/// (`frame(maxWidth:)` inside a fixed-size grid reports the capped width but the unwrapped height.)
struct CappedWidth: Layout {
    let maximum: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maximum)
        return CGSize(width: width, height: child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
