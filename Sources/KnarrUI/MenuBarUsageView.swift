import AppKit
import SwiftUI
import KnarrCore

// Ported from JitdeckApp/MenuBarUsageView.swift. Both entry points share this detail surface.
public struct MenuBarUsageView: View {
    let usage: SubscriptionUsageModel
    public init(usage: SubscriptionUsageModel) { self.usage = usage }
    public var body: some View {
        VStack(alignment: .leading, spacing: K.s4) {
            HStack {
                Text("구독 한도").font(K.title)
                Spacer()
                Text("남은 사용량").font(K.caption).foregroundStyle(K.muted)
            }
            ForEach(usage.details, id: \.name) { detail in
                VStack(alignment: .leading, spacing: K.s2) {
                    Label(detail.name, systemImage: detail.name == "Claude" ? "asterisk" : "terminal")
                        .font(K.body.weight(.semibold))
                    if detail.windows.isEmpty {
                        Text("사용량 확인 불가").font(K.secondary).foregroundStyle(K.muted)
                    }
                    ForEach(detail.windows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: K.s1) {
                            HStack {
                                Text(row.label).foregroundStyle(K.muted)
                                Spacer()
                                Text(row.text.percentText).monospacedDigit()
                            }.font(K.secondary)
                            if let left = row.remainingPercent {
                                ProgressView(value: left, total: 100).tint(left <= 20 ? K.amber : K.muted)
                                    .accessibilityLabel("\(detail.name) \(row.label) 남은 한도")
                                    .accessibilityValue("\(Int(left.rounded()))퍼센트")
                            }
                            Text(row.text.resetText).font(K.caption).foregroundStyle(K.muted)
                        }
                    }
                    Text(detail.updatedText).font(K.caption).foregroundStyle(K.faint)
                    if detail.name == "Claude" {
                        Text((usage.claude?.accountCount ?? 1) > 1 ? "OMP 구독 계정별로 보고된 한도 중 가장 빠듯한 값" : "OMP가 확인한 Anthropic 구독 한도")
                            .font(K.caption).foregroundStyle(K.muted)
                    }
                }
            }
            Divider().overlay(K.line)
            Button { usage.requestRefresh(.manual) } label: {
                Label(usage.refreshing ? "확인 중…" : "지금 새로고침", systemImage: "arrow.clockwise")
                    .font(K.secondary)
            }
            .buttonStyle(.plain).foregroundStyle(K.accent).disabled(usage.refreshing)
            .accessibilityIdentifier("usage-refresh")
        }
        .padding(K.s4).frame(width: 310, alignment: .leading)
        .background(K.surface).foregroundStyle(K.ink)
        .task(id: ObjectIdentifier(usage)) { await usage.refresh(.detailOpened) }
    }
}

/// A small labeled meter: "Claude 76%" and a thin bar filled to that share. Never a bare number.
struct UsageMeter: View {
    let label: String
    let value: String
    /// The share the bar fills, nil when the reading is missing.
    let fraction: Double?
    /// Close to the limit: the bar turns amber.
    var warn = false
    /// An old reading: the words go fainter.
    var stale = false

    var body: some View {
        HStack(spacing: K.s2) {
            Text("\(label) \(value)").font(K.caption).monospacedDigit().foregroundStyle(stale ? K.faint : K.muted)
            ZStack(alignment: .leading) {
                Capsule().fill(K.lineStrong)
                if let fraction { Capsule().fill(warn ? K.amber : K.muted).frame(width: K.s6 * min(1, max(0, fraction))) }
            }
            .frame(width: K.s6, height: K.bar)
        }
        .fixedSize()
    }

    /// A subscription headline: "76%" fills 76%, "~76%" is an old reading, "--" and "초기화" have no share to show.
    static func parse(headline: String) -> (value: String, fraction: Double?, stale: Bool) {
        let stale = headline.hasPrefix("~")
        let text = stale ? String(headline.dropFirst()) : headline
        guard text.hasSuffix("%"), let percent = Double(text.dropLast()) else { return (text, nil, stale) }
        return (text, percent / 100, stale)
    }

    static func provider(_ name: String, headline: String) -> UsageMeter {
        let parsed = parse(headline: headline)
        return UsageMeter(label: name, value: parsed.value, fraction: parsed.fraction,
                          warn: (parsed.fraction ?? 1) <= 0.2, stale: parsed.stale)
    }

    /// Context is a fill meter: 98% means almost full.
    static func context(_ usage: ContextUsage) -> UsageMeter {
        UsageMeter(label: "컨텍스트", value: "\(Int((usage.fraction * 100).rounded()))%", fraction: usage.fraction, warn: usage.fraction > 0.85)
    }
}

/// The header's usage meters. Opens the full quota detail; the tooltip carries the numbers behind each bar.
public struct UsageSummaryButton: View {
    let usage: SubscriptionUsageModel
    var context: ContextUsage?
    @State private var showing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(usage: SubscriptionUsageModel, context: ContextUsage? = nil) { self.usage = usage; self.context = context }
    public var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: K.s3) {
                ForEach(usage.headlines, id: \.provider) { item in
                    UsageMeter.provider(item.provider == .claude ? "Claude" : "Codex", headline: item.text)
                }
                if let context { UsageMeter.context(context) }
            }
            .fixedSize(horizontal: true, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("구독 사용량 상세")
        .accessibilityValue(usage.headlines.map { "\($0.provider.rawValue) \($0.text) 남음" }.joined(separator: ", "))
        .accessibilityIdentifier("usage-summary")
        .popover(isPresented: $showing, arrowEdge: .bottom) { MenuBarUsageView(usage: usage) }
        .animation(reduceMotion ? nil : (showing ? Motion.popOpen : Motion.popClose), value: showing)
    }

    private var tooltip: String {
        var lines = usage.details.flatMap { detail in
            [detail.name] + detail.windows.map { "  \($0.label) \($0.text.percentText) · \($0.text.resetText)" }
        }
        if let context {
            lines += ["컨텍스트", "  \(context.tokens.formatted()) / \(context.capacity.formatted()) 토큰 · \(max(0, context.capacity - context.tokens).formatted()) 토큰 남음"]
        }
        return (["구독 한도는 남은 사용량이에요. 눌러서 자세히 보기"] + lines).joined(separator: "\n")
    }
}

private struct UsageHeadlinePairs: View {
    let headlines: [MenuBarUsageHeadline]
    var body: some View {
        HStack(spacing: K.s2) {
            ForEach(headlines, id: \.provider) { item in
                HStack(spacing: K.s1) {
                    Image(systemName: item.provider == .claude ? "asterisk" : "terminal")
                    Text(item.text).monospacedDigit()
                }
                .font(K.secondary.weight(.medium))
            }
        }.fixedSize(horizontal: true, vertical: true)
    }
}

/// Jitdeck's template-image label retains both provider icon/percentage pairs in MenuBarExtra.
public struct MenuBarUsageLabel: View {
    let usage: SubscriptionUsageModel
    public init(usage: SubscriptionUsageModel) { self.usage = usage }
    public var body: some View {
        Image(nsImage: Self.render(usage.headlines))
            .accessibilityLabel("Knarr 구독 한도")
            .accessibilityValue(usage.headlines.map { "\($0.provider.rawValue) \($0.text) 남음" }.joined(separator: ", "))
    }
    @MainActor public static func render(_ headlines: [MenuBarUsageHeadline]) -> NSImage {
        let renderer = ImageRenderer(content: UsageHeadlinePairs(headlines: headlines).foregroundStyle(K.templateInk))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
