import CloudKit
import Foundation
import Testing
@testable import KnarrSync

@Suite struct PhoneProposalWireTests {
    @Test func newPhoneRestoresApprovalStateWhileOldPhoneReceivesProjection() throws {
        let zone = CKRecordZone.ID(zoneName: "fixture", ownerName: CKCurrentUserDefaultName)
        for state in [MobileIssue.State.awaitingApproval, .rejected] {
            let issue = MobileIssue(id: "p", title: "제안", project: "project", state: state, group: .mine,
                                    headline: "", detail: "", criteria: [], progress: nil, startedAt: .distantPast, updatedAt: .distantPast,
                                    proposal: .init(version: 3, title: "제안", criteria: ["검사 통과"], instruction: "승인한 지시",
                                                    model: "openai-codex/fixture", thinking: "low", mode: "inspect"),
                                    proposalReviewNote: state == .rejected ? "이번 변경은 하지 않아요" : nil)
            let record = MobileRecord.issue(issue).cloudRecord(in: zone)
            let data = try #require(record["payload"] as? Data)
            let legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(legacy["state"] as? String == (state == .awaitingApproval ? "needsInput" : "failed"))
            #expect(legacy["proposalState"] as? String == state.rawValue)
            #expect(try MobileRecord(cloudRecord: record) == .issue(issue))
        }
    }

    @Test @MainActor func rejectionSurvivesRequestDeletionAndFullReload() {
        let model = MobileClientModel()
        let request = model.makeRequest(.approveProposal(issue: "p", version: 1))
        let receipt = MobileAlert(id: "result", createdAt: .now, title: "승인 거부", body: "제안 버전이 바뀌었어요", issue: "p", requestID: request.id, requestFailure: "제안 버전이 바뀌었어요")
        model.apply(saved: [.request(request)], deleted: [])
        _ = model.apply(saved: [.alert(receipt)], deleted: [MobileRecord.request(request).recordName])
        #expect(model.proposalResult(for: "p")?.requestFailure == "제안 버전이 바뀌었어요")
        _ = model.replaceAll(with: [.alert(receipt)])
        #expect(model.proposalResult(for: "p")?.requestFailure == "제안 버전이 바뀌었어요")
    }

    @Test func versionedReviewsRoundTripAndMissingVersionIsRejected() throws {
        let zone = CKRecordZone.ID(zoneName: "fixture", ownerName: CKCurrentUserDefaultName)
        let kinds: [MobileRequest.Kind] = [
            .approveProposal(issue: "p", version: 3),
            .requestProposalChanges(issue: "p", version: 3, note: "범위 축소"),
            .rejectProposal(issue: "p", version: 3, note: "취소")
        ]
        for kind in kinds {
            let request = MobileRequest(id: "r", createdAt: Date(timeIntervalSince1970: 0), kind: kind)
            let record = MobileRecord.request(request).cloudRecord(in: zone)
            #expect(try MobileRecord(cloudRecord: record) == .request(request))
        }
        let missing = CKRecord(recordType: "Request", recordID: .init(recordName: "request-r", zoneID: zone))
        missing["payload"] = Data(#"{"createdAt":0,"id":"r","kind":{"approveProposal":{"thing":"p"}}}"#.utf8) as NSData
        #expect(throws: DecodingError.self) { try MobileRecord(cloudRecord: missing) }
    }
}
