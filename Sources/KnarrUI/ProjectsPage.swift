import AppKit
import SwiftUI
import KnarrCore

enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, milestones, documents, issues, runs, guide, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "개요"
        case .milestones: "마일스톤"
        case .documents: "문서"
        case .issues: "이슈"
        case .runs: "실행 기록"
        case .guide: "지침과 검증"
        case .settings: "설정"
        }
    }
}

/// Which Issues a project's 이슈 tab shows. One option per open state, plus the two closed ones.
enum IssueFilter: String, CaseIterable, Identifiable {
    case all, awaitingApproval, needsAnswer, inProgress, judging, awaitingIntegration, unmet, failed, completed, cancelled
    var id: String { rawValue }
    var status: IssueStatus? {
        switch self {
        case .all: nil
        case .awaitingApproval: .awaitingApproval
        case .needsAnswer: .needsAnswer
        case .inProgress: .inProgress
        case .judging: .judging
        case .awaitingIntegration: .awaitingIntegration
        case .unmet: .unmet
        case .failed: .failed
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }
    var title: String { status?.title ?? "전체" }
    func includes(_ issue: Issue, hasPendingQuestion: Bool = false) -> Bool {
        guard issue.archivedAt == nil else { return false }
        guard let status else { return true }
        return issue.presentationStatus(hasPendingQuestion: hasPendingQuestion) == status
    }
}

/// The 프로젝트 page: every project on the left, the picked one on the right.
struct ProjectsPage: View {
    let store: any KnarrStore
    @Binding var selected: String?
    let open: (Issue.ID) -> Void
    let search: () -> Void
    @Binding var scrollTarget: UUID?
    @AppStorage("knarr.projectTab") private var tabName = ProjectTab.overview.rawValue
    @State private var query = ""
    @State private var showingArchived = false
    @State private var issueFilter = IssueFilter.all
    @FocusState private var projectSearchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= K.projectListWidth + K.projectPanelMinimumWidth(store.projectSessionPolicy) {
                HStack(spacing: 0) {
                    list
                        .frame(width: K.projectListWidth)
                        .background(K.surface)
                        .overlay(alignment: .trailing) { Rectangle().fill(K.line).frame(width: 1) }
                    workspace
                }
            } else {
                VStack(spacing: 0) {
                    Menu {
                        ForEach(store.projects) { project in
                            Button(project.name) { selected = project.id }
                        }
                        Divider()
                        Button("추가", action: addProject)
                    } label: {
                        HStack {
                            Text(current?.name ?? "프로젝트").font(K.title).lineLimit(1)
                            Spacer(minLength: K.s2)
                            Image(systemName: "chevron.down").font(K.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, K.s3).frame(height: K.headerHeight)
                    .background(K.surface)
                    workspace
                }
            }
        }
        .onChange(of: selected) { _, _ in
            if current?.settings.workspaceStyle == .preparation { tabName = ProjectTab.overview.rawValue }
        }
        .onAppear {
            if current?.settings.workspaceStyle == .preparation { tabName = ProjectTab.overview.rawValue }
            if current == nil { selected = store.projects.first { !$0.archived }?.id }
            if current?.archived == true { showingArchived = true }
        }
    }

