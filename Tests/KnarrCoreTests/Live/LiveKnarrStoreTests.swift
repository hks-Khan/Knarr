import Foundation
import Testing
@testable import KnarrCore

actor LiveTestRPC: HirdRPC {
    var sessionID = "fixture-stallari"
    var cancelNewSession = false
    func setCancelNewSession() { cancelNewSession = true }
    var starts = 0
    var shutdowns = 0
    func start(_ configuration: OMPLaunchConfiguration) { starts += 1 }
    // Each subscriber gets its own stream, like OMPRPCSession; one shared stream would let
    // the store and Stallari steal each other's frames.
    var subscribers: [AsyncStream<OMPEvent>.Continuation] = []
    var prompts: [[String: OMPJSON]] = []
    var requests: [(String, [String: OMPJSON])] = []
    var promptIDs: [String] = []
    var beforePromptReply: (@Sendable (String) async -> Void)?
    func onPromptReply(_ action: @escaping @Sendable (String) async -> Void) { beforePromptReply = action }
    var busy = false
    var thinkingLevel = "medium"
    var model: OMPJSON = .object(["provider": .string("openai-codex"), "id": .string("fixture-gpt")])
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async -> OMPJSON {
        requests.append((command, fields))
        if command == "prompt", fields["message"]?.string == "/knarr-stallari-tools" {
            frame(.object(["type": .string("extension_ui_request"), "method": .string("setStatus"),
                "statusKey": .string("__knarr_tool_policy__"), "statusText": .string("ready")]))
            return .object(["data": .object(["agentInvoked": .bool(false)])])
        }
        if command == "prompt" {
            prompts.append(fields)
            let id = UUID().uuidString
            promptIDs.append(id)
            await beforePromptReply?(id)
            return .object(["id": .string(id), "data": .object([:])])
        }
        if command == "new_session" {
            if !cancelNewSession { sessionID = UUID().uuidString }
            return .object(["data": .object(["cancelled": .bool(cancelNewSession)])])
        }
        if command == "set_model" { model = .object(["provider": fields["provider"] ?? .null, "id": fields["modelId"] ?? .null]) }
        if command == "set_thinking_level" { thinkingLevel = fields["level"]?.string ?? thinkingLevel }
        if command == "get_available_thinking_levels" {
            return .object(["data": .object(["levels": .array([.string("low"), .string("medium"), .string("high")])])])
        }
        let state: OMPJSON = .object(["isStreaming": .bool(busy), "sessionId": .string(sessionID),
            "model": model, "thinkingLevel": .string(thinkingLevel),
            "dumpTools": .array(StallariTools.exposedNames.map { .object(["name": .string($0)]) })])
        let models: OMPJSON = .array([
            .object(["provider": .string("openai-codex"), "id": .string("fixture-gpt")]),
            .object(["provider": .string("anthropic"), "id": .string("fixture-claude")]),
            .object(["provider": .string("ollama"), "id": .string("local-model")]),
        ])
        let data: OMPJSON = command == "get_state" ? state : command == "get_available_models" ? .object(["models": models]) : .object([:])
        return .object(["data": data])
    }
    var failQuestionSend = false
    var questionSendDelay: Duration = .zero
    func setQuestionSendDelay(_ delay: Duration) { questionSendDelay = delay }
    func setFailQuestionSend(_ value: Bool) { failQuestionSend = value }
    func send(_ command: String, fields: [String: OMPJSON]) async throws {
        if command == "extension_ui_response" { try await Task.sleep(for: questionSendDelay) }
        if command == "extension_ui_response", failQuestionSend { throw CocoaError(.fileWriteUnknown) }
    }
    func subscribe() -> AsyncStream<OMPEvent> {
        let pair = AsyncStream<OMPEvent>.makeStream()
        subscribers.append(pair.continuation)
        return pair.stream
    }
    func frame(_ frame: OMPJSON) { for s in subscribers { s.yield(.frame(frame)) } }
    func terminate() {
        for s in subscribers { s.yield(.terminated(.init(status: 1, reason: .failed, remainingProcessIDs: []))) }
    }
    func setBusy() { busy = true }
    func setIdle() { busy = false }
    func shutdown(cancel: Bool) -> OMPProcessExit {
        shutdowns += 1
        for s in subscribers { s.finish() }
        return .init(status: 0, reason: .cancelled, remainingProcessIDs: [])
    }
}
actor LiveTestHird: HirdAdapter {
    var remaining: [Int32] = []
    func setRemaining(_ ids: [Int32]) { remaining = ids }
    func remainingProcessIDs() -> [Int32] { remaining }
    var runs: [PersistedRun] = []
    var resolutions: [QuestionResolution] = []
    var instructions: [(HirdRun.ID, String)] = []
    var holds: [HirdRun.ID: CheckedContinuation<Void, Never>] = [:]
    var cancelled: Set<HirdRun.ID> = []
    func start(_ run: PersistedRun, emit: @escaping HirdEventSink) async throws {
        guard !cancelled.contains(run.id), !Task.isCancelled else { return }
        runs.append(run)
        await withCheckedContinuation { holds[run.id] = $0 }
    }
    func deliver(_ resolution: QuestionResolution) { resolutions.append(resolution) }
    func steer(_ text: String, runID: HirdRun.ID) { instructions.append((runID, text)) }
    func cancel(_ runID: HirdRun.ID) { cancelled.insert(runID); holds.removeValue(forKey: runID)?.resume() }
    func terminationConfirmed(_ runID: HirdRun.ID) -> Bool { cancelled.contains(runID) && holds[runID] == nil && remaining.isEmpty }
    var model: String?
    func setModel(_ model: String) { self.model = model }
    func modelForNewRuns() async -> String? { model ?? "openai-codex/fixture-gpt" }
}
@MainActor struct LiveFixture {
    let directory: URL
    let repository: SQLiteKnarrRepository
    let rpc: LiveTestRPC
    let hird: LiveTestHird
    let session: StallariSession
    let store: LiveKnarrStore
    static func make() async throws -> Self {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = workspace.appendingPathComponent("outputs/issue-5/fixtures/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await SQLiteKnarrRepository.open(at: directory.appendingPathComponent("knarr.db"))
        try await repository.saveProject(.init(id: "p", name: "연결 프로젝트", absolutePath: directory.path))
        try await repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: directory.path))
        let rpc = LiveTestRPC(), hird = LiveTestHird()
        let session = StallariSession(repository: repository, rpc: rpc, hird: hird)
        let preferences = UserDefaults(suiteName: "knarr-test-\(UUID())")!
        let store = LiveKnarrStore(repository: repository, session: session, rpc: rpc, hird: hird, preferences: preferences,
                                  subscriptionUsage: .init(sample: true))
        try await store.connect()
        return .init(directory: directory, repository: repository, rpc: rpc, hird: hird, session: session, store: store)
    }
    /// Legacy bindings remain covered; new issue sessions have their own integration suite.
    func create(_ id: KnarrCore.Issue.ID = "t", title: String = "합계 함수 수정",
                criteria: [String] = ["합계 검사 통과"], instruction: String = "합계 함수를 고치고 검사해요",
                projectID: String = "p") async throws {
        let project = try #require(try await repository.snapshot().projects.first { $0.id == projectID })
        var issue = KnarrCore.Issue(id: id, title: title, projectName: project.name, state: .awaitingApproval,
            headline: "", detail: "", acceptance: (criteria + project.settings.criteria.filter { !criteria.contains($0) }).map {
                .init(text: $0, state: .pending, evidence: "")
            }, hirds: [], events: [], startedAt: .now)
        let fallback = await hird.modelForNewRuns()
        issue.proposal = .init(instruction: instruction, model: try #require(project.settings.hirdModel ?? fallback),
                               thinking: project.settings.hirdThinking)
        try await repository.saveIssue(issue, projectID: projectID)
    }
    func dispatch(_ id: HirdRun.ID = "r", issue: KnarrCore.Issue.ID = "t") async throws {
        if try await !repository.snapshot().runs.contains(where: { $0.id == id }) {
            let proposal = try #require(try await repository.snapshot().issues.first { $0.id == issue }?.proposal)
            _ = try await repository.approveIssueProposal(issueID: issue, version: proposal.version, at: .now)
        }
        _ = try await session.dispatch(issueID: issue, runID: id)
        for _ in 0..<200 { if await hird.runs.contains(where: { $0.id == id }) { return }; try await Task.sleep(for: .milliseconds(5)) }
        Testing.Issue.record("Hird did not start")
    }
    func result() -> RunResult {
        .init(worktreePath: directory.path, branch: "fixture-branch", commit: "fixture-commit", diffPath: nil, summary: "합계 수정 결과", verifications: [
            .init(id: "v", command: ["python3", "-m", "unittest"], workingDirectory: directory.path, startedAt: .now, finishedAt: .now, exitCode: 0, logPath: directory.appendingPathComponent("test.log").path, summary: "fixture 통과")])
    }
    func finish() async throws {
        _ = try await session.receive(.init(id: UUID().uuidString, runID: "r", at: .now, payload: .complete(result(), notificationID: "n")))
        try await session.judge(issueID: "t", runID: "r", evidence: [.init(criterionIndex: 0, verificationIDs: ["v"], explanation: "합계 검사 통과")])
    }
    func cleanup(expectClean: Bool = true) async throws {
        let exit = await store.shutdown()
        if expectClean { #expect(exit.remainingProcessIDs.isEmpty) }
        try await repository.close()
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor @Suite(.serialized) struct LiveKnarrStoreTests {
    @Test func persistedQuestionsAppearInExistingConversationAndAnswerExactRun() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = try await f.session.ask(id: "q", runID: "r", issueID: "t", prompt: "어떤 방식으로 고칠까요?", options: ["A", "B"])
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .needsInput)
            #expect(f.store.questions.first?.run == "r")
            #expect(f.store.chat.contains { $0.kind == .question("q") })
            f.store.answer("q", with: .init(selectedOptions: ["A"], text: "선택과 자유 입력"))
            try await f.store.whenIdle()
            #expect(f.store.questions.first?.state == .answered(.init(selectedOptions: ["A"], text: "선택과 자유 입력")))
            #expect(await f.hird.resolutions.first?.runID == "r")
            #expect(try await f.repository.snapshot().questions.first?.source == .stallari)
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("questionID=q") == true)
            #expect(f.store.issues.first?.state == .running)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func sendCarriesIssueContextAndStreamingSteering() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); await f.rpc.setBusy()
            f.store.send("  합계 결과 설명해 주세요  ", about: "t")
            try await f.store.whenIdle()
            #expect(await f.rpc.prompts.last?["message"]?.string?.contains("issueID=t") == true)
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "steer")
            #expect(f.store.chat.contains { $0.kind == .user("합계 결과 설명해 주세요") })
            #expect(try await f.repository.snapshot().chatLinks.last?.issueID == "t")
            #expect(f.store.isResponding)
            try await f.store.submit(.init(text: "지금 작업은 확인까지만 해 주세요"))
            try await f.store.whenIdle()
            #expect(await f.rpc.prompts.last?["streamingBehavior"]?.string == "steer")
            #expect(f.store.chat.contains { $0.kind == .user("지금 작업은 확인까지만 해 주세요") })
            #expect(await f.rpc.requests.allSatisfy { $0.0 != "abort" })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func steerTargetsOnlyWorkingRunAndRecordsActivity() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            f.store.steer("음수도 검사해 주세요", issue: "t"); try await f.store.whenIdle()
            #expect(await f.hird.instructions.last?.0 == "r")
            #expect(f.store.issues.first?.events.last?.detail == "음수도 검사해 주세요")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func stopClosesQuestionAndRejectsLateSuccess() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = try await f.session.ask(id: "q", runID: "r", issueID: "t", prompt: "선택", options: [])
            f.store.perform(.stop, on: "t"); try await f.store.whenIdle()
            #expect(try await f.repository.snapshot().runs.first?.state == .cancelled)
            #expect(f.store.questions.first?.state == .cancelled)
            #expect(await f.hird.cancelled.contains("r"))
            #expect(try await f.session.receive(.init(id: "late", runID: "r", at: .now, payload: .complete(f.result(), notificationID: "late-notice"))) == .ignoredTerminal)
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .failed)
            #expect(try await f.repository.snapshot().notifications.isEmpty)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func confirmAndRequestChangesUseSavedJudgementAndPreviousResult() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            f.store.perform(.confirmResult, on: "t"); try await f.store.whenIdle()
            #expect(f.store.issues.first?.confirmed == false)
            try await f.finish()
            f.store.perform(.confirmResult, on: "t"); try await f.store.whenIdle()
            #expect(f.store.issues.first?.confirmed == true)
            #expect(f.store.issues.first?.latestResult?.worktreePath == f.directory.path)
            f.store.perform(.requestChanges(note: ""), on: "t"); try await f.store.whenIdle()
            let runs = try await f.repository.snapshot().runs
            #expect(runs.count == 2)
            #expect(runs.last?.previousRunID == "r")
            #expect(f.store.issues.first?.state == .running)
            #expect(f.store.issues.first?.confirmed == false)
            #expect(f.store.issues.first?.acceptance.first?.state == .pending)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func cancelIsSpecificAndResolvedInputDoesNotInventQuestionAnswer() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = try await f.session.ask(id: "q", runID: "r", issueID: "t", prompt: "입력", options: [])
            f.store.perform(.resolvedInput, on: "t"); try await f.store.whenIdle()
            #expect(f.store.questions.first?.isPending == true)
            #expect(await f.hird.resolutions.isEmpty)
            f.store.cancel("q"); try await f.store.whenIdle()
            #expect(f.store.questions.first?.state == .cancelled)
            #expect(await f.hird.resolutions.last?.cancelled == true)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func approveProposalStartsHirdAndMessageEventsPersist() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            #expect(try await f.repository.snapshot().runs.isEmpty)
            f.store.perform(.approveProposal(version: 1), on: "t"); try await f.store.whenIdle()
            #expect(try await f.repository.snapshot().runs.count == 1)
            #expect(try await f.repository.snapshot().runs.first?.hird.role == "합계 함수를 고치고 검사해요")
            #expect(await f.rpc.prompts.isEmpty)
            await f.rpc.frame(.object(["type": .string("message_end"), "messageId": .string("proposal-result"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string("변경 결과를 설명해요")])])])]))
            for _ in 0..<200 {
                if f.store.chat.contains(where: { $0.kind == .stallari("변경 결과를 설명해요", project: nil) }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(f.store.chat.contains { $0.kind == .stallari("변경 결과를 설명해요", project: nil) })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func shutdownDoesNotHideHirdCleanupFailure() async throws {
        let f = try await LiveFixture.make()
        await f.hird.setRemaining([876543]) // Synthetic identity; no process is started or signalled.
        let exit = await f.store.shutdown()
        #expect(exit.remainingProcessIDs == [876543])
        #expect(exit.reason == .failed)
        try await f.cleanup(expectClean: false)
    }
    @Test func showsEveryProjectButNeverSampleOrTheHub() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.repository.saveIssue(.init(id: "foreign", title: "다른 작업", projectName: "다른 프로젝트", state: .running, headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now), projectID: "other")
            try await f.store.whenIdle()
            #expect(f.store.issues.map(\.id) == ["foreign"])
            #expect(f.store.questions.isEmpty)
            #expect(f.store.stallari.scope == "모든 프로젝트")
            #expect(Set(f.store.projects.map(\.id)) == ["p", "other"])
            #expect(f.store.projects.first { $0.id == "other" }?.openIssues == 1)
            #expect(f.store.stallari.engine.contains("fixture-gpt"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func messagesAboutAProjectAreLinkedToIt() async throws {
        let f = try await LiveFixture.make()
        do {
            f.store.send("다른 프로젝트 상태 알려줘", about: nil, project: "other"); try await f.store.whenIdle()
            f.store.send("전체 요약해줘", about: nil, project: nil); try await f.store.whenIdle()
            let links = try await f.repository.snapshot().chatLinks
            #expect(links.map(\.projectID) == ["other", StoredProject.hubID])
            let prompts = await f.rpc.prompts.map { $0["message"]?.string ?? "" }
            #expect(prompts.contains { $0.contains("projectID=other") && $0.contains("다른 프로젝트 상태 알려줘") })
            #expect(f.store.chat.contains { $0.kind == .user("전체 요약해줘") })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
