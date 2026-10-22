import Foundation
import Testing
import KnarrCore
import KnarrSync
@testable import KnarrMirror

@MainActor @Suite struct PhoneProposalTests {
    @Test func newlyCreatedProposalNotifiesItsIssue() {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        var detector = MobileAlertDetector()
        _ = detector.alerts(issues: [], questions: [], chat: [], now: now)
        let issue = makeIssue("proposal", .awaitingApproval, at: now)
        let alerts = detector.alerts(issues: [issue], questions: [], chat: [], now: now)
        #expect(alerts.map(\.issue) == ["proposal"])
        #expect(detector.alerts(issues: [issue], questions: [], chat: [], now: now).isEmpty)
    }

    @Test func staleAndDuplicateReviewsDoNotAuthorizeExecution() async throws {
        let store = SampleKnarrStore()
        let id = try #require(store.issues.first?.id)
        #expect(throws: (any Error).self) {
            try MobileRequestApplier.validateProposal(issue: store.issues.first, version: 999)
        }
        var issue = makeIssue("review", .awaitingApproval)
        issue.proposal = .init(version: 2, instruction: "고치기", model: "model")
        try MobileRequestApplier.validateProposal(issue: issue, version: 2)
        issue.approval = .init(version: 2, approvedAt: .now, source: "phone")
        #expect(throws: (any Error).self) {
            try MobileRequestApplier.validateProposal(issue: issue, version: 2)
        }
        await #expect(throws: (any Error).self) {
            try await MobileRequestApplier.apply(.approveProposal(issue: id.rawValue, version: 999), to: store)
        }
    }
}
