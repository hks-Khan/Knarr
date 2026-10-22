import KnarrSync
import SwiftUI

struct IssueListView: View {
    @Bindable var store: PhoneStore
    @State private var path: [String] = []
    @State private var projectFilter: String?

    var body: some View {
        NavigationStack(path: $path) { list }
    }

    private var projectNames: [String] {
        Array(Set(store.model.issues.values.map(\.project))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var sections: [MobileClientModel.Section] {
        guard let projectFilter else { return store.model.sections }
        return store.model.sections.compactMap { section in
            let issues = section.issues.filter { $0.project == projectFilter }
            return issues.isEmpty ? nil : MobileClientModel.Section(group: section.group, issues: issues)
        }
    }

    private var list: some View {
        List {
            Section { ConnectionBanner(store: store) }
            Section {
                NavigationLink { DashboardView(store: store, phone: true) } label: {
                    Label("현황 보기", systemImage: "square.grid.2x2")
                }
            }
            if sections.isEmpty, store.connection == .ready {
                ContentUnavailableView(projectFilter == nil ? "지금은 맡긴 이슈가 없어요" : "\(projectFilter!)에 이슈가 없어요",
                                       systemImage: "tray",
                                       description: Text("Stallari 탭에서 요청하면 여기에 이슈가 생겨요."))
            }
            ForEach(sections) { section in
                Section("\(section.group.title) \(section.issues.count)") {
                    ForEach(section.issues) { issue in
                        NavigationLink(value: issue.id) { IssueRow(issue: issue, asking: !store.model.pendingQuestions(for: issue.id).isEmpty) }
                    }
                }
            }
        }
        .navigationTitle("이슈")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("프로젝트", selection: $projectFilter) {
                        Text("모든 프로젝트").tag(String?.none)
                        ForEach(projectNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Image(systemName: projectFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("프로젝트로 거르기: \(projectFilter ?? "모든 프로젝트")")
            }
        }
        .navigationDestination(for: String.self) { id in IssueDetailView(store: store, issueID: id) }
        .refreshable { await store.reload() }
        .onChange(of: store.activityListRequest) { _, _ in
            path = store.openIssue.map { [$0] } ?? []
        }
        .onChange(of: store.openIssue, initial: true) { _, id in
            guard let id else { return }
            path = [id]
            store.openIssue = nil
        }
    }
}

struct IssueRow: View {
    let issue: MobileIssue
    let asking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(issue.project)
                    if let progress = issue.progress { Text("· \(progress)") }
                }
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if issue.state == .awaitingApproval || issue.state == .rejected {
                    Text(Palette.label(issue.state)).font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.color(issue.state))
                }
                if asking {
                    HStack(spacing: 4) {
                        Text("답변 필요")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.amber)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Palette.label(issue.state))
    }
}
