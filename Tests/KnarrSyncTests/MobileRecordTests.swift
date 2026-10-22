import CloudKit
import Foundation
import Testing
@testable import KnarrSync

@Suite struct MobileRecordTests {
    let zone = CKRecordZone.ID(zoneName: MobileZone.name, ownerName: CKCurrentUserDefaultName)
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func everyRecordSurvivesACloudKitRoundTrip() throws {
        let records: [MobileRecord] = [
            .issue(MobileIssue(id: "t1", title: "합계 고치기", project: "Calc", state: .needsInput, group: .mine,
                               headline: "Hird 1명 · 3분째", detail: "로그인이 필요해요",
                               criteria: [.init(text: "테스트 통과", state: .met)], progress: "2/4 · 테스트",
                               startedAt: at, updatedAt: at)),
            .question(MobileQuestion(id: "q1", issue: "t1", asker: "Hird-1", prompt: "어느 쪽?", options: ["A", "B"],
                                     allowsMultiple: true, state: .answered, answer: "A", askedAt: at)),
            .message(MobileMessage(id: "m1", at: at, role: .stallari, text: "끝났어요", project: "Calc")),
            .project(MobileProject(id: "p1", name: "Calc", openIssues: 2)),
            .request(MobileRequest(id: "r1", createdAt: at, kind: .answer(question: "q1", options: ["B"], text: "왜냐면"))),
            .request(MobileRequest(id: "r2", createdAt: at, kind: .message(text: "안녕", project: nil))),
            .request(MobileRequest(id: "r3", createdAt: at, kind: .action(issue: "t1", action: .confirmResult))),
            .request(MobileRequest(id: "r4", createdAt: at, kind: .cancelQuestion("q1"))),
            .request(MobileRequest(id: "r5", createdAt: at, kind: .steer(issue: "t1", text: "천천히"))),
            .alert(MobileAlert(id: "a1", createdAt: at, title: "질문이 왔어요", body: "어느 쪽?", issue: "t1")),
            .status(MobileStatus(isResponding: true, engine: "OMP · opus")),
            .activityDevice(MobileActivityDevice(id: "phone", environment: .production, enabled: true, startToken: "fixture", updatedAt: at)),
        ]
        for record in records {
            let ck = record.cloudRecord(in: zone)
            #expect(ck.recordID.zoneID == zone)
            #expect(try MobileRecord(cloudRecord: ck) == record)
        }
    }

    @Test func activityTravelsWithTheMessageAndChangesItsRecord() throws {
        let activity = MobileMessage.Activity(kind: "reasoning", title: "추론 요약", state: "running", label: "진행 중",
                                              startedAt: at, updatedAt: at.addingTimeInterval(2))
        let message = MobileMessage(id: "m", at: at, role: .stallari, text: "생각 중", project: nil, thread: "t", activity: activity)
        let back = try #require(try? MobileRecord(cloudRecord: MobileRecord.message(message).cloudRecord(in: zone)))
        #expect(back == .message(message))
        guard case .message(let decoded) = back else { return }
        #expect(decoded.activity == activity)

        // A stored record whose activity advanced is uploaded again, not skipped as unchanged.
        var plan = SyncPlan()
        plan.commit(plan.changes(to: [.message(message)]))
        var finished = message
        finished.activity?.state = "completed"; finished.activity?.label = "완료"; finished.activity?.updatedAt = at.addingTimeInterval(9)
        #expect(plan.changes(to: [.message(finished)]).saves == [.message(finished)])
    }

    @Test func aMessageWrittenBeforeActivityExistedStillDecodes() throws {
        // Wire shape of a Message record synced by a Mac build without activity.
        let json = #"{"at":1800000000000,"id":"old","role":"stallari","text":"예전 답변","thread":"main"}"#
        let message = try MobileRecord.decoder.decode(MobileMessage.self, from: Data(json.utf8))
        #expect(message.activity == nil)
        #expect(message.text == "예전 답변")
    }

    @Test func longTextIsCutToFitOneRecord() {
        let long = String(repeating: "가", count: MobileLimits.text + 500)
        let message = MobileMessage(id: "m", at: at, role: .stallari, text: long, project: nil)
        let back = try? MobileRecord(cloudRecord: MobileRecord.message(message).cloudRecord(in: zone))
        guard case .message(let m)? = back else { Testing.Issue.record("not a message"); return }
        #expect(m.text.count == MobileLimits.text + 1)
        #expect(m.text.hasSuffix("…"))
    }

    @Test func unknownRecordTypesAreRejected() {
        let ck = CKRecord(recordType: "Elsewhere", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        #expect(throws: MobileRecordError.self) { try MobileRecord(cloudRecord: ck) }
    }
}

@Suite struct SyncPlanTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func project(_ id: String, open: Int) -> MobileRecord { .project(MobileProject(id: id, name: id, openIssues: open)) }

    @Test func onlyChangedRecordsAreSaved() {
        var plan = SyncPlan()
        let first = plan.changes(to: [project("a", open: 1), project("b", open: 0)])
        #expect(first.saves.count == 2)
        #expect(first.deletes.isEmpty)
        plan.commit(first)
        let second = plan.changes(to: [project("a", open: 2), project("b", open: 0)])
        #expect(second.saves == [project("a", open: 2)])
        #expect(second.deletes.isEmpty)
    }

    @Test func recordsThatLeaveTheSnapshotAreDeleted() {
        var plan = SyncPlan()
        plan.commit(plan.changes(to: [project("a", open: 1), project("b", open: 0)]))
        let next = plan.changes(to: [project("a", open: 1)])
        #expect(next.saves.isEmpty)
        #expect(next.deletes == [project("b", open: 0).recordName])
    }

    @Test func nothingIsCommittedUntilTheUploadSucceeds() {
        var plan = SyncPlan()
        _ = plan.changes(to: [project("a", open: 1)])
        #expect(plan.changes(to: [project("a", open: 1)]).saves.count == 1)
    }

    @Test func requestsAndAlertsAreNeverDeletedByTheSnapshot() {
        var plan = SyncPlan()
        let alert = MobileRecord.alert(MobileAlert(id: "a", createdAt: at, title: "t", body: "b", issue: nil))
        plan.commit(plan.changes(to: [alert]))
        #expect(plan.changes(to: []).deletes.isEmpty)
    }
}

@Suite struct SchemaSampleTests {
    @Test func activityRegistrationHasItsOwnPhoneOwnedRecordType() {
        let kind = MobileRecord.Kind(rawValue: "ActivityDevice")
        #expect(kind != nil)
        #expect(kind?.isSnapshot == false)
    }

}
