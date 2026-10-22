import Foundation
import Testing
@testable import KnarrCore

struct HirdPlannedProgressTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)
    private var plan: [IssueStage] {
        [.init(id: "a", title: "저장 형식 확인", evidence: "구형 자료를 읽음", criterion: 1),
         .init(id: "b", title: "실행 경계 구현", evidence: "다른 실행 보고 거부")]
    }

    @Test func aPlanWithoutReportsRemainsVisibleWithoutClaimingAStartedStage() {
        let p = HirdProgress(.init(checks: [.init(command: "swift test --no-parallel", exitCode: 0, finishedAt: time)], plan: plan))
        #expect(p.plannedStages.map(\.title) == plan.map(\.title))
        #expect(p.plannedStages.map(\.state) == [.pending, .pending])
        let readback = StallariReadback.progress(p)
        #expect(readback["stageCount"]?.integer == 2)
        #expect(readback["stageIndex"] == .null)
        #expect(readback["stage"] == .null)
    }

    @Test func completionWithoutStageReportsPreservesTheUnreportedPlan() {
        let p = HirdProgress(.init(outcome: .done, plan: plan))
        #expect(p.condition == .done)
        #expect(p.plannedStages.map(\.state) == [.pending, .pending])
        #expect(StallariReadback.progress(p)["stageIndex"] == .null)
        #expect(p.steps.allSatisfy { $0.state == .pending })
    }

    @Test func aFinishedRunWithoutAPlanDoesNotPublishInventedStages() {
        let p = HirdProgress(.init(outcome: .done))
        let readback = StallariReadback.progress(p)
        #expect(readback["stageCount"]?.integer == 0)
        #expect(readback["stages"]?.array?.isEmpty == true)
        #expect(readback["stageIndex"] == .null)
    }

    @Test func reportsWithoutAnInitialPlanKeepLegacyInference() {
        let reports: [StageReport] = [.init(at: time, action: .replanned, stageID: "", plan: plan, reason: "조사 순서 조정")]
        let p = HirdProgress(.init(plan: [], reports: reports))
        #expect(p.plannedStages.isEmpty)
        #expect(p.stage == .prepare)
    }

    @Test func completionNeverImpliesCompletionOfOtherStagesOrCriteria() {
        let reports: [StageReport] = [
            .init(at: time, action: .started, stageID: "b", note: "소유 실행 확인"),
            .init(at: time.addingTimeInterval(1), action: .completed, stageID: "b", note: "구현 기록", verified: false)
        ]
        let p = HirdProgress(.init(outcome: .done, plan: plan, reports: reports))
        #expect(p.plannedStages.map(\.state) == [.pending, .done])
        #expect(p.plannedStages.map(\.verified) == [nil, false])
        #expect(p.steps.map(\.state) == [.pending, .done])
        #expect(p.steps.last?.sourceStatus == "unverified")
        #expect(p.plannedStages.last?.note == "구현 기록")
    }

    @Test func reorderingRenamingAddingAndMergingRetainStableStageEvidenceAndHistory() {
        let added = IssueStage(id: "c", title: "화면 확인", evidence: "PNG 읽음")
        let renamed = IssueStage(id: "a", title: "저장·호환 확인", evidence: "재오픈", criterion: 1)
        let reports: [StageReport] = [
            .init(at: time, action: .completed, stageID: "a", verified: true),
            .init(at: time.addingTimeInterval(1), action: .replanned, stageID: "", plan: [added, renamed], reason: "구현 단계를 저장 단계로 병합하고 화면 확인을 먼저 배치"),
            .init(at: time.addingTimeInterval(2), action: .started, stageID: "c")
        ]
        let p = HirdProgress(.init(plan: plan, reports: reports))
        #expect(p.titles == ["화면 확인", "저장·호환 확인"])
        #expect(p.plannedStages.map(\.state) == [.active, .done])
        #expect(p.plannedStages.last?.verified == true)
        #expect(p.plannedStages.last?.evidence == "재오픈")
        #expect(p.planChanges.map(\.titles) == [["화면 확인", "저장·호환 확인"]])
        #expect(p.planChanges.first?.reason == reports[1].reason)
        #expect(p.currentStageKey == "c")
    }

    @Test func laterCommandsCannotRetroactivelyConfirmAnUnverifiedReport() {
        let p = HirdProgress(.init(checks: [.init(command: "true", exitCode: 0, finishedAt: time.addingTimeInterval(10))],
            plan: plan, reports: [.init(at: time, action: .completed, stageID: "a", verified: false)]))
        #expect(p.plannedStages.first?.verified == false)
    }

    @Test func restartingACompletedStageClearsItsConfirmationAndKeepsEventOrderAtEqualTimes() {
        let reports: [StageReport] = [
            .init(at: time, action: .completed, stageID: "a", verified: true),
            .init(at: time, action: .started, stageID: "a"),
            .init(at: time, action: .started, stageID: "b")
        ]
        let p = HirdProgress(.init(waitingOnQuestion: true, plan: plan, reports: reports))
        #expect(p.plannedStages.map(\.state) == [.pending, .active])
        #expect(p.plannedStages.allSatisfy { $0.verified == nil })
        #expect(p.steps.map(\.state) == [.pending, .blocked])
        #expect(p.currentStageKey == "b")
    }
}
