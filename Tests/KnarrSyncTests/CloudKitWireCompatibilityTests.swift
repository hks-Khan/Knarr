import CloudKit
import Foundation
import Testing
@testable import KnarrSync

/// Frozen pre-Issue wire from 6bbd4de (mobile-cloudkit deployment lineage).
/// Literal payloads keep expected bytes independent of the current encoder.
@Suite struct CloudKitWireCompatibilityTests {
    let zone = CKRecordZone.ID(zoneName: "Knarr", ownerName: CKCurrentUserDefaultName)
    let at = Date(timeIntervalSince1970: 0)

    func fixture(_ type: String, _ name: String, _ payload: String) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: .init(recordName: name, zoneID: zone))
        record["payload"] = Data(payload.utf8) as NSData
        return record
    }

    @Test func oldSnapshotPayloadsRoundTripWithIdenticalBytesAndKeys() throws {
        let fixtures: [(String, String, String)] = [
            ("Thing", "thing-t", #"{"criteria":[{"evidence":"proof","state":"met","text":"check"}],"detail":"literal issue thing","events":[{"actor":"Hird","at":0,"text":"event"}],"group":"working","headline":"work","id":"t","progress":"1\/2","project":"P","runs":[{"name":"Hird","role":"role","status":"working","steps":[{"state":"active","title":"step"}]}],"startedAt":0,"state":"running","title":"Thing issue","updatedAt":0}"#),
            ("Question", "question-q", #"{"allowsMultiple":true,"answer":"A","askedAt":0,"asker":"Hird","id":"q","options":["A","B"],"prompt":"issue thing?","state":"answered","thing":"t"}"#),
            ("Message", "message-m", #"{"at":0,"id":"m","project":"P","role":"thing","text":"issue thing","thing":"t"}"#),
            ("Project", "project-p", #"{"id":"p","name":"P","openThings":2}"#),
            ("Status", "status", #"{"engine":"OMP","isResponding":false,"liveActivityRemoteEnabled":true,"macRunning":true}"#),
            ("ActivityDevice", "activityDevice-phone", #"{"enabled":false,"environment":"production","id":"phone","updatedAt":0}"#),
        ]
        for (type, name, payload) in fixtures {
            let decoded = try MobileRecord(cloudRecord: fixture(type, name, payload))
            let encoded = decoded.cloudRecord(in: zone)
            #expect(encoded.recordType == type)
            #expect(encoded.recordID.recordName == name)
            #expect(encoded.recordID.zoneID == zone)
            #expect(Set(encoded.allKeys()) == ["payload"])
            #expect(encoded["payload"] as? Data == Data(payload.utf8))
        }
        let decoded = try MobileRecord(cloudRecord: fixture("Message", "message-m", fixtures[2].2))
        guard case .message(let message) = decoded else { Issue.record("Expected message"); return }
        #expect(message.role == .issue)
        #expect(message.issue == "t")
        #expect(message.text == "issue thing")
    }

    @Test func oldSnapshotsStillDecodeWithoutAnyOfTheNewFields() throws {
        // A payload written before threads, reports, checks, captures and activity existed.
        let payload = #"{"criteria":[],"detail":"d","events":[],"group":"working","headline":"h","id":"t","project":"P","runs":[{"name":"Hird","role":"r","status":"working","steps":[]}],"startedAt":0,"state":"running","title":"T","updatedAt":0}"#
        guard case .issue(let issue) = try MobileRecord(cloudRecord: fixture("Thing", "thing-t", payload)) else {
            Issue.record("Expected an issue"); return
        }
        #expect(issue.thread == nil)
        #expect(issue.report == nil)
        #expect(issue.verifications == nil)
        #expect(issue.captures == nil)
        #expect(issue.runs.first?.activity == nil)
        #expect(issue.runs.first?.stage == nil)
        // Writing it back keeps every original key and adds only the new ones, all nil.
        let written = try MobileRecord(cloudRecord: fixture("Thing", "thing-t", payload)).cloudRecord(in: zone)
        let writtenPayload = try #require(written["payload"] as? Data)
        let fields = try #require(try JSONSerialization.jsonObject(with: writtenPayload) as? [String: Any])
        #expect(fields["title"] as? String == "T")
        #expect(fields["thread"] == nil)
        #expect(fields["state"] as? String == "running")

        // A message and a thread from before this release.
        let message = #"{"at":0,"id":"m","project":"P","role":"stallari","text":"old","thing":"t"}"#
        guard case .message(let old) = try MobileRecord(cloudRecord: fixture("Message", "message-m", message)) else {
            Issue.record("Expected a message"); return
        }
        #expect(old.thread == nil)
        #expect(old.attachments == nil)
        let thread = #"{"id":"default","kind":"main","name":"메인","working":false,"messageCount":0}"#
        guard case .thread(let value) = try MobileRecord(cloudRecord: fixture("Thread", "thread-default", thread)) else {
            Issue.record("Expected a thread"); return
        }
        #expect(value.lastMessageAt == nil)
    }

    @Test func threadMessagesAndOlderPageRequestsKeepTheirWireShape() throws {
        let payloads = [
            #"{"createdAt":0,"id":"r","kind":{"threadMessage":{"attachments":[{"byteCount":4,"id":"a","name":"a.jpg","type":"image/jpeg"}],"project":"P","text":"hi","thread":"t1"}}}"#,
            #"{"createdAt":0,"id":"r","kind":{"loadOlder":{"before":0,"thread":"t1"}}}"#,
        ]
        for payload in payloads {
            let decoded = try MobileRecord(cloudRecord: fixture("Request", "request-r", payload))
            // Decoding and writing again keeps every wire key and value; only key order differs.
            let written = try #require(decoded.cloudRecord(in: zone)["payload"] as? Data)
            let fields = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
            let original = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            #expect(fields["createdAt"] as? NSNumber == original["createdAt"] as? NSNumber)
            let kind = try #require(fields["kind"] as? [String: Any])
            let originalKind = try #require(original["kind"] as? [String: Any])
            #expect(Set(kind.keys) == Set(originalKind.keys))
        }
        // Byte counts and dates are numbers, not strings: an older decoder must not see new types here.
        let decoded = try MobileRecord(cloudRecord: fixture("Request", "request-r", payloads[0]))
        guard case .request(let request) = decoded, case .threadMessage(_, let thread, _, let files) = request.kind else {
            Issue.record("Expected a thread message"); return
        }
        #expect(thread == "t1")
        #expect(files?.first?.byteCount == 4)
    }

    @Test func aThreadRecordAddsATypeWithoutChangingExistingOnes() {
        #expect(CloudWire.recordType(.thread) == "Thread")
        #expect(CloudWire.recordType(.issue) == "Thing")
        #expect(MobileRecord.thread(MobileThread(id: "x", name: "n", kind: .main)).recordName == "thread-x")
        let kinds = Set(MobileRecord.schemaSamples.map(\.kind))
        #expect(kinds.contains(.thread))
        #expect(MobileRecord.Kind.allCases.allSatisfy { kinds.contains($0) })
    }

    @Test func queuedPhoneRequestsKeepTheirAssociatedValueKeysAndBytes() throws {
        let payloads = [
            #"{"createdAt":0,"id":"r","kind":{"message":{"project":"P","text":"issue thing"}}}"#,
            #"{"createdAt":0,"id":"r","kind":{"answer":{"options":["A"],"question":"q","text":"yes"}}}"#,
            #"{"createdAt":0,"id":"r","kind":{"cancelQuestion":{"_0":"q"}}}"#,
            #"{"createdAt":0,"id":"r","kind":{"steer":{"text":"issue thing","thing":"t"}}}"#,
        ] + ["confirmResult", "requestChanges", "resolvedInput", "stop", "resume"].map {
            "{\"createdAt\":0,\"id\":\"r\",\"kind\":{\"action\":{\"action\":\"\($0)\",\"thing\":\"t\"}}}"
        }
        for payload in payloads {
            let decoded = try MobileRecord(cloudRecord: fixture("Request", "request-r", payload))
            #expect(decoded.cloudRecord(in: zone)["payload"] as? Data == Data(payload.utf8))
            guard case .request(let request) = decoded else { Issue.record("Expected request"); continue }
            switch request.kind {
            case .action(let issue, _), .steer(let issue, _): #expect(issue == "t")
            default: break
            }
        }
    }

    @Test func oldUnversionedApprovalCannotBecomeAnApprovedRun() {
        let payload = #"{"createdAt":0,"id":"r","kind":{"action":{"action":"acceptProposal","thing":"t"}}}"#
        #expect(throws: DecodingError.self) {
            try MobileRecord(cloudRecord: fixture("Request", "request-r", payload))
        }
    }

    @Test func alertPayloadAndPushFieldsKeepTheDeployedThingKey() throws {
        let payload = #"{"body":"question","createdAt":0,"id":"a","thing":"t","title":"input"}"#
        let record = try MobileRecord(cloudRecord: fixture("Alert", "alert-a", payload)).cloudRecord(in: zone)
        #expect(record["payload"] as? Data == Data(payload.utf8))
        #expect(Set(record.allKeys()) == ["payload", "title", "body", "thing"])
        #expect(record["thing"] as? String == "t")
        #expect(record["title"] as? String == "input")
        #expect(record["body"] as? String == "question")
    }

    @Test func newProposalStatesRemainReadableByTheDeployedPhoneWithoutImplyingExecution() throws {
        for (state, expected) in [(MobileIssue.State.awaitingApproval, "needsInput"), (.rejected, "failed")] {
            let issue = MobileIssue(id: "t", title: "proposal", project: "P", state: state, group: .mine,
                                    headline: "approval", detail: "Mac approval required", criteria: [], progress: nil,
                                    startedAt: at, updatedAt: at)
            let record = MobileRecord.issue(issue).cloudRecord(in: zone)
            #expect(record.recordType == "Thing")
            let payload = try #require(record["payload"] as? Data)
            let fields = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(fields["state"] as? String == expected)
            #expect(fields["group"] as? String == "mine")
            #expect(issue.state == state)
            // Internal Codable still preserves the new state; only the cloud projection is lossy.
            #expect(try JSONDecoder().decode(MobileIssue.self, from: JSONEncoder().encode(issue)).state == state)
        }
    }

    @Test func activityContentKeepsThingIDAndTheDeployedDeepLink() throws {
        let payload = #"{"attentionCount":0,"detail":"work","newestStartedAt":0,"runningCount":1,"startedAt":0,"status":"running","thingID":"t","title":"P","updatedAt":0}"#
        let value = try JSONDecoder().decode(LiveActivitySummary.self, from: Data(payload.utf8))
        #expect(value.issueID == "t")
        #expect(value.url.absoluteString == "knarr://activity?thing=t")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(value) == Data(payload.utf8))
        let push = LiveActivityPush(event: .update, token: "fixture", environment: .production, content: value, sessionID: "s", timestamp: 0)
        let json = try #require(JSONSerialization.jsonObject(with: push.payload()) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Any])
        let content = try #require(aps["content-state"] as? [String: Any])
        #expect(content["thingID"] as? String == "t")
        #expect(content["issueID"] == nil)
    }
}
