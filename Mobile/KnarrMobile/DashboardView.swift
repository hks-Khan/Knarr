import KnarrSync
import SwiftUI

/// The whole house at a glance: counts per stage, projects, running Hirds, recent alerts and the
/// Mac's last change. The iPad's first screen; also the first tab on iPhone.
struct DashboardView: View {
    @Bindable var store: PhoneStore
    var phone: Bool
    var openThread: ((String) -> Void)? = nil
    var openIssue: ((String) -> Void)? = nil
    /// iPhone opens Issues through the existing list navigation.
    @State private var path: [String] = []

    private var dashboard: MobileDashboard { store.model.dashboard() }

    var body: some View {
        content
            .navigationTitle("현황")
            .navigationBarTitleDisplayMode(.inline)
            .background(Palette.page)
            .navigationDestination(for: String.self) { id in IssueDetailView(store: store, issueID: id) }
            .refreshable { await store.refresh() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                counts
                if !dashboard.working.isEmpty { working }
                projects
                alertsAndTransport
            }
            .padding(.horizontal, phone ? 16 : 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("현황").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(summaryLine).font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer()
        }
    }

    private var summaryLine: String {
        var parts: [String] = ["이슈 \(store.model.issues.count)개"]
        if dashboard.working.count > 0 { parts.append("실행 중 Hird \(dashboard.working.count)") }
        if dashboard.pendingQuestions > 0 { parts.append("질문 \(dashboard.pendingQuestions)") }
        return parts.joined(separator: " · ")
    }

    private var counts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: phone ? 104 : 130), spacing: 10)], spacing: 10) {
            ForEach(dashboard.counts) { count in
                Button { navigate(to: count.bucket) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(count.bucket.title).font(.system(size: 13)).foregroundStyle(Palette.muted)
                        Text("\(count.count)").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.ink).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.page)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .accessibilityLabel("\(count.bucket.title) \(count.count)개")
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("진행 \(dashboard.working.count)")
            VStack(spacing: 0) {
                ForEach(Array(dashboard.working.enumerated()), id: \.element.id) { index, item in
                    Button { open(item.issue) } label: { WorkingRow(item: item) }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                    if index < dashboard.working.count - 1 {
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 12)
                    }
                }
            }
            .background(Palette.page)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("프로젝트")
            if dashboard.projects.isEmpty {
                Text("프로젝트가 아직 없어요").font(.footnote).foregroundStyle(Palette.faint)
            }
            ForEach(dashboard.projects) { project in
                HStack(spacing: 10) {
                    Text(project.name).font(.system(size: 14)).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                    if project.needsAnswer > 0 {
                        Label("답변 \(project.needsAnswer)", systemImage: "questionmark.bubble.fill")
                            .font(.caption2).foregroundStyle(Palette.amber)
                    }
                    Text("\(project.open)").font(.callout.monospacedDigit()).foregroundStyle(Palette.muted)
                }
                .padding(.vertical, 6)
                Divider().overlay(Palette.line)
            }
        }
    }

    private var alertsAndTransport: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("알림")
            if store.model.inbox.alerts.isEmpty {
                Text("최근 알림이 없어요").font(.footnote).foregroundStyle(Palette.faint)
            }
            ForEach(store.model.inbox.alerts.prefix(3)) { alert in
                Button { open(alert.issue) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(store.model.inbox.isRead(alert.id) ? Palette.lineStrong : Palette.accent)
                            .frame(width: 6, height: 6).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                            Text(alert.body).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                        }
                        Spacer()
                        Text(alert.createdAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(Palette.faint)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(alert.issue == nil)
            }
            Divider().overlay(Palette.line).padding(.vertical, 4)
            HStack(spacing: 12) {
                Image(systemName: store.connectionLine.symbol).foregroundStyle(store.connectionLine.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.connectionLine.text).font(.footnote).foregroundStyle(Palette.ink)
                    Text("Mac 마지막 변경 \(store.model.lastChangedAt.map { ConnectionBanner.ago($0, now: .now) } ?? "기록 없음") · 전달 대기 \(store.model.pendingRequests.count)")
                        .font(.caption).foregroundStyle(Palette.faint)
                }
            }
        }
    }

    private func open(_ issue: String?) {
        guard let issue else { return }
        if phone { path = [issue] } else { openIssue?(issue) }
    }

    private func navigate(to bucket: MobileDashboard.Bucket) {
        guard !phone else { return }
        let candidates = store.model.issues.values
            .filter { MobileDashboard.bucket(of: $0, asking: !store.model.pendingQuestions(for: $0.id).isEmpty) == bucket }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let first = candidates.first else { return }
        openIssue?(first.id)
        if let thread = store.model.thread(forIssue: first.id)?.id { openThread?(thread) }
    }
}

