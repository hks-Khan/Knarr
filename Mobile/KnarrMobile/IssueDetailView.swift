import KnarrSync
import SwiftUI
import UIKit

struct IssueDetailView: View {
    @Bindable var store: PhoneStore
    let issueID: String
    /// The iPad's right column shows the same content without its own navigation chrome.
    var pane = false
    /// Closes the iPad's Issue column; nil on iPhone, where the navigation stack does that.
    var onClose: (() -> Void)?
    @State private var note = ""
    @State private var steering = false
    /// A button that changes the original project or stops work waits for a second tap here.
    @State private var confirming: MobileAction?
    private struct Review: Identifiable {
        enum Decision: String { case approve, changes, reject }
        let proposal: MobileIssue.Proposal
        let decision: Decision
        var id: String { "\(proposal.version)-\(decision.rawValue)" }
    }
    @State private var review: Review?
    @State private var reviewNote = ""

    var body: some View {
        if let issue = store.model.issues[issueID] {
            content(issue)
        } else {
            ContentUnavailableView("이슈가 목록에서 빠졌어요", systemImage: "tray",
                                   description: Text("Mac에서 정리됐거나 보관됐어요."))
        }
    }

    private func content(_ issue: MobileIssue) -> some View {
        let waiting = store.model.isAwaitingMac(issue: issue.id)
        return ScrollViewReader { proxy in List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Palette.label(issue.state))
                        .font(.footnote.weight(.semibold)).foregroundStyle(Palette.color(issue.state))
                    Text(issue.title).font(.system(size: 18, weight: .semibold))
                    Text([issue.project, issue.headline].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let application = issue.application {
                        Label(application, systemImage: application.contains("막혔") ? "exclamationmark.triangle.fill" : "checkmark")
                            .font(.footnote).foregroundStyle(application.contains("막혔") ? Palette.red : Palette.green)
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(store.model.pendingQuestions(for: issue.id)) { question in
                Section { QuestionCard(store: store, question: question) }
            }
            if let proposal = issue.proposal {
                Section("제안 v\(proposal.version)") {
                    proposalSummary(proposal)
                    if let note = issue.proposalReviewNote {
                        Label("검토 메모 · \(note)", systemImage: "text.bubble").font(.system(size: 14))
                    }
                }
            }
            if let receipt = store.model.proposalResult(for: issue.id) {
                Section("Mac 처리 결과") {
                    Label(receipt.requestFailure ?? receipt.body,
                          systemImage: receipt.requestFailure == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(receipt.requestFailure == nil ? Palette.green : Palette.red)
                }
            }
            if !issue.detail.isEmpty {
                Section(Self.detailTitle(issue.state)) {
                    MarkdownView(text: issue.detail, size: 15).textSelection(.enabled)
                }
            }
            Section {
                if waiting {
                    Label("Mac에 전달하는 중이에요", systemImage: "paperplane").foregroundStyle(Palette.amber)
                }
                actions(issue).disabled(waiting)
            }
            if let report = issue.report {
                Section("최종 보고") {
                    DisclosureGroup("보고 요약 보기") {
                        MarkdownView(text: report, size: 15).textSelection(.enabled)
                    }
                }
            }
            if !issue.runs.isEmpty {
                Section("작업 단계") {
                    ForEach(Array(issue.runs.enumerated()), id: \.offset) { _, run in RunView(run: run) }
                }
            }
            if let checks = issue.verifications, !checks.isEmpty {
                Section("검증") {
                    ForEach(checks) { check in
                        VerificationRow(check: check)
                    }
                }
            }
            if let captures = issue.captures, !captures.isEmpty {
                Section("화면 캡처") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(captures) { capture in
                                if let data = capture.data, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit()
                                        .frame(height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                                        .accessibilityLabel(capture.caption)
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            if !issue.criteria.isEmpty {
                Section("완료 조건 \(issue.criteria.filter { $0.state == .met }.count)/\(issue.criteria.count)") {
                    ForEach(Array(issue.criteria.enumerated()), id: \.offset) { _, criterion in CriterionRow(criterion: criterion) }
                }
            }
            let resolved = store.model.resolvedQuestions(for: issue.id)
            if !resolved.isEmpty {
                Section("지난 질문") {
                    ForEach(resolved) { q in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.prompt).font(.system(size: 14))
                            Text(q.state == .answered ? "\(q.asker) 질문에 답함 · \(q.answer ?? "")" : "\(q.asker) 질문 닫음")
                                .font(.caption).foregroundStyle(q.state == .answered ? Palette.green : .secondary)
                        }
                    }
                }
            }
            if !issue.events.isEmpty {
                Section("활동") {
                    ForEach(Array(issue.events.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text).font(.system(size: 14))
                            Text("\(event.actor) · \(event.at.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Color.clear.frame(height: 1).listRowBackground(Color.clear).id("detail-bottom")
        }
        .task {
            // Sample launches only (`-detailBottom`), to review the lower sections in screenshots.
            if store.isSample, store.sampleConfirm { confirming = .stop; store.sampleConfirm = false }
            if store.isSample, ProcessInfo.processInfo.arguments.contains("-detailBottom") {
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo("detail-bottom", anchor: .bottom)
            }
        }
        }
        .font(.system(size: 14))
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.page)
        .environment(\.defaultMinListRowHeight, 36)
        .navigationTitle(issue.project)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if pane {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onClose?() }
                        .accessibilityLabel("이슈 상세 닫기")
                }
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $steering) { steerSheet(issue) }
        .sheet(item: $review) { review in reviewSheet(issueID: issue.id, review: review) }
        .confirmationDialog(confirming.map(Self.confirmTitle) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            Button(PhoneStore.actionTitle(action), role: action == .stop ? .destructive : nil) {
                store.send(.action(issue: issue.id, action: action))
            }
            Button("취소", role: .cancel) {}
        } message: { action in
            Text(Self.confirmMessage(action))
        }
    }

    @ViewBuilder private func actions(_ issue: MobileIssue) -> some View {
        switch issue.state {
        case .done, .failed:
            // Stallari judges and integrates. The phone shows the recorded outcome, not a review step.
            Text(Self.stateFact(issue)).font(.system(size: 14)).foregroundStyle(Palette.muted)
        case .running:
            Button { steering = true } label: { Text("추가 지시") }
            action("멈추기", "stop.circle", role: .destructive) { confirming = .stop }
        case .needsInput:
            Button { steering = true } label: { Text("추가 지시") }
            action("멈추기", "stop.circle", role: .destructive) { confirming = .stop }
        case .awaitingApproval:
            if let proposal = issue.proposal, issue.proposalReviewNote == nil {
                action("제안 v\(proposal.version) 승인", "checkmark.seal", prominent: true) {
                    reviewNote = ""; review = Review(proposal: proposal, decision: .approve)
                }
                action("수정 요청", "square.and.pencil") {
                    reviewNote = ""; review = Review(proposal: proposal, decision: .changes)
                }
                action("거절", "xmark.circle", role: .destructive) {
                    reviewNote = ""; review = Review(proposal: proposal, decision: .reject)
                }
            } else {
                Text(issue.proposal == nil ? "Mac에서 제안 요약을 받을 때까지 승인할 수 없어요" : "Stallari가 수정한 새 버전을 기다려 주세요")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
        case .rejected:
            Text("거절한 제안은 실행하지 않아요. Stallari에게 새 제안을 요청해 주세요").font(.system(size: 14)).foregroundStyle(.secondary)
        }

    }

    private func action(_ title: String, _ symbol: String, prominent: Bool = false, role: ButtonRole? = nil,
                        _ perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Text(title).fontWeight(prominent ? .semibold : .regular)
        }
    }

    /// The recorded outcome in one line, matching the Mac card's status wording.
    static func stateFact(_ issue: MobileIssue) -> String {
        let unmet = issue.criteria.filter { $0.state == .unmet }.count
        switch issue.status {
        case "awaitingIntegration": return "완료 조건 충족 · 통합 대기"
        case "judging": return "실행 종료 · Stallari 판정 대기"
        case "unmet": return unmet > 0 ? "미충족 \(unmet)개" : "미충족"
        case "failed": return "실행 실패 · 판정 전에 멈춤"
        default: break
        }
        if issue.state == .done { return "완료 조건 충족 · 통합 대기" }
        return unmet > 0 ? "미충족 \(unmet)개" : "실행 실패"
    }

    private func proposalSummary(_ proposal: MobileIssue.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.title).font(.headline)
            Text("모델 · \(proposal.model)").font(.footnote)
            Text("추론 · \(proposal.thinking ?? "xhigh · 구형 제안 기본값")").font(.footnote)
            Text("모드 · \(proposal.mode == "inspect" ? "조사" : "변경")").font(.footnote)
            ForEach(Array(proposal.criteria.enumerated()), id: \.offset) { _, criterion in
                Label(criterion, systemImage: "checklist").font(.system(size: 14))
            }
            DisclosureGroup("실행 지시") {
                MarkdownView(text: proposal.instruction, size: 15).textSelection(.enabled)
            }
        }
    }

    private func reviewSheet(issueID: String, review selection: Review) -> some View {
        let title = selection.decision == .approve ? "승인" : selection.decision == .changes ? "수정 요청" : "거절"
        return NavigationStack {
            Form {
                Section("검토한 제안 v\(selection.proposal.version)") { proposalSummary(selection.proposal) }
                if selection.decision != .approve {
                    Section("메모") {
                        TextField(selection.decision == .changes ? "수정할 내용" : "거절 이유 (선택)", text: $reviewNote, axis: .vertical)
                            .lineLimit(3...8)
                    }
                }
                Section {
                    Text(selection.decision == .approve ? "이 버전의 지시·모델·추론·모드로 Mac이 Hird를 실행해요." : "승인이 아니며 Hird를 실행하지 않아요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("제안 v\(selection.proposal.version) \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { review = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title, role: selection.decision == .reject ? .destructive : nil) {
                        let version = selection.proposal.version
                        let note = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        switch selection.decision {
                        case .approve: store.send(.approveProposal(issue: issueID, version: version))
                        case .changes: store.send(.requestProposalChanges(issue: issueID, version: version, note: note))
                        case .reject: store.send(.rejectProposal(issue: issueID, version: version, note: note))
                        }
                        review = nil; reviewNote = ""
                    }
                    .disabled(store.model.isAwaitingMac(issue: issueID) ||
                              (selection.decision == .changes && reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }

    private func steerSheet(_ issue: MobileIssue) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("지시 내용", text: $note, axis: .vertical).lineLimit(3...8)
                }
            }
            .navigationTitle("추가 지시")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { steering = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("보내기") {
                        store.send(.steer(issue: issue.id, text: note.trimmingCharacters(in: .whitespacesAndNewlines)))
                        note = ""
                        steering = false
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    static func confirmTitle(_ action: MobileAction) -> String {
        action == .stop ? "Hird를 멈출까요?" : "결과를 원본에 반영할까요?"
    }

    static func confirmMessage(_ action: MobileAction) -> String {
        action == .stop
            ? "이 이슈의 Hird 실행이 모두 멈춰요. 지금까지 한 변경은 남고, 나중에 다시 시작할 수 있어요."
            : "Mac이 결과를 원본 프로젝트에 합쳐요. 합친 뒤에는 되돌리기 어려워요."
    }

    static func detailTitle(_ state: MobileIssue.State) -> String {
        switch state {
        case .running: "진행"
        case .needsInput: "필요한 것"
        case .failed: "멈춘 이유"
        case .done: "결과 요약"
        case .awaitingApproval: "승인 대기"
        case .rejected: "거절한 제안"
        }
    }
}

struct RunView: View {
    let run: MobileIssue.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.name).font(.system(size: 14, weight: .semibold))
                Text(Self.status(run.status)).font(.caption).foregroundStyle(Self.color(run.status))
                Spacer()
                Text("\(run.steps.filter { $0.state == .done }.count)/\(run.steps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !run.role.isEmpty { Text(run.role).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let stages = run.stages, !stages.isEmpty {
                StageBar(stage: run.stage ?? 1, waiting: run.status == .waiting)
                Text(stages.indices.contains((run.stage ?? 1) - 1) ? stages[(run.stage ?? 1) - 1].title : "")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            if let activity = run.activity, !activity.isEmpty {
                Text(activity).font(.caption2.monospaced()).foregroundStyle(Palette.accent)
                    .lineLimit(1)
            }
            ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                Label {
                    Text(step.title).font(.system(size: 14)).foregroundStyle(step.state == .pending ? .secondary : .primary)
                } icon: {
                    Image(systemName: step.state == .done ? "checkmark" : "circle.fill").font(.system(size: step.state == .done ? 11 : 5)).foregroundStyle(Self.color(step.state))
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func status(_ s: MobileIssue.Run.Status) -> String {
        switch s { case .working: "일하는 중"; case .waiting: "기다리는 중"; case .failed: "멈춤"; case .done: "끝남" }
    }

    static func color(_ s: MobileIssue.Run.Status) -> Color {
        switch s { case .working: Palette.blue; case .waiting: Palette.amber; case .failed: Palette.red; case .done: Palette.green }
    }

    static func symbol(_ s: MobileIssue.Run.Step.State) -> String {
        switch s {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted.circle"
        case .pending: "circle"
        case .waiting: "hourglass"
        case .blocked: "hand.raised.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    static func color(_ s: MobileIssue.Run.Step.State) -> Color {
        switch s {
        case .done: Palette.green
        case .active: Palette.blue
        case .pending, .waiting: Palette.grey
        case .blocked: Palette.amber
        case .failed: Palette.red
        }
    }
}

struct VerificationRow: View {
    let check: MobileIssue.Verification

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(check.exitCode.map { "종료 \($0)" } ?? "종료 코드 없음")
                    .font(.caption.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Text(check.at, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(Palette.faint)
            }
            Text(check.command).font(.caption.monospaced()).foregroundStyle(Palette.ink).textSelection(.enabled)
            if let summary = check.summary, !summary.isEmpty {
                Text(summary).font(.caption2).foregroundStyle(Palette.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch check.exitCode {
        case 0: "checkmark.circle.fill"
        case nil: "hourglass"
        default: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.exitCode {
        case 0: Palette.green
        case nil: Palette.faint
        default: Palette.red
        }
    }
}

struct CriterionRow: View {
    let criterion: MobileIssue.Criterion
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if criterion.evidence != nil { withAnimation(.snappy) { open.toggle() } } } label: {
                HStack(alignment: .top) {
                    Image(systemName: Self.symbol(criterion.state)).foregroundStyle(Self.color(criterion.state))
                    Text(criterion.text).font(.system(size: 14)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Spacer()
                    if criterion.evidence != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.faint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            if open, let evidence = criterion.evidence {
                Text(evidence).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 28)
            }
        }
        .accessibilityHint(criterion.evidence == nil ? "" : "근거 보기")
    }

    static func symbol(_ state: MobileIssue.Criterion.State) -> String {
        switch state { case .met: "checkmark.circle.fill"; case .unmet: "xmark.circle.fill"; case .pending: "circle" }
    }

    static func color(_ state: MobileIssue.Criterion.State) -> Color {
        switch state { case .met: Palette.green; case .unmet: Palette.red; case .pending: Palette.grey }
    }
}
