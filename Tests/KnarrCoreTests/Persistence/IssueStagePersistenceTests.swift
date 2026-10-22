import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct IssueStagePersistenceTests {
    private let start = Date(timeIntervalSinceReferenceDate: 100)
    private var plan: [IssueStage] { IssueStage.plan(titles: [("조사", "관련 코드 확인", nil), ("수정", "수정 파일", 1)]) }

    private func fixture(_ body: (SQLiteKnarrRepository, URL) async throws -> Void) async throws {
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-stages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("knarr.sqlite")
        let db = try await SQLiteKnarrRepository.open(at: url)
        do {
            try await db.saveProject(.init(id: "p", name: "project", absolutePath: "/tmp/stages"))
            var issue = KnarrCore.Issue(id: "i", title: "단계", projectName: "project", state: .awaitingApproval,
                headline: "", detail: "", acceptance: [.init(text: "완료", state: .pending, evidence: "")],
                hirds: [], events: [], startedAt: start)
            issue.proposal = .init(instruction: "작업", model: "provider/model", stages: plan)
            try await db.saveIssue(issue, projectID: "p")
            try await body(db, url)
            try await db.close()
        } catch { try? await db.close(); throw error }
    }

    private func run(_ id: HirdRun.ID = "r") -> PersistedRun {
        .init(hird: .init(id: id, name: "Hird", role: "작업", status: .working, steps: [], currentCommand: nil,
                         lastActivityAt: start), issueID: "i", projectID: "p", ompSessionID: nil,
              ownershipToken: "owner-\(id.rawValue)", startedAt: start, mode: .change, requestedModel: "provider/model")
    }
    private func admit(_ db: SQLiteKnarrRepository) async throws {
        _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: start)
        _ = try await db.createApprovedRun(run(), proposalVersion: 1)
    }
    private func report(_ db: SQLiteKnarrRepository, _ action: StageReport.Action, at offset: Double,
                        stage: String = "stage-1", ids: [String] = [], plan: [IssueStage]? = nil,
                        reason: String? = nil, verified: Bool? = nil) async throws {
        let at = start.addingTimeInterval(offset)
        _ = try await db.recordEvent(id: UUID().uuidString, runID: "r", at: at,
            payload: .stage(.init(at: at, action: action, stageID: stage, verificationIDs: ids,
                                  plan: plan, reason: reason, verified: verified)))
    }
    private func result(_ records: [VerificationRecord]) -> RunResult {
        .init(worktreePath: "/tmp/stages", branch: nil, commit: nil, diffPath: nil, summary: "검증", verifications: records)
    }
    private func check(_ id: String, at offset: Double, command: [String] = ["swift", "test"],
                       exit: Int32 = 0, kind: VerificationRecord.Kind? = nil) -> VerificationRecord {
        .init(id: id, command: command, workingDirectory: "/tmp/stages", startedAt: start,
              finishedAt: start.addingTimeInterval(offset), exitCode: exit,
              logPath: "/tmp/stages-\(id).log", summary: "검증", kind: kind)
    }

    @Test func legacyProposalAndRunDecodeWithoutStageKeys() throws {
        let proposal = try JSONDecoder().decode(IssueProposal.self, from: Data(#"{"version":1,"instruction":"작업","model":"provider/model","mode":"change"}"#.utf8))
        #expect(proposal.stages == nil)
        #expect(proposal.stagePlan.isEmpty)
        let legacy = #"{"hird":{"id":{"rawValue":"r"},"name":"Hird","role":"작업","status":{"working":{}},"steps":[],"lastActivityAt":100},"issueID":{"rawValue":"i"},"projectID":"p","ownershipToken":"owner","startedAt":100,"state":"working","lastSequence":0,"resultHistory":[]}"#
        let run = try JSONDecoder().decode(PersistedRun.self, from: Data(legacy.utf8))
        #expect(run.stagePlan == nil)
        #expect(run.stageReports == nil)
        #expect(run.lastFileChangeAt == nil)
    }

    @Test func legacyIssuePreservesOnlyKnownProposalVersions() async throws {
        try await fixture { db, url in
            let raw = try SQLiteConnection(path: url.path, flags: 2)
            try raw.execute("UPDATE issues SET payload=json_remove(json_set(payload,'$.proposal.version',4),'$.proposalHistory') WHERE id='i'")
            try raw.close()
            let legacy = try #require(try await db.snapshot().issues.first)
            #expect(legacy.proposal?.version == 4)
            #expect(legacy.proposalHistory == nil)
            let readback = try StallariReadback.issue(legacy)
            #expect(readback["proposalHistory"]?.array?.compactMap { $0["version"]?.integer } == [4])
            try await db.saveIssueProposal(issueID: "i",
                proposal: .init(version: 5, instruction: "현재 버전 보완", model: "provider/model"), expectedVersion: 4)
            #expect(try await db.snapshot().issues[0].proposalHistory?.map(\.version) == [4, 5])
            let reopened = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await reopened.snapshot().issues[0].proposalHistory?.map(\.version) == [4, 5])
            try await reopened.close()
        }
    }

    @Test func approvalRejectsAnExplicitlyDifferentInitialPlan() async throws {
        try await fixture { db, _ in
            _ = try await db.approveIssueProposal(issueID: "i", version: 1, at: start)
            var mismatched = run()
            mismatched.stagePlan = []
            await #expect(throws: PersistenceError.self) {
                try await db.createApprovedRun(mismatched, proposalVersion: 1)
            }
            #expect(try await db.snapshot().runs.isEmpty)
            #expect(try await db.createApprovedRun(run(), proposalVersion: 1) == .applied)
            #expect(try await db.createApprovedRun(run(), proposalVersion: 1) == .duplicate)
            #expect(try await db.readRun("r").stagePlan == plan)
        }
    }

    @Test func approvalCopiesPlanAndVersionsRoundTrip() async throws {
        try await fixture { db, url in
            try await admit(db)
            #expect(try await db.readRun("r").stagePlan == plan)
            _ = try await db.recordEvent(id: "end", runID: "r", at: start.addingTimeInterval(5), payload: .fail("종료"))
            try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "보완", model: "provider/model"), expectedVersion: 1)
            #expect(try await db.snapshot().issues[0].proposal?.stagePlan == plan)
            try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 3, instruction: "단계 제거", model: "provider/model", stages: []), expectedVersion: 2)
            #expect(try await db.snapshot().issues[0].proposal?.stagePlan == [])
            let reopened = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await reopened.snapshot().issues[0].proposal?.version == 3)
            #expect(try await reopened.snapshot().issues[0].proposalHistory?.map(\.version) == [1, 2, 3])
            #expect(try await reopened.snapshot().issues[0].proposalHistory?.map(\.stagePlan) == [plan, plan, []])
            #expect(try await reopened.readRun("r").stagePlan == plan)
            try await reopened.close()
        }
    }

    @Test func metadataSaveWithoutHistoryPreservesPlansAndRejectsHistoryRewrites() async throws {
        try await fixture { db, _ in
            try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "보완", model: "provider/model"), expectedVersion: 1)
            var issue = try #require(try await db.snapshot().issues.first)
            issue.hirds = []; issue.events = []
            issue.proposalHistory = nil
            issue.detail = "메타데이터만 수정"
            try await db.saveIssue(issue, projectID: "p")
            let saved = try #require(try await db.snapshot().issues.first)
            #expect(saved.detail == "메타데이터만 수정")
            #expect(saved.proposalHistory?.map(\.version) == [1, 2])
            #expect(saved.proposalHistory?.map(\.stagePlan) == [plan, plan])
            issue.proposalHistory = [try #require(issue.proposal)]
            await #expect(throws: PersistenceError.self) { try await db.saveIssue(issue, projectID: "p") }
            #expect(try await db.snapshot().issues[0].proposalHistory == saved.proposalHistory)
        }
    }

    @Test func confirmationsAreFrozenAndEveryReportResetsAutomaticWindow() async throws {
        try await fixture { db, url in
            try await admit(db)
            try await report(db, .started, at: 1)
            _ = try await db.recordEvent(id: "checks", runID: "r", at: start.addingTimeInterval(3),
                payload: .saveResult(result([check("passing", at: 2)])))
            try await report(db, .completed, at: 4)
            try await report(db, .completed, at: 5, stage: "stage-2", verified: true)
            #expect(try await db.readRun("r").stageReports?.map(\.verified) == [nil, true, false])
            _ = try await db.recordEvent(id: "later", runID: "r", at: start.addingTimeInterval(7),
                payload: .saveResult(result([check("passing", at: 2), check("later", at: 6)])))
            #expect(try await db.readRun("r").stageReports?.last?.verified == false)
            let reopened = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await reopened.readRun("r").stageReports?.map(\.verified) == [nil, true, false])
            try await reopened.close()
        }
    }

    @Test func actualChangesAndExplicitInspectionIDsConfirmButMissingIDsReject() async throws {
        try await fixture { db, _ in
            try await admit(db)
            try await report(db, .started, at: 1)
            _ = try await db.recordEvent(id: "changed", runID: "r", at: start.addingTimeInterval(2), payload: .fileChanged(path: "Sources/Fix.swift"))
            try await report(db, .completed, at: 3)
            _ = try await db.recordEvent(id: "inspection", runID: "r", at: start.addingTimeInterval(4),
                payload: .saveResult(result([check("read-source", at: 2, command: ["read"], kind: .inspection)])))
            try await report(db, .completed, at: 5, stage: "stage-2", ids: ["read-source"])
            await #expect(throws: PersistenceError.self) { try await report(db, .completed, at: 6, ids: ["not-this-run"]) }
            #expect(try await db.readRun("r").stageReports?.map(\.verified) == [nil, true, true])
            #expect(try await db.readRun("r").lastFileChangeAt == start.addingTimeInterval(2))
        }
    }

    @Test func replacedSnapshotsKeepRunScopedCommandAndExplicitEvidenceAvailable() async throws {
        try await fixture { db, url in
            try await admit(db)
            try await report(db, .started, at: 1)
            _ = try await db.recordEvent(id: "earlier-evidence", runID: "r", at: start.addingTimeInterval(3),
                payload: .saveResult(result([
                    check("earlier-pass", at: 2),
                    check("earlier-inspection", at: 2, command: ["read"], exit: 1, kind: .inspection)
                ])))
            _ = try await db.recordEvent(id: "replacement", runID: "r", at: start.addingTimeInterval(4),
                payload: .saveResult(.init(worktreePath: "/tmp/stages", branch: nil, commit: "saved-snapshot",
                                          diffPath: nil, summary: "새 스냅샷", verifications: [])))
            #expect(try await db.readRun("r", includeHistory: false).result?.verifications.isEmpty == true)
            try await report(db, .completed, at: 5)
            try await report(db, .started, at: 6, stage: "stage-2")
            try await report(db, .completed, at: 7, stage: "stage-2", ids: ["earlier-inspection"])
            #expect(try await db.readRun("r").stageReports?.map(\.verified) == [nil, true, nil, true])
            let reopened = try await SQLiteKnarrRepository.open(at: url)
            #expect(try await reopened.readRun("r").stageReports?.map(\.verified) == [nil, true, nil, true])
            try await reopened.close()
        }
    }

    @Test func fileAndStageEventsKeepMonotonicAndStaleBoundaries() async throws {
        try await fixture { db, _ in
            try await admit(db)
            let changedAt = start.addingTimeInterval(2)
            _ = try await db.apply(.init(id: "file", runID: "r", sequence: 3, at: changedAt,
                                        payload: .fileChanged(path: "Fix.swift")))
            await #expect(throws: PersistenceError.self) { try await report(db, .started, at: 1) }
            await #expect(throws: PersistenceError.self) {
                try await db.recordEvent(id: "older-file", runID: "r", at: start.addingTimeInterval(1),
                                         payload: .fileChanged(path: "Fix.swift"))
            }
            try await report(db, .started, at: 3)
            await #expect(throws: PersistenceError.self) {
                try await db.recordEvent(id: "before-report", runID: "r", at: changedAt, payload: .fileChanged(path: "Fix.swift"))
            }
            await #expect(throws: PersistenceError.self) {
                try await db.recordEvent(id: "empty-file", runID: "r", at: start.addingTimeInterval(4), payload: .fileChanged(path: " "))
            }
            let staleAt = start.addingTimeInterval(1)
            #expect(try await db.apply(.init(id: "stale-stage", runID: "r", sequence: 1, at: staleAt,
                payload: .stage(.init(at: staleAt, action: .completed, stageID: "stage-1")))) == .ignoredStale)
            #expect(try await db.apply(.init(id: "stale-file", runID: "r", sequence: 2, at: staleAt,
                payload: .fileChanged(path: "Fix.swift"))) == .ignoredStale)
            #expect(try await db.readRun("r").stageReports?.count == 1)
            #expect(try await db.readRun("r").lastFileChangeAt == changedAt)
        }
    }

    @Test func replanKeepsOriginalPlanAndRejectsInvalidShapesTimesAndTerminalReports() async throws {
        try await fixture { db, _ in
            try await admit(db)
            try await report(db, .started, at: 1)
            var revised = plan
            revised[0].title = "원인 분석"
            try await report(db, .replanned, at: 2, stage: "", plan: revised, reason: "발견한 원인에 맞춰 이름을 구체화")
            #expect(try await db.readRun("r").stagePlan == plan)
            #expect(try await db.readRun("r").stageReports?.last?.plan == revised)
            await #expect(throws: PersistenceError.self) { try await report(db, .started, at: 1) }
            await #expect(throws: PersistenceError.self) { try await report(db, .started, at: 3, stage: "unknown") }
            await #expect(throws: PersistenceError.self) { try await report(db, .replanned, at: 3, plan: revised, reason: " ") }
            await #expect(throws: PersistenceError.self) { try await report(db, .replanned, at: 3, plan: [revised[0], revised[0]], reason: "중복") }
            await #expect(throws: PersistenceError.self) { try await report(db, .started, at: 3, plan: revised) }
            _ = try await db.recordEvent(id: "stop", runID: "r", at: start.addingTimeInterval(4), payload: .fail("종료"))
            let outcome = try await db.recordEvent(id: "terminal-stage", runID: "r", at: start.addingTimeInterval(5),
                payload: .stage(.init(at: start.addingTimeInterval(5), action: .completed, stageID: "stage-1")))
            #expect(outcome == .ignoredTerminal)
            #expect(try await db.readRun("r").stageReports?.count == 2)
        }
    }

    @Test func automaticConfirmationRequiresStrictWindowAndSingleSuccessfulCommand() async throws {
        try await fixture { db, _ in
            try await admit(db)
            try await report(db, .started, at: 1)
            _ = try await db.recordEvent(id: "boundary-checks", runID: "r", at: start.addingTimeInterval(2),
                payload: .saveResult(result([
                    check("equal", at: 1), check("future", at: 9),
                    check("failed", at: 2, exit: 1),
                    check("compound", at: 2, command: ["sh", "-c", "false; true"]),
                    check("inspection-only", at: 2, command: ["read"], kind: .inspection)
                ])))
            try await report(db, .completed, at: 3)
            #expect(try await db.readRun("r").stageReports?.last?.verified == false)
            try await report(db, .started, at: 4, stage: "stage-2")
            _ = try await db.recordEvent(id: "on-time", runID: "r", at: start.addingTimeInterval(5),
                payload: .saveResult(result([check("inclusive", at: 6)])))
            try await report(db, .completed, at: 6, stage: "stage-2")
            #expect(try await db.readRun("r").stageReports?.last?.verified == true)
        }
    }

    @Test func unverifiedStagesNeverJudgeCriteriaOrBlockRunCompletion() async throws {
        try await fixture { db, _ in
            try await admit(db)
            let approved = try #require(try await db.snapshot().issues.first?.approval)
            try await report(db, .completed, at: 1)
            try await report(db, .started, at: 2, stage: "stage-2")
            let pending = try #require(try await db.snapshot().issues.first)
            #expect(pending.approval == approved)
            #expect(pending.acceptance.allSatisfy { $0.state == .pending })
            #expect(try await db.readRun("r").stageReports?.first?.verified == false)
            let saved = RunResult(worktreePath: "/tmp/stages", branch: nil, commit: "saved-snapshot",
                                  diffPath: nil, summary: "작업 보고", verifications: [])
            #expect(try await db.recordEvent(id: "complete", runID: "r", at: start.addingTimeInterval(3),
                payload: .complete(saved, notificationID: "completion")) == .applied)
            #expect(try await db.readRun("r").state == .succeeded)
            #expect(try await db.readRun("r").stageReports?.first?.verified == false)
            let finished = try #require(try await db.snapshot().issues.first)
            #expect(finished.approval == approved)
            #expect(finished.acceptance.allSatisfy { $0.state == .pending })
        }
    }

    @Test func foreignRunEvidenceIsRejectedAndReportRetriesDoNotAppend() async throws {
        try await fixture { db, _ in
            try await admit(db)
            _ = try await db.createRun(run("foreign"))
            _ = try await db.recordEvent(id: "foreign-checks", runID: "foreign", at: start.addingTimeInterval(2),
                payload: .saveResult(result([check("foreign-id", at: 2)])))
            await #expect(throws: PersistenceError.self) {
                try await report(db, .completed, at: 3, ids: ["foreign-id"])
            }
            await #expect(throws: PersistenceError.self) {
                try await report(db, .completed, at: 3, ids: ["foreign-id", "foreign-id"])
            }
            let unplannedAt = start.addingTimeInterval(3)
            await #expect(throws: PersistenceError.self) {
                try await db.recordEvent(id: "unplanned-stage", runID: "foreign", at: unplannedAt,
                    payload: .stage(.init(at: unplannedAt, action: .started, stageID: "stage-1")))
            }
            let at = start.addingTimeInterval(4)
            let payload = RunEvent.Payload.stage(.init(at: at, action: .completed, stageID: "stage-1", verified: true))
            #expect(try await db.recordEvent(id: "retry-stage", runID: "r", at: at, payload: payload) == .applied)
            #expect(try await db.recordEvent(id: "retry-stage", runID: "r", at: at, payload: payload) == .duplicate)
            #expect(try await db.readRun("r").stageReports?.count == 1)
            #expect(try await db.readRun("r").stageReports?.last?.verified == false)
            let mismatched = StageReport(at: at.addingTimeInterval(1), action: .started, stageID: "stage-1")
            await #expect(throws: PersistenceError.self) {
                try await db.recordEvent(id: "wrong-clock", runID: "r", at: at, payload: .stage(mismatched))
            }
        }
    }

    @Test func criterionUsesActualIssueCountWithoutStageCountRestriction() async throws {
        try await fixture { db, _ in
            let single = [IssueStage(id: "stage-1", title: "작업", evidence: "검사", criterion: 1)]
            try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 2, instruction: "작업", model: "provider/model", stages: single), expectedVersion: 1)
            await #expect(throws: PersistenceError.self) {
                try await db.saveIssueProposal(issueID: "i", proposal: .init(version: 3, instruction: "작업", model: "provider/model", stages: [.init(id: "stage-1", title: "작업", evidence: "검사", criterion: 2)]), expectedVersion: 2)
            }
            let invalidPlans: [[IssueStage]] = [
                [single[0], single[0]],
                [.init(id: "has whitespace", title: "작업", evidence: "검사")],
                [.init(id: "stage-1", title: " ", evidence: "검사")],
                [.init(id: "stage-1", title: "작업", evidence: " ")],
                [.init(id: "stage-1", title: "작업", evidence: "검사", criterion: 0)]
            ]
            for invalid in invalidPlans {
                await #expect(throws: PersistenceError.self) {
                    try await db.saveIssueProposal(issueID: "i",
                        proposal: .init(version: 3, instruction: "작업", model: "provider/model", stages: invalid), expectedVersion: 2)
                }
            }
        }
    }
}

