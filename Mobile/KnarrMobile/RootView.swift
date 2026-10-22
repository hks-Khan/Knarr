import KnarrSync
import SwiftUI
import UIKit

/// Chooses the iPad three-column layout or the iPhone tabs. Both read the same model.
struct RootView: View {
    @Bindable var store: PhoneStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadRootView(store: store)
            } else {
                PhoneRootView(store: store)
            }
        }
        .tint(Palette.accent)
        .overlay(alignment: .top) { FeedbackToast(store: store) }
        .alert("보내지 못했어요", isPresented: Binding(get: { store.sendError != nil }, set: { if !$0 { store.sendError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(store.sendError ?? "")
        }
    }
}

struct FeedbackToast: View {
    let store: PhoneStore

    var body: some View {
        if let feedback = store.feedback {
            Label(feedback, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(Palette.green)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.snappy, value: feedback)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

struct PhoneRootView: View {
    @Bindable var store: PhoneStore
    @State private var tab = PhoneTab.dashboard

    enum PhoneTab: Hashable { case dashboard, issues, chat, alerts }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { DashboardView(store: store, phone: true) }
                .tabItem { Label("현황", systemImage: "square.grid.2x2") }
                .tag(PhoneTab.dashboard)
            IssueListView(store: store)
                .tabItem { Label("이슈", systemImage: "checklist") }
                .badge(store.model.pendingQuestionCount)
                .tag(PhoneTab.issues)
            NavigationStack { ChatView(store: store) }
                .tabItem { Label("Stallari", systemImage: "bubble.left.and.bubble.right") }
                .tag(PhoneTab.chat)
            NavigationStack { AlertsView(store: store) }
                .tabItem { Label("알림", systemImage: "bell") }
                .badge(store.model.inbox.unreadCount)
                .tag(PhoneTab.alerts)
        }
        .onChange(of: store.openIssue) { _, issue in if issue != nil { tab = .issues } }
        .onChange(of: store.openChat) { _, open in if open { tab = .chat; store.openChat = false } }
        .onChange(of: store.openSection) { _, section in
            switch section {
            case .alerts: tab = .alerts
            case .settings, .dashboard: tab = .dashboard
            case .issues: tab = .issues
            case nil: break
            }
            store.openSection = nil
        }
        .onOpenURL { url in
            store.handleActivityURL(url)
            if url.scheme == "knarr", url.host == "activity" { tab = .issues }
        }
        .onChange(of: store.activityListRequest) { _, _ in tab = .issues }
        .onAppear {
            if store.startOnChat { tab = .chat }
            if let thread = store.sampleThread {
                // The iPhone list has no conversation picker; the Stallari tab shows every thread merged.
                tab = .chat
                store.sampleJump = nil
                _ = thread
                store.sampleThread = nil
            }
        }
    }
}

/// Connection line at the top of each screen: is the Mac on, how fresh the data is, and what is still on its way.
struct ConnectionBanner: View {
    let store: PhoneStore
    @State private var showingPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.connection {
            case .starting:
                row("arrow.triangle.2.circlepath", "iCloud에 연결하는 중", Palette.faint)
            case .unavailable(let why), .failed(let why):
                row("exclamationmark.icloud", why, Palette.red)
            case .ready:
                if store.model.status?.macRunning == false {
                    row("desktopcomputer.trianglebadge.exclamationmark", "Mac의 Knarr가 꺼져 있어요 · 요청은 켜지면 처리돼요", Palette.amber)
                } else if let at = store.model.lastChangedAt {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        row("checkmark.icloud", "Mac 마지막 변경 \(Self.ago(at, now: context.date))", Palette.faint)
                    }
                } else {
                    row("checkmark.icloud", "Mac 연결됨", Palette.faint)
                }
            }
            let pending = store.model.pendingRequests.count
            if pending > 0 {
                Button { showingPending = true } label: {
                    HStack {
                        row("paperplane", "Mac에 전달 대기 \(pending)개", Palette.amber)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("대기 중인 요청을 보고 취소할 수 있어요")
            }
        }
        .sheet(isPresented: $showingPending) { PendingRequestsSheet(store: store) }
    }

    private func row(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)초 전" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86_400 { return "\(s / 3600)시간 전" }
        return "\(s / 86_400)일 전"
    }
}

struct PendingRequestsSheet: View {
    let store: PhoneStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.model.pendingRequests) { request in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.summary(of: request)).font(.callout).lineLimit(3)
                            Text(request.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("취소", role: .destructive) { store.cancel(request) }
                        }
                    }
                } footer: {
                    Text("Mac의 Knarr가 켜져 있으면 곧 처리돼요. 밀어서 취소하면 Mac이 아직 받지 않은 요청만 취소돼요.")
                }
            }
            .overlay { if store.model.pendingRequests.isEmpty { ContentUnavailableView("대기 중인 요청이 없어요", systemImage: "checkmark.circle") } }
            .navigationTitle("전달 대기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
