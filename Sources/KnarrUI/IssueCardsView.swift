import SwiftUI
import KnarrCore

/// Only this area scrolls when the cards exceed half the available conversation height.
struct IssueCardsView: View {
    let store: any KnarrStore
    let maximumHeight: CGFloat
    /// The detail shown beside the conversation, so its card reads as selected.
    var selected: Issue.ID? = nil
    let open: (Issue.ID) -> Void
    /// The header chip owns expansion, so the list and its chip cannot disagree.
    @Binding var collapsed: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let cards = store.topIssueCards
        if !cards.entries.isEmpty {
            VStack(spacing: 0) {
                if !collapsed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: K.s2) {
                            ForEach(cards.entries) { entry in
                                switch entry {
                                case .issue(let issue):
                                    IntegratedIssueCard(issue: issue, store: store, selected: issue.id == selected,
                                                        open: { open(issue.id) })
                                case .stallariWork(let workers):
                                    StallariWorkCard(workers: workers)
                                }
                            }
                        }
                        .padding(.horizontal, K.s5).padding(.bottom, K.s3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .frame(height: min(contentHeight > 0 ? contentHeight : maximumHeight,
                                       max(0, maximumHeight)))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("issue-cards-scroll")
                }
            }
            .background(K.canvas)
            .overlay(alignment: .bottom) { Divider().overlay(K.line) }
        }
    }
}

private struct StallariWorkCard: View {
    let workers: [SubagentWork]
    var body: some View {
        VStack(alignment: .leading, spacing: K.s1) {
            HStack(spacing: K.s2) {
                Text("Stallari 작업").font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
                Text("\(workers.count)개").font(K.caption).foregroundStyle(K.faint)
                Spacer(minLength: 0)
            }
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                VStack(alignment: .leading, spacing: K.s1) {
                    ForEach(workers) { work in
                        HStack(spacing: K.s2) {
                            Text(work.name).font(K.caption.weight(.medium)).foregroundStyle(K.ink).lineLimit(1)
                            Text("·").font(K.caption).foregroundStyle(K.faint)
                            Text(work.currentCommand ?? "작업 중").font(K.mono).foregroundStyle(K.muted)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text("·").font(K.caption).foregroundStyle(K.faint)
                            if let quiet = IssueCards.quietLabel(for: work, now: clock.date) {
                                Text(quiet).font(K.caption).foregroundStyle(K.amber).fixedSize()
                            } else {
                                Text(IssueCards.elapsed(from: work.startedAt, to: clock.date))
                                    .font(K.caption).foregroundStyle(K.faint).monospacedDigit().fixedSize()
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("stallari-work-" + work.id)
                    }
                }
            }
        }
        .padding(K.s2)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stallari-work")
    }
}

private struct IntegratedIssueCard: View {
    let issue: Issue
    let store: any KnarrStore
    /// This issue's detail is the one shown beside the conversation.
    var selected = false
    let open: () -> Void
    @State private var expanded = false
    @State private var planExpanded = false
    /// One approval per proposal version; a pushed button does not fire twice.
    @State private var approvalSent = false
    @State private var hovering = false
    private var pending: [Question] { store.pendingQuestions(for: issue.id) }
    private var asking: Bool { issue.needsAnswer(hasPendingQuestion: !pending.isEmpty) }
    private var closed: Bool { issue.displayStatus == .completed || issue.displayStatus == .cancelled }
    private var actions: IssueCardActions {
        IssueCardActions(issue: issue, store: store, open: open,
                         goToThread: { store.goToThread(for: issue.id) })
    }

