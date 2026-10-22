import SwiftUI
import KnarrCore

/// Compact project-page issue card; the home uses IntegratedIssueCard instead.
/// Surface with a thin line; sunken under the pointer; selection gets an accent outline.
struct PanelCard: View {
    let issue: Issue
    /// Someone on this Issue is waiting for the person's answer.
    var asking = false
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: K.s2) {
                Text(issue.title).font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IssueMeta(issue: issue, asking: asking)
            }
            .padding(K.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? K.sunken : K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
            .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(selected ? K.accent : K.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
