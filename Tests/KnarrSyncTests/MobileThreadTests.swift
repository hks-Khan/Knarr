import CloudKit
import Foundation
import Testing
@testable import KnarrSync

@Suite struct MobileThreadRecordTests {
    let zone = CKRecordZone.ID(zoneName: MobileZone.name, ownerName: CKCurrentUserDefaultName)
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func schemaSeedsEverySupportedAssetSlot() {
        let samples = MobileRecord.schemaSamples.map { $0.cloudRecord(in: zone) }
        for (type, prefix, count) in [("Thing", "capture", MobileLimits.captureCount),
                                      ("Message", "attachment", MobileLimits.attachmentCount),
                                      ("Request", "attachment", MobileLimits.attachmentCount)] {
            let keys = Set(samples.filter { $0.recordType == type }.flatMap { $0.allKeys() })
            for index in 0..<count { #expect(keys.contains("\(prefix)\(index)")) }
        }
    }

    @Test func threadAndIssueDetailSurviveTheCloudRoundTrip() throws {
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let records: [MobileRecord] = [
            .thread(MobileThread(id: "t-1", name: "이슈 대화", kind: .issue, project: "P", issue: "i1",
                                 lastMessageAt: at, working: true, messageCount: 42)),
            .issue(MobileIssue(id: "i1", title: "제목", project: "P", state: .done, group: .mine, headline: "", detail: "",
                               criteria: [.init(text: "통과", state: .met, evidence: "swift test → 0")], progress: "5/5",
                               startedAt: at, updatedAt: at,
                               runs: [.init(name: "Hird-1", role: "고치기", status: .working, steps: [.init(title: "구현", state: .active)],
                                            activity: "swift test", stages: [.init(title: "구현", state: .active)],
                                            stage: 3, startedAt: at, checksPassed: 1, checksFailed: 0)],
                               report: "보고 요약", verifications: [.init(id: "v1", command: "swift test", exitCode: 0, at: at, summary: "통과")],
                               captures: [.init(id: "shot.png", caption: "화면", width: 640, height: 400, data: pixel)],
                               thread: "t-1")),
            .message(MobileMessage(id: "m1", at: at, role: .user, text: "사진", project: nil, thread: "t-1",
                                   attachments: [.init(id: "a1", name: "a.jpg", type: "image/jpeg", byteCount: pixel.count, data: pixel)])),
            .request(MobileRequest(id: "r1", createdAt: at, kind: .threadMessage(
                text: "안녕", thread: "t-1", project: "P",
                attachments: [.init(id: "a1", name: "a.jpg", type: "image/jpeg", byteCount: pixel.count, data: pixel)]))),
            .request(MobileRequest(id: "r2", createdAt: at, kind: .loadOlder(thread: "t-1", before: at))),
        ]
        for record in records {
            let ck = record.cloudRecord(in: zone)
            let back = try MobileRecord(cloudRecord: ck)
            #expect(back.kind == record.kind)
            switch (record, back) {
            case (.issue(let a), .issue(let b)):
                #expect(b.report == a.report)
                #expect(b.verifications == a.verifications)
                #expect(b.captures?.first?.data == pixel)
                #expect(b.thread == "t-1")
                #expect(b.runs.first?.activity == "swift test")
                #expect(b.runs.first?.stage == 3)
            case (.message(let a), .message(let b)):
                #expect(b.thread == "t-1")
                #expect(b.attachments?.first?.data == pixel)
                #expect(b.attachments?.first?.name == a.attachments?.first?.name)
            case (.request(let a), .request(let b)):
                #expect(a.kind == b.kind)
            case (.thread(let a), .thread(let b)):
                #expect(a == b)
            default:
                Issue.record("record kind changed in the round trip")
            }
        }
    }

    @Test func imagesTravelAsAssetFieldsNotInsideThePayload() throws {
        let pixel = Data([0x01, 0x02, 0x03])
        let issue = MobileIssue(id: "i", title: "t", project: "P", state: .running, group: .working, headline: "", detail: "",
                                criteria: [], progress: nil, startedAt: at, updatedAt: at,
                                runs: [.init(name: "H", role: "", status: .working, steps: [])],
                                captures: [.init(id: "a", caption: "c", width: 1, height: 1, data: pixel)])
        let record = MobileRecord.issue(issue).cloudRecord(in: zone)
        let asset = try #require(record["capture0"] as? CKAsset)
        #expect(try Data(contentsOf: #require(asset.fileURL)) == pixel)
        let payload = try #require(record["payload"] as? Data)
        #expect(!payload.contains(pixel))
    }
}

@Suite struct MobileHistoryTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func message(_ n: Int, thread: String = "t") -> MobileMessage {
        MobileMessage(id: "m\(n)", at: at.addingTimeInterval(Double(n)), role: .user, text: "\(n)", project: nil, thread: thread)
    }

