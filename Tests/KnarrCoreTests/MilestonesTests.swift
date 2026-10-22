import Foundation
import Testing
@testable import KnarrCore

@Suite struct MilestonesTests {
    private func criterion(_ text: String, met: Bool = false, evidence: String = "") -> Criterion {
        .init(text: text, state: met ? .met : .pending, evidence: evidence)
    }

    @Test func validationTrimsAndRejectsSelfAndCrossProjectPrerequisites() throws {
        let other = Milestone(id: "other", projectID: "p2", order: 1, title: "다른 프로젝트")
        var milestone = Milestone(id: "m1", projectID: "p", order: 1, title: "  첫 단계  ",
                                  inScope: [" 앱 실행 ", "  "], prerequisites: ["m1"])
        #expect(milestone.cleaned.title == "첫 단계")
        #expect(milestone.cleaned.inScope == ["앱 실행"])
        #expect(milestone.cleaned.prerequisites.isEmpty)
        #expect(throws: MilestoneError.self) { try milestone.validate(inProject: "p", existing: [other]) }
        milestone.prerequisites = ["other"]
        #expect(throws: MilestoneError.self) { try milestone.validate(inProject: "p", existing: [other]) }
        #expect(throws: MilestoneError.self) { try milestone.validate(inProject: "p2") }
        milestone.prerequisites = []
        #expect(throws: MilestoneError.self) {
            try Milestone(id: "m2", projectID: "p", order: 1, title: "").validate(inProject: "p")
        }
    }

    @Test func prerequisiteCyclesAreRejectedAcrossTheProject() throws {
        let a = Milestone(id: "a", projectID: "p", order: 1, title: "A", prerequisites: ["b"])
        let b = Milestone(id: "b", projectID: "p", order: 2, title: "B", prerequisites: ["a"])
        #expect(throws: MilestoneError.self) { try Milestone.validate([a, b], projectID: "p") }
        let chain = [Milestone(id: "a", projectID: "p", order: 1, title: "A"),
                     Milestone(id: "b", projectID: "p", order: 2, title: "B", prerequisites: ["a"]),
                     Milestone(id: "c", projectID: "p", order: 3, title: "C", prerequisites: ["a", "b"])]
        try Milestone.validate(chain, projectID: "p")
        let duplicateOrder = chain + [Milestone(id: "d", projectID: "p", order: 3, title: "D")]
        #expect(throws: MilestoneError.self) { try Milestone.validate(duplicateOrder, projectID: "p") }
    }

    @Test func reachedStateRequiresExplicitEvidenceForEveryCriterion() throws {
        var milestone = Milestone(id: "m", projectID: "p", order: 1, title: "단계",
                                  criteria: [criterion("테스트 통과")])
        #expect(!milestone.canReach)
        #expect(throws: MilestoneError.self) { try milestone.markReached(at: .now) }
        milestone.criteria = [criterion("테스트 통과", met: true, evidence: "swift test 로그")]
        var unproven = milestone
        unproven.criteria.append(criterion("화면 확인", met: true))
        #expect(!unproven.canReach)
        try milestone.markReached(at: Date(timeIntervalSinceReferenceDate: 100))
        #expect(milestone.status == .reached && milestone.reachedAt == Date(timeIntervalSinceReferenceDate: 100))
        #expect(milestone.displayStatus == .reached)
        let forged = Milestone(id: "forged", projectID: "p", order: 2, title: "몰래 완료",
                               status: .reached, criteria: [], reachedAt: .now)
        #expect(throws: MilestoneError.self) { try forged.validate(inProject: "p") }
    }

    @Test func blockedMilestoneNeedsAReason() throws {
        let blocked = Milestone(id: "m", projectID: "p", order: 1, title: "단계", status: .blocked)
        #expect(throws: MilestoneError.self) { try blocked.validate(inProject: "p") }
        try Milestone(id: "m", projectID: "p", order: 1, title: "단계", status: .blocked, blockedReason: "API 키 대기")
            .validate(inProject: "p")
    }

    @Test func weeklyHistoryIsAppendOnlyAndTargetDateEditsDoNotTouchIt() throws {
        let calendar = Calendar(identifier: .gregorian)
        let first = Date(timeIntervalSince1970: 1_759_000_000) // 2025-09-25 Thu
        let monday = Milestone.weekStart(containing: first, calendar: calendar)
        var milestone = Milestone(id: "m", projectID: "p", order: 1, title: "단계", targetDate: Date(timeIntervalSince1970: 1_800_000_000))
        try milestone.setWeek(scope: ["첫 주 범위", ""], result: "", at: first, calendar: calendar)
        #expect(milestone.weeks.map(\.weekStart) == [monday])
        #expect(milestone.weeks[0].scope == ["첫 주 범위"])
        let nextWeek = first.addingTimeInterval(7 * 86400)
        try milestone.setWeek(scope: ["둘째 주 범위"], result: "결과", at: nextWeek, calendar: calendar)
        #expect(milestone.weeks.count == 2)
        let oldWeeks = milestone.weeks
        milestone.targetDate = .now
        #expect(milestone.weeks == oldWeeks)
        let calendarNow = first.addingTimeInterval(7 * 86400 + 60)
        #expect(Milestone.preservesWeekHistory(oldWeeks, in: milestone.weeks, at: calendarNow, calendar: calendar))
        #expect(!Milestone.preservesWeekHistory(oldWeeks, in: [oldWeeks[0]], at: calendarNow, calendar: calendar))
        var rewritten = milestone
        rewritten.weeks[0].scope = ["바꿈"]
        #expect(!Milestone.preservesWeekHistory(oldWeeks, in: rewritten.weeks, at: calendarNow, calendar: calendar))
        #expect(throws: MilestoneError.self) {
            try milestone.setWeek(scope: ["지난주"], result: "", at: first, calendar: calendar)
        }
        // Updating this week's entry revises it in place instead of appending.
        try milestone.setWeek(scope: ["수정된 둘째 주"], result: "진행", at: nextWeek.addingTimeInterval(60), calendar: calendar)
        #expect(milestone.weeks.count == 2 && milestone.weeks[1].scope == ["수정된 둘째 주"])
        var duplicateWeek = milestone
        duplicateWeek.weeks.append(duplicateWeek.weeks[1])
        #expect(throws: MilestoneError.self) { try duplicateWeek.validate(inProject: "p") }
    }

    @Test func currentStageFollowsActiveThenBlockedThenFirstUnreached() throws {
        var planned = Milestone(id: "a", projectID: "p", order: 0, title: "예정")
        var blocked = Milestone(id: "b", projectID: "p", order: 1, title: "막힘", status: .blocked, blockedReason: "대기")
        var active = Milestone(id: "c", projectID: "p", order: 2, title: "진행", status: .active)
        #expect(Milestone.current(in: [planned, blocked, active])?.id == "c")
        active.status = .planned
        #expect(Milestone.current(in: [planned, blocked, active])?.id == "b")
        blocked.status = .planned
        #expect(Milestone.current(in: [planned, blocked, active])?.id == "a")
        var reached = [planned, blocked, active]
        for index in reached.indices {
            reached[index].status = .reached
            reached[index].reachedAt = .now
            reached[index].criteria = [criterion("확인", met: true, evidence: "로그")]
        }
        // Everything reached: the last stage stays visible instead of an empty state.
        #expect(Milestone.current(in: reached)?.id == "c")
        #expect(Milestone.current(in: []) == nil)
    }

    @Test func preparedForSaveAppendsTargetDateHistoryOnlyWhenTheDateChanges() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-86400)
        let newDate = now.addingTimeInterval(86400)
        let old = Milestone(id: "m", projectID: "p", order: 1, title: "단계", targetDate: oldDate, createdAt: now.addingTimeInterval(-600))
        var unchanged = try old.preparedForSave(over: old, at: now)
        #expect(unchanged.targetDateHistory.isEmpty)
        #expect(unchanged.updatedAt == now)
        #expect(unchanged.createdAt == old.createdAt)

        var changed = old
        changed.targetDate = newDate
        changed.updatedAt = .distantPast
        let first = try changed.preparedForSave(over: old, at: now)
        #expect(first.createdAt == old.createdAt)
        #expect(first.updatedAt == now)
        #expect(first.targetDateHistory == [.init(previous: oldDate, updated: newDate, changedAt: now)])

        // Re-saving the same value grows nothing; a second real edit appends in order.
        let noGrowth = try first.preparedForSave(over: first, at: now.addingTimeInterval(10))
        #expect(noGrowth.targetDateHistory == first.targetDateHistory)
        var cleared = noGrowth
        cleared.targetDate = nil
        let second = try cleared.preparedForSave(over: noGrowth, at: now.addingTimeInterval(20))
        #expect(second.targetDateHistory.map(\.previous) == [oldDate, newDate])
        #expect(second.targetDateHistory.map(\.updated) == [newDate, nil])
        #expect(second.targetDateHistory.map(\.changedAt) == [now, now.addingTimeInterval(20)])

        // A client-supplied history is replaced by the stored prefix, never trusted.
        var forged = second
        forged.targetDateHistory = [.init(previous: nil, updated: oldDate, changedAt: .distantPast)]
        let saved = try forged.preparedForSave(over: second, at: now)
        #expect(saved.targetDateHistory == second.targetDateHistory)
    }

    @Test func weekProtectionUsesTheServerClockNotThePayload() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let lastWeek = Date(timeIntervalSince1970: 1_759_000_000)
        let thisWeek = lastWeek.addingTimeInterval(7 * 86400)
        var milestone = Milestone(id: "m", projectID: "p", order: 1, title: "단계")
        try milestone.setWeek(scope: ["지난주 계획"], result: "완료", at: lastWeek, calendar: calendar)
        let stale = milestone

        // Editing last week's entry in the new week is rejected even when it is the last row.
        var rewritten = stale
        rewritten.weeks[0].scope = ["지난주 계획 수정"]
        #expect(throws: MilestoneError.historyRewritten) {
            try rewritten.preparedForSave(over: stale, at: thisWeek, calendar: calendar)
        }
        // Back-dating the payload clock does not help: the repository passes its own time.
        var oldClock = stale
        oldClock.updatedAt = lastWeek
        oldClock.weeks[0].result = "다시 씀"
        #expect(throws: MilestoneError.historyRewritten) {
            try oldClock.preparedForSave(over: stale, at: thisWeek, calendar: calendar)
        }
        // Rewriting a full stored entry is fine while it is still that week.
        try rewritten.preparedForSave(over: stale, at: lastWeek.addingTimeInterval(60), calendar: calendar)

        // Adding this week's entry is accepted; appending a past week is not.
        var appended = stale
        try appended.setWeek(scope: ["이번 주 계획"], result: "", at: thisWeek.addingTimeInterval(60), calendar: calendar)
        let saved = try appended.preparedForSave(over: stale, at: thisWeek.addingTimeInterval(60), calendar: calendar)
        #expect(saved.weeks.count == 2)
        #expect(saved.weeks[0] == stale.weeks[0])
        var backFilled = stale
        backFilled.weeks = [.init(weekStart: lastWeek.addingTimeInterval(-7 * 86400), scope: ["그 전"], result: "", recordedAt: lastWeek)]
            + stale.weeks
        #expect(throws: MilestoneError.historyRewritten) {
            try backFilled.preparedForSave(over: stale, at: thisWeek, calendar: calendar)
        }
        // A new milestone may record this week, but not a week that has not started.
        var ancient = Milestone(id: "n", projectID: "p", order: 2, title: "새 단계")
        ancient.weeks = [.init(weekStart: lastWeek, scope: [], result: "", recordedAt: lastWeek)]
        #expect(try ancient.preparedForSave(over: nil, at: thisWeek, calendar: calendar).weeks.count == 1)
        ancient.weeks = [.init(weekStart: thisWeek.addingTimeInterval(7 * 86400), scope: [], result: "", recordedAt: thisWeek)]
        #expect(throws: MilestoneError.historyRewritten) {
            try ancient.preparedForSave(over: nil, at: thisWeek, calendar: calendar)
        }
    }

    @Test func legacyIssuePayloadDecodesWithoutMilestone() throws {
        let issue = try JSONDecoder().decode(Issue.self, from: Data(#"{"id":{"rawValue":"legacy"},"title":"이전","projectName":"P","state":"done","confirmed":true,"headline":"","detail":"","acceptance":[],"hirds":[],"events":[],"startedAt":10}"#.utf8))
        #expect(issue.milestoneID == nil)
    }
}
