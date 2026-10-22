import ActivityKit
import KnarrSync
import SwiftUI
import WidgetKit

@main
struct KnarrActivityWidgetBundle: WidgetBundle {
    var body: some Widget { KnarrActivityWidget() }
}

struct KnarrActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KnarrActivityAttributes.self) { context in
            ActivityCard(value: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.state.url)
        } dynamicIsland: { context in
            let value = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Knarr", systemImage: value.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(value.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityCount(value: value).font(.caption.weight(.medium))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(value.title).font(.headline).lineLimit(1)
                        Text(context.isStale ? "최근 상태 확인이 필요해요" : value.detail)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 5)
                }
            } compactLeading: {
                Image(systemName: value.symbol).foregroundStyle(value.tint)
            } compactTrailing: {
                Text(value.compactLabel).font(.caption2.weight(.semibold)).foregroundStyle(value.tint)
            } minimal: {
                Image(systemName: value.symbol).foregroundStyle(value.tint)
            }
            .widgetURL(value.url)
            .keylineTint(value.tint)
        }
    }
}

private struct ActivityCard: View {
    let value: LiveActivitySummary
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Knarr", systemImage: value.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(value.tint)
                Spacer()
                ActivityCount(value: value).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value.title).font(.headline).lineLimit(2)
                Text(stale ? "최근 상태 확인이 필요해요" : value.detail)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if value.status == .running && !stale {
                HStack(spacing: 4) {
                    Text(value.startedAt, style: .timer).monospacedDigit().frame(width: 70, alignment: .leading)
                    Text("경과")
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityCount: View {
    let value: LiveActivitySummary
    var body: some View {
        if value.isFinished {
            Text(value.status == .completed ? "완료" : "종료")
        } else if value.attentionCount > 0 {
            Text(value.runningCount > 0 ? "진행 \(value.runningCount) · 확인 \(value.attentionCount)" : "확인 \(value.attentionCount)개")
        }
    }
}

private extension LiveActivitySummary {
    var symbol: String {
        switch status {
        case .running: "circle.dotted"
        case .needsInput: "questionmark.bubble.fill"
        case .review: "doc.text.magnifyingglass"
        case .stopped: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .ended: "stop.circle"
        }
    }
    var tint: Color {
        switch status {
        case .running: .blue
        case .needsInput, .review: .orange
        case .stopped: .red
        case .completed: .green
        case .ended: .secondary
        }
    }
    var compactLabel: String {
        switch status {
        case .needsInput: "답변"
        case .review: "확인"
        case .stopped: "멈춤"
        case .completed: "완료"
        case .ended: "종료"
        case .running: "\(runningCount)"
        }
    }
}