    @Test func aPageIsNewestFirstAndStopsAtTheGivenTime() {
        let all = (0..<120).map { message($0) }
        let page = MobileHistory.page(all, thread: "t", before: at.addingTimeInterval(100))
        #expect(page.count == MobileLimits.historyPage)
        #expect(page.first?.id == "m99")
        #expect(page.last?.id == "m50")
        #expect(page.allSatisfy { $0.at < at.addingTimeInterval(100) })
    }

    @Test func anotherThreadNeverLeaksIntoAPage() {
        let page = MobileHistory.page([message(1), message(2, thread: "other")], thread: "t", before: at.addingTimeInterval(10))
        #expect(page.map(\.id) == ["m1"])
    }

    @Test func fourthOlderPageRemainsAvailableAndIsNotAlsoDeleted() {
        var ledger = MobileHistoryLedger()
        for range in [250..<300, 200..<250, 150..<200] {
            ledger.retain(range.reversed().map { message($0) }, thread: "t")
        }
        let next = (100..<150).reversed().map { message($0) }
        let dropped = Set(ledger.retain(next, thread: "t"))
        #expect(Set(next.map(\.id)).isSubset(of: ledger.messageIDs))
        #expect(Set(next.map(\.id)).isDisjoint(with: dropped))
        #expect(ledger.messageIDs.count == MobileLimits.historyOnMac)
    }

    @Test func ledgerDropsOnlyTheOldestPagesPastTheLimit() {
        var ledger = MobileHistoryLedger()
        let first = (0..<60).map { message($0) }
        #expect(ledger.retain(first, thread: "t", limit: 100).isEmpty)
        let second = (60..<120).map { message($0) }
        // Pages arrive newest first; the limit still drops the oldest twenty, not the newest page.
        let dropped = ledger.retain(second, thread: "t", limit: 100)
        #expect(Set(dropped) == Set((0..<20).map { "m\($0)" }))
        #expect(ledger.messageIDs.count == 100)
        #expect(ledger.messageIDs.contains("m119"))
        #expect(ledger.messageIDs.contains("m20"))
        #expect(!ledger.messageIDs.contains("m19"))
        // Asking for the same page again changes nothing.
        #expect(ledger.retain(second, thread: "t", limit: 100).isEmpty)
        // Another conversation keeps its own budget.
        #expect(ledger.retain([message(1, thread: "other")], thread: "other", limit: 100).isEmpty)
        #expect(ledger.messageIDs.count == 101)
    }
}

