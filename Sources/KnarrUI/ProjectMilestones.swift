import SwiftUI
import KnarrCore

/// A request from another tab: open one milestone's detail, or start a new milestone.
enum MilestoneRequest: Equatable {
    case select(Milestone.ID)
    case create
}

/// Project milestones: an ordered plan with an inline editor. Completion is recorded only by
/// verifying every criterion; the screen never derives it from issue counts.
struct ProjectMilestones: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let issues: [Issue]
    let open: (Issue.ID) -> Void
    let request: (String) -> Void
    @Binding var milestoneRequest: MilestoneRequest?

    @State private var selected: Milestone.ID?
    @State private var draft: MilestoneDraft?
    @State private var problem: String?

    private var milestones: [Milestone] { store.milestones(inProject: project.id) }
    /// One selection rule shared with the overview, so 자세히 always lands on the shown stage.
    private var effectiveSelection: Milestone.ID? {
        if let selected { return selected }
        return Milestone.current(in: milestones)?.id
    }
    private var chosen: Milestone? { effectiveSelection.flatMap { store.milestone($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: K.s5) {
            HStack(spacing: K.s3) {
                Text("마일스톤").font(K.body.weight(.semibold))
                Text("순서대로 쌓이는 프로젝트 단계").font(K.secondary).foregroundStyle(K.faint)
                Spacer(minLength: K.s2)
                KButton(title: "새 마일스톤", style: .primary, enabled: !project.archived) { create() }
                    .accessibilityIdentifier("milestone-new")
            }
            if milestones.isEmpty, draft == nil {
                empty
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: K.s5) {
                        list.frame(minWidth: 280, maxWidth: 340)
                        detail
                    }
                    VStack(alignment: .leading, spacing: K.s4) { list; detail }
                }
            }
        }
        .onChange(of: project.id) { _, _ in selected = nil; draft = nil; problem = nil; milestoneRequest = nil }
        .onAppear { consumeRequest() }
        .onChange(of: milestoneRequest) { _, _ in consumeRequest() }
    }

    /// A request set before the tab existed (the overview's 자세히) is applied on first mount.
    private func consumeRequest() {
        guard let request = milestoneRequest else { return }
        milestoneRequest = nil
        switch request {
        case .select(let id):
            selected = id
            draft = nil
            problem = nil
        case .create:
            create()
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: K.s3) {
            Text("아직 마일스톤이 없어요").font(K.body.weight(.semibold))
            Text("완료 조건과 목표일을 단계별로 남겨 두면 Stallari가 이슈를 어느 단계에 붙일지 알 수 있어요.")
                .font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
            KButton(title: "마일스톤 만들기", style: .primary, enabled: !project.archived) { create() }
                .accessibilityIdentifier("milestone-create-empty")
        }
        .padding(K.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    private var list: some View {
        VStack(spacing: K.s2) {
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                row(index + 1, milestone)
            }
        }
    }

    private func row(_ position: Int, _ milestone: Milestone) -> some View {
        let linked = issues.filter { $0.milestoneID == milestone.id && $0.archivedAt == nil }
        let met = milestone.criteria.filter { $0.state == .met }.count
        let prerequisites = milestone.prerequisites.compactMap { id in milestones.first { $0.id == id }?.title }
        return Button {
            selected = milestone.id
            draft = nil
            problem = nil
        } label: {
            VStack(alignment: .leading, spacing: K.s2) {
                HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                    Text("\(position)").font(K.caption).monospacedDigit().foregroundStyle(K.faint)
                    Text(milestone.title).font(K.secondary.weight(.semibold)).foregroundStyle(K.ink)
                        .lineLimit(1)
                    Spacer(minLength: K.s1)
                    statusChip(milestone)
                }
                HStack(spacing: K.s2) {
                    if let date = milestone.targetDate {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).font(K.caption).foregroundStyle(K.muted)
                    } else {
                        Text("목표일 없음").font(K.caption).foregroundStyle(K.faint)
                    }
                    Text("조건 \(met)/\(milestone.criteria.count)").font(K.caption).foregroundStyle(K.faint)
                    if !linked.isEmpty { Text("이슈 \(linked.count)").font(K.caption).foregroundStyle(K.faint) }
                }
                if !prerequisites.isEmpty {
                    Text("선행: " + prerequisites.joined(separator: ", "))
                        .font(K.caption).foregroundStyle(K.faint).lineLimit(1)
                }
                if milestone.status == .blocked, let reason = milestone.blockedReason {
                    Text("막힘: " + reason).font(K.caption).foregroundStyle(K.red).lineLimit(2)
                }
            }
            .padding(K.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(effectiveSelection == milestone.id && draft == nil ? K.sunken : K.surface,
                        in: RoundedRectangle(cornerRadius: K.rCard))
            .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(effectiveSelection == milestone.id && draft == nil ? K.lineStrong : K.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("milestone-row-\(milestone.id.rawValue)")
        .accessibilityLabel(milestone.title)
    }

    private func statusChip(_ milestone: Milestone) -> some View {
        let status = milestone.displayStatus
        let (fg, bg): (Color, Color?) = switch status {
        case .planned: (K.muted, nil)
        case .active: (K.accent, K.accentSoft)
        case .blocked: (K.red, K.redSoft)
        case .reached: (K.green, K.greenSoft)
        }
        return Chip(text: status.title, fg: fg, bg: bg)
    }

    @ViewBuilder private var detail: some View {
        if let draft {
            editor(draft)
        } else if let chosen {
            summary(chosen)
        } else {
            Text(milestones.isEmpty ? "새 마일스톤으로 이번 단계를 적어 보세요." : "왼쪽에서 마일스톤을 고르세요.")
                .font(K.secondary).foregroundStyle(K.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(K.s4)
                .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
                .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
        }
    }

    // MARK: Summary

    private func summary(_ milestone: Milestone) -> some View {
        let linked = issues.filter { $0.milestoneID == milestone.id }
        let prerequisites = milestone.prerequisites.compactMap { id in milestones.first { $0.id == id }?.title }
        return VStack(alignment: .leading, spacing: K.s4) {
            HStack(alignment: .top, spacing: K.s2) {
                VStack(alignment: .leading, spacing: K.s1) {
                    Text(milestone.title).font(K.title)
                        .accessibilityIdentifier("milestone-detail-title")
                    if let date = milestone.targetDate {
                        Text("목표일 " + date.formatted(date: .long, time: .omitted)).font(K.secondary).foregroundStyle(K.muted)
                    }
                }
                Spacer(minLength: K.s2)
                statusChip(milestone)
            }
            if !milestone.detail.isEmpty {
                Text(milestone.detail).font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
            }
            if milestone.status == .blocked, let reason = milestone.blockedReason {
                Text("막힘: " + reason).font(K.secondary).foregroundStyle(K.red).fixedSize(horizontal: false, vertical: true)
            }
            if !prerequisites.isEmpty { pair("선행", prerequisites.joined(separator: ", ")) }
            if !milestone.targetDateHistory.isEmpty { targetHistory(milestone.targetDateHistory) }
            if !milestone.inScope.isEmpty { bullets("이번 단계 범위", milestone.inScope) }
            if !milestone.outOfScope.isEmpty { bullets("하지 않는 것", milestone.outOfScope) }
            criteriaList(milestone)
            weekly(milestone)
            if !milestone.evidence.isEmpty { pair("증거", milestone.evidence) }
            HStack(spacing: K.s2) {
                KButton(title: "고치기", enabled: !project.archived) { edit(milestone) }
                KButton(title: "위로", enabled: !project.archived && canMove(milestone, by: -1)) { move(milestone, by: -1) }
                    .accessibilityLabel("순서 위로")
                KButton(title: "아래로", enabled: !project.archived && canMove(milestone, by: 1)) { move(milestone, by: 1) }
                    .accessibilityLabel("순서 아래로")
                KButton(title: "이슈 만들기", style: .primary, enabled: !project.archived) { makeIssue(milestone) }
                    .accessibilityIdentifier("milestone-create-issue")
                Spacer(minLength: K.s2)
                if milestone.isReached {
                    KButton(title: "다시 열기", enabled: !project.archived) { reopen(milestone) }
                } else {
                    KButton(title: "도달로 표시", enabled: !project.archived && milestone.canReach) { reach(milestone) }
                        .accessibilityIdentifier("milestone-mark-reached")
                }
            }
            if !milestone.canReach, !milestone.isReached {
                Text("모든 완료 조건에 확인 근거를 적으면 도달로 표시할 수 있어요.")
                    .font(K.caption).foregroundStyle(K.faint)
            }
            if !linked.isEmpty {
                VStack(alignment: .leading, spacing: K.s1) {
                    Text("이 마일스톤의 이슈").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                    ForEach(linked) { issue in
                        Button { open(issue.id) } label: {
                            Text(issue.title).font(K.secondary).foregroundStyle(K.accent).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(K.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    /// Stored target-date edits, newest first. Entries come from the store; the screen never
    /// derives them from the current date.
    private func targetHistory(_ changes: [Milestone.TargetDateChange]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("목표일 변경 이력").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            ForEach(Array(changes.indices.reversed()), id: \.self) { index in
                let change = changes[index]
                Text(day(change.previous) + " → " + day(change.updated) + " · "
                     + change.changedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(K.caption).foregroundStyle(K.muted)
                    .accessibilityIdentifier("milestone-history-\(index)")
            }
        }
    }

    private func day(_ date: Date?) -> String {
        guard let date else { return "날짜 없음" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func criteriaList(_ milestone: Milestone) -> some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text("완료 조건 \(milestone.criteria.filter { $0.state == .met }.count)/\(milestone.criteria.count)")
                .font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            ForEach(Array(milestone.criteria.enumerated()), id: \.offset) { _, criterion in
                HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                    Image(systemName: criterion.state == .met ? "checkmark.circle.fill" : "circle")
                        .font(K.caption).foregroundStyle(criterion.state == .met ? K.green : K.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(criterion.text).font(K.secondary)
                        if !criterion.evidence.isEmpty {
                            Text(criterion.evidence).font(K.caption).foregroundStyle(K.muted)
                        }
                    }
                }
            }
            if milestone.criteria.isEmpty { Text("완료 조건이 없어요").font(K.secondary).foregroundStyle(K.faint) }
        }
    }

    /// Weekly planning moved to the project. Older milestone weekly records stay readable as
    /// history and are never rewritten by this screen.
    private func weekly(_ milestone: Milestone) -> some View {
        let records = milestone.weeks.sorted { $0.weekStart > $1.weekStart }
        return VStack(alignment: .leading, spacing: K.s2) {
            Text("저장된 주간 기록").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            if records.isEmpty {
                Text("이 마일스톤에 저장된 주간 기록이 없어요").font(K.secondary).foregroundStyle(K.faint)
            }
            ForEach(records, id: \.weekStart) { week in
                VStack(alignment: .leading, spacing: 1) {
                    Text(week.weekStart.formatted(date: .abbreviated, time: .omitted))
                        .font(K.caption).foregroundStyle(K.muted)
                    if !week.scope.isEmpty {
                        Text(week.scope.joined(separator: " · ")).font(K.caption).foregroundStyle(K.faint)
                    }
                    if !week.result.isEmpty { Text("결과: " + week.result).font(K.caption).foregroundStyle(K.muted) }
                }
                .accessibilityIdentifier("milestone-week-\(week.weekStart.timeIntervalSinceReferenceDate)")
            }
            Text("이번 주 계획과 결과는 개요의 이번 주 계획 카드에서 봅니다.")
                .font(K.caption).foregroundStyle(K.faint)
        }
    }

    private func bullets(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("· " + line).font(K.secondary).foregroundStyle(K.muted)
            }
        }
    }

    private func pair(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: K.s2) {
            Text(name).font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            Text(value).font(K.secondary).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Editor

    private func editor(_ draft: MilestoneDraft) -> some View {
        VStack(alignment: .leading, spacing: K.s3) {
            Text(draft.isNew ? "새 마일스톤" : "마일스톤 고치기").font(K.body.weight(.semibold))
            VStack(alignment: .leading, spacing: K.s2) {
                Text("제목").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                field("예: 대화 반복 제거", binding(\.title)).accessibilityIdentifier("milestone-title")
            }
            HStack(alignment: .top, spacing: K.s3) {
                VStack(alignment: .leading, spacing: K.s2) {
                    Text("목표일").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                    field("YYYY-MM-DD", Binding(get: { draft.targetDateText ?? "" },
                                                 set: { [self] in self.draft?.targetDateText = $0 }), mono: true)
                        .frame(maxWidth: 160)
                        .accessibilityIdentifier("milestone-target")
                    if let text = draft.targetDateText, draft.parsedTargetDate == nil, !text.isEmpty {
                        Text("날짜를 YYYY-MM-DD로 적어 주세요").font(K.caption).foregroundStyle(K.red)
                    }
                }
                VStack(alignment: .leading, spacing: K.s2) {
                    Text("상태").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                    HStack(spacing: K.s1) {
                        if draft.original.status == .reached {
                            Chip(text: Milestone.Status.reached.title, fg: K.green, bg: K.greenSoft)
                        }
                        ForEach(draft.original.status == .reached ? [] : [Milestone.Status.planned, .active, .blocked], id: \.self) { status in
                            Button { set(\.status, status) } label: {
                                Chip(text: status.title,
                                     fg: draft.status == status ? K.ink : K.muted,
                                     bg: draft.status == status ? K.sunken : nil)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(draft.status == status ? .isSelected : [])
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if draft.status == .blocked {
                VStack(alignment: .leading, spacing: K.s2) {
                    Text("막힌 이유").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                    field("무엇이 기다리고 있나요?", binding(\.blockedReason))
                }
            }
            VStack(alignment: .leading, spacing: K.s2) {
                Text("완료 조건").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                ForEach(draft.criteria.indices, id: \.self) { index in
                    HStack(alignment: .center, spacing: K.s2) {
                        Button { toggleCriterion(index) } label: {
                            Image(systemName: draft.criteria[index].met ? "checkmark.circle.fill" : "circle")
                                .font(K.body).foregroundStyle(draft.criteria[index].met ? K.green : K.faint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(draft.criteria[index].met ? "확인됨" : "확인 안 됨")
                        field("결과로 확인할 수 있는 조건", criteriaText(index))
                        Button { removeCriterion(index) } label: {
                            Image(systemName: "xmark").font(K.caption).foregroundStyle(K.faint)
                        }
                        .buttonStyle(.plain).accessibilityLabel("조건 빼기")
                    }
                    field("확인 근거 (테스트, 화면 확인 등)", criteriaEvidence(index), mono: true)
                        .padding(.leading, 26)
                }
                HStack(spacing: K.s2) {
                    KButton(title: "조건 추가") { appendCriterion() }
                    Text("확인으로 표시하려면 근거가 필요해요.").font(K.caption).foregroundStyle(K.faint)
                }
            }
            VStack(alignment: .leading, spacing: K.s2) {
                Text("선행 마일스톤").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
                let options = milestones.filter { $0.id != draft.id }
                if options.isEmpty {
                    Text("같은 프로젝트에 다른 마일스톤이 없어요").font(K.caption).foregroundStyle(K.faint)
                } else {
                    ForEach(options) { option in
                        Button { togglePrerequisite(option.id) } label: {
                            HStack(spacing: K.s2) {
                                Image(systemName: draft.prerequisites.contains(option.id) ? "checkmark.square.fill" : "square")
                                    .font(K.caption).foregroundStyle(draft.prerequisites.contains(option.id) ? K.accent : K.faint)
                                Text(option.title).font(K.secondary).foregroundStyle(K.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let problem {
                Text(problem).font(K.secondary).foregroundStyle(K.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: K.s2) {
                KButton(title: "저장", style: .primary, enabled: !project.archived) { save() }
                    .accessibilityIdentifier("milestone-save")
                KButton(title: "취소") { self.draft = nil; problem = nil }
                Spacer(minLength: K.s2)
                if !draft.isNew {
                    KButton(title: "삭제", style: .destructive, enabled: !project.archived) { delete(draft) }
                }
            }
        }
        .padding(K.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.surface, in: RoundedRectangle(cornerRadius: K.rCard))
        .overlay(RoundedRectangle(cornerRadius: K.rCard).strokeBorder(K.line))
    }

    private func binding<T>(_ path: WritableKeyPath<MilestoneDraft, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft![keyPath: path] = $0 })
    }

    private func set<T>(_ path: WritableKeyPath<MilestoneDraft, T>, _ value: T) {
        draft![keyPath: path] = value
    }

    private func criteriaText(_ index: Int) -> Binding<String> {
        Binding(get: { draft?.criteria[index].text ?? "" },
                set: { draft?.criteria[index].text = $0 })
    }

    private func criteriaEvidence(_ index: Int) -> Binding<String> {
        Binding(get: { draft?.criteria[index].evidence ?? "" },
                set: { draft?.criteria[index].evidence = $0 })
    }

    private func toggleCriterion(_ index: Int) {
        guard var draft else { return }
        draft.criteria[index].met.toggle()
        self.draft = draft
    }

    private func removeCriterion(_ index: Int) {
        guard var draft, draft.criteria.indices.contains(index) else { return }
        draft.criteria.remove(at: index)
        self.draft = draft
    }

    private func appendCriterion() {
        guard var draft else { return }
        draft.criteria.append(.init())
        self.draft = draft
    }

    private func togglePrerequisite(_ id: Milestone.ID) {
        guard var draft else { return }
        if let index = draft.prerequisites.firstIndex(of: id) { draft.prerequisites.remove(at: index) }
        else { draft.prerequisites.append(id) }
        self.draft = draft
    }

    // MARK: Actions

    private func create() {
        let order = (milestones.map(\.order).max() ?? -1) + 1
        let id = Milestone.ID("m-" + UUID().uuidString.lowercased())
        selected = nil
        problem = nil
        draft = MilestoneDraft(new: Milestone(id: id, projectID: project.id, order: order, title: "",
            status: .planned, createdAt: .now), isNew: true)
    }

    private func edit(_ milestone: Milestone) {
        selected = milestone.id
        problem = nil
        draft = MilestoneDraft(new: milestone, isNew: false)
    }

    private func save() {
        guard let draft else { return }
        guard let milestone = draft.milestone else { problem = "제목과 목표일을 확인해 주세요"; return }
        do {
            try milestone.validate(inProject: project.id, existing: milestones)
            store.saveMilestone(milestone)
            selected = milestone.id
            self.draft = nil
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "마일스톤을 저장하지 못했어요"
        }
    }

    private func reach(_ milestone: Milestone) {
        var value = milestone
        do {
            try value.markReached(at: .now)
            store.saveMilestone(value)
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "도달로 표시하지 못했어요"
        }
    }

    private func reopen(_ milestone: Milestone) {
        var value = milestone
        value.reopen(at: .now)
        store.saveMilestone(value)
    }

    private func canMove(_ milestone: Milestone, by offset: Int) -> Bool {
        guard let index = milestones.firstIndex(where: { $0.id == milestone.id }) else { return false }
        return milestones.indices.contains(index + offset)
    }

    /// Swaps with its neighbour through the store's one-transaction reorder.
    private func move(_ milestone: Milestone, by offset: Int) {
        guard let index = milestones.firstIndex(where: { $0.id == milestone.id }),
              milestones.indices.contains(index + offset) else { return }
        var ids = milestones.map(\.id)
        ids.swapAt(index, index + offset)
        store.reorderMilestones(projectID: project.id, orderedIDs: ids)
    }

    private func delete(_ draft: MilestoneDraft) {
        store.deleteMilestone(draft.id)
        if selected == draft.id { selected = nil }
        self.draft = nil
    }

    /// Uses the project conversation: the composer draft names the milestone ID so Stallari can
    /// attach the created issue, with no separate milestone-only chat.
    private func makeIssue(_ milestone: Milestone) {
        let criteria = milestone.criteria.isEmpty ? "아직 완료 조건이 없어요. 함께 정해 주세요."
            : milestone.criteria.map { "- " + $0.text }.joined(separator: "\n")
        let scope = milestone.inScope.isEmpty ? "정하지 않음" : milestone.inScope.joined(separator: ", ")
        request("‘\(milestone.title)’ 마일스톤(마일스톤 ID: \(milestone.id.rawValue)) 기준으로 이슈를 만들어 주세요.\n목표: \(milestone.detail.isEmpty ? milestone.title : milestone.detail)\n완료 조건:\n\(criteria)\n범위: \(scope)")
    }
}

/// Editable snapshot of a milestone. Only title, criteria, target date, status and prerequisites
/// are inputs; description, scope and weekly history stay on the stored value untouched.
struct MilestoneDraft {
    struct CriterionDraft {
        var text = ""
        var met = false
        var evidence = ""
    }

    let original: Milestone
    let isNew: Bool
    var title: String
    var status: Milestone.Status
    var blockedReason: String
    var targetDateText: String?
    var prerequisites: [Milestone.ID]
    var criteria: [CriterionDraft]

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var id: Milestone.ID { original.id }
    var projectID: String { original.projectID }

    init(new milestone: Milestone, isNew: Bool) {
        original = milestone
        self.isNew = isNew
        title = milestone.title
        status = milestone.status
        blockedReason = milestone.blockedReason ?? ""
        targetDateText = milestone.targetDate.map { Self.day.string(from: $0) }
        prerequisites = milestone.prerequisites
        criteria = milestone.criteria.map { .init(text: $0.text, met: $0.state == .met, evidence: $0.evidence) }
    }

    /// A blank target date stays blank; unparseable text is reported by the caller.
    var parsedTargetDate: Date? {
        guard let text = targetDateText?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Self.day.date(from: text)
    }

    /// Applies the edited fields over the stored milestone. Fields this form does not show
    /// (`detail`, `inScope`, `outOfScope`, `weeks`, `evidence`, `targetDateHistory`) are carried through.
    var milestone: Milestone? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let text = targetDateText?.trimmingCharacters(in: .whitespaces), !text.isEmpty, parsedTargetDate == nil { return nil }
        var value = original
        value.title = title
        value.targetDate = parsedTargetDate
        if original.status == .reached {
            // A reached milestone stays reached while its text or date is edited; only 다시 열기 clears it.
            value.status = .reached
            value.reachedAt = original.reachedAt
        } else {
            value.status = status
            value.reachedAt = nil
        }
        let reason = blockedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        value.blockedReason = reason.isEmpty ? nil : reason
        value.criteria = criteria.map { .init(text: $0.text, state: $0.met ? .met : .pending, evidence: $0.evidence) }
        value.prerequisites = prerequisites
        value.updatedAt = .now
        return value
    }
}
