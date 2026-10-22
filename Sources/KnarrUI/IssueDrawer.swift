import SwiftUI
import KnarrCore

/// Issue detail, opened over the conversation. Sections sit 24pt apart under faint captions;
/// facts are two-column key-value rows; long text is folded.
struct IssueDrawer: View {
    let issue: Issue
    let store: any KnarrStore
    let close: () -> Void
    var goToThread: (() -> Void)? = nil
    @State private var note = ""
    @State private var steering = false
    @State private var appNote = ""
    @State private var confirmingInstall = false
    private var pending: [Question] { store.pendingQuestions(for: issue.id) }

    /// The link leads somewhere only when another thread exists and the issue lives in it.
    private var showsThreadLink: Bool {
        store.threads.count > 1 && issue.conversationThreadID != store.selectedThreadID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(K.line)
            ScrollView {
                VStack(alignment: .leading, spacing: K.s5) {
                    section("목표") {
                        ForEach(Array(issue.acceptance.enumerated()), id: \.offset) { _, criterion in
                            HStack(alignment: .top, spacing: K.s2) {
                                CriterionBox(state: criterion.state)
                                Text(criterion.text).font(K.secondary).lineLimit(3)
                            }
                        }
                    }
                    section("현재 상황") {
                        let status = issue.presentationStatus(hasPendingQuestion: !pending.isEmpty)
                        let progress = IssueCards.progress(for: issue)
                        if let hird = IssueCards.activeHirds(for: issue).first {
                            TimelineView(.periodic(from: .now, by: 30)) { clock in
                                HirdActivityLine(activity: hird.activityLine(now: clock.date), now: clock.date)
                            }
                        } else {
                            Text(status.title).font(K.secondary.weight(.semibold))
                        }
                        if issue.displayStatus != .completed, issue.displayStatus != .unmet, issue.displayStatus != .failed,
                           !issue.detail.isEmpty, issue.detail != issue.proposal?.instruction, !issue.hirds.contains(where: { $0.role == issue.detail }) {
                            Text(issue.detail).font(K.secondary).foregroundStyle(K.muted).lineLimit(3)
                        }
                        if issue.hasActiveHird || !progress.plannedStages.isEmpty {
                            StepBar(steps: progress.plannedStages.isEmpty ? issue.hirds.first?.displaySteps ?? [] : progress.steps,
                                    labels: false)
                        }
                        if !progress.plannedStages.isEmpty {
                            Text(progress.planSummary)
                                .font(K.caption).foregroundStyle(K.muted)
                            ReportedStagesView(progress: progress, showsEvidence: true)
                        }
                    }
                    if issue.needsAnswer(hasPendingQuestion: !pending.isEmpty) {
                        section("필요한 결정") {
                            Text(issue.userActionLine(hasPendingQuestion: !pending.isEmpty)).font(K.secondary)
                        }
                    }
                    if issue.displayStatus == .awaitingApproval, issue.archivedAt == nil, let proposal = issue.proposal, issue.state == .awaitingApproval {
                        ProposalReviewView(issue: issue, proposal: proposal, surface: "drawer", blockReason: store.approvalBlockReason(for: issue.id)) { store.perform($0, on: issue.id) }
                            .id("\(issue.id.rawValue):\(proposal.version)")
                    }
                    if showsThreadLink {
                        Button {
                            if let goToThread { goToThread() }
                            else { store.goToThread(for: issue.id); close() }
                        } label: {
                            Label("스레드로 이동 · " + (store.threads.first { $0.id == issue.conversationThreadID }?.name ?? "기본"), systemImage: "bubble.left")
                                .font(K.secondary)
                        }
                        .buttonStyle(.plain).foregroundStyle(K.accent)
                        .accessibilityIdentifier("issue-thread-link")
                    }
                    if issue.needsAnswer(hasPendingQuestion: !pending.isEmpty) {
                        ForEach(pending) { q in
                            QuestionCard(question: q, answer: { store.answer(q.id, with: $0) }, cancel: { store.cancel(q.id) })
                        }
                    }
                    if issue.displayStatus == .unmet, issue.needsAppConfirmation {
                        section("실제 앱 확인") {
                            Text("아래 완료 조건의 미확인 사유를 읽고 실제 앱을 직접 확인하세요. 기록만으로 자동 반영하지 않습니다.")
                                .font(K.secondary).foregroundStyle(K.muted)
                            TextField("실제 앱에서 확인한 내용", text: $appNote).textFieldStyle(.roundedBorder)
                            KButton(title: "실제 확인 기록", enabled: !appNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                store.perform(.confirmAppResult(note: appNote), on: issue.id)
                            }
                        }
                    }
                    if let confirmation = issue.userAppConfirmation {
                        Text("사용자 확인 · \(confirmation.at.formatted()) · \(confirmation.note)")
                            .font(K.secondary).textSelection(.enabled)
                    }
                    if let application = issue.application { ApplicationLine(application: application) }
                    if let archiveNote = issue.archiveNote, !archiveNote.isEmpty {
                        Text("닫은 사유 · \(archiveNote)").font(K.secondary).textSelection(.enabled)
                    }
                    if let replacement = issue.supersededBy {
                        Text("대체 이슈 · \(replacement.rawValue)").font(K.mono).textSelection(.enabled)
                    }
                    if let result = issue.latestResult {
                        section("결과") {
                            let commands = result.verifications.filter { !$0.isInspection }
                            let passed = commands.filter { $0.exitCode == 0 }.count
                            let failed = commands.filter { $0.exitCode.map { $0 != 0 } ?? false }.count
                            let inspected = result.verifications.filter(\.isInspection).count
                            Text("검사 통과 \(passed) · 실패 \(failed) · 문서·화면 확인 \(inspected)")
                                .font(K.secondary)
                        }
                    }
                    FoldSection(title: "상세 기록", identifier: "issue-detail-records") {
                        VStack(alignment: .leading, spacing: K.s4) {
                            if let proposal = issue.proposal {
                                section("작업 지시 · v\(proposal.version)") {
                                    KeyValueRows(mono: Self.meta(of: proposal))
                                    MarkdownText(text: proposal.instruction, scale: .secondary)
                                        .accessibilityIdentifier("issue-instruction-drawer")
                                }
                            }
                            section("완료 조건") {
                                ForEach(Array(issue.acceptance.enumerated()), id: \.offset) { _, criterion in
                                    VStack(alignment: .leading, spacing: K.s1) {
                                        Text(criterion.text).font(K.secondary)
                                        Text(Self.readable(criterion.evidence)).font(K.caption).foregroundStyle(K.muted)
                                    }
                                }
                            }
                            if !issue.detail.isEmpty { MarkdownText(text: issue.detail, scale: .secondary) }
                            if let result = issue.latestResult {
                                if issue.state == .done, result.summary != issue.detail {
                                    Text(result.summary).font(K.secondary).foregroundStyle(K.muted)
                                }
                                section("검증 근거") {
                                    ForEach(result.verifications, id: \.id) { record in
                                        Text(record.command.joined(separator: " ") + " · " + (record.isInspection ? "내용 확인" : record.exitCode.map(String.init) ?? "미종료"))
                                            .font(K.mono).textSelection(.enabled)
                                    }
                                    Text("작업 폴더 · \(result.worktreePath)").font(K.mono).textSelection(.enabled)
                                    HirdReportView(store: store, issueID: issue.id)
                                }
                            }
                            if let model = issue.executionModel {
                                KeyValueRows(mono: [("실행 모델", model), ("추론", issue.executionThinking ?? "미확인")])
                            }
                            if let approvals = issue.approvalHistory, !approvals.isEmpty {
                                section("승인 기록") {
                                    ForEach(Array(approvals.enumerated()), id: \.offset) { _, approval in
                                        Text("v\(approval.version) · \(approval.approvedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(K.secondary).foregroundStyle(K.muted)
                                    }
                                }
                            }
                            FoldSection(title: "활동") {
                                VStack(spacing: 0) {
                                    ForEach(Array(issue.events.enumerated()), id: \.element.id) { index, e in
                                        if index > 0 { Divider().overlay(K.line) }
                                        HStack(alignment: .top, spacing: K.s2) {
                                            Text(e.at.formatted(date: .omitted, time: .shortened))
                                                .font(K.caption).monospacedDigit().foregroundStyle(K.faint)
                                                .frame(width: 58, alignment: .leading)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(e.actor) · \(e.text)").font(K.secondary)
                                                if let d = e.detail {
                                                    Text(d).font(K.mono).foregroundStyle(K.muted).lineLimit(1)
                                                }
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, K.s2)
                                    }
                                }
                            }
                            ForEach(issue.hirds) { hird in hirdRow(hird) }
                        }
                    }


                }
                .padding(K.s5)
            }
            Divider().overlay(K.line)
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(K.surface)
        .overlay(alignment: .leading) { Rectangle().fill(K.lineStrong).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("issue-drawer")
    }

    /// Model, thinking, mode and the run it builds on, as key-value rows.
    static func meta(of proposal: IssueProposal) -> [(String, String)] {
        var rows = [("모델", proposal.model), ("추론", proposal.thinking ?? "xhigh"),
                    ("모드", "\(proposal.mode == .inspect ? "조사" : "변경") (\(proposal.mode.rawValue))")]
        if let previous = proposal.previousRunID { rows.append(("이전 실행", previous.rawValue)) }
        return rows
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            HStack(spacing: K.s2) {
                ProjectChip(name: issue.projectName)
                Spacer(minLength: K.s2)
                KButton(title: "닫기 · Esc", action: close)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityIdentifier("issue-drawer-close")
            }
            // Five lines covers a long Korean title at the 380pt floor; the body below scrolls,
            // so the header never grows without bound.
            Text(issue.title).font(K.title).lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: K.s2) {
                IssueStatusBadge(issue: issue, hasPendingQuestion: !pending.isEmpty)
                LivenessLabel { issue.liveness(now: $0) }
                Text(IssueCards.acceptanceSummary(for: issue))
                    .font(K.caption).foregroundStyle(K.faint)
            }
        }
        .padding(.horizontal, K.s5).padding(.top, K.s4).padding(.bottom, K.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface)
    }