struct WorkingRow: View {
    let item: MobileDashboard.Working
    @State private var now = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(item.project).font(.caption2).foregroundStyle(Palette.faint).lineLimit(1)
                Spacer()
                Text(elapsed).font(.caption2.monospacedDigit()).foregroundStyle(Palette.faint)
            }
            StageBar(stage: item.stage, waiting: item.waiting)
            HStack(spacing: 6) {
                Image(systemName: item.waiting ? "hand.raised.fill" : "terminal")
                    .font(.caption2).foregroundStyle(item.waiting ? Palette.amber : Palette.accent)
                Text(item.activity).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(item.startedAt)))
        if seconds < 60 { return "\(seconds)초" }
        if seconds < 3600 { return "\(seconds / 60)분째" }
        return "\(seconds / 3600)시간 \(seconds % 3600 / 60)분째"
    }
}

/// The five stages as thin segments; the current one is filled, a stopped or waiting one is tinted.
struct StageBar: View {
    let stage: Int
    let waiting: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(color(index))
                    .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("5단계 중 \(max(1, stage))단계")
    }

    private func color(_ index: Int) -> Color {
        if index < stage { return Palette.accent.opacity(0.55) }
        if index == stage { return waiting ? Palette.amber : Palette.accent }
        return Palette.line
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted)
    }
}

struct AlertsView: View {
    @Bindable var store: PhoneStore
    var openIssue: ((String) -> Void)? = nil
    @State private var path: [String] = []

    var body: some View {
        List {
            if store.model.inbox.alerts.isEmpty {
                ContentUnavailableView("알림이 없어요", systemImage: "bell",
                                       description: Text("이슈 상태가 바뀌거나 질문이 오면 여기에 쌓여요. 기기에는 일주일 동안 남아요."))
            }
            ForEach(store.model.inbox.alerts) { alert in
                Button {
                    store.markAlertRead(alert.id)
                    guard let issue = alert.issue else { return }
                    if let openIssue { openIssue(issue) } else { path = [issue] }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(store.model.inbox.isRead(alert.id) ? Palette.lineStrong : Palette.accent)
                            .frame(width: 7, height: 7).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.title).font(.system(size: 14, weight: store.model.inbox.isRead(alert.id) ? .regular : .medium))
                                .foregroundStyle(Palette.ink)
                            Text(alert.body).font(.caption).foregroundStyle(Palette.muted).lineLimit(3)
                            Text(alert.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption2).foregroundStyle(Palette.faint)
                        }
                        Spacer()
                        if alert.issue != nil {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.page)
        .navigationTitle("알림함")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.model.inbox.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("모두 읽음") { store.markAlertsRead() }
                        .font(.footnote)
                }
            }
        }
        .navigationDestination(for: String.self) { id in IssueDetailView(store: store, issueID: id) }
        .onChange(of: store.openIssue) { _, issue in
            guard let issue, openIssue == nil else { return }
            path = [issue]
            store.openIssue = nil
        }
    }
}

struct SettingsView: View {
    @Bindable var store: PhoneStore
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded { content }
        else { NavigationStack { content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } } } }
    }

    private var content: some View {
        List {
            Section("연결") {
                LabeledContent("Mac", value: store.connectionLine.text)
                if let status = store.model.status {
                    LabeledContent("엔진", value: status.engine)
                    LabeledContent("Mac 실행", value: status.macRunning == false ? "꺼짐" : "켜짐")
                }
                LabeledContent("마지막 동기화", value: store.model.lastChangedAt.map { ConnectionBanner.ago($0, now: .now) } ?? "기록 없음")
                LabeledContent("전달 대기", value: "\(store.model.pendingRequests.count)")
            }
            Section("동기화") {
                LabeledContent("대화", value: "\(store.model.threads.count)")
                LabeledContent("이슈", value: "\(store.model.issues.count)")
                LabeledContent("이전 기록", value: "대화에서 불러오기")
            }
            Section("알림") {
                LabeledContent("읽지 않음", value: "\(store.model.inbox.unreadCount)")
                Button("모두 읽음") { store.markAlertsRead() }.disabled(store.model.inbox.unreadCount == 0)
            }
        }
        .font(.system(size: 14))
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: embedded ? 700 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.page)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }
}
