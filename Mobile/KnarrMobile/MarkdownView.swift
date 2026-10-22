import KnarrText
import SwiftUI
import UIKit

/// Stallari's Markdown on the phone: the Mac's block parser (`MarkdownBlocks`) and code colors (`CodeTokens`),
/// laid out for a narrow screen. Wide code and tables scroll sideways instead of wrapping.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 16

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlocks.parse(text), size: size)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bold and italic as written, `code` on a faint chip, links in blue.
    static func inline(_ s: String, size: CGFloat) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: s, options: options) else { return Text(s) }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: size - 1.5, design: .monospaced)
                attributed[run.range].foregroundColor = Palette.codeInk
                attributed[run.range].backgroundColor = Palette.codeChip
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Palette.blue
                attributed[run.range].underlineStyle = .single
            }
        }
        return Text(attributed)
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block, first: index == 0)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownView.inline(text, size: size)
                .font(.system(size: size + [4, 2, 1][max(0, min(2, level - 1))], weight: level == 1 ? .bold : .semibold))
                .padding(.top, first ? 0 : 6)
        case .paragraph(let text):
            MarkdownView.inline(text, size: size).font(.system(size: size)).lineSpacing(size * 0.25)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                markerView(marker).frame(minWidth: 14, alignment: .trailing)
                MarkdownView.inline(text, size: size).font(.system(size: size)).lineSpacing(size * 0.2)
                    .strikethrough(marker == .task(done: true), color: Palette.faint)
                    .foregroundStyle(marker == .task(done: true) ? Palette.muted : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
            .padding(.top, -size * 0.3)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text, size: size)
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, size: size)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.lineStrong).frame(width: 3)
                MarkdownBlocksView(blocks: inner, size: size).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 8).padding(.leading, 8).padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8))
        case .callout(let kind, let title, let folded, let body):
            CalloutView(kind: kind, title: title, startsFolded: folded, blocks: body, size: size)
        case .divider:
            Rectangle().fill(Palette.lineStrong).frame(height: 1).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func markerView(_ marker: ListMarker) -> some View {
        switch marker {
        case .bullet:
            Circle().fill(Palette.muted).frame(width: 5, height: 5).offset(y: -size * 0.2)
        case .number(let n):
            Text(n).font(.system(size: size).monospacedDigit()).foregroundStyle(Palette.muted)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: size)).foregroundStyle(done ? Palette.green : Palette.faint)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    let size: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption.weight(.medium)).foregroundStyle(Palette.faint)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption).foregroundStyle(copied ? Palette.green : Palette.muted)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("코드 복사")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: true) {
                highlighted
                    .font(.system(size: size - 3, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .textSelection(.enabled)
            }
        }
        .background(Palette.codeBlock, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }

    private var highlighted: Text {
        CodeTokens.tokenize(code, language: language).reduce(Text("")) { text, token in
            let piece = Text(token.text)
            switch token.kind {
            case .plain: return text + piece.foregroundColor(Palette.ink)
            case .keyword: return text + piece.foregroundColor(Palette.synKeyword).fontWeight(.medium)
            case .string: return text + piece.foregroundColor(Palette.synString)
            case .number: return text + piece.foregroundColor(Palette.synNumber)
            case .comment: return text + piece.foregroundColor(Palette.faint).italic()
            case .added: return text + piece.foregroundColor(Palette.green)
            case .removed: return text + piece.foregroundColor(Palette.red)
            }
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
    let size: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in cell(header[c], column: c).fontWeight(.semibold).background(Palette.sunken) }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Rectangle().fill(Palette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], column: c) }
                    }
                }
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.lineStrong))
            .padding(1)
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: .leading; case .center: .center; case .trailing: .trailing
        }
        return CappedWidth(maximum: 240) {
            MarkdownView.inline(text, size: size - 1).font(.system(size: size - 1)).lineSpacing(2)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .overlay(alignment: .leading) { if column > 0 { Rectangle().fill(Palette.line).frame(width: 1) } }
    }
}

struct CalloutView: View {
    let kind: CalloutKind
    let title: String?
    let blocks: [MarkdownBlock]
    let size: CGFloat
    let foldable: Bool
    @State private var folded: Bool

    init(kind: CalloutKind, title: String?, startsFolded: Bool, blocks: [MarkdownBlock], size: CGFloat) {
        self.kind = kind; self.title = title; self.blocks = blocks; self.size = size
        foldable = startsFolded
        _folded = State(initialValue: startsFolded)
    }

    var body: some View {
        let style = Self.style(kind)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(style.fg).padding(.top, 1)
            VStack(alignment: .leading, spacing: size * 0.5) {
                if let title {
                    let heading = MarkdownView.inline(title, size: size).font(.system(size: size, weight: .semibold)).foregroundStyle(Palette.ink)
                    if canFold {
                        Button { withAnimation(.snappy) { folded.toggle() } } label: {
                            HStack(spacing: 6) {
                                heading
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.faint)
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
                if !(canFold && folded) { MarkdownBlocksView(blocks: blocks, size: size) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.bg, in: RoundedRectangle(cornerRadius: 10))
    }

    private var canFold: Bool { foldable && title != nil && !blocks.isEmpty }

    static func style(_ kind: CalloutKind) -> (symbol: String, fg: Color, bg: Color) {
        switch kind {
        case .info: ("info.circle.fill", Palette.blue, Palette.blueSoft)
        case .result: ("checkmark.circle.fill", Palette.green, Palette.greenSoft)
        case .decide: ("hand.raised.fill", Palette.red, Palette.redSoft)
        case .stop: ("exclamationmark.triangle.fill", Palette.amber, Palette.amberSoft)
        }
    }
}

/// Natural width up to `maximum`, then wraps; the height follows the wrapped text.
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
