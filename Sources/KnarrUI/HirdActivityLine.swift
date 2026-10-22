import SwiftUI
import KnarrCore

/// One line for what a Hird is doing now: a small state icon, the line, and how long it has been so.
/// Thinking and writing breathe subtly; Reduce Motion renders the same line still.
struct HirdActivityLine: View {
    let activity: HirdActivity
    /// Compact form for issue cards: no relative time.
    var showsTime = true
    /// The clock the relative time is read against; a ticking container passes its own date.
    var now: Date = .now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStreaming: Bool { activity.kind == .thinking || activity.kind == .writing }

    var body: some View {
        HStack(spacing: K.s2) {
            Image(systemName: Self.symbol(activity.kind))
                .font(K.caption)
                .foregroundStyle(isStreaming ? K.accent : K.faint)
                .frame(width: K.badgeHeight)
                .accessibilityHidden(true)
            if isStreaming, !reduceMotion {
                ShimmerText(text: activity.displayText, font: K.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text(activity.displayText)
                    .font(K.secondary)
                    .foregroundStyle(activity.kind == .waitingQuestion ? K.amber : K.ink)
                    .lineLimit(1).truncationMode(.middle)
            }
            if showsTime {
                Text(activity.relativeLabel(now: now))
                    .font(K.caption).foregroundStyle(K.faint).fixedSize()
            }
            Spacer(minLength: 0)
        }
        // One label for the row: the shimmer draws the same text twice, which would otherwise read twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.displayText)
        .accessibilityValue(showsTime ? activity.relativeLabel(now: now) : "")
        .accessibilityIdentifier("hird-activity")
    }

    static func symbol(_ kind: HirdActivity.Kind) -> String {
        switch kind {
        case .thinking: "brain"
        case .writing: "text.alignleft"
        case .read: "doc.text"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .command: "terminal"
        case .subagents: "person.2"
        case .waitingQuestion: "questionmark.circle"
        case .idle: "pause.circle"
        }
    }
}

/// The newest lines under the current one, back to back with no card inside a card.
struct HirdActivityHistory: View {
    let lines: [HirdActivity]
    let limit: Int

    var body: some View {
        let shown = Array(lines.dropFirst().prefix(limit))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: K.s1) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    HStructuredActivityRow(activity: line)
                }
            }
        }
    }
}

private struct HStructuredActivityRow: View {
    let activity: HirdActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { clock in
            HStack(spacing: K.s2) {
                Image(systemName: HirdActivityLine.symbol(activity.kind))
                    .font(K.caption).foregroundStyle(K.faint)
                    .frame(width: K.badgeHeight)
                    .accessibilityHidden(true)
                Text(activity.displayText)
                    .font(K.caption).foregroundStyle(K.muted)
                    .lineLimit(1).truncationMode(.middle)
                Text(activity.relativeLabel(now: clock.date))
                    .font(K.caption).foregroundStyle(K.faint).fixedSize()
                Spacer(minLength: 0)
            }
        }
    }
}
