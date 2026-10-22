import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) @MainActor struct DesktopNotificationTests {
    @Test func baselineReplayRestartAndOfflineEvents() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var snapshot = f.snapshot()
        var service = try f.service()
        await service.observe(snapshot)
        #expect(f.client.sent.isEmpty)
        snapshot.issues[0].proposal?.version = 2
        await service.observe(snapshot)
        await service.observe(snapshot)
        #expect(f.client.sent.map(\.kind) == [.approval])
        service = try f.service()
        await service.observe(snapshot)
        #expect(f.client.sent.count == 1)
        // A version saved while the app is offline is new, not historical baseline.
        snapshot.issues[0].proposal?.version = 3
        service = try f.service()
        await service.observe(snapshot)
        #expect(f.client.sent.count == 2)
        #expect(Set(f.client.sent.map(\.id)).count == 2)
    }

    @Test func terminalStatesAndQuestionDoNotDuplicateIssueProjection() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var s = f.snapshot()
        s.issues[0].state = .needsInput
        s.runs = [f.run(id: "r")]
        s.questions = [.init(id: "question", runID: "r", issueID: "i", prompt: "secret log", options: [], createdAt: .now)]
        await service.observe(s)
        #expect(f.client.sent.map(\.kind) == [.question])
        for state in [DurableRunState.failed, .cancelled, .interrupted, .succeeded] {
            s.questions = []
            var run = f.run(id: state.rawValue)
            run.state = state; run.endedAt = Date(timeIntervalSince1970: 20)
            s.runs = [run]
            s.notifications = state == .succeeded ? [.init(id: "completion", runID: run.id, createdAt: .now)] : []
            await service.observe(s)
        }
        #expect(f.client.sent.map(\.kind) == [.question, .failed, .cancelled, .interrupted, .hirdCompleted])
        s.issues[0].state = .done
        s.issues[0].completedAt = Date(timeIntervalSince1970: 30)
        await service.observe(s)
        await service.observe(s)
        #expect(f.client.sent.map(\.kind).last == .issueCompleted)
        #expect(f.client.sent.count == 6)
        #expect(f.client.sent.allSatisfy { !$0.body.contains("secret") && !$0.title.contains("secret") })
    }

    @Test func coalescedFinalCompletionSuppressesHirdCompletion() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var s = f.snapshot()
        s.issues[0].state = .done; s.issues[0].completedAt = .now
        var run = f.run(id: "r"); run.state = .succeeded
        s.runs = [run]; s.notifications = [.init(id: "n", runID: "r", createdAt: .now)]
        await service.observe(s)
        #expect(f.client.sent.map(\.kind) == [.issueCompleted])
    }

    @Test func unmetJudgementIsNotReportedAsSuccessfulIssueCompletion() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var s = f.snapshot()
        s.issues[0].state = .failed
        s.issues[0].acceptance = [.init(text: "criterion", state: .unmet, evidence: "private")]
        var run = f.run(id: "r"); run.state = .succeeded
        s.runs = [run]; s.notifications = [.init(id: "n", runID: "r", createdAt: .now)]
        await service.observe(s)
        await service.observe(s)
        #expect(f.client.sent.map(\.kind) == [.issueFailed])
    }

    @Test func deniedPermissionChangesAndSendFailureAreBoundedAndDurable() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        f.client.authorization = .notDetermined
        f.client.grantsRequest = false
        await service.observe(f.snapshot())
        await service.observe(f.snapshot())
        #expect(f.client.requests == 1)
        #expect(service.status == .denied)
        #expect(service.deliveredIDs.isEmpty)
        f.client.authorization = .authorized; f.client.failSend = true
        await service.refreshAuthorization()
        #expect(service.status == .failed)
        #expect(service.deliveredIDs.isEmpty)
        let attempts = f.client.attempts
        await service.observe(f.snapshot())
        #expect(f.client.attempts == attempts)
        f.client.failSend = false
        let restarted = try f.service()
        await restarted.observe(f.snapshot())
        #expect(f.client.sent.count == 1)
        #expect(restarted.deliveredIDs == Set(f.client.sent.map(\.id)))
    }

    @Test func requestAndLedgerErrorsNeverClaimDelivery() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        f.client.authorization = .notDetermined; f.client.failRequest = true
        await service.observe(f.snapshot())
        #expect(service.status == .failed)
        #expect(service.deliveredIDs.isEmpty)
        #expect(f.client.sent.isEmpty)
        let bad = f.directory.appendingPathComponent("bad.json")
        try Data("invalid".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try DesktopNotificationService(client: f.client, ledgerURL: bad) }
    }

    @Test func coldStartClickAndInvalidStaleArchivedOwnershipRouting() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var selected: [String] = []
        var activations = 0
        var service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var s = f.snapshot()
        await service.observe(s)
        let id = try #require(f.client.sent.first?.id)
        service = try f.service()
        service.activate = { activations += 1 }
        service.selectThread = { selected.append($0) }
        await service.open(id) // Before the repository/window are ready.
        #expect(selected.isEmpty)
        await service.observe(s)
        #expect(selected == ["owner"])
        #expect(activations == 1)
        #expect(s.issues[0].approval == nil)
        await service.open("file:///tmp/anything")
        s.issues[0].proposal?.version = 2
        await service.observe(s)
        await service.open(id)
        #expect(selected == ["owner"])
        let current = try #require(f.client.sent.last?.id)
        s.issueProjects["i"] = "foreign"
        await service.observe(s)
        await service.open(current)
        #expect(selected == ["owner"])
        s.issueProjects["i"] = "p"; s.issues[0].archivedAt = .now
        await service.observe(s)
        await service.open(current)
        #expect(selected == ["owner"])
        s.issues = []
        await service.observe(s)
        await service.open(current)
        #expect(selected == ["owner"])
    }

    @Test func osAcceptanceReconcilesUnacknowledgedSendWithoutAnotherBanner() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var service = try f.service()
        await service.observe(f.snapshot(issues: []))
        f.client.failSend = true
        await service.observe(f.snapshot())
        let event = try #require(DesktopNotificationEvent.events(in: f.snapshot()).first)
        f.client.accepted.insert(event.id)
        f.client.failSend = false
        service = try f.service()
        await service.observe(f.snapshot())
        #expect(f.client.sent.isEmpty)
        #expect(service.deliveredIDs == [event.id])
    }

    @Test func persistedRepositoryEventsAndClickNeverApproveOrDispatch() async throws {
        let f = try await LiveFixture.make()
        do {
            let client = Client()
            let service = try DesktopNotificationService(client: client, ledgerURL: f.directory.appendingPathComponent("desktop.json"))
            await service.observe(try await f.repository.snapshot())
            try await f.create()
            await service.observe(try await f.repository.snapshot())
            #expect(client.sent.map(\.kind) == [.approval])
            let before = try await f.repository.snapshot()
            service.currentSnapshot = { try await f.repository.snapshot() }
            service.activate = {}
            service.selectThread = { f.store.openNotificationThread($0) }
            await service.open(try #require(client.sent.first?.id))
            let after = try await f.repository.snapshot()
            #expect(after.issues == before.issues)
            #expect(after.runs == before.runs)
            try await f.dispatch()
            _ = try await f.session.ask(id: "saved-question", runID: "r", issueID: "t", prompt: "private", options: ["A"])
            await service.observe(try await f.repository.snapshot())
            #expect(client.sent.map(\.kind) == [.approval, .question])
            _ = try await f.session.receive(.init(id: "complete", runID: "r", at: .now, payload: .complete(f.result(), notificationID: "saved-notice")))
            await service.observe(try await f.repository.snapshot())
            try await f.session.judge(issueID: "t", runID: "r", evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "검사 통과")])
            await service.observe(try await f.repository.snapshot())
            #expect(client.sent.map(\.kind) == [.approval, .question, .hirdCompleted, .issueCompleted])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func historicalFinalsAreSilentAndResolvedUndeliveredQuestionsAreRetired() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var history = f.snapshot()
        history.issues[0].state = .done; history.issues[0].completedAt = .now
        var run = f.run(id: "old"); run.state = .succeeded
        history.runs = [run]; history.notifications = [.init(id: "old-notice", runID: run.id, createdAt: .distantPast)]
        var service = try f.service()
        await service.observe(history)
        #expect(f.client.sent.isEmpty)
        f.client.authorization = .denied
        var current = f.snapshot()
        current.issues[0].state = .needsInput; current.runs = [f.run(id: "r")]
        current.questions = [.init(id: "q", runID: "r", issueID: "i", prompt: "private", options: [], createdAt: .now)]
        await service.observe(current)
        current.questions[0].state = .answered
        await service.observe(current)
        f.client.authorization = .authorized
        service = try f.service()
        await service.observe(current)
        #expect(f.client.sent.isEmpty)
    }

    @Test func freshOwnershipOriginAndPermissionGrantAreChecked() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        f.client.authorization = .notDetermined
        var snapshot = f.snapshot()
        snapshot.threads[0].originThreadID = "project"
        snapshot.threads.append(.init(id: "project", name: "Project", projectID: "p"))
        await service.observe(snapshot)
        #expect(f.client.requests == 1)
        #expect(f.client.sent.count == 1)
        var routed: [String] = []
        service.activate = {}
        service.selectThread = { routed.append($0) }
        var fresh = snapshot
        fresh.projects[0].archivedAt = .now
        service.currentSnapshot = { fresh.value }
        await service.open(try #require(f.client.sent.first?.id))
        #expect(routed.isEmpty)
        snapshot.threads[1].projectID = "foreign"
        #expect(DesktopNotificationEvent.events(in: snapshot).isEmpty)
    }

    @Test func legacyConversationOwnershipStillReceivesAndRoutesEvents() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var snapshot = f.snapshot()
        snapshot.threads[0].issueID = nil // Persisted pre-issue-session custom conversation.
        await service.observe(snapshot)
        #expect(f.client.sent.map(\.kind) == [.approval])
        var selected: [String] = []
        service.activate = {}
        service.selectThread = { selected.append($0) }
        let id = try #require(DesktopNotificationEvent.events(in: snapshot).first?.id)
        await service.open(id)
        #expect(selected == ["owner"])
        snapshot.threads[0].issueID = "foreign-issue"
        await service.observe(snapshot)
        await service.open(id)
        #expect(selected == ["owner"])
    }

    @Test func nativeClickRecoversReceiptGapWithoutReposting() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var service = try f.service()
        await service.observe(f.snapshot(issues: []))
        // The durable outbox exists, but the native acceptance receipt was not saved.
        f.client.failSend = true
        await service.observe(f.snapshot())
        let id = try #require(DesktopNotificationEvent.events(in: f.snapshot()).first?.id)
        #expect(service.deliveredIDs.isEmpty)
        service = try f.service()
        var selected: [String] = []
        service.activate = {}
        service.selectThread = { selected.append($0) }
        // A verified native response proves delivery even if clicking removed it from the OS list.
        await service.open(id)
        f.client.failSend = false
        await service.observe(f.snapshot())
        #expect(selected == ["owner"])
        #expect(service.deliveredIDs == [id])
        #expect(f.client.sent.isEmpty)
        let restarted = try f.service()
        await restarted.observe(f.snapshot())
        #expect(f.client.sent.isEmpty)
    }

    @Test func interruptedSendWithNoOSReceiptDoesNotRiskAnotherSound() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var service = try f.service()
        await service.observe(f.snapshot(issues: []))
        f.client.failSend = true
        await service.observe(f.snapshot())
        let event = try #require(DesktopNotificationEvent.events(in: f.snapshot()).first)
        let url = f.directory.appendingPathComponent("receipts.json")
        var persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // Crash fixture: intent reached disk, but neither add's outcome nor its receipt did.
        persisted["uncertain"] = [event.id: try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.target))]
        try JSONSerialization.data(withJSONObject: persisted).write(to: url)
        f.client.failSend = false
        service = try f.service()
        await service.observe(f.snapshot())
        await service.observe(f.snapshot())
        #expect(f.client.attempts == 1)
        #expect(f.client.sent.isEmpty)
        #expect(service.deliveredIDs.isEmpty)
        #expect(service.status == .failed)
        service = try f.service()
        await service.observe(f.snapshot())
        #expect(f.client.attempts == 1)
        service.activate = {}
        var selected: [String] = []
        service.selectThread = { selected.append($0) }
        await service.open(event.id) // Verified native response resolves the ambiguous receipt.
        #expect(selected == ["owner"])
        #expect(service.deliveredIDs == [event.id])
        service = try f.service()
        await service.observe(f.snapshot())
        #expect(f.client.attempts == 1)
    }

    @Test func shutdownCancellationIsNotReportedAsUserCancellation() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let service = try f.service()
        await service.observe(f.snapshot(issues: []))
        var snapshot = f.snapshot()
        snapshot.issues[0].state = .failed
        var user = f.run(id: "user"); user.state = .cancelled
        user.stopReason = "사용자 요청"
        var shutdown = f.run(id: "shutdown"); shutdown.state = .cancelled
        shutdown.stopReason = DesktopNotificationPolicy.current.shutdownCancellationReason
        snapshot.runs = [user, shutdown]
        await service.observe(snapshot)
        await service.observe(snapshot)
        #expect(f.client.sent.map(\.kind) == [.cancelled, .interrupted])
    }

    @Test func nativeCenterGuardRejectsCLIAndMissingBundleID() {
        #if os(macOS)
        #expect(!MacNotificationClient.isUsable(bundleURL: URL(fileURLWithPath: "/tmp/Knarr"), bundleIdentifier: "com.knarr"))
        #expect(!MacNotificationClient.isUsable(bundleURL: URL(fileURLWithPath: "/tmp/Knarr.app"), bundleIdentifier: nil))
        #expect(MacNotificationClient.isUsable(bundleURL: URL(fileURLWithPath: "/tmp/Knarr.app"), bundleIdentifier: "com.knarr"))
        #expect(MacNotificationClient.makeIfUsable() == nil)
        #endif
    }

    final class Client: DesktopNotificationClient {
        var authorization: DesktopNotificationAuthorization = .authorized
        var grantsRequest = true
        var failSend = false
        var failRequest = false
        var requests = 0
        var attempts = 0
        var sent: [DesktopNotificationEvent] = []
        var accepted: Set<String> = []
        func authorizationStatus() async -> DesktopNotificationAuthorization { authorization }
        func requestAuthorization() async throws -> Bool {
            requests += 1
            if failRequest { throw CocoaError(.fileReadUnknown) }
            authorization = grantsRequest ? .authorized : .denied
            return grantsRequest
        }
        func acceptedIdentifiers() async -> Set<String> { accepted }
        func send(_ event: DesktopNotificationEvent) async throws {
            attempts += 1
            if failSend { throw CocoaError(.fileWriteUnknown) }
            sent.append(event); accepted.insert(event.id)
        }
    }
    struct Snapshot {
        var projects: [StoredProject]
        var threads: [ConversationThread]
        var issues: [KnarrCore.Issue]
        var issueProjects: [KnarrCore.Issue.ID: String]
        var runs: [PersistedRun] = []
        var questions: [PersistedQuestion] = []
        var notifications: [CompletionNotification] = []
        var value: PersistenceSnapshot {
            .init(projects: projects, threads: threads, issues: issues, issueProjects: issueProjects,
                  chat: [], chatLinks: [], runs: runs, questions: questions, notifications: notifications)
        }
    }
    @MainActor struct Fixture {
        let directory: URL
        let client = Client()
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-notifications-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        func service() throws -> DesktopNotificationService {
            try .init(client: client, ledgerURL: directory.appendingPathComponent("receipts.json"))
        }
        func snapshot(issues: [KnarrCore.Issue]? = nil) -> Snapshot {
            var issue = Issue(id: "i", title: "secret issue title", projectName: "Project", state: .awaitingApproval,
                              headline: "", detail: "secret details", acceptance: [], hirds: [], events: [], startedAt: .now)
            issue.threadID = "owner"
            issue.proposal = .init(instruction: "secret instruction", model: "model")
            return .init(projects: [.init(id: "p", name: "Project", absolutePath: "/synthetic")],
                         threads: [.init(id: "owner", name: "Issue", issueID: "i")],
                         issues: issues ?? [issue], issueProjects: ["i": "p"])
        }
        func run(id: String) -> PersistedRun {
            .init(hird: .init(id: .init(id), name: "Hird", role: "", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
                  issueID: "i", projectID: "p", ompSessionID: nil, ownershipToken: "synthetic", startedAt: .now)
        }
    }
}

private extension DesktopNotificationService {
    func observe(_ snapshot: DesktopNotificationTests.Snapshot) async { await observe(snapshot.value) }
}
private extension DesktopNotificationEvent {
    static func events(in snapshot: DesktopNotificationTests.Snapshot) -> [Self] { events(in: snapshot.value) }
}
