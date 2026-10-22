import Foundation
import Testing
@testable import KnarrCore

actor TestHird: HirdAdapter {
    var runs: [PersistedRun] = []
    var resolutions: [QuestionResolution] = []
    var failDelivery = false
    var deliveryGate: CheckedContinuation<Void, Never>?
    var holdNextDelivery = false
    var enteredDelivery = false
    func holdDelivery() { holdNextDelivery = true }
    func releaseDelivery() { deliveryGate?.resume(); deliveryGate = nil }
    var holds: [HirdRun.ID: CheckedContinuation<Void, Never>] = [:]
    var cancelledRuns: Set<HirdRun.ID> = []
    var defaultModel = "openai-codex/fixture-model"
    var steering: [(HirdRun.ID, String)] = []
    var holdCancellation = false
    var cancellationEntered = false
    var cancellationGate: CheckedContinuation<Void, Never>?
    func modelForNewRuns() -> String? { defaultModel }
    func setModel(_ model: String) { defaultModel = model }
    func steer(_ text: String, runID: HirdRun.ID) throws {
        guard !cancelledRuns.contains(runID) else { throw StallariError.terminalRun }
        steering.append((runID, text))
    }
    func holdCancel() { holdCancellation = true }
    func releaseCancel() { cancellationGate?.resume(); cancellationGate = nil }
    func terminationConfirmed(_ runID: HirdRun.ID) -> Bool { cancelledRuns.contains(runID) && holds[runID] == nil && !holdCancellation }
    func start(_ run: PersistedRun, emit: @escaping HirdEventSink) async throws {
        guard !cancelledRuns.contains(run.id), !Task.isCancelled else { return }
        runs.append(run)
        await withCheckedContinuation { holds[run.id] = $0 }
    }
    func deliver(_ resolution: QuestionResolution) async throws {
        if holdNextDelivery {
            holdNextDelivery = false; enteredDelivery = true
            await withCheckedContinuation { deliveryGate = $0 }
        }
        if failDelivery { throw OMPRPCError.notRunning }
        if !resolutions.contains(resolution) { resolutions.append(resolution) }
    }
    func cancel(_ runID: HirdRun.ID) async {
        cancelledRuns.insert(runID)
        if holdCancellation {
            cancellationEntered = true
            await withCheckedContinuation { cancellationGate = $0 }
            holdCancellation = false
        }
        holds.removeValue(forKey: runID)?.resume()
    }
    func setFailure(_ value: Bool) { failDelivery = value }
}
actor TestStallariRPC: StallariRPC {
    var busy = false
    var thinking = "high"
    var model = "fixture-model"
    var provider = "openai-codex"
    private var rejectModelChanges = false
    func rejectModels() { rejectModelChanges = true }
    var prompts: [[String: OMPJSON]] = []
    var sent: [[String: OMPJSON]] = []
    var sendByteLimit = Int.max
    func setSendByteLimit(_ value: Int) { sendByteLimit = value }
    var failPrompt = false
    var promptGate: CheckedContinuation<Void, Never>?
    var holdNextPrompt = false
    var enteredPrompt = false
    func holdPrompt() { holdNextPrompt = true }
    func releasePrompt() { promptGate?.resume(); promptGate = nil }
    var subscribers: [AsyncStream<OMPEvent>.Continuation] = []
    func subscribe() -> AsyncStream<OMPEvent> {
        let pair = AsyncStream<OMPEvent>.makeStream()
        subscribers.append(pair.continuation)
        return pair.stream
    }
    func emit(_ event: OMPEvent) { for subscriber in subscribers { subscriber.yield(event) } }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        if command == "prompt", fields["message"]?.string == "/knarr-stallari-tools" {
            emit(.frame(.object(["type": .string("extension_ui_request"), "method": .string("setStatus"),
                "statusKey": .string("__knarr_tool_policy__"), "statusText": .string("ready")])))
            return .object(["data": .object(["agentInvoked": .bool(false)])])
        }
        if command == "prompt" {
            if holdNextPrompt {
                holdNextPrompt = false; enteredPrompt = true
                await withCheckedContinuation { promptGate = $0 }
            }
            if failPrompt { throw OMPRPCError.notRunning }
            prompts.append(fields)
        }
        if command == "set_thinking_level" { thinking = fields["level"]?.string ?? thinking }
        if command == "set_model", rejectModelChanges { throw OMPRPCError.notRunning }
        if command == "set_model" { model = fields["modelId"]?.string ?? model; provider = fields["provider"]?.string ?? provider }
        if command == "get_available_thinking_levels" { return .object(["data": .object(["levels": .array([.string("off"), .string("high")])])]) }
        if command == "get_available_models" {
            return .object(["data": .object(["models": .array(["fixture-model", "second-model"].map { .object(["provider": .string("openai-codex"), "id": .string($0)]) })])])
        }
        let data: OMPJSON = command == "get_state" ? .object([
            "isStreaming": .bool(busy), "sessionId": .string("stallari-omp"),
            "model": .object(["provider": .string(provider), "id": .string(model)]), "thinkingLevel": .string(thinking),
            "dumpTools": .array(StallariTools.exposedNames.map { .object(["name": .string($0)]) })
        ]) : .object([:])
        return .object(["success": .bool(true), "data": data])
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {
        guard try OMPJSON.object(fields).jsonLine().count <= sendByteLimit else { throw OMPRPCError.invalidFrame("inbound physical limit") }
        sent.append(fields)
    }
    func setBusy(_ value: Bool) { busy = value }
    func setFailure(_ value: Bool) { failPrompt = value }
    func shutdown(cancel: Bool) async -> OMPProcessExit {
        for subscriber in subscribers { subscriber.finish() }
        return .init(status: 0, reason: .normal, remainingProcessIDs: [])
    }
}
struct StallariFixture {
    let directory: URL
    let repository: SQLiteKnarrRepository
    let hird = TestHird()
    let rpc = TestStallariRPC()
    let session: StallariSession
    static func make() async throws -> Self {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = base.appendingPathComponent("outputs/issue-3/fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("knarr.db"))
        let fixture = Self(directory: directory, repository: repository)
        try await repository.saveProject(.init(id: "p", name: "project", absolutePath: directory.path))
        return fixture
    }
    private init(directory: URL, repository: SQLiteKnarrRepository) {
        self.directory = directory; self.repository = repository
        session = StallariSession(repository: repository, rpc: rpc, hird: hird)
    }
    func cleanup() async throws {
        _ = await session.shutdown()
        try await repository.close()
        try FileManager.default.removeItem(at: directory)
    }
    /// Existing behavioural suites deliberately retain migrated same-thread issues.
    func issue(_ id: String) async throws -> KnarrCore.Issue.ID {
        try await legacyIssue(id: .init(id), title: "합계", criteria: ["합계 검사가 통과해요"], instruction: "합계 수정")
    }
    func legacyIssue(id: KnarrCore.Issue.ID, title: String, criteria: [String], instruction: String,
                     projectID: String = "p", model: String? = nil, mode: HirdRunMode = .change) async throws -> KnarrCore.Issue.ID {
        let project = try #require(try await repository.snapshot().projects.first { $0.id == projectID })
        var issue = KnarrCore.Issue(id: id, title: title, projectName: project.name, state: .awaitingApproval,
            headline: "사용자 승인 대기", detail: "", acceptance: (criteria + project.settings.criteria.filter { !criteria.contains($0) }).map {
                .init(text: $0, state: .pending, evidence: "")
            }, hirds: [], events: [], startedAt: .now)
        let fallback = await hird.modelForNewRuns()
        issue.proposal = .init(instruction: instruction, model: model ?? project.settings.hirdModel ?? fallback ?? "openai-codex/fixture-model",
                               mode: mode, thinking: project.settings.hirdThinking)
        try await repository.saveIssue(issue, projectID: projectID)
        return id
    }
    func dispatch(_ id: String, issue: KnarrCore.Issue.ID) async throws -> HirdRun.ID {
        if try await repository.snapshot().runs.contains(where: { $0.id.rawValue == id }) {
            return try await session.dispatch(issueID: issue, runID: .init(id))
        }
        let proposal = try #require(try await repository.snapshot().issues.first { $0.id == issue }?.proposal)
        _ = try await repository.approveIssueProposal(issueID: issue, version: proposal.version, at: .now)
        return try await session.dispatch(issueID: issue, runID: .init(id))
    }
    func result(passing: Bool = true) -> RunResult {
        .init(worktreePath: directory.path, branch: "test", commit: "fixture-commit", diffPath: nil,
              summary: "명시적 내부 Hird adapter 결과", verifications: [
                .init(id: "v", command: ["swift", "test"], workingDirectory: directory.path,
                      startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
                      exitCode: passing ? 0 : 1, logPath: directory.appendingPathComponent("test.log").path, summary: "합계 확인")])
    }
}
@Suite(.serialized) struct StallariTests {
    /// Each launch used to get a fresh session folder, so Stallari forgot everything said before a restart.
    @Test func sharedSessionDirectoryStartsFromTheNewestEarlierConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stallari-sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("stallari/A/sessions"), new = root.appendingPathComponent("stallari/B/sessions")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("1.jsonl"), atomically: true, encoding: .utf8)
        try "new".write(to: new.appendingPathComponent("2.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: old.appendingPathComponent("1.jsonl").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: new.appendingPathComponent("2.jsonl").path)
        let shared = try StallariTools.sessionDirectory(root: root, threadID: ConversationThread.defaultID)
        #expect(shared.standardizedFileURL.path == root.appendingPathComponent("stallari/sessions").standardizedFileURL.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path) == ["2.jsonl"])
        #expect(try String(contentsOf: shared.appendingPathComponent("2.jsonl"), encoding: .utf8) == "new")
        // Once the shared folder has a conversation, later launches keep it instead of reseeding.
        try "continued".write(to: shared.appendingPathComponent("2.jsonl"), atomically: true, encoding: .utf8)
        _ = try StallariTools.sessionDirectory(root: root, threadID: ConversationThread.defaultID)
        #expect(try String(contentsOf: shared.appendingPathComponent("2.jsonl"), encoding: .utf8) == "continued")
    }
    @Test func durableDispatchReturnsBeforeResultAndDuplicateDoesNotLaunchAgain() async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.issue("t")
            let run = try await f.dispatch("r", issue: issue)
            #expect(run.rawValue == "r")
            let snapshot = try await f.repository.snapshot()
            #expect(snapshot.runs.count == 1)
            #expect(snapshot.runs[0].result == nil)
            _ = try await f.dispatch("r", issue: issue)
            for _ in 0..<100 { if await f.hird.runs.count == 1 { break }; await Task.yield() }
            #expect(await f.hird.runs.count == 1)
            #expect(try await f.repository.snapshot().issues[0].state != .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func completionOutboxIdleBusyReplayAndJudgement() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            await f.rpc.setFailure(true)
            let update = HirdUpdate(id: "end", runID: r, at: Date(timeIntervalSince1970: 20), payload: .complete(f.result(), notificationID: "notice"))
            #expect(try await f.session.receive(update) == .applied)
            #expect(try await f.session.receive(update) == .duplicate)
            #expect(try await f.repository.pendingNotifications().count == 1)
            #expect(try await f.repository.snapshot().issues[0].state != .done)
            await f.rpc.setFailure(false)
            try await f.session.deliverNotifications()
            #expect(await f.rpc.prompts.count == 1)
            #expect(await f.rpc.prompts[0]["streamingBehavior"] == nil)
            try await f.session.deliverNotifications()
            #expect(await f.rpc.prompts.count == 1)
            #expect(try await f.repository.pendingNotifications().isEmpty)
            try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "합계 검사 통과")])
            try await f.session.judge(issueID: t, runID: r, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "합계 검사 통과")])
            #expect(try await f.repository.snapshot().issues[0].state == .done)
            #expect(try await f.repository.snapshot().issues[0].confirmed == false)
            let t2 = try await f.issue("t2"), r2 = try await f.dispatch("r2", issue: t2)
            await f.rpc.setBusy(true)
            _ = try await f.session.receive(.init(id: "end2", runID: r2, at: Date(timeIntervalSince1970: 21), payload: .complete(f.result(), notificationID: "notice2")))
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "followUp")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func questionsReverseDuplicateMismatchCancelAndReplayAfterDeliveryFailure() async throws {
        let f = try await StallariFixture.make()
        do {
            let t1 = try await f.issue("t1"), t2 = try await f.issue("t2")
            let r1 = try await f.dispatch("r1", issue: t1), r2 = try await f.dispatch("r2", issue: t2)
            _ = try await f.session.ask(id: "q1", runID: r1, issueID: t1, prompt: "첫 질문", options: ["A", "B"])
            _ = try await f.session.ask(id: "q2", runID: r2, issueID: t2, prompt: "두 번째", options: ["A", "B"])
            let answer = QuestionAnswer(selectedOptions: ["A"], text: nil)
            await #expect(throws: (any Error).self) { _ = try await f.session.answer(questionID: "q1", runID: r2, issueID: t2, answer: answer) }
            await #expect(throws: (any Error).self) { _ = try await f.session.answer(questionID: "q1", runID: r1, issueID: t2, answer: answer) }
            #expect(try await f.session.answer(questionID: "q2", runID: r2, issueID: t2, answer: answer) == .applied)
            #expect(try await f.session.answer(questionID: "q1", runID: r1, issueID: t1, answer: answer) == .applied)
            #expect(try await f.session.answer(questionID: "q1", runID: r1, issueID: t1, answer: answer) == .duplicate)
            await #expect(throws: (any Error).self) { _ = try await f.session.answer(questionID: "q1", runID: r1, issueID: t1, answer: .init(selectedOptions: ["B"], text: nil)) }
            #expect(await f.hird.resolutions.map(\.runID) == [r2, r1])
            _ = try await f.session.ask(id: "q3", runID: r1, issueID: t1, prompt: "취소", options: [])
            #expect(try await f.session.cancelQuestion(questionID: "q3", runID: r1, issueID: t1) == .applied)
            #expect(try await f.session.answer(questionID: "q3", runID: r1, issueID: t1, answer: .init(selectedOptions: [], text: "늦은 답변")) == .ignoredTerminal)
            _ = try await f.session.ask(id: "q4", runID: r1, issueID: t1, prompt: "전달 실패", options: [])
            await f.hird.setFailure(true)
            await #expect(throws: (any Error).self) { _ = try await f.session.answer(questionID: "q4", runID: r1, issueID: t1, answer: .init(selectedOptions: [], text: "보존")) }
            #expect(try await f.repository.snapshot().questions.last?.state == .answered)
            let replacement = StallariSession(repository: f.repository, rpc: f.rpc, hird: f.hird)
            await f.hird.setFailure(false)
            try await replacement.deliverAnswers()
            try await replacement.deliverAnswers()
            #expect(await f.hird.resolutions.filter { $0.questionID == "q4" }.count == 1)
            _ = await replacement.shutdown()
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func runCancelAndFailedVerificationCannotCompleteIssue() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            _ = try await f.session.ask(id: "q", runID: r, issueID: t, prompt: "답변", options: [])
            _ = try await f.session.cancelRun(r)
            #expect(try await f.session.answer(questionID: "q", runID: r, issueID: t, answer: .init(selectedOptions: [], text: "늦음")) == .ignoredTerminal)
            #expect(try await f.session.receive(.init(id: "late", runID: r, at: .now, payload: .complete(f.result(), notificationID: "late-notice"))) == .ignoredTerminal)
            #expect(try await f.repository.pendingNotifications().isEmpty)
            let t2 = try await f.issue("t2"), r2 = try await f.dispatch("r2", issue: t2)
            _ = try await f.session.receive(.init(id: "bad", runID: r2, at: .now, payload: .complete(f.result(passing: false), notificationID: "bad-notice")))
            await #expect(throws: (any Error).self) { try await f.session.judge(issueID: t2, runID: r2, evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "실패")]) }
            #expect(try await f.repository.snapshot().issues.last?.state != .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct StallariStorageBoundaryTests {
    @Test func oneStallariWorksAcrossProjects() async throws {
        let f = try await StallariFixture.make()
        do {
            try await f.repository.saveProject(.init(id: "other", name: "other", absolutePath: f.directory.path + "/other"))
            let t = try await f.legacyIssue(id: "in-other", title: "다른 프로젝트 작업", criteria: ["검사"], instruction: "고쳐요", projectID: "other")
            #expect(try await f.repository.projectID(forIssue: t) == "other")
            let r = try await f.dispatch("r-other", issue: t)
            #expect(try await f.repository.snapshot().runs.first { $0.id == r }?.projectID == "other")
            let listed = try await f.session.listProjects()
            #expect(Set(listed.map(\.id)) == ["p", "other"])
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func aIssueNeedsAKnownProjectWhenThereIsAChoice() async throws {
        let f = try await StallariFixture.make()
        do {
            // One project: it is the obvious home.
            let only = try await f.session.createIssue(id: "only", title: "작업", criteria: ["검사"], instruction: "고쳐요")
            #expect(try await f.repository.projectID(forIssue: only) == "p")
            try await f.repository.saveProject(.init(id: "other", name: "other", absolutePath: f.directory.path + "/other"))
            await #expect(throws: StallariError.self) { _ = try await f.session.createIssue(id: "which", title: "작업", criteria: ["검사"], instruction: "고쳐요") }
            await #expect(throws: StallariError.self) { _ = try await f.session.createIssue(id: "nowhere", title: "작업", criteria: ["검사"], instruction: "고쳐요", projectID: "missing") }
            try await f.repository.saveProject(.init(id: StoredProject.hubID, name: "Stallari", absolutePath: f.directory.path))
            await #expect(throws: StallariError.self) { _ = try await f.session.createIssue(id: "hub", title: "작업", criteria: ["검사"], instruction: "고쳐요", projectID: StoredProject.hubID) }
            #expect(try await f.session.listProjects().contains { $0.id == StoredProject.hubID } == false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func duplicateDispatchAfterReopenNeverRespawnsInterruptedRun() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            _ = try await f.session.ask(id: "q", runID: r, issueID: t, prompt: "중단", options: [])
            await f.hird.setFailure(true)
            await #expect(throws: (any Error).self) { _ = try await f.session.answer(questionID: "q", runID: r, issueID: t, answer: .init(selectedOptions: [], text: "보존된 답")) }
            _ = await f.session.shutdown()
            try await f.repository.close()
            let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            let next = TestHird()
            let replacement = StallariSession(repository: reopened, rpc: TestStallariRPC(), hird: next)
            #expect(try await replacement.dispatch(issueID: t, runID: r) == r)
            try await replacement.deliverAnswers()
            #expect(await next.runs.isEmpty)
            #expect(await next.resolutions.isEmpty)
            #expect(try await reopened.snapshot().runs[0].state == .interrupted)
            _ = await replacement.shutdown()
            try await reopened.close()
            try FileManager.default.removeItem(at: f.directory)
        } catch { try? await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct StallariConcurrencyTests {
    @Test func newAnswerWhileDeliverySuspendedDrainsWithoutAnotherEvent() async throws {
        let f = try await StallariFixture.make()
        let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
        _ = try await f.session.ask(id: "q1", runID: r, issueID: t, prompt: "첫째", options: [])
        _ = try await f.session.ask(id: "q2", runID: r, issueID: t, prompt: "둘째", options: [])
        await f.hird.holdDelivery()
        let first = Task { try await f.session.answer(questionID: "q1", runID: r, issueID: t, answer: .init(selectedOptions: [], text: "1")) }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while await !f.hird.enteredDelivery && ContinuousClock.now < deadline { await Task.yield() }
            #expect(await f.hird.enteredDelivery)
            _ = try await f.session.answer(questionID: "q2", runID: r, issueID: t, answer: .init(selectedOptions: [], text: "2"))
            await f.hird.releaseDelivery()
            _ = try await first.value
            #expect(await f.hird.resolutions.map(\.questionID) == ["q1", "q2"])
            try await f.cleanup()
        } catch { await f.hird.releaseDelivery(); _ = await first.result; try await f.cleanup(); throw error }
    }
    @Test func newCompletionWhilePromptSuspendedDrainsWithoutPolling() async throws {
        let f = try await StallariFixture.make()
        let t1 = try await f.issue("t1"), t2 = try await f.issue("t2")
        let r1 = try await f.dispatch("r1", issue: t1), r2 = try await f.dispatch("r2", issue: t2)
        await f.rpc.holdPrompt()
        let first = Task { try await f.session.receive(.init(id: "end1", runID: r1, at: .now, payload: .complete(f.result(), notificationID: "n1"))) }
        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while await !f.rpc.enteredPrompt && ContinuousClock.now < deadline { await Task.yield() }
            #expect(await f.rpc.enteredPrompt)
            _ = try await f.session.receive(.init(id: "end2", runID: r2, at: .now, payload: .complete(f.result(), notificationID: "n2")))
            await f.rpc.releasePrompt()
            _ = try await first.value
            #expect(await f.rpc.prompts.count == 2)
            #expect(try await f.repository.pendingNotifications().isEmpty)
            try await f.cleanup()
        } catch { await f.rpc.releasePrompt(); _ = await first.result; try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct StallariLateEventTests {
    @Test func multipleLateEventsAfterCancelKeepDistinctLedgerSequences() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            _ = try await f.session.cancelRun(r)
            for index in 1...2 {
                let outcome = try await f.session.receive(.init(id: "late-\(index)", runID: r, at: Date(timeIntervalSince1970: Double(index)), payload: .complete(f.result(), notificationID: "late-notice-\(index)")))
                #expect(outcome == .ignoredTerminal)
            }
            #expect(try await f.repository.snapshot().runs[0].state == .cancelled)
            #expect(try await f.repository.pendingNotifications().isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct StallariJudgementStorageTests {
    @Test func staleJudgementCannotOverwriteNewRunOrUserConfirmation() async throws {
        let f = try await StallariFixture.make()
        do {
            let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
            _ = try await f.session.receive(.init(id: "complete", runID: r, at: .now, payload: .complete(f.result(), notificationID: "n")))
            let snapshot = try await f.repository.snapshot(), expected = snapshot.runs[0]
            var target = snapshot.issues[0]
            target.state = .done; target.hirds = []; target.events = []
            target.acceptance[0].state = .met; target.acceptance[0].evidence = "v"
            var confirmed = target; confirmed.confirmed = true
            try await f.repository.saveIssue(confirmed, projectID: "p")
            try await f.repository.saveIssue(target, projectID: "p", expectedJudgementRun: expected)
            #expect(try await f.repository.snapshot().issues[0].confirmed)
            try await f.session.updateIssueProposal(issueID: t, expectedVersion: 1, instruction: "재작업", previousRunID: r)
            _ = try await f.dispatch("new", issue: t)
            await #expect(throws: (any Error).self) { try await f.repository.saveIssue(target, projectID: "p", expectedJudgementRun: expected) }
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Suite(.serialized) struct StallariDurableDeliveryTests {
    @Test func completionReplayAfterReopenKeepsOneResultAndOneDelivery() async throws {
        let f = try await StallariFixture.make()
        let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
        let update = HirdUpdate(id: "end", runID: r, at: Date(timeIntervalSince1970: 25), payload: .complete(f.result(), notificationID: "n"))
        await f.rpc.setFailure(true)
        _ = try await f.session.receive(update)
        _ = await f.session.shutdown()
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
        let rpc = TestStallariRPC(), hird = TestHird()
        let session = StallariSession(repository: reopened, rpc: rpc, hird: hird)
        do {
            #expect(try await session.receive(update) == .duplicate)
            #expect(try await session.receive(update) == .duplicate)
            #expect(try await reopened.snapshot().runs[0].resultHistory.count == 1)
            #expect(try await reopened.snapshot().notifications.count == 1)
            #expect(await rpc.prompts.count == 1)
            #expect(try await reopened.pendingNotifications().isEmpty)
            _ = await session.shutdown()
            try await reopened.close()
            try FileManager.default.removeItem(at: f.directory)
        } catch { _ = await session.shutdown(); try await reopened.close(); try FileManager.default.removeItem(at: f.directory); throw error }
    }
    @Test func deliveredAnswerReceiptSurvivesReopenAndLegacyQuestionDecodes() async throws {
        let f = try await StallariFixture.make()
        let t = try await f.issue("t"), r = try await f.dispatch("r", issue: t)
        _ = try await f.session.ask(id: "q", runID: r, issueID: t, prompt: "질문", options: [])
        _ = try await f.session.answer(questionID: "q", runID: r, issueID: t, answer: .init(selectedOptions: [], text: "답"))
        let stored = try await f.repository.snapshot().questions[0]
        #expect(stored.deliveredAt != nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        legacy.removeValue(forKey: "deliveredAt")
        #expect(try JSONDecoder().decode(PersistedQuestion.self, from: JSONSerialization.data(withJSONObject: legacy)).deliveredAt == nil)
        _ = await f.session.shutdown()
        try await f.repository.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"), probe: { run in .alive(ownershipToken: run.ownershipToken, ompSessionID: run.ompSessionID) })
        let hird = TestHird(), session = StallariSession(repository: reopened, rpc: TestStallariRPC(), hird: hird)
        do {
            try await session.deliverAnswers()
            #expect(await hird.resolutions.isEmpty)
            #expect(try await reopened.snapshot().questions[0].deliveredAt == stored.deliveredAt)
            _ = await session.shutdown()
            try await reopened.close()
            try FileManager.default.removeItem(at: f.directory)
        } catch { _ = await session.shutdown(); try await reopened.close(); try FileManager.default.removeItem(at: f.directory); throw error }
    }
}
