import AppKit
import SwiftUI
import KnarrCore

// MARK: - 개요

struct ProjectOverview: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let issues: [Issue]
    let inspection: ProjectInspection?
    let open: (Issue.ID) -> Void
    let reload: () async -> Void
    let show: (ProjectTab) -> Void
    let openMilestone: (Milestone.ID) -> Void
    let createMilestone: () -> Void
    let filter: (IssueFilter) -> Void
    var questions: [Question] = []
    var documents: [ProjectDocument] = []
    var mergeResults: ProjectMergeResults?
    let openDocument: (String) -> Void
    let request: (String) -> Void
    var milestones: [Milestone] = []
    var weekPlans: [ProjectWeekPlan] = []

    var body: some View {
        let active = issues.filter { $0.archivedAt == nil }
        let attention = active.filter(\.needsAttention)
        let applied = active.filter { $0.displayStatus == .completed }
            .sorted { (IssueCards.completion(of: $0) ?? .distantPast) > (IssueCards.completion(of: $1) ?? .distantPast) }
        let counts = IssueCounts(issues: issues, questions: questions)
        VStack(alignment: .leading, spacing: K.s5) {
            currentMilestone
            ProjectWeekCard(store: store, project: project, issues: issues, milestones: milestones,
                            plans: weekPlans, open: open)
            FlowRow(spacing: K.s2) {
                count(counts.count(.awaitingApproval), IssueStatus.awaitingApproval.title, K.muted, .awaitingApproval)
                count(counts.count(.needsAnswer), IssueStatus.needsAnswer.title, K.amber, .needsAnswer)
                count(counts.count(.inProgress), IssueStatus.inProgress.title, K.accent, .inProgress)
                count(counts.count(.judging), IssueStatus.judging.title, K.muted, .judging)
                count(counts.count(.awaitingIntegration), IssueStatus.awaitingIntegration.title, K.green, .awaitingIntegration)
                count(counts.count(.unmet), IssueStatus.unmet.title, K.red, .unmet)
                count(counts.count(.failed), IssueStatus.failed.title, K.red, .failed)
                count(counts.completedThisWeek, "이번 주 완료", K.green, .completed)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    work(attention, applied).frame(minWidth: 420)
                    side.frame(width: 320)
                }
                VStack(alignment: .leading, spacing: 20) { work(attention, applied); side }
            }
        }
    }

    /// The plan's current stage: target date, status, this week's scope and a link to the tab.
    /// Uses the same selection rule as the milestones tab so the link opens this exact stage.
    @ViewBuilder private var currentMilestone: some View {
        let current = Milestone.current(in: milestones)
        ProjectCard(title: "현재 마일스톤", accessory: {
            if let current {
                KButton(title: "자세히") { openMilestone(current.id) }
                    .accessibilityIdentifier("overview-milestone-detail")
            }
        }) {
            if let milestone = current {
                VStack(alignment: .leading, spacing: K.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                        Text(milestone.title).font(K.body.weight(.semibold))
                        milestoneChip(milestone)
                        Spacer(minLength: K.s1)
                        if let date = milestone.targetDate {
                            Text("목표 " + date.formatted(date: .abbreviated, time: .omitted))
                                .font(K.secondary).foregroundStyle(K.muted)
                        }
                    }
                    if milestone.status == .blocked, let reason = milestone.blockedReason {
                        Text("막힘: " + reason).font(K.secondary).foregroundStyle(K.red)
                    }
                    if milestones.allSatisfy(\.isReached) {
                        Text("모든 마일스톤에 도달했어요. 지난 단계는 마일스톤 탭에서 볼 수 있어요.")
                            .font(K.caption).foregroundStyle(K.green)
                    }
                    if !milestone.detail.isEmpty {
                        Text(milestone.detail).font(K.secondary).foregroundStyle(K.muted)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, K.s4).padding(.bottom, K.s4)
            } else {
                HStack(alignment: .center, spacing: K.s3) {
                    VStack(alignment: .leading, spacing: K.s1) {
                        Text("아직 마일스톤이 없어요").font(K.secondary.weight(.semibold))
                        Text("이번 단계와 완료 조건을 적어 두면 Stallari가 이슈를 어디에 붙일지 알 수 있어요.")
                            .font(K.secondary).foregroundStyle(K.faint)
                    }
                    Spacer(minLength: K.s2)
                    KButton(title: "마일스톤 만들기", enabled: !project.archived) { createMilestone() }
                        .accessibilityIdentifier("overview-milestone-create")
                }
                .padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
        }
    }

    private func milestoneChip(_ milestone: Milestone) -> some View {
        let status = milestone.displayStatus
        let (fg, bg): (Color, Color?) = switch status {
        case .planned: (K.muted, nil)
        case .active: (K.accent, K.accentSoft)
        case .blocked: (K.red, K.redSoft)
        case .reached: (K.green, K.greenSoft)
        }
        return Chip(text: status.title, fg: fg, bg: bg)
    }

    private func count(_ n: Int, _ label: String, _ color: Color, _ target: IssueFilter) -> some View {
        Button { filter(target) } label: {
            HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                Text("\(n)").font(K.title).monospacedDigit().foregroundStyle(n == 0 ? K.faint : color)
                    .contentTransition(.numericText()).animation(Motion.numberPop, value: n)
                Text(label).font(K.secondary).foregroundStyle(K.muted)
            }
            .padding(.horizontal, K.s4).padding(.vertical, K.s3)
            .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
            .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label) 이슈만 보기")
    }

    private func work(_ attention: [Issue], _ applied: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: K.s5) {
            ProjectCard(title: "합칠 결과", subtitle: "main에 아직 없는 Hird 커밋") {
                VStack(alignment: .leading, spacing: K.s3) {
                    if let mergeResults {
                        if let problem = mergeResults.problem {
                            Text(problem).font(K.secondary).foregroundStyle(K.red)
                        }
                        if mergeResults.results.isEmpty && mergeResults.problem == nil {
                            Text("합칠 결과가 없어요").font(K.secondary).foregroundStyle(K.faint)
                        }
                        ForEach(mergeResults.results) { result in
                            VStack(alignment: .leading, spacing: K.s2) {
                                Button { open(result.issueID) } label: {
                                    Text(result.title).font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
                                }
                                .buttonStyle(.plain)
                                Text("커밋 \(result.commitCount)개 · 바뀐 파일 \(result.changedFileCount)개 · \(result.judgement)")
                                    .font(K.caption).foregroundStyle(K.muted)
                                KButton(title: "Stallari에게 합치기 요청", enabled: !project.archived) {
                                    request("이 프로젝트의 이슈 ‘\(result.title)’ (\(result.issueID.rawValue)), 결과 \(result.id)를 검토하고 main에 합쳐 주세요.")
                                }
                            }
                            if result.id != mergeResults.results.last?.id { Divider().overlay(K.line) }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
            ProjectCard(title: "현재 작업", subtitle: "승인 대기 · 진행 중 · 판정 전") {
                rows(attention, empty: project.archived ? "현재 작업이 없어요." : "현재 작업이 없어요. Stallari에게 새 이슈를 맡겨 보세요.")
            }
            ProjectCard(title: "최근 완료한 이슈", accessory: { KButton(title: "전체 보기") { filter(.completed) } }) {
                rows(Array(applied.prefix(4)), empty: "아직 완료한 이슈가 없어요.")
            }
        }
    }

    @ViewBuilder private func rows(_ list: [Issue], empty: String) -> some View {
        if list.isEmpty {
            Text(empty).font(K.secondary).foregroundStyle(K.faint)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        } else {
            VStack(spacing: 0) {
                ForEach(list) { t in
                    Divider().overlay(K.line)
                    ProjectIssueRow(issue: t, open: open, hasPendingQuestion: questions.contains { $0.issue == t.id && $0.isPending })
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProjectCard(title: "최근 문서", accessory: { KButton(title: "전체 보기") { show(.documents) } }) {
                VStack(alignment: .leading, spacing: K.s3) {
                    if documents.isEmpty {
                        Text("Markdown 문서가 없어요").font(K.secondary).foregroundStyle(K.faint)
                    }
                    ForEach(documents) { document in
                        Button { openDocument(document.relativePath) } label: {
                            VStack(alignment: .leading, spacing: K.s1) {
                                Text(document.relativePath).font(K.mono).foregroundStyle(K.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(K.caption).foregroundStyle(K.faint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(document.relativePath)
                        .accessibilityIdentifier("project-recent-document-\(document.relativePath)")
                    }
                }
                .padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
            ProjectCard(title: "프로젝트 폴더") {
                FlowRow(spacing: K.s2) {
                    KButton(title: "Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true)) }
                    KButton(title: "터미널") { ProjectFolderActions.terminal(project.path) }
                    KButton(title: "편집기") { ProjectFolderActions.editor(project.path) }
                }
                .padding(.horizontal, K.s4).padding(.bottom, K.s4)
            }
            ProjectCard(title: "저장소", subtitle: inspection.map { "\($0.readAt.formatted(date: .omitted, time: .shortened))에 읽음" },
                        accessory: { KButton(title: "다시 읽기") { Task { await reload() } } }) {
                VStack(alignment: .leading, spacing: 6) {
                    if let i = inspection {
                        if let problem = i.problem {
                            Text(problem).font(K.secondary).foregroundStyle(K.red)
                        } else {
                            pair("브랜치", i.branch ?? "없음 (HEAD 분리)", mono: true)
                            pair("원격과 차이", i.ahead == nil ? "원격 브랜치 없음" : (i.ahead == 0 && i.behind == 0 ? "같음" : "↑\(i.ahead ?? 0)  ↓\(i.behind ?? 0)"))
                            Divider().overlay(K.line).padding(.vertical, 4)
                            label("커밋 안 한 파일 \(i.changes.count)")
                            if i.changes.isEmpty { Text("없어요").font(K.secondary).foregroundStyle(K.faint) }
                            ForEach(Array(i.changes.prefix(6).enumerated()), id: \.offset) { _, c in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(c.code).font(K.mono).foregroundStyle(c.code == "??" ? K.green : K.amber).frame(width: 18, alignment: .leading)
                                    Text(c.path).font(K.mono).lineLimit(1).truncationMode(.head)
                                }
                            }
                            if i.changes.count > 6 { Text("외 \(i.changes.count - 6)개").font(K.secondary).foregroundStyle(K.faint) }
                            Divider().overlay(K.line).padding(.vertical, 4)
                            label("최근 커밋")
                            if i.commits.isEmpty { Text("커밋이 없어요").font(K.secondary).foregroundStyle(K.faint) }
                            ForEach(i.commits, id: \.hash) { c in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(c.hash).font(K.mono).foregroundStyle(K.muted)
                                    Text(c.subject).font(K.secondary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(c.date.formatted(.relative(presentation: .named))).font(K.caption).foregroundStyle(K.faint).lineLimit(1)
                                }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
            ProjectCard(title: "Stallari가 판정에 쓰는 것", accessory: { KButton(title: "고치기") { show(.guide) } }) {
                VStack(alignment: .leading, spacing: 6) {
                    pair("AGENTS.md", inspection == nil ? "읽는 중" : (inspection?.agents == nil ? "없음" : "있음"), warn: inspection != nil && inspection?.agents == nil)
                    pair("검증 명령", "\(project.settings.verification.count)개")
                    pair("기본 완료 조건", "\(project.settings.criteria.count)개")
                    pair("결과 반영", project.settings.resultMode == .merge ? "확인하면 현재 브랜치에 합침" : "Hird 브랜치로 남김")
                    pair("동시에 일하는 Hird", project.settings.maxHirds == 0 ? "제한 없음" : "\(project.settings.maxHirds)명")
                    if !project.settings.memo.isEmpty {
                        Divider().overlay(K.line).padding(.vertical, 4)
                        label("메모")
                        Text(project.settings.memo).font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
    }

    private func pair(_ name: String, _ value: String, mono: Bool = false, warn: Bool = false) -> some View {
        HStack {
            Text(name).font(K.secondary)
            Spacer()
            Text(value).font(mono ? K.mono : K.secondary).foregroundStyle(warn ? K.red : K.muted).lineLimit(1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
    }
}

// MARK: - 이슈

struct ProjectIssues: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let issues: [Issue]
    @Binding var filter: IssueFilter
    let open: (Issue.ID) -> Void
    let talk: (String) -> Void
    @AppStorage("knarr.projectBoard") private var board = false
    @State private var composing = false
    @State private var request = ""
    @State private var sent = false

    var body: some View {
        let pending = Set(store.questions.filter(\.isPending).compactMap(\.issue))
        let shown = issues.filter { filter.includes($0, hasPendingQuestion: pending.contains($0.id)) }
        VStack(alignment: .leading, spacing: K.s4) {
            HStack(spacing: K.s3) {
                Segmented(options: IssueFilter.allCases.map { option in
                    (option, "\(option.title) \(issues.filter { option.includes($0, hasPendingQuestion: pending.contains($0.id)) }.count)")
                }, selection: $filter)
                Spacer(minLength: 8)
                Segmented(options: [(false, "목록"), (true, "보드")], selection: $board)
                KButton(title: "새 이슈", style: .primary, enabled: !project.archived) { composing = true; sent = false }
            }
            VStack(alignment: .leading, spacing: 0) {
                if composing { composer.transition(.softReveal) }
                if sent {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").foregroundStyle(K.green)
                        Text("Stallari에게 보냈어요. 완료 조건을 정하면 여기 이슈로 나타나요.")
                        Spacer()
                        KButton(title: "대화 보기") { talk(project.id) }
                    }
                    .font(K.secondary).padding(.bottom, 4)
                    .transition(.softReveal)
                }
            }
            .clipped()
            .animation(Motion.disclosure, value: composing)
            .animation(Motion.disclosure, value: sent)

            if board {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: K.s3) {
                        ForEach(IssueStatus.openCases, id: \.self) { status in
                            column(status.title, shown.filter { $0.presentationStatus(hasPendingQuestion: pending.contains($0.id)) == status })
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                ProjectCard(title: filter.title, subtitle: "\(shown.count)개") {
                    if shown.isEmpty {
                        Text("이 상태의 이슈가 없어요").font(K.secondary).foregroundStyle(K.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(shown) { t in
                                Divider().overlay(K.line)
                                ProjectIssueRow(issue: t, open: open, hasPendingQuestion: pending.contains(t.id))
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(project.name)에 맡길 이슈").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            TextEditor(text: $request)
                .font(K.body).scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if request.isEmpty {
                        Text("예: 설정 화면에서 알림 시간을 고를 수 있게 해줘. 테스트도 같이.")
                            .font(K.body).foregroundStyle(K.faint).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("Stallari가 완료 조건을 정하고 필요하면 Hird를 보내요.").font(K.secondary).foregroundStyle(K.faint)
                Spacer()
                KButton(title: "취소") { composing = false }
                KButton(title: "Stallari에게 맡기기", style: .primary, enabled: !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    store.send(request, about: nil, project: project.id, attachments: [])
                    request = ""; composing = false; sent = true
                }
            }
        }
        .padding(12)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.lineStrong))
        .padding(.bottom, 4)
    }

    private func column(_ title: String, _ list: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title); Spacer(); Text("\(list.count)")
            }
            .font(K.secondary.weight(.semibold)).foregroundStyle(K.muted).padding(.horizontal, 4)
            ForEach(list) { t in
                PanelCard(issue: t, asking: store.pendingQuestions(for: t.id).count > 0, selected: false) { open(t.id) }
            }
            if list.isEmpty { Text("없음").font(K.secondary).foregroundStyle(K.faint).padding(4) }
        }
        .padding(10)
        .frame(width: 250, alignment: .top)
        .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rCard))
    }
}

/// A compact segmented control in the app's own look.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(K.secondary.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? K.ink : K.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? K.surface : .clear, in: RoundedRectangle(cornerRadius: K.rSmall))
                        .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(on ? K.lineStrong : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .fixedSize()
            }
        }
        .padding(2)
        .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
        .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.line))
    }
}

// MARK: - 실행 기록

struct ProjectRuns: View {
    let store: any KnarrStore
    let issues: [Issue]
    let open: (Issue.ID) -> Void

    var body: some View {
        let runs = issues.flatMap { t in t.hirds.map { (issue: t, run: $0) } }.sorted { $0.run.lastActivityAt > $1.run.lastActivityAt }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("이 프로젝트의 Hird 실행 \(runs.count)개").font(K.secondary).foregroundStyle(K.muted)
                Spacer()
                if let bytes = store.storageBytes {
                    Text("작업 사본 전체 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(K.secondary).foregroundStyle(K.faint)
                }
                KButton(title: "끝난 작업 사본 정리") { store.cleanFinishedWorkspaces() }
                    .help("완료하거나 중단한 작업 사본을 모든 프로젝트에서 지워요. 작업 중인 사본은 남겨요.")
            }
            ProjectCard(title: "실행", subtitle: "행을 누르면 그 이슈가 열려요") {
                if runs.isEmpty {
                    Text("아직 Hird가 일한 적이 없어요").font(K.secondary).foregroundStyle(K.faint)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
                        header
                        ForEach(runs, id: \.run.id) { item in
                            Divider().overlay(K.line)
                            Button { open(item.issue.id) } label: { row(item.issue, item.run) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Hird").frame(width: 160, alignment: .leading)
            Text("이슈").frame(maxWidth: .infinity, alignment: .leading)
            Text("단계").frame(width: 60, alignment: .leading)
            Text("상태").frame(width: 150, alignment: .leading)
        }
        .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(K.sunken)
    }

    private func row(_ issue: Issue, _ run: HirdRun) -> some View {
        let p = run.progress
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(run.name).font(K.secondary.weight(.semibold))
                Text(run.roleSummary).font(K.secondary).foregroundStyle(K.faint).lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
            Text(issue.title).font(K.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(p.done)/\(p.total)").font(K.secondary).monospacedDigit().foregroundStyle(K.muted).frame(width: 60, alignment: .leading)
            LivenessLabel(compute: { run.liveness(now: $0) }).frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - 지침과 검증

struct ProjectGuide: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let inspection: ProjectInspection?
    let reload: () async -> Void
    let talk: (String) -> Void
    @State private var draft = ProjectSettings()
    @State private var newCriterion = ""
    @State private var editing: String?
    /// The AGENTS.md text the edit started from; nil when there was no file.
    @State private var editBase: String?
    @State private var saving = false
    @State private var agentsMessage: (text: String, ok: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            agents
            section("검증 명령", "Stallari가 Hird 결과를 판정할 때 이 명령의 출력을 증거로 요구해요.") { verification }
            section("기본 완료 조건", "이 프로젝트의 이슈마다 Stallari가 정한 완료 조건에 항상 더해요.") { criteria }
            section("Stallari 메모", "저장소에 넣기 애매한, 나와 Stallari 사이의 약속이에요. Knarr에만 저장돼요.") {
                TextEditor(text: $draft.memo)
                    .font(K.secondary).scrollContentBackground(.hidden)
                    .padding(6).frame(minHeight: 84)
                    .background(K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
                    .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
            }
            if draft.cleaned != project.settings.cleaned {
                HStack(spacing: 8) {
                    Text("저장하지 않은 변경이 있어요").font(K.secondary).foregroundStyle(K.muted)
                    Spacer()
                    KButton(title: "되돌리기") { draft = project.settings }
                    KButton(title: "저장", style: .primary) { store.updateProjectSettings(project.id, draft) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rCard))
            }
        }
        .onAppear { draft = project.settings }
        .onChange(of: project.settings) { _, saved in draft = saved }
    }

    private func section<Content: View>(_ title: String, _ hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(K.title)
            Text(hint).font(K.secondary).foregroundStyle(K.faint).padding(.bottom, 6)
            content()
        }
    }

    @ViewBuilder private var agents: some View {
        section("AGENTS.md", "저장소에 있는 파일이에요. Stallari와 Hird가 이슈를 시작할 때 읽어요. 저장하면 이 파일만 커밋해서 새 Hird도 바로 읽어요.") {
            if let editing {
                VStack(alignment: .leading, spacing: 8) {
                    if inspection?.agents?.uncommitted == true {
                        Text("이 파일에 커밋하지 않은 변경이 있어요. 저장하면 그 변경까지 같이 커밋돼요.")
                            .font(K.secondary).foregroundStyle(K.amber)
                    }
                    TextEditor(text: Binding(get: { editing }, set: { self.editing = $0 }))
                        .font(K.mono).scrollContentBackground(.hidden)
                        .padding(8).frame(minHeight: 220)
                        .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rCard))
                        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.lineStrong))
                    HStack {
                        Spacer()
                        KButton(title: "취소") { self.editing = nil; agentsMessage = nil }
                        KButton(title: saving ? "저장 중" : "저장하고 커밋", style: .primary, enabled: !saving) { save(editing) }
                    }
                }
            } else if let problem = inspection?.problem {
                Text(problem + ". 폴더를 확인해 주세요.").font(K.secondary).foregroundStyle(K.red)
            } else if let file = inspection?.agents {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(file.text).font(K.mono).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(maxHeight: 260)
                    .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rCard))
                    .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
                    HStack(spacing: 8) {
                        if file.uncommitted { Text("커밋 안 된 변경 있음").font(K.secondary).foregroundStyle(K.amber) }
                        Spacer()
                        KButton(title: "편집") { editBase = file.text; editing = file.text; agentsMessage = nil }
                    }
                }
            } else if inspection != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("이 저장소에는 AGENTS.md가 없어요. Hird가 빌드·테스트 방법을 매번 새로 찾아야 해요.")
                        .font(K.secondary).foregroundStyle(K.muted)
                    HStack(spacing: 8) {
                        KButton(title: "직접 쓰기") { editBase = nil; editing = "# \(project.name) 작업 규칙\n\n- 테스트: \n"; agentsMessage = nil }
                        KButton(title: "Stallari에게 초안 받기", enabled: !project.archived) {
                            store.send("이 프로젝트를 읽고 AGENTS.md 초안을 써줘. 빌드·테스트 명령과 지켜야 할 규칙 위주로 짧게. 파일은 만들지 말고 내용만 답해줘. 내가 프로젝트 화면에서 붙여 넣고 저장할게.",
                                       about: nil, project: project.id, attachments: [])
                            talk(project.id)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
                .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
            } else {
                ProgressView().controlSize(.small)
            }
            if let message = agentsMessage {
                Text(message.text).font(K.secondary).foregroundStyle(message.ok ? K.green : K.red).padding(.top, 4)
            }
        }
    }

    private func save(_ text: String) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.saveAgentsFile(project.id, text: text, expected: editBase)
                editing = nil
                agentsMessage = ("저장하고 AGENTS.md만 커밋했어요", true)
                await reload()
            } catch {
                agentsMessage = ((error as? LocalizedError)?.errorDescription ?? "AGENTS.md를 저장하지 못했어요. 폴더 권한과 저장소 상태를 확인해 주세요", false)
            }
        }
    }

    private var verification: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("이름").frame(width: 130, alignment: .leading)
                Text("명령").frame(maxWidth: .infinity, alignment: .leading)
                Text("언제").frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(K.sunken)
            ForEach(draft.verification.indices, id: \.self) { i in
                Divider().overlay(K.line)
                HStack(spacing: 8) {
                    field("예: 전체 테스트", $draft.verification[i].name).frame(width: 130)
                    field("예: swift test", $draft.verification[i].command, mono: true)
                    Picker("", selection: $draft.verification[i].timing) {
                        ForEach(VerificationCommand.Timing.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    Button { draft.verification.remove(at: i) } label: { Image(systemName: "xmark").font(K.caption).foregroundStyle(K.faint) }
                        .buttonStyle(.plain).frame(width: 24).help("이 명령 빼기").accessibilityLabel("이 명령 빼기")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            if draft.verification.isEmpty {
                Divider().overlay(K.line)
                Text("검증 명령이 없어요. Stallari가 결과를 판정할 근거가 약해져요.")
                    .font(K.secondary).foregroundStyle(K.faint).padding(.vertical, 14)
            }
            Divider().overlay(K.line)
            HStack {
                KButton(title: "명령 추가") { draft.verification.append(.init(name: "", command: "")) }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .clipShape(RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    private var criteria: some View {
        VStack(spacing: 0) {
            ForEach(Array(draft.criteria.enumerated()), id: \.offset) { i, c in
                if i > 0 { Divider().overlay(K.line) }
                HStack {
                    Text(c).font(K.secondary)
                    Spacer()
                    Button { draft.criteria.remove(at: i) } label: { Image(systemName: "xmark").font(K.caption).foregroundStyle(K.faint) }
                        .buttonStyle(.plain).help("이 조건 빼기").accessibilityLabel("이 조건 빼기")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            if !draft.criteria.isEmpty { Divider().overlay(K.line) }
            HStack(spacing: 8) {
                field("예: 공개 API를 바꾸면 CHANGELOG에 적는다", $newCriterion).onSubmit(addCriterion)
                KButton(title: "추가", enabled: !newCriterion.trimmingCharacters(in: .whitespaces).isEmpty, action: addCriterion)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    private func addCriterion() {
        let c = newCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !draft.criteria.contains(c) else { return }
        draft.criteria.append(c); newCriterion = ""
    }
}

/// A plain text field in the app's look.
func field(_ prompt: String, _ text: Binding<String>, mono: Bool = false) -> some View {
    TextField(prompt, text: text)
        .textFieldStyle(.plain)
        .font(mono ? K.mono : K.secondary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
        .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
}

// MARK: - 설정

struct ProjectSettingsTab: View {
    let store: any KnarrStore
    let project: ProjectSummary
    @State private var name = ""
    @State private var confirmingArchive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("이름", nil) {
                HStack(spacing: 8) {
                    field("프로젝트 이름", $name).frame(maxWidth: 320).onSubmit(rename)
                    if name.trimmingCharacters(in: .whitespaces) != project.name {
                        KButton(title: "바꾸기", style: .primary, enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, action: rename)
                    }
                }
            }
            row("프로젝트 화면", "준비·아카이브형은 공고·작성본·진행 기록을 모아 봐요") {
                Picker("프로젝트 화면", selection: Binding(get: { project.settings.workspaceStyle }, set: { value in change { $0.workspaceStyle = value } })) {
                    ForEach(ProjectSettings.WorkspaceStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("project-workspace-style")
            }
            row("색", nil) {
                HStack(spacing: 8) {
                    ForEach(K.projectColors.indices, id: \.self) { i in
                        Button { change { $0.color = i } } label: {
                            RoundedRectangle(cornerRadius: K.rSmall).fill(K.projectColors[i]).frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(project.settings.color == i ? K.ink : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain).accessibilityLabel("색 \(i + 1)")
                        .accessibilityAddTraits(project.settings.color == i ? .isSelected : [])
                    }
                }
                .padding(.leading, 3)
            }
            row("폴더", "폴더를 옮겼다면 새 위치를 프로젝트로 추가해 주세요") {
                HStack(spacing: 8) {
                    Text(project.path).font(K.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    KButton(title: "Finder에서 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true)) }
                }
            }
            row("결과 반영", "Stallari가 판정한 결과를 통합할 때") {
                VStack(alignment: .leading, spacing: 8) {
                    radio(.merge, "현재 브랜치에 합치기", "커밋 안 한 변경이나 충돌이 있으면 합치지 않고 알려줘요")
                    radio(.branch, "Hird 브랜치로만 남기기", "knarr/hird/… 브랜치에 보관하고, 통합은 Stallari가 처리해요")
                }
            }
            row("동시에 일하는 Hird", "이 프로젝트에서 한 번에") {
                HStack(spacing: 0) {
                    stepButton("minus", -1, enabled: project.settings.maxHirds != ProjectSettings.hirdRange.lowerBound)
                    Text(project.settings.maxHirds == 0 ? "제한 없음" : "\(project.settings.maxHirds)명").font(K.secondary).monospacedDigit().frame(width: 68)
                        .contentTransition(.numericText()).animation(Motion.numberPop, value: project.settings.maxHirds)
                    stepButton("plus", 1, enabled: project.settings.maxHirds != 0)
                }
                .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
                .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
            }
            row("Hird 모델", "새 제안부터 적용해요") {
                Picker("", selection: Binding(get: { project.settings.hirdModel ?? "" }, set: { v in change { $0.hirdModel = v.isEmpty ? nil : v } })) {
                    Text("기본값 (6.1 Sol)").tag("")
                    ForEach(store.models, id: \.self) { Text($0).tag($0) }
                    if let m = project.settings.hirdModel, !store.models.contains(m) { Text(m + " (지금 쓸 수 없음)").tag(m) }
                }
                .labelsHidden().fixedSize()
            }
            row("Hird 추론 수준", "Stallari와 별도로 새 제안부터 적용해요") {
                Picker("", selection: Binding(get: { project.settings.hirdThinking }, set: { value in change { $0.hirdThinking = value } })) {
                    ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
            }
            archive.padding(.top, 24)
        }
        .onAppear { name = project.name }
        .onChange(of: project.name) { _, saved in name = saved }
    }

    private func rename() { store.renameProject(project.id, to: name) }
    private func change(_ edit: (inout ProjectSettings) -> Void) {
        var s = project.settings; edit(&s); store.updateProjectSettings(project.id, s)
    }

    private func row<Content: View>(_ title: String, _ hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(K.secondary.weight(.semibold))
                    if let hint { Text(hint).font(K.secondary).foregroundStyle(K.faint).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(width: 200, alignment: .leading)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
            Divider().overlay(K.line)
        }
    }

    private func radio(_ mode: ProjectSettings.ResultMode, _ title: String, _ hint: String) -> some View {
        Button { change { $0.resultMode = mode } } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: project.settings.resultMode == mode ? "largecircle.fill.circle" : "circle")
                    .font(K.body).foregroundStyle(project.settings.resultMode == mode ? K.accent : K.faint)
                    .contentTransition(.symbolEffect(.replace)).animation(Motion.iconSwap, value: project.settings.resultMode)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(K.secondary)
                    Text(hint).font(K.secondary).foregroundStyle(K.faint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(project.settings.resultMode == mode ? .isSelected : [])
    }

    private func stepButton(_ symbol: String, _ delta: Int, enabled: Bool) -> some View {
        Button {
            change {
                if $0.maxHirds == 0 { $0.maxHirds = ProjectSettings.hirdRange.upperBound }
                else if delta > 0 && $0.maxHirds >= ProjectSettings.hirdRange.upperBound { $0.maxHirds = 0 }
                else { $0.maxHirds += delta }
            }
        } label: {
            Image(systemName: symbol).font(K.caption.weight(.semibold)).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).foregroundStyle(enabled ? K.ink : K.faint)
        .accessibilityLabel(delta > 0 ? "늘리기" : "줄이기")
    }

    private var archive: some View {
        let live = store.issues(inProject: project.id).filter { $0.state == .running || $0.state == .needsInput }.count
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.archived ? "보관된 프로젝트" : "목록에서 빼기").font(K.secondary.weight(.semibold))
                Text(project.archived ? "다시 넣으면 Stallari가 새 이슈를 받아요." : "저장소 폴더와 이슈 기록은 지우지 않아요. 언제든 다시 넣을 수 있어요.")
                    .font(K.secondary).foregroundStyle(K.faint)
            }
            if project.archived {
                KButton(title: "목록에 다시 넣기") { store.setProjectArchived(project.id, false) }
            } else if confirmingArchive {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(project.name)를 목록에서 뺄까요?" + (live > 0 ? " 진행 중인 이슈 \(live)개의 Hird를 먼저 멈춰요." : ""))
                        .font(K.secondary)
                    HStack(spacing: 6) {
                        KButton(title: "목록에서 빼기", style: .destructive) { store.setProjectArchived(project.id, true); confirmingArchive = false }
                        KButton(title: "취소") { confirmingArchive = false }
                    }
                }
                .padding(12)
                .background(K.sunken, in: RoundedRectangle(cornerRadius: K.rSmall))
                .transition(.softReveal)
            } else {
                KButton(title: "목록에서 빼기…") { confirmingArchive = true }
            }
        }
        .animation(Motion.disclosure, value: confirmingArchive)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }
}
