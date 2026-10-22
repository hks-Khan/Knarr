import AppKit
import SwiftUI
import KnarrCore

/// What the main area shows; the rail switches between them.
public enum HomePage: Sendable, Hashable {
    case conversation
    case projects
    case history
}

/// Conversations with integrated issue cards; details remain in the existing drawer.
public struct HomeView: View {
    let store: any KnarrStore
    @State private var opened: Issue.ID?
    @State private var page: HomePage
    @State private var project: String?
    @State private var showingSettings = false
    @State private var selectedReport: String?
    @State private var historyReports = true
    @State private var showingSearch = false
    @State private var scrollTarget: UUID?
    @State private var previewWidth: CGFloat?
    @AppStorage("knarr.issuePanelWidth") private var preferredWidth = 0.0
    @Environment(\.chatWebPreferences) private var chatWebPreferences
    @State private var conversationWindows: MessageConversationWindows?

    /// - Parameters:
    ///   - opened: an Issue to show in the drawer at first (previews and snapshots).
    ///   - page, project: the page and project to start on (previews and snapshots).
    public init(store: any KnarrStore, opened: Issue.ID? = nil, page: HomePage = .conversation, project: String? = nil) {
        self.store = store
        _opened = State(initialValue: opened)
        _page = State(initialValue: page)
        _project = State(initialValue: project)
    }