    var body: some View {
        let progress = IssueCards.progress(for: issue)
        let active = closed ? [] : IssueCards.activeHirds(for: issue)
        VStack(alignment: .leading, spacing: K.s1) {
            HStack(spacing: K.s2) {
                ProjectChip(name: issue.projectName)
                Text(issue.title).font(K.secondary.weight(.semibold)).foregroundStyle(K.ink).lineLimit(1)
                    .accessibilityIdentifier("issue-title-" + issue.id.rawValue)
                Spacer(minLength: 0)
                IssueStatusBadge(issue: issue, hasPendingQuestion: !pending.isEmpty)
                if active.isEmpty { IssueElapsedLabel(issue: issue) }
                cardMenu
            }
            if active.count == 1, let hird = active.first {
                ActiveHirdLine(number: nil, hird: hird, progress: progress)
            } else {
                let summary = IssueCards.latestLine(for: issue)
                if !summary.isEmpty {
                    Text(summary).font(K.secondary).foregroundStyle(K.muted).lineLimit(1)
                }
                if active.isEmpty, let last = issue.hirds.last {
                    HirdActivityHistory(lines: last.recentActivityLines(), limit: 2)
                }
            }
            if !progress.plannedStages.isEmpty {
                DisclosureGroup(isExpanded: $planExpanded) {
                    ReportedStagesView(progress: progress)
                } label: {
                    Text(progress.planSummary).font(K.caption).foregroundStyle(K.muted).lineLimit(1)
                }
                .accessibilityIdentifier("issue-plan-" + issue.id.rawValue)
            }
            if !closed {
                if active.count > 1 {
                    if !asking || expanded {
                        ForEach(Array(active.enumerated()), id: \.element.id) { index, hird in
                            ActiveHirdLine(number: index + 1, hird: hird, progress: hird.stageProgress ?? .initial)
                        }
                    }
                    if asking {
                        Button { expanded.toggle() } label: {
                            Label("Hird \(active.count)명", systemImage: expanded ? "chevron.down" : "chevron.right")
                                .font(K.caption).foregroundStyle(K.faint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("issue-hirds-" + issue.id.rawValue)
                    }
                }
                ForEach(pending) { question in
                    QuestionCard(question: question, answer: { store.answer(question.id, with: $0) }, cancel: { store.cancel(question.id) })
                }
                cardActions
            }
        }
        .padding(K.s2)
        .background((hovering || selected) ? K.sunken : K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(borderColor))
        // A click anywhere on the card body opens the detail; its own buttons keep their clicks.
        .contentShape(RoundedRectangle(cornerRadius: K.rCard))
        .onTapGesture(perform: open)
        .accessibilityAction(named: "상세 열기", open)
        .onHover { hovering = $0 }
        .contextMenu { menuContent }
        // Opening the same card again must not change what the detail shows.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("integrated-issue-" + issue.id.rawValue)
        .onChange(of: issue.proposal?.version) { approvalSent = false }
    }

    /// The same commands as the right-click menu, and nothing new.
    private var cardMenu: some View {
        Menu { menuContent } label: {
            Image(systemName: "ellipsis").font(K.secondary).foregroundStyle(K.muted)
                .frame(width: K.controlHeight, height: K.badgeHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("이슈 메뉴")
        .accessibilityLabel("이슈 메뉴")
        .accessibilityIdentifier("issue-menu-" + issue.id.rawValue)
    }

    @ViewBuilder private var menuContent: some View {
        ForEach(actions.items) { item in
            Button(item.menuTitle, action: item.perform).disabled(!item.enabled)
        }
        if actions.canClose {
            Divider()
            Menu("이슈 닫기") {
                ForEach(actions.closeItems) { item in
                    Button(item.menuTitle, action: item.perform).disabled(!item.enabled)
                }
            }
        }
    }

    private var borderColor: Color {
        if selected { return K.accent }
        return asking ? K.amber : K.line
    }

    @ViewBuilder private var cardActions: some View {
        switch issue.presentationStatus(hasPendingQuestion: !pending.isEmpty) {
        case .awaitingApproval:
            if let proposal = issue.proposal {
                Text("제안 v\(proposal.version) · " + (proposal.instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""))
                    .font(K.secondary).foregroundStyle(K.muted).lineLimit(1)
                KButton(title: "이 제안대로 실행", style: .primary,
                        enabled: !approvalSent && issue.proposalReviewNote == nil && issue.approval?.runID == nil && store.approvalBlockReason(for: issue.id) == nil) {
                    approvalSent = true
                    store.perform(.approveProposal(version: proposal.version), on: issue.id)
                }
                if let reason = store.approvalBlockReason(for: issue.id) {
                    Text(reason).font(K.caption).foregroundStyle(K.amber).lineLimit(1)
                }
            } else if issue.needsNewProposal {
                Text(issue.userActionLine(hasPendingQuestion: !pending.isEmpty)).font(K.caption).foregroundStyle(K.faint)
            }
        case .needsAnswer:
            HStack(spacing: K.s2) {
                Text(IssueCards.acceptanceSummary(for: issue)).font(K.caption).foregroundStyle(K.faint)
                Spacer()
                if issue.state == .needsInput, pending.isEmpty {
                    KButton(title: "외부 작업 끝냈어요 · 이어서") { store.perform(.resolvedInput, on: issue.id) }
                }
            }
        case .judging, .awaitingIntegration, .unmet, .failed:
            HStack(spacing: K.s2) {
                Text(IssueCards.acceptanceSummary(for: issue)).font(K.caption).foregroundStyle(K.faint)
                Spacer()
                Text(issue.userActionLine(hasPendingQuestion: !pending.isEmpty)).font(K.caption).foregroundStyle(K.faint).lineLimit(1)
            }
        case .inProgress, .completed, .cancelled: EmptyView()
        }
    }
}

private struct IssueElapsedLabel: View {
    let issue: Issue
    var body: some View {
        if let end = IssueCards.completion(of: issue), let start = IssueCards.firstApproval(of: issue) {
            Text(IssueCards.elapsed(from: start, to: end, completed: true)).font(K.caption).foregroundStyle(K.faint).monospacedDigit().fixedSize()
        } else if IssueCards.firstApproval(of: issue) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                Text(IssueCards.elapsed(for: issue, now: clock.date) ?? "").font(K.caption).foregroundStyle(K.faint).monospacedDigit().fixedSize()
            }
        }
    }
}

private struct ActiveHirdLine: View {
    let number: Int?
    let hird: HirdRun
    let progress: HirdProgress
    var body: some View {
        VStack(alignment: .leading, spacing: K.s1) {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                HStack(spacing: K.s2) {
                    if let number {
                        Text("Hird \(number)").font(K.caption.weight(.medium)).foregroundStyle(K.ink).fixedSize()
                    }
                    HirdActivityLine(activity: hird.activityLine(now: clock.date), showsTime: false)
                    Spacer(minLength: 0)
                    if let quiet = IssueCards.quietLabel(for: hird, now: clock.date) {
                        Text(quiet).font(K.caption).foregroundStyle(K.amber).fixedSize()
                    } else if let start = hird.startedAt {
                        Text(IssueCards.elapsed(from: start, to: clock.date)).font(K.caption).foregroundStyle(K.faint).monospacedDigit().fixedSize()
                    }
                }
            }
            HirdActivityHistory(lines: hird.recentActivityLines(), limit: 2)
            if number != nil, !progress.plannedStages.isEmpty {
                Text(progress.planSummary).font(K.caption).foregroundStyle(K.muted).lineLimit(1)
            }
        }
    }
}

/// Saved stage reports stay distinct from verified completion criteria.
struct ReportedStagesView: View {
    let progress: HirdProgress
    var showsEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: K.s1) {
            ForEach(progress.plannedStages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: K.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                        Text(stage.title).foregroundStyle(K.ink)
                        Text(stateTitle(stage.state)).foregroundStyle(K.muted).fixedSize()
                        if let verified = stage.verified {
                            Text(verified ? "확인됨" : "근거 없음")
                                .foregroundStyle(verified ? K.muted : K.amber).fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    if showsEvidence {
                        if !stage.evidence.isEmpty {
                            Text(stage.evidence).foregroundStyle(K.muted)
                        }
                        if let note = stage.note, !note.isEmpty {
                            Text(note).foregroundStyle(K.muted)
                        }
                    }
                }
                .font(K.caption)
                .help(stage.evidence + (stage.note.map { "\n" + $0 } ?? ""))
            }
            ForEach(progress.planChanges.indices, id: \.self) { index in
                Text("계획 변경 · \(progress.planChanges[index].reason)")
                    .font(K.caption).foregroundStyle(K.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(progress.planChanges[index].titles.joined(separator: " → "))
            }
        }
    }