    private func hirdRow(_ h: HirdRun) -> some View {
        VStack(alignment: .leading, spacing: K.s2) {
            HStack(spacing: K.s2) {
                Text(h.name).font(K.secondary.weight(.semibold))
                Spacer()
                LivenessLabel { h.liveness(now: $0) }
            }
            StepBar(steps: h.stageProgress.map { $0.plannedStages.isEmpty ? h.displaySteps : $0.steps } ?? h.displaySteps,
                    labels: true)
            if let progress = h.stageProgress, !progress.plannedStages.isEmpty {
                ReportedStagesView(progress: progress, showsEvidence: true)
            }
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                VStack(alignment: .leading, spacing: K.s1) {
                    switch h.status {
                    case .working, .waitingOnHuman:
                        HirdActivityLine(activity: h.activityLine(now: clock.date), now: clock.date)
                    case .done, .failed:
                        EmptyView()
                    }
                    HirdActivityHistory(lines: h.recentActivityLines(), limit: 4)
                }
            }
            if let resources = h.runtimeResources {
                DisclosureGroup("OMP 실행 자원") {
                    VStack(alignment: .leading, spacing: K.s2) {
                        resourceList("규칙 · context 파일", resources.contextFiles)
                        resourceList("Skills", resources.skills)
                        resourceList("확장 명령 · 공식 API", resources.extensionCommands)
                        resourceList("명시적 신뢰 확장 · CLI", resources.trustedExtensions)
                        Text("외부 확장 자동 로드는 차단돼요. Knarr LSP 상한 확장만 명시적으로 로드해요. OMP 18.7.0 RPC는 전체 확장 모듈 목록을 제공하지 않아요.")
                            .font(K.caption).foregroundStyle(K.faint)
                        ForEach(Array((h.lspRecords ?? []).enumerated()), id: \.offset) { _, record in
                            Text("LSP \(record.action) · \(record.server ?? "서버 없음") · \(record.succeeded ? "성공" : "실패 · LSP 없이 계속")")
                                .font(K.caption).foregroundStyle(K.muted)
                        }
                    }
                    .padding(.top, K.s2)
                }
                .font(K.secondary).foregroundStyle(K.muted)
            }
        }
        .padding(.vertical, K.s2)
    }

    /// The card menu's close rows, so both surfaces offer the same reasons and the same blocks.
    static func closeItems(issue: Issue, store: any KnarrStore) -> [IssueCardActions.Item] {
        IssueCardActions(issue: issue, store: store, open: {}, goToThread: {}).closeItems
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            if issue.archivedAt == nil, steering {
                HStack(spacing: K.s2) {
                    TextField("Hird에게 전할 말", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendNote)
                    KButton(title: "보내기", style: .primary, action: sendNote)
                }
            }
            HStack(spacing: K.s2) {
                // An older applied result must not hide control of a newer active run.
                if issue.archivedAt == nil, issue.hasActiveHird, !issue.needsAttention {
                    KButton(title: "멈추기", style: .destructive) { store.perform(.stop, on: issue.id) }
                }
                // Stallari judges and integrates; the detail only shows the recorded state and the
                // two things the person owns: answering and approving a saved proposal.
                if issue.needsAttention {
                    switch issue.presentationStatus(hasPendingQuestion: !pending.isEmpty) {
                    case .inProgress:
                        if issue.hasActiveHird {
                            KButton(title: "Hird에게 한마디") { steering.toggle() }
                            KButton(title: "멈추기", style: .destructive) { store.perform(.stop, on: issue.id) }
                        }
                    case .needsAnswer:
                        if issue.state == .needsInput, pending.isEmpty {
                            KButton(title: "외부 작업 끝냈어요 · 이어서", style: .primary) { store.perform(.resolvedInput, on: issue.id) }
                        }
                    case .awaitingApproval:
                        if issue.needsNewProposal {
                            KButton(title: "새 제안 요청", style: .primary) {
                                store.send("이 이슈는 실행과 승인 제안이 없어요. 현재 요청 범위의 새 제안을 만들고 필요한 작업과 검증을 이어서 마무리해 주세요. 기존 이슈를 대체하면 기록을 남겨 주세요.", about: issue.id)
                            }
                        }
                    case .judging, .awaitingIntegration, .unmet, .failed, .completed, .cancelled:
                        Text(issue.userActionLine(hasPendingQuestion: !pending.isEmpty)).font(K.caption).foregroundStyle(K.faint).lineLimit(1)
                    }
                }
                Spacer()
                KButton(title: "Stallari에게 묻기", style: .link) {
                    store.send("이 이슈 어떻게 되고 있어?", about: issue.id)
                    close()
                }
            }
            if issue.archivedAt == nil {
                HStack(spacing: K.s3) {
                    // The same reasons and blocks as the card menu. The menu stays clickable while a
                    // Hird runs; each row then names why it cannot close instead of being a dead control.
                    Menu("이슈 닫기") {
                        ForEach(Self.closeItems(issue: issue, store: store)) { item in
                            Button(item.menuTitle, action: item.perform).disabled(!item.enabled)
                        }
                    }
                    .fixedSize().font(K.secondary)
                    .accessibilityIdentifier("issue-drawer-close-menu")
                    if issue.latestResult != nil {
                        KButton(title: "설치하고 다시 시작", enabled: store.installationBlockReason == nil) { confirmingInstall = true }
                    }
                    Spacer(minLength: 0)
                }
                if issue.hasActiveHird {
                    Text("실행이 끝난 뒤 닫을 수 있어요").font(K.caption).foregroundStyle(K.faint)
                }
                if let error = store.lastError {
                    // A refused close or menu command explains itself here, not only in the transcript.
                    Text(error).font(K.caption).foregroundStyle(K.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("issue-drawer-error")
                }
                if let reason = store.installationBlockReason, issue.latestResult != nil {
                    Text(reason).font(K.caption).foregroundStyle(K.amber)
                }
            }
        }
        .padding(.horizontal, K.s5).padding(.vertical, K.s3)
        .confirmationDialog("앱을 정상 종료하고 DB를 백업한 뒤 후보 앱을 설치·재실행합니다.", isPresented: $confirmingInstall) {
            Button("설치하고 다시 시작") { store.installAndRestart(issue.id) }
        }
    }

    private var detailHeading: String {
        switch issue.displayStatus {
        case .awaitingApproval: "제안"
        case .inProgress, .needsAnswer: "지금 하는 일"
        case .judging, .awaitingIntegration, .unmet, .failed, .completed: "결과 요약"
        case .cancelled: "이슈 기록"
        }
    }

    private func resourceList(_ title: String, _ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: K.s1) {
            Text(title).font(K.caption.weight(.semibold))
            if entries.isEmpty {
                Text("보고된 항목 없음").font(K.caption).foregroundStyle(K.faint)
            } else {
                ForEach(entries, id: \.self) { Text($0).font(K.mono).textSelection(.enabled) }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text(title).font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            content()
        }
    }

    /// Evidence without the trailing `[verification:…]` IDs Stallari cites; they stay in storage for audit.
    static func readable(_ evidence: String) -> String {
        guard let open = evidence.range(of: " [verification:", options: .backwards), evidence.hasSuffix("]") else { return evidence }
        return String(evidence[..<open.lowerBound])
    }

    private func sendNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.steer(text, issue: issue.id)
        note = ""
        steering = false
    }
}