@Suite(.serialized) struct IssueStageProposalToolTests {
    @Test func toolsPreserveOmittedStagesRemoveExplicitEmptyAndReturnVersionHistory() async throws {
        let f = try await StallariFixture.make()
        do {
            let stages: OMPJSON = .array([
                .object(["title": .string("기능 수정"), "evidence": .string("수정 코드와 검사"), "criterion": .number(1)])
            ])
            _ = try await f.session.performTool("create_issue", arguments: .object([
                "issueID": .string("staged"), "title": .string("선택 단계"), "criteria": .array([.string("기능 동작")]),
                "instruction": .string("기능 수정"), "stages": stages
            ]))
            _ = try await f.session.performTool("update_issue_proposal", arguments: .object([
                "issueID": .string("staged"), "expectedVersion": .number(1), "instruction": .string("검사 보완")
            ]))
            let saved = try #require(try await f.repository.snapshot().issues.first { $0.id == "staged" })
            #expect(saved.proposal?.stagePlan.first?.id == "stage-1")
            #expect(saved.proposal?.stagePlan.first?.criterion == 1)
            _ = try await f.session.performTool("update_issue_proposal", arguments: .object([
                "issueID": .string("staged"), "expectedVersion": .number(2), "instruction": .string("기존 진행 표시"), "stages": .array([])
            ]))
            let read = try await f.session.performTool("get_issue", arguments: .object(["issueID": .string("staged")]))
            #expect(read["issue"]?["proposal"]?["stages"]?.array == [])
            #expect(read["issue"]?["proposalHistory"]?.array?.count == 3)
            #expect(read["issue"]?["proposalHistory"]?.array?.first?["stages"]?.array?.first?["title"]?.string == "기능 수정")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func stageInputRejectsMalformedShapeAndOutOfRangeActualCriterion() async throws {
        let f = try await StallariFixture.make()
        do {
            let project = try #require(try await f.repository.snapshot().projects.first { $0.id == "p" })
            let count = 1 + project.settings.criteria.filter { $0 != "완료" }.count
            let invalid: [OMPJSON] = [
                .null,
                .array([.object(["title": .string("단계"), "evidence": .string("검사"), "criterion": .number(0)])]),
                .array([.object(["title": .string("단계"), "evidence": .string("검사"), "criterion": .number(1.5)])]),
                .array([.object(["title": .string("단계"), "evidence": .string("검사"), "criterion": .number(Double(count + 1))])]),
                .array([.object(["title": .string("단계"), "evidence": .string("검사"), "id": .string("injected")])])
            ]
            for (index, stages) in invalid.enumerated() {
                await #expect(throws: (any Error).self) {
                    try await f.session.performTool("create_issue", arguments: .object([
                        "issueID": .string("invalid-\(index)"), "title": .string("거부"), "criteria": .array([.string("완료")]),
                        "instruction": .string("작업"), "stages": stages
                    ]))
                }
            }
            #expect(try await f.repository.snapshot().issues.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