@Suite struct MobileDashboardTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func issue(_ id: String, _ state: MobileIssue.State, group: MobileIssue.Group, project: String = "P",
               run: MobileIssue.Run? = nil) -> MobileIssue {
        MobileIssue(id: id, title: id, project: project, state: state, group: group, headline: "", detail: "",
                    criteria: [], progress: nil, startedAt: at, updatedAt: at, runs: run.map { [$0] } ?? [])
    }
    func run(_ name: String, _ status: MobileIssue.Run.Status = .working) -> MobileIssue.Run {
        .init(name: name, role: "", status: status, steps: [], activity: "swift test", stages: nil, stage: 3, startedAt: at)
    }

    @Test func everyIssueFallsInExactlyOneBucket() {
        let issues = [issue("a", .needsInput, group: .mine), issue("b", .awaitingApproval, group: .mine),
                      issue("c", .running, group: .working, run: run("Hird-1")), issue("d", .failed, group: .stopped),
                      issue("e", .done, group: .mine), issue("f", .done, group: .finished)]
        let dashboard = MobileDashboard.make(issues: issues, questions: [], projects: [], lastChangedAt: at)
        #expect(dashboard.count(.needsAnswer) == 1)
        #expect(dashboard.count(.awaitingApproval) == 1)
        #expect(dashboard.count(.running) == 1)
        #expect(dashboard.count(.failed) == 1)
        #expect(dashboard.count(.judging) == 1)
        #expect(dashboard.count(.recentlyDone) == 1)
        #expect(dashboard.counts.map(\.count).reduce(0, +) == issues.count)
    }

    @Test func theMacsPresentationStateDecidesThePhoneBucket() {
        func phone(_ status: String) -> MobileIssue {
            MobileIssue(id: "p", title: "p", project: "P", state: .running, group: .mine, headline: "", detail: "",
                        criteria: [], progress: nil, startedAt: at, updatedAt: at, runs: [run("Hird-1")], status: status)
        }
        let expectations: [(String, MobileDashboard.Bucket)] = [
            ("awaitingApproval", .awaitingApproval), ("inProgress", .running), ("needsAnswer", .needsAnswer),
            ("judging", .judging), ("awaitingIntegration", .awaitingIntegration),
            ("unmet", .unmet), ("failed", .failed)
        ]
        for (status, bucket) in expectations {
            #expect(MobileDashboard.bucket(of: phone(status), asking: false) == bucket, Comment(rawValue: status))
        }
    }

    @Test func aPendingQuestionOutranksTheExecutionState() {
        let issue = issue("a", .running, group: .mine, run: run("Hird-1"))
        let question = MobileQuestion(id: "q", issue: "a", asker: "Hird-1", prompt: "?", options: [], allowsMultiple: false,
                                      state: .pending, answer: nil, askedAt: at)
        let dashboard = MobileDashboard.make(issues: [issue], questions: [question], projects: [], lastChangedAt: at)
        #expect(dashboard.count(.needsAnswer) == 1)
        #expect(dashboard.pendingQuestions == 1)
    }

    @Test func onlyWorkingRunsAreListedWithTheirStageAndActivity() {
        let working = issue("a", .running, group: .working, run: run("Hird-1"))
        let waiting = issue("b", .needsInput, group: .working, project: "Q", run: run("Hird-2", .waiting))
        let done = issue("c", .done, group: .mine, run: run("Hird-3", .done))
        let dashboard = MobileDashboard.make(issues: [working, waiting, done], questions: [], projects: [], lastChangedAt: at)
        #expect(dashboard.working.map(\.issue) == ["a", "b"])
        #expect(dashboard.working.map(\.stage) == [3, 3])
        #expect(dashboard.working.first?.activity == "swift test")
        #expect(dashboard.working.first?.stageTitle == "구현")
        #expect(dashboard.working.last?.waiting == true)
    }

    @Test func projectCountsIgnoreFinishedIssues() {
        let issues = [issue("a", .running, group: .working, project: "P"), issue("b", .done, group: .finished, project: "P"),
                      issue("c", .failed, group: .mine, project: "Q")]
        let projects = [MobileProject(id: "P", name: "P", openIssues: 1), MobileProject(id: "Q", name: "Q", openIssues: 1)]
        let dashboard = MobileDashboard.make(issues: issues, questions: [], projects: projects, lastChangedAt: nil)
        #expect(dashboard.projects.map(\.id) == ["P", "Q"])
        #expect(dashboard.projects.first?.open == 1)
        #expect(dashboard.projects.first?.needsAnswer == 0)
    }
}

@Suite struct MobileAlertInboxTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func alert(_ id: String, at date: Date, issue: String? = nil) -> MobileAlert {
        MobileAlert(id: id, createdAt: date, title: id, body: "b", issue: issue)
    }

    @Test func alertsOutliveTheSixHourServerCopyAndKeepReadState() {
        var inbox = MobileAlertInbox()
        let old = alert("old", at: now.addingTimeInterval(-2 * 24 * 3600), issue: "i1")
        inbox.merge(saved: [old], now: now)
        inbox.markRead(["old"])
        // The Mac deleted the alert after six hours; the phone still shows it, already read.
        inbox.merge(saved: [], now: now.addingTimeInterval(3 * 24 * 3600))
        #expect(inbox.alerts.map(\.id) == ["old"])
        #expect(inbox.isRead("old"))
        #expect(inbox.alert(for: "i1")?.id == "old")
        // After a week the phone lets it go.
        inbox.merge(saved: [], now: now.addingTimeInterval(8 * 24 * 3600))
        #expect(inbox.alerts.isEmpty)
        #expect(inbox.unreadCount == 0)
    }

    @Test func newAlertsAreUnreadAndNewestFirst() {
        var inbox = MobileAlertInbox()
        inbox.merge(saved: [alert("a", at: now.addingTimeInterval(-60)), alert("b", at: now)], now: now)
        #expect(inbox.alerts.map(\.id) == ["b", "a"])
        #expect(inbox.unreadCount == 2)
        inbox.markAllRead()
        #expect(inbox.unreadCount == 0)
        let restored = MobileAlertInbox(stored: inbox.stored)
        #expect(restored.unreadCount == 0)
        #expect(restored.alerts.map(\.id) == ["b", "a"])
    }
}