    @ViewBuilder private var workspace: some View {
        if let project = current {
            ProjectWorkspace(store: store, project: project, tab: tab, issueFilter: $issueFilter,
                             open: open, search: search, scrollTarget: $scrollTarget,
                             releaseSearchFocus: { projectSearchFocused = false })
                .id(project.id)
        } else {
            Text(store.projects.isEmpty ? "프로젝트를 추가하면 여기서 관리해요" : "왼쪽에서 프로젝트를 골라 주세요")
                .font(K.secondary).foregroundStyle(K.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var current: ProjectSummary? { selected.flatMap(store.project) }
    private var tab: Binding<ProjectTab> {
        Binding(get: { ProjectTab(rawValue: tabName) ?? .overview }, set: { tabName = $0.rawValue })
    }

    private var list: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = store.projects.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        let active = matching.filter { !$0.archived }
        let archived = matching.filter(\.archived)
        return VStack(alignment: .leading, spacing: K.s3) {
            HStack {
                Text("프로젝트").font(K.title)
                Spacer()
                KButton(title: "추가", action: addProject).help("Git 저장소 폴더를 프로젝트로 추가")
            }
            .padding(.top, K.s6 + K.s1)
            UsageSummaryButton(usage: store.subscriptionUsage)
            TextField("이름이나 경로로 찾기", text: $query)
                .textFieldStyle(.plain).font(K.secondary)
                .focused($projectSearchFocused)
                .padding(.horizontal, K.s2).padding(.vertical, K.s2)
                .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
                .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
            ScrollView {
                VStack(alignment: .leading, spacing: K.s1) {
                    ForEach(active) { row($0) }
                    if active.isEmpty {
                        Text(store.projects.isEmpty ? "아직 프로젝트가 없어요. Git 저장소 폴더를 추가해 주세요." : "맞는 프로젝트가 없어요")
                            .font(K.secondary).foregroundStyle(K.faint).padding(.vertical, K.s3)
                    }
                    if !archived.isEmpty {
                        Button { showingArchived.toggle() } label: {
                            HStack {
                                Text("보관됨 \(archived.count)")
                                Spacer()
                                Image(systemName: "chevron.right").rotationEffect(.degrees(showingArchived ? 90 : 0))
                            }
                            .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                            .padding(.horizontal, K.s2).padding(.top, K.s4).padding(.bottom, K.s1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .animation(Motion.disclosure, value: showingArchived)
                        if showingArchived {
                            ForEach(archived) { row($0) }.transition(.softReveal)
                        }
                    }
                }
                .padding(.bottom, K.s4)
            }
        }
        .padding(.horizontal, K.s3)
    }

    private func row(_ p: ProjectSummary) -> some View {
        let issues = store.executionIssues(inProject: p.id)
        let counts = IssueCounts(issues: issues, questions: store.questions)
        let summary = p.settings.workspaceStyle == .preparation ? "준비 항목 \(store.preparationItems(inProject: p.id).count)" + (issues.contains(where: \.needsAttention) ? " · " + counts.summary : "") : counts.summary
        return Button { selected = p.id } label: {
            HStack(spacing: K.s3) {
                ProjectIcon(project: p)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(K.secondary.weight(.semibold)).lineLimit(1)
                    Group {
                        if p.archived { Text("보관됨").foregroundStyle(K.faint) }
                        else { Text(summary).foregroundStyle(K.muted) }
                    }
                    .font(K.caption).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, K.s2).padding(.vertical, K.s2)
            .background(p.id == selected ? K.sunken : .clear, in: RoundedRectangle(cornerRadius: K.rSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.name), \(p.archived ? "보관됨" : summary)")
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "프로젝트로 추가"
        panel.message = "Stallari가 관리할 Git 저장소 폴더를 골라 주세요"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addProject(path: url.path) }
    }
}

/// Collapse belongs to the project, not the selected home conversation or this view's lifetime.
private struct ProjectWorkspace: View {
    let store: any KnarrStore
    let project: ProjectSummary
    @Binding var tab: ProjectTab
    @Binding var issueFilter: IssueFilter
    let open: (Issue.ID) -> Void
    let search: () -> Void
    let releaseSearchFocus: () -> Void
    @Binding var scrollTarget: UUID?
    @AppStorage private var collapsed: Bool
    @AppStorage("knarr.projectSessionWidth") private var preferredWidth = 0.0
    @State private var previewWidth: CGFloat?
    @State private var focusRequest: UUID?

    init(store: any KnarrStore, project: ProjectSummary, tab: Binding<ProjectTab>,
         issueFilter: Binding<IssueFilter>, open: @escaping (Issue.ID) -> Void,
         search: @escaping () -> Void, scrollTarget: Binding<UUID?>,
         releaseSearchFocus: @escaping () -> Void) {
        self.store = store; self.project = project; self.open = open; self.search = search
        self.releaseSearchFocus = releaseSearchFocus
        _tab = tab; _issueFilter = issueFilter; _scrollTarget = scrollTarget
        _collapsed = AppStorage(wrappedValue: store.projectSessionPolicy.panelDefaultCollapsed,
                                "knarr.projectSessionCollapsed." + project.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let policy = store.projectSessionPolicy
            let minimum = K.projectPanelMinimumWidth(policy)
            let readable = !project.archived ||
                store.threads.first(where: { $0.id == store.selectedThreadID })?.projectID == project.id
            // A saved wide preference must not change the split/overlay breakpoint.
            let split = geometry.size.width >= CGFloat(policy.panelDefaultWidth) +
                K.projectDetailMinimumWidth + K.projectResizeHitWidth
            let maximum = max(minimum, geometry.size.width - K.projectResizeHitWidth -
                              (split ? K.projectDetailMinimumWidth : 0))
            let panelWidth = min(maximum, K.projectPanelWidth(policy, preferred: preferredWidth))
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    detail
                    if collapsed || !readable {
                        Button { talk(project.id) } label: {
                            Image(systemName: "bubble.right").font(K.secondary).foregroundStyle(K.muted)
                                .frame(width: K.projectCollapsedPanelWidth, height: K.headerHeight)
                        }
                        .buttonStyle(.plain).disabled(project.archived)
                        .help(store.projectSessionPolicy.panelOpenLabel)
                        .accessibilityLabel(store.projectSessionPolicy.panelOpenLabel)
                        .accessibilityIdentifier("project-session-open-" + project.id)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(K.surface)
                        .overlay(alignment: .leading) { Divider().overlay(K.line) }
                    } else if split {
                        Color.clear.frame(width: panelWidth + K.projectResizeHitWidth)
                    }
                }
                // Keep one panel identity across split, overlay and narrow overflow.
                // Moving ConversationView between branches discards its reading state.
                if !collapsed && readable {
                    ScrollView(.horizontal) {
                        resizablePanel(width: panelWidth, minimum: minimum, maximum: maximum)
                            .frame(height: geometry.size.height)
                    }
                    .frame(width: min(geometry.size.width, panelWidth + K.projectResizeHitWidth))
                }
                if let previewWidth, !collapsed && readable {
                    Rectangle().fill(K.accent).frame(width: K.projectResizeGuideWidth)
                        .offset(x: -(min(maximum, max(minimum, previewWidth)) +
                                     (K.projectResizeHitWidth - K.projectResizeGuideWidth) / 2))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            // No animated width proposals, and no transcript reflow until the drag ends.
            .transaction { $0.animation = nil }
        }
        .onAppear {
            if scrollTarget != nil { collapsed = false }
            if !collapsed && !project.archived { store.selectProjectConversation(project.id) }
        }
        .onChange(of: scrollTarget) {
            if scrollTarget != nil { collapsed = false }
        }
    }

    private func resizablePanel(width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> some View {
        HStack(spacing: 0) {
            ProjectPanelSplitter(projectID: project.id, width: width, minimum: minimum, maximum: maximum,
                                 preview: { previewWidth = $0 },
                                 commit: { preferredWidth = Double($0) })
                .frame(width: K.projectResizeHitWidth)
            panel.frame(width: width)
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(K.surface)
    }

    private var detail: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                ProjectDetail(store: store, project: project, tab: $tab, issueFilter: $issueFilter,
                              open: open, talk: talk, request: request)
                    .frame(width: max(geometry.size.width, K.projectDetailMinimumWidth),
                           height: geometry.size.height)
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panel: some View {
        ConversationView(store: store, open: open, search: search, focusRequest: focusRequest,
                         closeProjectPanel: { collapsed = true }, scrollTarget: $scrollTarget)
            .frame(minWidth: K.projectPanelMinimumWidth(store.projectSessionPolicy))
            .background(K.surface)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project-session-panel-" + project.id)
    }

    private func talk(_ id: String) {
        guard id == project.id, !project.archived else { return }
        releaseSearchFocus()
        store.selectProjectConversation(id)
        collapsed = false
        focusRequest = UUID()
    }

    private func request(_ text: String) {
        guard ProjectConversationRequest.prepare(store: store, projectID: project.id, text: text) else { return }
        talk(project.id)
    }
}

/// One project: header with its folder state, then the tabs.
struct ProjectDetail: View {
    let store: any KnarrStore
    let project: ProjectSummary
    @Binding var tab: ProjectTab
    @Binding var issueFilter: IssueFilter
    let open: (Issue.ID) -> Void
    let talk: (String) -> Void
    let request: (String) -> Void
    @State private var inspection: ProjectInspection?
    @State private var copied = false
    @State var documents = ProjectDocumentsModel()
    @State private var mergeResults: ProjectMergeResults?
    @State private var milestoneRequest: MilestoneRequest?

    var body: some View {
        let issues = store.executionIssues(inProject: project.id)
        VStack(spacing: 0) {
            header(issues)
            Divider().overlay(K.line)
            if project.archived {
                HStack(spacing: K.s2) {
                    Image(systemName: "archivebox").foregroundStyle(K.amber)
                    Text("보관된 프로젝트예요. Stallari가 여기서는 새 이슈를 받지 않아요.").foregroundStyle(K.muted)
                    Spacer()
                    KButton(title: "목록에 다시 넣기") { store.setProjectArchived(project.id, false) }
                }
                .font(K.secondary)
                .padding(.horizontal, K.s5).padding(.top, K.s3)
            }
            if tab == .documents {
                ProjectDocuments(project: project, model: documents, reload: reloadDocuments,
                                 ask: { request($0) })
            } else {
            ScrollView {
                Group {
                    switch tab {
                    case .overview:
                        if project.settings.workspaceStyle == .preparation {
                            ProjectPreparationOverview(store: store, project: project, documents: documents.recent, documentChoices: documents.library?.documents ?? [],
                                                       openDocument: openDocument, showDocuments: { tab = .documents })
                        } else {
                        ProjectOverview(store: store, project: project, issues: issues, inspection: inspection, open: open,
                                        reload: reload, show: { tab = $0 },
                                        openMilestone: openMilestone, createMilestone: createMilestone,
                                        filter: { issueFilter = $0; tab = .issues },
                                        questions: store.questions, documents: documents.recent,
                                        mergeResults: mergeResults, openDocument: openDocument, request: request,
                                        milestones: store.milestones(inProject: project.id),
                                        weekPlans: store.weekPlans(inProject: project.id))
                        }
                    case .milestones:
                        ProjectMilestones(store: store, project: project, issues: issues, open: open, request: request,
                                          milestoneRequest: $milestoneRequest)
                    case .issues:
                        ProjectIssues(store: store, project: project, issues: issues, filter: $issueFilter, open: open, talk: talk)
                    case .documents:
                        EmptyView()
                    case .runs:
                        ProjectRuns(store: store, issues: issues, open: open)
                    case .guide:
                        ProjectGuide(store: store, project: project, inspection: inspection, reload: reload, talk: talk)
                    case .settings:
                        ProjectSettingsTab(store: store, project: project)
                    }
                }
                .padding(.horizontal, K.s5).padding(.top, K.s5).padding(.bottom, K.s6 + K.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
        .background(K.canvas)
        // Refresh on entry and explicit action, never by polling.
        .task(id: project.id + ":" + tab.rawValue) {
            if tab == .documents {
                if inspection == nil { inspection = await store.inspectProject(project.id) }
                await reloadDocuments()
            } else if tab == .overview {
                await reload()
            } else if inspection == nil {
                inspection = await store.inspectProject(project.id)
            }
        }
    }

    /// Sends the clicked stage ID to the tab so its detail is exact, not the tab's default.
    private func openMilestone(_ id: Milestone.ID) {
        milestoneRequest = .select(id)
        tab = .milestones
    }

    /// The overview's empty card starts the editor directly, with no extra click.
    private func createMilestone() {
        milestoneRequest = .create
        tab = .milestones
    }

    private func reload() async {
        inspection = await store.inspectProject(project.id)
        await reloadDocuments()
        if project.settings.workspaceStyle == .development { mergeResults = await store.inspectProjectMergeResults(project.id) }
    }

    private func reloadDocuments() async {
        await documents.reload(root: URL(fileURLWithPath: project.path, isDirectory: true))
    }

    private func openDocument(_ path: String) {
        documents.selectedPath = path
        tab = .documents
        Task { await documents.select(path) }
    }

    private func header(_ issues: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: K.s3) {
                ProjectIcon(project: project, size: 44)
                VStack(alignment: .leading, spacing: K.s1) {
                    Text(project.name).font(K.title).lineLimit(1)
                    HStack(spacing: K.s2) {
                        Text(project.path).font(K.mono).foregroundStyle(K.faint).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(K.caption).foregroundStyle(copied ? K.green : K.faint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain).help("경로 복사").accessibilityLabel("경로 복사")
                        .animation(Motion.iconSwap, value: copied)
                    }
                    chips.padding(.top, K.s1)
                }
                Spacer(minLength: K.s3)
                HStack(spacing: K.s2) {
                    KButton(title: "Finder에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true)) }
                    KButton(title: "이 프로젝트로 말하기", style: .primary, enabled: !project.archived) { talk(project.id) }
                }
                .fixedSize()
            }
            .padding(.top, K.s6)
            HStack(spacing: K.s1) {
                ForEach(ProjectTab.allCases) { t in
                    let count: Int? = switch t {
                    case .issues: issues.filter { $0.archivedAt == nil }.count
                    case .runs: issues.reduce(0) { $0 + $1.hirds.count }
                    default: nil
                    }
                    Button { tab = t } label: {
                        HStack(spacing: K.s1) {
                            Text(t.title).font(K.secondary.weight(tab == t ? .semibold : .regular))
                            if let count { Text("\(count)").font(K.caption).foregroundStyle(K.faint) }
                        }
                        .foregroundStyle(tab == t ? K.ink : K.muted)
                        .padding(.horizontal, K.s2).padding(.top, K.s3).padding(.bottom, K.s2)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? K.ink : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, K.s5)
        .background(K.surface)
        .onChange(of: copied) { _, on in
            guard on else { return }
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
    }

    @ViewBuilder private var chips: some View {
        FlowRow(spacing: K.s2) {
            if let i = inspection {
                if let problem = i.problem {
                    Chip(text: problem, fg: K.red, bg: K.redSoft)
                } else {
                    Chip(text: i.branch ?? "브랜치 없음 (HEAD 분리)", symbol: "arrow.triangle.branch", mono: true)
                    if let ahead = i.ahead, ahead > 0 { Chip(text: "↑\(ahead) 올리지 않은 커밋") }
                    if let behind = i.behind, behind > 0 { Chip(text: "↓\(behind) 받을 커밋") }
                    if i.changes.isEmpty { Chip(text: "작업 트리 깨끗함") }
                    else { Chip(text: "커밋 안 한 파일 \(i.changes.count)", fg: K.amber, bg: K.amberSoft) }
                    if i.agents == nil { Chip(text: "AGENTS.md 없음", fg: K.red, bg: K.redSoft) } else { Chip(text: "AGENTS.md 있음") }
                }
            } else {
                Chip(text: "저장소 읽는 중")
            }
        }
    }
}

/// A chip: 18pt high, a thin line or a soft wash of one meaning, caption medium.
struct Chip: View {
    let text: String
    var fg: Color = K.muted
    var bg: Color? = nil
    var symbol: String? = nil
    var mono = false
    var body: some View {
        HStack(spacing: K.s1) {
            if let symbol { Image(systemName: symbol).font(K.caption) }
            Text(text).font(mono ? K.mono : K.caption.weight(.medium))
        }
            .foregroundStyle(fg)
            .padding(.horizontal, K.s2)
            .frame(height: K.badgeHeight)
            .background(bg ?? .clear, in: RoundedRectangle(cornerRadius: K.rSmall))
            .overlay { if bg == nil { RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.line) } }
    }
}

/// A titled box on the project page.
struct ProjectCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: K.s2) {
                Text(title).font(K.body.weight(.semibold))
                if let subtitle { Text(subtitle).font(K.secondary).foregroundStyle(K.faint).lineLimit(1) }
                Spacer(minLength: 0)
                accessory()
            }
            .padding(.horizontal, K.s4).padding(.top, K.s3).padding(.bottom, K.s2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }
}

extension ProjectCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// One Issue as a row in a project card or list.
struct ProjectIssueRow: View {
    let issue: Issue
    let open: (Issue.ID) -> Void
    var hasPendingQuestion = false
    var body: some View {
        Button { open(issue.id) } label: {
            HStack(alignment: .center, spacing: K.s3) {
                IssueStatusBadge(issue: issue, hasPendingQuestion: hasPendingQuestion)
                VStack(alignment: .leading, spacing: K.s1) {
                    Text(issue.title).font(K.secondary.weight(.semibold)).lineLimit(1)
                    Text(IssueCards.latestLine(for: issue)).font(K.secondary).foregroundStyle(K.faint).lineLimit(1)
                    if let run = issue.hirds.first, issue.displayStatus == .inProgress || issue.displayStatus == .needsAnswer {
                        StepBar(steps: run.displaySteps).frame(maxWidth: 260).padding(.top, K.s1)
                    }
                }
                Spacer(minLength: K.s2)
                if let application = issue.application, issue.displayStatus == .completed || issue.displayStatus == .awaitingIntegration {
                    Text(applicationText(application)).font(K.caption).foregroundStyle(K.faint).lineLimit(1)
                } else {
                    LivenessLabel(compute: { issue.liveness(now: $0) })
                }
            }
            .padding(.horizontal, K.s4).padding(.vertical, K.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    private func applicationText(_ a: ResultApplication) -> String {
        switch a {
        case .applied(let branch, let commit): "\(branch) · \(commit.prefix(7))"
        case .kept(let branch, _): "\(branch)에 남김"
        case .blocked: "반영 안 됨"
        }
    }
}