/// Git application facts, independent of historical user acknowledgement.
struct ApplicationLine: View {
    let application: ResultApplication
    var body: some View {
        let (symbol, color, text): (String, Color, String) = {
            switch application {
            case .applied(let branch, let commit): ("checkmark.circle", K.green, "원본 `\(branch)`에 반영했어요 · `\(commit.prefix(7))`")
            case .kept(let branch, let commit): ("checkmark.circle", K.green, "`\(branch)` 브랜치에 보관돼 있어요 · `\(commit.prefix(7))`")
            case .blocked(let reason): ("exclamationmark.triangle", K.amber, reason)
            }
        }()
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(color).frame(width: 2)
            HStack(alignment: .top, spacing: K.s2) {
                Image(systemName: symbol).font(K.secondary).foregroundStyle(color).padding(.top, 1)
                MarkdownText.inline(text).font(K.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, K.s3).padding(.vertical, K.s1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Expanded content is mounted lazily, keeping long reports out of idle renders.
struct FoldSection<Content: View>: View {
    let title: String
    var identifier: String = ""
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Button { expanded.toggle() } label: {
                HStack(spacing: K.s1) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(K.caption.weight(.semibold))
                    Text(title)
                    Spacer()
                }.font(K.secondary.weight(.medium)).foregroundStyle(K.muted)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            if expanded { content().transition(.softReveal) }
        }
        .clipped().animation(Motion.disclosure, value: expanded)
    }
}

private struct HirdReportView: View {
    let store: any KnarrStore
    let issueID: Issue.ID
    @State private var text = "보고서를 읽는 중"
    var body: some View {
        MarkdownText(text: text, scale: .secondary).task { text = await store.resultReport(issueID) }
    }
}
