import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct PhoneProposalReviewTests {
    @Test func approvalRecordsPhoneAndRejectsReplay() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.store.whenIdle()
            try await f.store.reviewProposal(.approveProposal(version: 1), on: "t", source: "phone")
            let snapshot = try await f.repository.snapshot()
            let issue = try #require(snapshot.issues.first)
            #expect(issue.approval?.source == "phone")
            #expect(issue.approvalHistory?.last?.source == "phone")
            #expect(issue.approvalHistory?.last?.runID == snapshot.runs.first?.id)
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.approveProposal(version: 1), on: "t", source: "phone")
            }
            #expect(try await f.repository.snapshot().runs.count == 1)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func staleReviewAndRepeatedChangeRequestNeverStartHird() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.session.updateIssueProposal(issueID: "t", expectedVersion: 1, instruction: "새 실행 범위")
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.approveProposal(version: 1), on: "t", source: "phone")
            }
            try await f.store.reviewProposal(.requestProposalChanges(version: 2, note: "검사 추가"), on: "t", source: "phone")
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.requestProposalChanges(version: 2, note: "중복"), on: "t", source: "phone")
            }
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.approveProposal(version: 2), on: "t", source: "phone")
            }
            #expect(try await f.repository.snapshot().runs.isEmpty)
            #expect(try await f.repository.snapshot().issues.first?.proposalReviewNote == "검사 추가")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func rejectionIsVersionedAndCannotBeReplayed() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            try await f.store.reviewProposal(.rejectProposal(version: 1, note: "취소"), on: "t", source: "phone")
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.rejectProposal(version: 1, note: "중복"), on: "t", source: "phone")
            }
            #expect(try await f.repository.snapshot().issues.first?.state == .rejected)
            #expect(try await f.repository.snapshot().runs.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func capacityRefusalDoesNotConsumePhoneApprovalAndAllowsRetry() async throws {
        let f = try await LiveFixture.make()
        do {
            var settings = ProjectSettings(); settings.maxHirds = 1
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            try await f.create("t"); try await f.create("u")
            try await f.dispatch("r", issue: "t")
            await #expect(throws: (any Error).self) {
                try await f.store.reviewProposal(.approveProposal(version: 1), on: "u", source: "phone")
            }
            let refused = try #require(try await f.repository.snapshot().issues.first { $0.id == "u" })
            #expect(refused.approval == nil)
            #expect(refused.approvalHistory?.isEmpty != false)
            f.store.perform(.stop, on: "t"); try await f.store.whenIdle()
            try await f.store.reviewProposal(.approveProposal(version: 1), on: "u", source: "phone")
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs.filter { $0.issueID == "u" }.count == 1)
            #expect(snapshot.issues.first { $0.id == "u" }?.approvalHistory?.last?.source == "phone")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func externalInputSignalCannotAdvanceRunningOrRejectedIssues() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            f.store.perform(.resolvedInput, on: "t"); try await f.store.whenIdle()
            #expect(f.store.lastError != nil)
            #expect(await f.hird.instructions.isEmpty)
            try await f.create("u")
            try await f.store.reviewProposal(.rejectProposal(version: 1, note: ""), on: "u", source: "phone")
            f.store.perform(.resolvedInput, on: "u"); try await f.store.whenIdle()
            #expect(await f.rpc.prompts.isEmpty)
            #expect(try await f.repository.snapshot().issues.first { $0.id == "u" }?.state == .rejected)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func simultaneousPhoneApprovalsCannotSpendTheSameSlot() async throws {
        let f = try await LiveFixture.make()
        do {
            var settings = ProjectSettings(); settings.maxHirds = 1
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            try await f.create("t"); try await f.create("u")
            async let first: HirdRun.ID? = try? f.session.approveIssue(issueID: "t", version: 1, source: "phone")
            async let second: HirdRun.ID? = try? f.session.approveIssue(issueID: "u", version: 1, source: "phone")
            let results = await [first, second]
            #expect(results.compactMap { $0 }.count == 1)
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs.count == 1)
            let unstarted = try #require(snapshot.issues.first { $0.approval?.runID == nil })
            #expect(unstarted.approval == nil)
            #expect(unstarted.state == .awaitingApproval)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func phoneRunsReviewedHirdReasoningNotLaterStallariOrProjectDefaults() async throws {
        let f = try await LiveFixture.make()
        do {
            var settings = ProjectSettings(); settings.hirdThinking = "low"
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            try await f.create()
            settings.hirdThinking = "high"
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            _ = await f.rpc.request("set_thinking_level", fields: ["level": .string("medium")], timeout: .seconds(1))
            try await f.store.reviewProposal(.approveProposal(version: 1), on: "t", source: "phone")
            #expect(try await f.repository.snapshot().runs.first?.requestedThinking == "low")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