    public var body: some View {
        HStack(spacing: 0) {
            Rail(page: page, show: show, showSettings: { showingSettings = true })
            VStack(spacing: 0) {
                if page == .conversation {
                    ThreadBar(store: store)
                }
                GeometryReader { geometry in
                    let available = geometry.size.width
                    let split = opened != nil && IssuePanelLayout.isSplit(available: available)
                    let minimum = K.issuePanelMinimumWidth
                    let maximum = split
                        ? IssuePanelLayout.maximumWidth(available: available, windowWidth: available + K.railWidth)
                        : max(minimum, min(available, K.drawerWidth))
                    // Too narrow to split: the detail covers the content instead of leaving a cut-off strip.
                    let width = split
                        ? IssuePanelLayout.width(available: available, windowWidth: available + K.railWidth, preferred: preferredWidth)
                        : available
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            pageContent
                            // The detail's column is reserved, not animated: the transcript gets one new width.
                            if opened != nil, split {
                                Color.clear.frame(width: width + K.issueResizeHitWidth)
                            }
                        }
                        if let issue = opened.flatMap(store.issue) {
                            HStack(spacing: 0) {
                                if split {
                                    IssuePanelSplitter(width: width, minimum: minimum, maximum: maximum,
                                                       reset: min(maximum, max(minimum, K.issuePanelDefaultWidth)),
                                                       preview: { previewWidth = $0 },
                                                       commit: { preferredWidth = Double($0) })
                                        .frame(width: K.issueResizeHitWidth)
                                }
                                IssueDrawer(issue: issue, store: store, close: { opened = nil }, goToThread: {
                                    store.goToThread(for: issue.id); opened = nil; page = .conversation
                                })
                                .frame(width: width)
                            }
                            .transition(.trailingPanel)
                            .animation(opened == nil ? Motion.panelClose : Motion.panelOpen, value: opened)
                        }
                        if let previewWidth, split, opened != nil {
                            let shown = min(maximum, max(minimum, previewWidth))
                            Rectangle().fill(K.accent).frame(width: K.issueResizeGuideWidth)
                                .offset(x: -(shown + (K.issueResizeHitWidth - K.issueResizeGuideWidth) / 2))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(K.canvas)
        .foregroundStyle(K.ink)
        .environment(\.openMessageConversation, { root in
            if conversationWindows == nil { conversationWindows = MessageConversationWindows(preferences: chatWebPreferences) }
            conversationWindows?.open(root, store: store, revealIssue: { opened = $0 })
        })
        .onDisappear { conversationWindows?.closeAll() }
        .onExitCommand { opened = nil }
        .onChange(of: store.selectedThreadID) {
            if store.selectedIssue != nil {
                if page == .projects { opened = nil; page = .conversation }
            } else if let projectID = store.threads.first(where: { $0.id == store.selectedThreadID })?.projectID {
                opened = nil
                project = projectID
            } else if store.selectedThreadID == ConversationThread.defaultID {
                opened = nil
                page = .conversation
            }
        }
        .onChange(of: store.notificationNavigationRevision) {
            opened = nil
            project = nil
            page = .conversation
            showingSettings = false
            showingSearch = false
        }
        .sheet(isPresented: $showingSettings) { SettingsSheet(store: store) }
        .sheet(isPresented: $showingSearch) { SearchSheet(store: store, jump: {
            scrollTarget = $0
            if page != .projects { page = .conversation }
        }) }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .conversation:
            ConversationView(store: store, open: { opened = $0 },
                             search: { if !showingSettings { showingSearch = true } },
                             openReport: openReport,
                             selectedIssue: opened, scrollTarget: $scrollTarget)
                .id(store.selectedThreadID)
        case .projects:
            ProjectsPage(store: store, selected: $project, open: { opened = $0 },
                         search: { if !showingSettings { showingSearch = true } },
                         scrollTarget: $scrollTarget)
        case .history:
            VStack(spacing: 0) {
                Picker("기록 종류", selection: $historyReports) {
                    Text("작업 보고").tag(true)
                    Text("이슈·대화").tag(false)
                }.pickerStyle(.segmented).padding(K.s4).accessibilityIdentifier("history-kind")
                if historyReports {
                    WorkReportHistory(store: store, selected: $selectedReport) { id in
                        store.goToThread(for: id); opened = id; page = .conversation
                    }
                } else {
                    IssueHistoryPage(store: store, navigate: { id in
                        store.goToThread(for: id); opened = nil; page = .conversation
                    }, openThread: { id in
                        store.selectThread(id); opened = nil; page = .conversation
                    })
                }
            }
        }
    }

    /// Opens a report card's detail in the record page, where the same report is listed.
    private func openReport(_ id: String) {
        selectedReport = id
        historyReports = true
        opened = nil
        page = .history
    }

    private func show(_ next: HomePage) {
        if next == .projects,
           let projectID = store.threads.first(where: { $0.id == store.selectedThreadID })?.projectID {
            project = projectID
        }
        opened = nil
        page = next
    }
}

struct Rail: View {
    var page: HomePage = .conversation
    var show: ((HomePage) -> Void)?
    var showSettings: (() -> Void)?
    var body: some View {
        VStack(spacing: K.s1) {
            Image(nsImage: AppArtwork.logo)
                .resizable().scaledToFit()
                .frame(width: K.brandMark, height: K.brandMark)
                .padding(.top, 38)
                .padding(.bottom, K.s3)
                .accessibilityLabel("Knarr")
            item("bubble.left", "홈", on: page == .conversation) { show?(.conversation) }
            item("folder", "프로젝트", on: page == .projects) { show?(.projects) }
            item("clock", "기록", on: page == .history) { show?(.history) }
            Spacer()
            item("gearshape", "설정", action: showSettings)
                .padding(.bottom, K.s3)
        }
        .frame(width: K.railWidth)
        .frame(maxHeight: .infinity)
        .background(K.canvas)
        .overlay(alignment: .trailing) { Rectangle().fill(K.line).frame(width: 1) }
    }

    /// A selected item is ink on a sunken wash; the rest are muted. No accent here: color is for meaning.
    private func item(_ symbol: String, _ title: String, on: Bool = false, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            VStack(spacing: K.s1) {
                Image(systemName: symbol).font(K.railIcon)
                Text(title).font(K.caption.weight(on ? .semibold : .regular))
            }
            .foregroundStyle(on ? K.ink : K.muted)
            .frame(width: 48).padding(.vertical, K.s1)
            .background(on ? K.sunken : .clear, in: RoundedRectangle(cornerRadius: K.rCard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