    private func stateTitle(_ state: HirdProgress.StageState) -> String {
        switch state {
        case .active:
            switch progress.condition {
            case .running: "진행 중"
            case .waitingQuestion: "답변 대기"
            case .stopped: "중단됨"
            case .done: "실행 종료 · 완료 미보고"
            }
        case .done: "완료 보고"
        case .pending: "진행 미보고"
        }
    }
}

struct IssueHistoryPage: View {
    let store: any KnarrStore
    let navigate: (Issue.ID) -> Void
    let openThread: (String) -> Void
    var body: some View {
        let issues = IssueCards.history(issues: store.issues)
        let legacyThreads = store.threads.filter { $0.id != ConversationThread.defaultID && $0.issueID == nil }
        VStack(alignment: .leading, spacing: 0) {
            Text("기록").font(K.title).padding(.horizontal, K.s5).frame(height: K.headerHeight)
            Divider().overlay(K.line)
            if issues.isEmpty && legacyThreads.isEmpty {
                Text("완료하거나 닫은 이슈가 없어요").font(K.secondary).foregroundStyle(K.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(issues) { issue in
                            Button { navigate(issue.id) } label: {
                                HStack(spacing: K.s3) {
                                    ProjectChip(name: issue.projectName)
                                    Text(issue.title).font(K.secondary.weight(.medium)).foregroundStyle(K.ink).lineLimit(1)
                                    IssueStatusBadge(issue: issue)
                                    Spacer()
                                    IssueElapsedLabel(issue: issue)
                                }.padding(K.s4).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("history-issue-" + issue.id.rawValue)
                            Divider().overlay(K.line)
                        }
                        ForEach(legacyThreads) { thread in
                            Button { openThread(thread.id) } label: {
                                HStack(spacing: K.s3) {
                                    Image(systemName: "bubble.left").font(K.secondary).foregroundStyle(K.faint)
                                    Text(thread.name).font(K.secondary).foregroundStyle(K.ink).lineLimit(1)
                                    Spacer()
                                    Text("이전 대화").font(K.caption).foregroundStyle(K.faint)
                                }.padding(K.s4).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("history-thread-" + thread.id)
                            Divider().overlay(K.line)
                        }
                    }.padding(.horizontal, K.s3)
                }
            }
        }.background(K.surface)
    }
}
