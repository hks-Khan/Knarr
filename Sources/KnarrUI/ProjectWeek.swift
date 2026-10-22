import SwiftUI
import KnarrCore

/// A project's weekly plan and its automatic results. The plan is the only input; results are
/// issues judged satisfied in that week, so completing an issue never edits the plan or a milestone.
struct ProjectWeekCard: View {
    let store: any KnarrStore
    let project: ProjectSummary
    let issues: [Issue]
    var milestones: [Milestone] = []
    var plans: [ProjectWeekPlan] = []
    let open: (Issue.ID) -> Void
    var now: Date = .now

    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?

    private var thisWeek: Date { ProjectWeek.start(containing: now) }
    private var current: ProjectWeekPlan? { plans.first { $0.weekStart == thisWeek } }
    private var past: [ProjectWeekPlan] { plans.filter { $0.weekStart < thisWeek } }
    private var results: [ProjectWeeklyResult] {
        ProjectWeek.results(issues: issues, milestones: milestones, weekStart: thisWeek)
    }

    var body: some View {
        ProjectCard(title: "이번 주 계획", subtitle: weekRange) {
            VStack(alignment: .leading, spacing: K.s3) {
                plan
                Divider().overlay(K.line)
                resultsSection
                if !past.isEmpty {
                    Divider().overlay(K.line)
                    history
                }
            }
            .padding(.horizontal, K.s4).padding(.bottom, K.s4)
        }
    }

    private var weekRange: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: thisWeek) ?? thisWeek
        return thisWeek.formatted(date: .abbreviated, time: .omitted) + " – "
            + end.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder private var plan: some View {
        if editing {
            VStack(alignment: .leading, spacing: K.s2) {
                TextEditor(text: $draft)
                    .font(K.secondary).scrollContentBackground(.hidden)
                    .padding(6).frame(minHeight: 72)
                    .background(K.surface, in: RoundedRectangle(cornerRadius: K.rSmall))
                    .overlay(RoundedRectangle(cornerRadius: K.rSmall).strokeBorder(K.lineStrong))
                    .accessibilityIdentifier("week-plan-editor")
                Text("한 줄에 하나씩 적어 주세요. 지난 주 계획은 바꿀 수 없어요.").font(K.caption).foregroundStyle(K.faint)
                if let problem {
                    Text(problem).font(K.secondary).foregroundStyle(K.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: K.s2) {
                    KButton(title: "저장", style: .primary, enabled: !project.archived) { save() }
                        .accessibilityIdentifier("week-plan-save")
                    KButton(title: "취소") { editing = false; problem = nil }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: K.s2) {
                if let plan = current?.plan, !plan.isEmpty {
                    ForEach(Array(plan.enumerated()), id: \.offset) { _, line in
                        Text("· " + line).font(K.secondary).foregroundStyle(K.muted)
                    }
                } else {
                    Text("이번 주 계획이 아직 없어요").font(K.secondary).foregroundStyle(K.faint)
                }
                KButton(title: current == nil ? "계획 적기" : "계획 고치기", enabled: !project.archived) { begin() }
                    .accessibilityIdentifier("week-plan-edit")
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text("이번 주 결과").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            if results.isEmpty {
                Text("이번 주에 판정을 마친 이슈가 없어요").font(K.secondary).foregroundStyle(K.faint)
            }
            ForEach(results) { result in
                Button { open(result.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                        Image(systemName: "checkmark.circle.fill").font(K.caption).foregroundStyle(K.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title).font(K.secondary).foregroundStyle(K.ink).lineLimit(1)
                            Text(result.milestoneTitle ?? "마일스톤 없음")
                                .font(K.caption).foregroundStyle(K.faint).lineLimit(1)
                        }
                        Spacer(minLength: K.s2)
                        Text(result.completedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(K.caption).foregroundStyle(K.faint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("week-result-\(result.id.rawValue)")
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text("지난 주 계획").font(K.caption.weight(.semibold)).foregroundStyle(K.faint)
            ForEach(past.reversed(), id: \.id) { week in
                VStack(alignment: .leading, spacing: 1) {
                    Text(week.weekStart.formatted(date: .abbreviated, time: .omitted))
                        .font(K.caption).foregroundStyle(K.muted)
                    Text(week.plan.joined(separator: " · ")).font(K.caption).foregroundStyle(K.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("week-history-\(week.weekStart.timeIntervalSinceReferenceDate)")
            }
        }
    }

    private func begin() {
        draft = (current?.plan ?? []).joined(separator: "\n")
        problem = nil
        editing = true
    }

    private func save() {
        let plan = ProjectWeekPlan(projectID: project.id, weekStart: thisWeek,
                                   plan: draft.split(separator: "\n").map(String.init), recordedAt: now)
        guard plan.weekStart == ProjectWeek.start(containing: .now) else {
            problem = "이번 주 계획만 저장할 수 있어요"
            return
        }
        store.saveWeekPlan(plan)
        editing = false
        problem = nil
    }
}
