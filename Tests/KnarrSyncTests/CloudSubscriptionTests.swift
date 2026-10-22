import CloudKit
import Foundation
import Testing
@testable import KnarrSync

@Suite struct CloudSubscriptionTests {
    @Test func individualSaveFailureIsPropagated() {
        let rejected = CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "attempting to create a subscription in a production container"])
        do {
            try CloudSyncEngine.checkSubscriptionSaved(id: "request", results: ["request": .failure(rejected)])
            Testing.Issue.record("A rejected subscription must not be reported as ready")
        } catch {
            #expect((error as? CKError)?.code == .invalidArguments)
            #expect(error.localizedDescription == rejected.localizedDescription)
        }
    }

    @Test func missingResultCannotBeReportedAsSuccess() {
        #expect(throws: (any Error).self) {
            try CloudSyncEngine.checkSubscriptionSaved(id: "request", results: [:])
        }
    }

    @Test func anotherSubscriptionsSuccessDoesNotHideFailure() {
        let other = CKDatabaseSubscription(subscriptionID: "other")
        #expect(throws: (any Error).self) {
            try CloudSyncEngine.checkSubscriptionSaved(id: "request", results: ["other": .success(other)])
        }
    }

    @Test func matchingSuccessIsAccepted() throws {
        let saved = CKDatabaseSubscription(subscriptionID: "request")
        try CloudSyncEngine.checkSubscriptionSaved(id: saved.subscriptionID, results: [saved.subscriptionID: .success(saved)])
    }
}
