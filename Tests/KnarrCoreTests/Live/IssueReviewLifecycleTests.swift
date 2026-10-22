import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct IssueReviewLifecycleTests {
    @Test func proposalVersionsAppendOncePersistAndNeverApproveFromText() async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("이전 대화", about: nil, project: nil, attachments: [])
            try await f.store.whenIdle()
            try await f.create()
            try await f.store.whenIdle()
            let first = try #require(f.store.chat.last { $0.kind == .proposal("t", version: 1) })
            #expect(f.store.chat.last?.id == first.id)
            try await f.repository.ensureProposalCards()
            try await f.session.updateIssueProposal(issueID: "t", expectedVersion: 1, instruction: "새 지시")
            try await f.store.whenIdle()
            let revised = try #require(f.store.chat.last)
            #expect(revised.kind == .proposal("t", version: 2))
            #expect(revised.id != first.id)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            f.store.send("승인합니다", about: "t", project: nil, attachments: [])
            try await f.store.whenIdle()
            #expect(try await f.repository.snapshot().runs.isEmpty)
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.chat.filter { $0.kind == .proposal("t", version: 1) }.map(\.id) == [first.id])
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await reopened.snapshot().chat.contains(revised))
            try await reopened.close()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func appAttestationDoesNotApplyAutomaticallyOrEraseUnmetEvidence() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = try await f.session.receive(.init(id: "finish", runID: "r", at: .now, payload: .complete(f.result(), notificationID: "n")))
            var issue = try #require(try await f.repository.snapshot().issues.first)
            issue.state = .failed
            issue.acceptance = [.init(text: "실제 앱", state: .unmet, evidence: "실제 앱 확인 필요: 움직임은 오프스크린으로 확인할 수 없음")]
            issue.hirds = []; issue.events = []
            try await f.repository.saveIssue(issue, projectID: "p")
            f.store.perform(.confirmResult, on: "t")
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.application == nil)
            f.store.perform(.confirmAppResult(note: "실제 창에서 확인함"), on: "t")
            try await f.store.whenIdle()
            let saved = try #require(try await f.repository.snapshot().issues.first)
            #expect(saved.userAppConfirmation?.runID == "r")
            #expect(saved.userAppConfirmation?.note == "실제 창에서 확인함")
            #expect(saved.acceptance[0].state == .unmet)
            #expect(saved.application == nil && !saved.confirmed)
            #expect(saved.state == .failed)
            f.store.perform(.confirmResult, on: "t")
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.confirmed == true)
            guard case .blocked = f.store.issues.first?.application else { Issue.record("Explicit apply should reach ResultApplier for the fake project"); try await f.cleanup(); return }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func unrelatedFailuresRejectAppAttestationAndClosingPreservesHistory() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            await #expect(throws: LiveKnarrError.installBusy) { try await f.repository.beginInstallation() }
            f.store.perform(.closeIssue(reason: .cancelled), on: "t")
            try await f.store.whenIdle()
            #expect(try await f.repository.snapshot().issues.first?.archivedAt == nil)
            #expect(try await f.repository.snapshot().runs.first?.state == .working)
            f.store.perform(.stop, on: "t")
            try await f.store.whenIdle()
            f.store.perform(.closeIssue(reason: .cancelled), on: "t")
            try await f.store.whenIdle()
            let saved = try await f.repository.snapshot()
            #expect(saved.issues.first?.archiveReason == "취소")
            #expect(saved.issues.first?.proposal?.version == 1)
            #expect(saved.runs.first?.state == .cancelled)
            #expect(Panel.sections(for: f.store.issues).isEmpty)
            await #expect(throws: PersistenceError.self) {
                try await f.repository.confirmAppResult(issueID: "t", note: "확인함", at: .now)
            }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func shutdownRecordsAppInterruptionAndOffersRestartWithoutAQuestion() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = await f.store.shutdown()
            let snapshot = try await f.repository.snapshot()
            let run = try #require(snapshot.runs.first)
            #expect(run.state == .cancelled)
            #expect(run.stopReason?.contains("앱 종료") == true)
            #expect(run.processEndedAt != nil)
            #expect(snapshot.questions.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
