import KnarrSync
import SwiftUI

/// iPad: conversations on the left, the selected conversation in the middle, the selected Issue on the right.
/// A narrow window shows the conversation or detail while retaining the composer state.
struct PadRootView: View {
    @Bindable var store: PhoneStore
    @State private var column: NavigationSplitViewColumn = .sidebar
    @State private var selection: SidebarItem? = .dashboard
    @State private var threadID: String?
    @State private var issueID: String?
    @State private var search = ""
    @State private var showingSettings = false
    @State private var showingSidebar = false

    enum SidebarItem: Hashable {
        case dashboard
        case alerts
        case settings
        case project(String)
        case thread(String)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1100
            let selectedIssue = issueID.flatMap { store.model.issues[$0] }
            let hideConversation = !wide && selectedIssue != nil
            HStack(spacing: 0) {
                if wide {
                    NavigationStack {
                        SidebarView(store: store, selection: sidebarSelection, search: $search, showingSettings: $showingSettings)
                    }
                    .frame(width: 200)
                    Rectangle().fill(Palette.line).frame(width: 1)
                }
                NavigationStack {
                    selectedContent
                        .toolbar {
                            if !wide {
                                ToolbarItem(placement: .topBarLeading) { Button("목록") { showingSidebar = true } }
                            }
                        }
                }
                // Keep the conversation and its composer alive while a portrait detail covers it.
                .frame(width: hideConversation ? 0 : nil)
                .frame(maxWidth: hideConversation ? nil : .infinity)
                .clipped()
                .opacity(hideConversation ? 0 : 1)
                .allowsHitTesting(!hideConversation)
                .disabled(hideConversation)
                .accessibilityHidden(hideConversation)
                if let issue = selectedIssue {
                    if wide { Rectangle().fill(Palette.line).frame(width: 1) }
                    NavigationStack {
                        IssueDetailView(store: store, issueID: issue.id, pane: true, onClose: { self.issueID = nil })
                    }
                    .frame(width: wide ? 340 : nil)
                    .frame(maxWidth: wide ? nil : .infinity)
                }
            }
            .background(Palette.page)
        }
        .sheet(isPresented: $showingSidebar) {
            NavigationStack {
                SidebarView(store: store, selection: sidebarSelection, search: $search, showingSettings: $showingSettings)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { showingSidebar = false } } }
            }
            .presentationDetents([.large])
        }
        .onChange(of: store.openIssue, initial: true) { _, id in
            guard let id else { return }
            issueID = id
            store.openIssue = nil
            if let thread = store.model.thread(forIssue: id)?.id { threadID = thread; selection = .thread(thread) }
        }
        .onChange(of: store.openChat) { _, open in
            guard open else { return }
            selection = .thread(threadID ?? ConversationID.main)
            store.openChat = false
        }
        .onChange(of: selection) { _, item in
            showingSidebar = false
            if case .thread(let id) = item {
                threadID = id
            }
        }
        .task {
            // Sample launches only: start on a named conversation, issue or the settings sheet.
            if let id = store.sampleThread {
                selection = .thread(id); threadID = id; store.sampleThread = nil
            }
            if let issue = store.openIssue { issueID = issue; store.openIssue = nil }
            if store.sampleSettings { selection = .settings; store.sampleSettings = false }
            #if DEBUG
            if store.isSample, let screen = store.sampleScreen {
                try? await Task.sleep(for: .milliseconds(300))
                switch screen {
                case "dashboard": selection = .dashboard; issueID = nil
                case "alerts": selection = .alerts; issueID = nil
                case "settings": selection = .settings; issueID = nil
                case "project":
                    if let project = store.model.projects.first(where: { $0.name == "Soomcha" }) { selection = .project(project.id) }
                    issueID = nil
                case "chatDetail": selection = .thread(ConversationID.main); threadID = ConversationID.main; issueID = "s1"
                case "detail": issueID = "s1"
                default: break
                }
                store.sampleScreen = nil
            }
            #endif
        }
        .background(detailShortcuts)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { selection = $0; issueID = nil; showingSidebar = false })
    }

    @ViewBuilder private var selectedContent: some View {
        switch selection {
        case .dashboard, nil:
            DashboardView(store: store, phone: false, openThread: { id in threadID = id; selection = .thread(id) },
                          openIssue: { issueID = $0 })
        case .alerts:
            AlertsView(store: store, openIssue: { issueID = $0 })
        case .settings:
            SettingsView(store: store, embedded: true)
        case .project(let id):
            ProjectDetailView(store: store, projectID: id, openThread: { threadID = $0; selection = .thread($0) },
                              openIssue: { issueID = $0 })
        case .thread(let id):
            ChatView(store: store, thread: id, title: id == ConversationID.main ? "메인 대화" : store.model.threadByID[id]?.name ?? "대화", compactHeader: true).id(id)
        }
    }

    /// Hardware keyboard: ⌘⇧I opens or closes the Issue pane, ⌘N starts a new request,
    /// ⌘F searches the sidebar, ⌘↩ sends. Each key is also reachable by tap.
    private var detailShortcuts: some View {
        Group {
            Button("") {
                if issueID != nil {
                    issueID = nil
                } else if let thread = threadID, let issue = store.model.messages(in: thread).last?.issue {
                    issueID = issue
                } else if let first = store.model.issues.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                    issueID = first.id
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("") { selection = .thread(ConversationID.main) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { selection = .dashboard }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { selection = .alerts }
                .keyboardShortcut("2", modifiers: .command)
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

/// Left column: Mac connection, search, status board, projects, conversations, alerts.
struct SidebarView: View {
    @Bindable var store: PhoneStore
    @Binding var selection: PadRootView.SidebarItem?
    @Binding var search: String
    @Binding var showingSettings: Bool

    private var threads: [MobileThread] {
        let all = store.model.threads.filter { $0.id != ConversationID.main }
        guard !search.isEmpty else {
            // Issues that are running read best next to the conversations they belong to.
            return all
        }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var projects: [MobileProject] {
        guard !search.isEmpty else { return store.model.projects }
        return store.model.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var issueMatches: [MobileIssue] {
        guard !search.isEmpty else { return [] }
        return store.model.issues.values.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.project.localizedCaseInsensitiveContains(search)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                row(.dashboard, title: "현황")
                row(.alerts, title: "알림", count: store.model.unreadAlerts().count)
                Divider().padding(.horizontal, 20).padding(.vertical, 16)
                if !projects.isEmpty {
                    sectionTitle("프로젝트")
                    ForEach(projects) { project in
                        row(.project(project.id), title: project.name)
                    }
                    Divider().padding(.horizontal, 20).padding(.vertical, 16)
                }
                sectionTitle("대화")
                // The main composer must remain reachable before the first CloudKit snapshot arrives.
                row(.thread(ConversationID.main), title: "메인 대화")
                ForEach(threads) { thread in row(.thread(thread.id), title: thread.name) }
                if !issueMatches.isEmpty {
                    sectionTitle("이슈")
                    ForEach(issueMatches) { issue in
                        Button { store.openIssue = issue.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.title).lineLimit(2)
                                Text(issue.project).font(.caption).foregroundStyle(Palette.faint)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                ConnectionSummary(store: store)
                Button("설정") { selection = .settings }.foregroundStyle(selection == .settings ? Palette.accent : Palette.ink)
                    .frame(minHeight: 36)
            }.font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Palette.page)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 36)
        .font(.system(size: 14))
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .searchable(text: $search, prompt: "검색")
        .navigationTitle("Knarr")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.faint)
            .padding(.horizontal, 20).padding(.bottom, 8)
    }
    private func row(_ item: PadRootView.SidebarItem, title: String, count: Int = 0) -> some View {
        let selected = selection == item
        return Button { selection = item } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").foregroundStyle(Palette.accent).monospacedDigit() }
            }
            .font(.system(size: 14, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Palette.accent : Palette.ink)
            .padding(.horizontal, 20).padding(.vertical, 9).frame(minHeight: 38)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Palette.accent).frame(width: 3).padding(.vertical, 4) } }
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

}

struct ConnectionSummary: View {
    let store: PhoneStore
    @State private var showingPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(store.connectionLine.color).frame(width: 8, height: 8)
                Text(store.connectionLine.text).font(.footnote.weight(.medium)).foregroundStyle(Palette.ink)
            }
            if store.model.pendingRequests.count > 0 {
                Button { showingPending = true } label: {
                    Label("전달 대기 \(store.model.pendingRequests.count)개", systemImage: "paperplane")
                        .font(.caption).foregroundStyle(Palette.amber)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingPending) { PendingRequestsSheet(store: store) }
    }
}

struct ThreadSidebarRow: View {
    let store: PhoneStore
    let thread: MobileThread
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.name).font(.system(size: 14)).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 5) {
                    if let at = thread.lastMessageAt {
                        Text(at, format: .dateTime.month().day().hour().minute())
                    }
                    if thread.working {
                        Text("진행").foregroundStyle(Palette.accent)
                    }
                }
                .font(.caption2).foregroundStyle(Palette.faint).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct IssuePlaceholder: View {
    let store: PhoneStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right").font(.system(size: 30)).foregroundStyle(Palette.lineStrong)
            Text("이슈를 고르면 상세가 여기에 보여요").font(.callout).foregroundStyle(Palette.muted)
            Text("현황이나 대화에서 이슈 카드를 눌러도 열려요.").font(.footnote).foregroundStyle(Palette.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}

/// A project's Issues, plus its own conversation.
struct ProjectDetailView: View {
    @Bindable var store: PhoneStore
    let projectID: String
    let openThread: (String) -> Void
    let openIssue: (String) -> Void

    private var issues: [MobileIssue] {
        store.model.issues.values.filter { $0.project == projectID || $0.project == store.model.projects.first { $0.id == projectID }?.name }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var projectThread: MobileThread? {
        store.model.threads.first { $0.project == projectID }
    }

    var body: some View {
        List {
            Section {
                if let projectThread {
                    Button { openThread(projectThread.id) } label: {
                        Text("대화")
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(MobileIssue.Group.allCases, id: \.self) { group in
                let list = issues.filter { $0.group == group }
                if !list.isEmpty {
                    Section("\(group.title) \(list.count)") {
                        ForEach(list) { issue in
                            Button { openIssue(issue.id) } label: { IssueRow(issue: issue, asking: !store.model.pendingQuestions(for: issue.id).isEmpty) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.page)
        .navigationTitle(store.model.projects.first { $0.id == projectID }?.name ?? projectID)
        .navigationBarTitleDisplayMode(.inline)
    }
}
