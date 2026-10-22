import Foundation

public protocol HirdRPC: StallariRPC {
    func start(_ configuration: OMPLaunchConfiguration) async throws
}
extension OMPRPCSession: HirdRPC {}

/// Each durable run owns one single-use RPC process and a preserved Git worktree.
public actor OMPHirdAdapter: HirdAdapter {
    private final class Context: Sendable {
        let run: PersistedRun
        let rpc: any HirdRPC
        let emit: HirdEventSink
        let root: URL
        init(run: PersistedRun, rpc: any HirdRPC, emit: @escaping HirdEventSink, root: URL) {
            self.run = run; self.rpc = rpc; self.emit = emit; self.root = root
        }
    }
    private struct Execution {
        let context: Context
        var workspace: RunWorkspace?
        var base = ""
        var capturePolicy: HirdCapturePolicy?
        var active = true
        var questions: [String: OMPExtensionDialog] = [:]
        var deliveries: [String: QuestionResolution] = [:]
        var inFlightDeliveries: Set<String> = []
        var commands: [String: String] = [:]
        var subagents = OMPSubagentActivity()
        var verifications: [VerificationRecord] = []
        var backgroundChecks: [String: VerificationRecord] = [:]
        var verifiedDiff: HirdCaptureSnapshot?
        var verificationCache: (stamp: [String: String], snapshot: HirdCaptureSnapshot)?
        var lastResult: RunResult?
        var lastCheckpointAttempt: ContinuousClock.Instant?
        var captureFailureStages: Set<String> = []
        var transportExit: OMPProcessExit?
        var reportPath: String?
        var lastMutationAt: Date?
        var inspectionRequests: [String: OMPJSON] = [:]
        var commandStarts: [String: Date] = [:]
        var toolActivities: [String: HirdActivity] = [:]
        var lspRequests: [String: OMPJSON] = [:]
        var mutationCalls: Set<String> = []
        var mutationBaseline: HirdCaptureSnapshot?
        var stageCalls: [String: OMPJSON] = [:]
        var stageReplies: [String: [String: OMPJSON]] = [:]
        var promptID: String?
        var promptCompleted = false
        var verificationRetries = 0
        var continuationPolicy: HirdContinuationPolicy?
        var continuationRetries = 0
        var modelMaxTokens: Int?
        var interruptedResponse: String?
        /// Last state written to the ledger, plus interval write limiting. Repeated deltas and
        /// identical tool calls never reach storage; rapid alternation writes at most once per
        /// interval and always ends on the newest state.
        var activity = HirdActivityCoalescer()
        var activityFlush: Task<Void, Never>?
    }
    private let repository: SQLiteKnarrRepository
    private let installation: OMPInstallation
    private let resultRoot: URL
    private let policyFiles: HirdPolicyFiles
    private var expectedModel: String
    private let environment: [String: String]
    private let makeRPC: @Sendable () -> any HirdRPC
    private let extensions: KnarrExtensions?
    private let hive: HiveProviderRuntime?
    /// Minimum gap between two activity ledger writes for one run; zero writes each transition.
    private let activityInterval: TimeInterval
    private var executions: [HirdRun.ID: Execution] = [:]
    // Reserve the tombstone BEFORE any suspension. A late start never creates a new generation.
    private var tombstones: Set<HirdRun.ID> = []
    private var finished: Set<HirdRun.ID> = []
    private var finishWaiters: [HirdRun.ID: [CheckedContinuation<Void, Never>]] = [:]
    public private(set) var exits: [HirdRun.ID: OMPProcessExit] = [:]

    public init(repository: SQLiteKnarrRepository, installation: OMPInstallation, resultRoot: URL,
                expectedModel: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                policyDirectory: URL? = nil,
                makeRPC: @escaping @Sendable () -> any HirdRPC = { OMPRPCSession() }, extensionRoot: URL? = nil,
                hive: HiveProviderRuntime? = nil,
                activityInterval: TimeInterval = HirdActivityCoalescer.defaultInterval) {
        self.repository = repository; self.installation = installation; self.resultRoot = resultRoot
        self.policyFiles = HirdPolicyFiles(directory: policyDirectory ?? resultRoot.deletingLastPathComponent().appendingPathComponent("hird", isDirectory: true))
        self.expectedModel = expectedModel; self.environment = environment; self.makeRPC = makeRPC
        self.extensions = extensionRoot.map(KnarrExtensions.init(root:))
        self.hive = hive
        self.activityInterval = activityInterval
    }

    public func start(_ run: PersistedRun, emit: @escaping HirdEventSink) async throws {
        guard !tombstones.contains(run.id), !Task.isCancelled else { return }
        if let old = executions[run.id] {
            guard old.context.run == run else { throw HirdError.staleRun }; return
        }
        guard !finished.contains(run.id) else { return }
        let root = resultRoot.appendingPathComponent(UUID().uuidString)
        let context = Context(run: run, rpc: makeRPC(), emit: emit, root: root)
        executions[run.id] = Execution(context: context, activity: HirdActivityCoalescer(interval: activityInterval))
        let requestedModel = run.requestedModel ?? expectedModel
        var failure: (any Error)?
        do {
            try await withTaskCancellationHandler {
                let snapshot = try await repository.snapshot(includeHistory: false)
                guard let saved = snapshot.runs.first(where: { $0.id == run.id }), saved.ownershipToken == run.ownershipToken,
                      !saved.state.isTerminal, let project = snapshot.projects.first(where: { $0.id == run.projectID }) else { throw HirdError.staleRun }
                try live(context)
                let previous = run.previousRunID.flatMap { id in snapshot.runs.first { $0.id == id } }
                if run.previousRunID != nil && previous?.result == nil { throw HirdError.workspace }
                let capturePolicy = try policyFiles.loadCapture()
                executions[run.id]?.capturePolicy = capturePolicy
                let (workspace, base) = try await HirdWorkspace.prepare(project: URL(fileURLWithPath: project.absolutePath), root: root, previous: previous, policy: capturePolicy)
                executions[run.id]?.workspace = workspace; executions[run.id]?.base = base
                // Archive the location even when cancellation raced Git setup.
                try await event(context, .recordWorkspace(workspace))
                try live(context)
                let sessionDirectory = root.appendingPathComponent("sessions")
                try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
                let continuation = try await HirdSessionContinuation.prepare(previous: previous, workspace: workspace, model: requestedModel,
                    capturePolicy: capturePolicy)
                let overlay = root.appendingPathComponent("hird.yml")
                let configuration: HirdPolicy
                do { configuration = try policyFiles.load() }
                catch { throw HirdError.instructions }
                executions[run.id]?.continuationPolicy = configuration.continuation
                for warning in configuration.warnings { try await activity(context, text: warning) }
                if run.mode != .inspect {
                    guard configuration.instructionFailure == nil else { throw HirdError.instructions }
                    if let instructions = configuration.userInstructions {
                        try await activity(context, text: "[instructions] version=\(instructions.version) files=\(instructions.sources.map(\.path).joined(separator: ","))")
                    }
                }
                try configuration.overlayText(mode: run.mode).write(to: overlay, atomically: true, encoding: .utf8)
                let extensionURL = root.appendingPathComponent("hird-lsp-policy.ts")
                if run.mode == .inspect { try configuration.extensionSource.write(to: extensionURL, atomically: true, encoding: .utf8) }
                var modeArguments = ["--no-lsp"] + configuration.inspectionArguments(extensionURL: extensionURL)
                if run.mode != .inspect {
                    let policy = root.appendingPathComponent("hird-lsp-policy.ts")
                    try configuration.extensionSource.write(to: policy, atomically: true, encoding: .utf8)
                    modeArguments = ["--no-extensions"] + (try extensions?.arguments(for: .hird, policy: policy) ?? ["--trusted-extension", policy.path])
                }
                let stream = await context.rpc.subscribe()
                try live(context)
                var launch = OMPLaunchConfiguration(installation: installation, workingDirectory: URL(fileURLWithPath: workspace.worktreePath),
                    arguments: ["--mode", "rpc-ui", "--no-title", "--no-pty", "--no-ui", "--config", overlay.path,
                        "--session-dir", sessionDirectory.path] + (run.requestedThinking.map { ["--thinking", $0] } ?? []) + modeArguments + continuation.arguments, environment: environment)
                if let hive { launch = try hive.configure(launch) }
                try await context.rpc.start(launch)
                try live(context)
                // OMP 18.7 filters session events at the source. Responses, prompt_result,
                // session_settled, extension UI/errors and host control frames stay unfiltered.
                _ = try await context.rpc.request("set_event_filter", fields: [
                    "events": .array(["message_update", "message_end", "tool_execution_start", "tool_execution_end"].map(OMPJSON.string)),
                    "messageUpdates": .string("delta")
                ], timeout: .seconds(10))
                try live(context)
                var state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
                let initialModel = (state["model"]?["provider"]?.string ?? "") + "/" + (state["model"]?["id"]?.string ?? "")
                if initialModel != requestedModel {
                    let selected = requestedModel.split(separator: "/", maxSplits: 1).map(String.init)
                    guard selected.count == 2, selected.allSatisfy({ !$0.isEmpty }) else { throw HirdError.modelMismatch }
                    _ = try await context.rpc.request("set_model", fields: ["provider": .string(selected[0]), "modelId": .string(selected[1])], timeout: .seconds(10))
                    state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
                }
                try live(context)
                let model = (state["model"]?["provider"]?.string ?? "") + "/" + (state["model"]?["id"]?.string ?? "")
                if model != "/" { try await event(context, .bindModel(model)) }
                guard model == requestedModel else { throw HirdError.modelMismatch }
                executions[run.id]?.modelMaxTokens = state["model"]?["maxTokens"]?.integer
                if let thinking = run.requestedThinking {
                    if state["thinkingLevel"]?.string != thinking {
                        _ = try await context.rpc.request("set_thinking_level", fields: ["level": .string(thinking)], timeout: .seconds(10))
                        state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
                    }
                    guard state["thinkingLevel"]?.string == thinking else { throw HirdError.thinkingMismatch }
                }
                if let thinking = state["thinkingLevel"]?.string { try await event(context, .bindThinking(thinking)) }
                if run.mode == .inspect {
                    let tools = state["dumpTools"]?.array?.compactMap { $0["name"]?.string } ?? []
                    guard !tools.isEmpty, Set(tools).isSubset(of: Set(configuration.inspectTools)), tools.contains("bash") else { throw HirdError.inspectionTools }
                }
                // Check the native inspect tool boundary before adding this progress-only host tool.
                _ = try await context.rpc.request("set_host_tools", fields: ["tools": .array([try configuration.stageTool])], timeout: .seconds(10))
                try live(context)
                if let id = state["sessionId"]?.string { try await event(context, .bindSession(id)) }
                _ = try await context.rpc.request("set_subagent_subscription", fields: ["level": .string("progress")], timeout: .seconds(10))
                // Pin ask's native select/editor fallback; rich ask-dialog is not a Knarr surface.
                _ = try await context.rpc.request("set_ask_dialog", fields: ["enabled": .bool(false)], timeout: .seconds(10))
                if run.mode != .inspect {
                    let commands = try await context.rpc.request("get_available_commands", fields: [:], timeout: .seconds(10))["data"] ?? .null
                    try live(context)
                    try await event(context, .recordResources(.capture(state: state, commands: commands,
                        trustedExtensions: launch.arguments.enumerated().compactMap { index, value in
                            value == "--trusted-extension" && index + 1 < launch.arguments.count ? launch.arguments[index + 1] : nil
                        }, at: .now)))
                }
                try live(context)
                if !(run.stagePlan ?? []).isEmpty {
                    // Capture before admitting model work; a start event can arrive after a fast edit.
                    // The snapshot is computed before touching the dictionary: assigning the result of
                    // an awaited call directly into a subscript holds an exclusive access across suspension.
                    let baseline = await mutationSnapshot(context)
                    executions[run.id]?.mutationBaseline = baseline
                    try live(context)
                }
                let response = try await context.rpc.request("prompt", fields: ["message": .string(continuation.header + configuration.prompt(mode: run.mode, task: run.hird.role, stages: run.stagePlan ?? []))], timeout: .seconds(10))
                executions[run.id]?.promptID = response["id"]?.string
                for await incoming in stream {
                    try live(context)
                    switch incoming {
                    case .terminated(let exit):
                        executions[run.id]?.transportExit = exit
                        try? await activity(context, text: "[transport_terminated] stage=rpc.events status=\(exit.status) cause=unknown · 사용자 실행 취소로 추정하지 않았어요")
                        throw HirdError.transportTerminated
                    case .frame(let frame):
                        if try await receive(frame, context: context) { return }
                    }
                }
                try? await activity(context, text: "[transport_terminated] stage=rpc.events cause=unknown · 종료 프레임 없이 전송이 끝났어요")
                throw HirdError.transportTerminated
            } onCancel: { Task { await self.cancel(run.id, source: "task") } }
        } catch { failure = error }
        // All exits share the same archival and reclamation path, including startup failures.
        // A state held back by the write interval still lands before the run is archived.
        await flushActivity(context, requireActive: false)
        executions[run.id]?.active = false
        stopActivityFlush(run.id)
        let reclaimed = await context.rpc.shutdown(cancel: tombstones.contains(run.id) || Task.isCancelled)
        let observed = executions[run.id]?.transportExit
        let exit = observed.map { OMPProcessExit(status: $0.status, reason: $0.reason, remainingProcessIDs: reclaimed.remainingProcessIDs) } ?? reclaimed
        exits[run.id] = exit
        if failure != nil || tombstones.contains(run.id) {
            _ = await checkpoint(context, summary: tombstones.contains(run.id) ? "취소된 작업 결과" : "실행 종료 결과", stage: "archive.capture")
        }
        let cleanupFailed = !exit.remainingProcessIDs.isEmpty
        if cleanupFailed && failure == nil { failure = HirdError.cleanup }
        if !cleanupFailed { _ = try? await repository.markProcessEnded(run.id, at: .now) }
        if !tombstones.contains(run.id), let failure {
            var reason = (failure as? HirdError)?.reason ?? "[omp_runtime] OMP 요청·이벤트 처리가 실패했어요. 보존된 실행 로그를 확인하세요."
            let stages = executions[run.id]?.captureFailureStages.sorted() ?? []
            for stage in stages { reason += "\n[capture_failed] stage=\(stage) · 코드 스냅샷 캡처 실패, 검증 로그를 별도로 보존했어요" }
            if cleanupFailed, failure as? HirdError != .cleanup { reason += "\n" + HirdError.cleanup.reason }
            _ = try? await event(context, .fail(reason))
        }
        finished.insert(run.id); executions.removeValue(forKey: run.id)
        finishWaiters.removeValue(forKey: run.id)?.forEach { $0.resume() }
        if let failure, !tombstones.contains(run.id) { throw failure }
    }
    private func live(_ context: Context) throws {
        guard !Task.isCancelled, !tombstones.contains(context.run.id),
              executions[context.run.id]?.context === context, executions[context.run.id]?.active == true else { throw HirdError.staleRun }
    }
    @discardableResult private func event(_ context: Context, _ payload: RunEvent.Payload, at: Date = .now) async throws -> MutationOutcome {
        let update = HirdUpdate(id: "hird:" + context.run.id.rawValue + ":" + UUID().uuidString,
                                runID: context.run.id, at: at, payload: payload)
        return try await context.emit(update)
    }
    private func activity(_ context: Context, text: String, command: String? = nil, steps: [HirdStep]? = nil) async throws {
        try await event(context, .activity(.init(at: .now, actor: context.run.hird.name, text: text), currentCommand: command, steps: steps))
    }
    /// Records a state transition at most once per interval. Repeated deltas of one thinking
    /// block, or the same tool call seen again, cost neither an event nor a row. A burst of
    /// different states writes the first immediately and the newest one when the interval ends,
    /// so the ledger never lags by more than that interval and the last state is never lost.
    private func stateActivity(_ context: Context, _ activity: HirdActivity) async throws {
        let id = context.run.id
        guard var execution = executions[id] else { return }
        if let due = execution.activity.offer(activity, at: .now) {
            execution.activityFlush?.cancel(); execution.activityFlush = nil
            executions[id] = execution
            try await emitActivity(context, due)
            return
        }
        let needsTimer = execution.activity.pending != nil && execution.activityFlush == nil
        executions[id] = execution
        if needsTimer { scheduleActivityFlush(context) }
    }
    private func emitActivity(_ context: Context, _ activity: HirdActivity) async throws {
        try await event(context, .activityState(activity, currentCommand: currentCommand(context)))
    }
    private func scheduleActivityFlush(_ context: Context) {
        let id = context.run.id
        guard let deadline = executions[id]?.activity.deadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        executions[id]?.activityFlush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushActivity(context)
        }
    }
    /// Writes the newest state that was held back, if any. Used by the interval timer and before
    /// the run's result is captured, so a trailing state is never dropped at completion.
    private func flushActivity(_ context: Context, requireActive: Bool = true) async {
        let id = context.run.id
        guard var execution = executions[id], !requireActive || execution.active else { return }
        execution.activityFlush = nil
        guard let due = execution.activity.flush(at: .now) else { executions[id] = execution; return }
        executions[id] = execution
        try? await emitActivity(context, due)
    }
    private func stopActivityFlush(_ id: HirdRun.ID) {
        executions[id]?.activityFlush?.cancel()
        executions[id]?.activityFlush = nil
    }
    /// Only the block kind matters; delta text is never read, stored or shown.
    private static func messageActivity(_ frame: OMPJSON, at now: Date) -> HirdActivity? {
        guard frame["type"]?.string == "message_update",
              frame["message"]?["role"]?.string == "assistant" else { return nil }
        switch frame["assistantMessageEvent"]?["type"]?.string {
        case "thinking_start", "thinking_delta": return .init(kind: .thinking, at: now)
        case "text_start", "text_delta", "text_end": return .init(kind: .writing, at: now)
        default: return nil
        }
    }
    private func refreshTodos(_ context: Context) async throws -> [HirdStep] {
        let state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))
        try live(context)
        let steps = HirdTodoMapper.steps(state["data"]?["todoPhases"] ?? .array([]))
        try await activity(context, text: "작업 단계 갱신", command: currentCommand(context), steps: steps)
        return steps
    }
    private func currentCommand(_ context: Context) -> String? {
        guard let execution = executions[context.run.id] else { return nil }
        let latest = execution.commands.keys.max {
            (execution.commandStarts[$0] ?? .distantPast) < (execution.commandStarts[$1] ?? .distantPast)
        }
        let command = latest.flatMap { execution.commands[$0] }
        if !execution.subagents.active.isEmpty, command == nil || command == "wait" || command == "task" {
            return "하위 작업 \(execution.subagents.active.count)개 진행 중"
        }
        return command
    }
    private func capture(_ context: Context, summary: String, stage: String) async throws -> (RunResult, HirdCaptureSnapshot) {
        guard let execution = executions[context.run.id], let workspace = execution.workspace,
              let policy = execution.capturePolicy else { throw HirdError.workspace }
        do {
            let before = try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)
            let captured = try await HirdWorkspace.capture(workspace: workspace, root: context.root, base: execution.base,
                verifications: execution.verifications, summary: summary, reportPath: execution.reportPath, policy: policy)
            if let before, before == (try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)) {
                executions[context.run.id]?.verificationCache = (before, captured.1)
            } else { executions[context.run.id]?.verificationCache = nil }
            return captured
        } catch {
            executions[context.run.id]?.captureFailureStages.insert(stage)
            let diagnostic = "[capture_failed] stage=\(stage) · 코드 스냅샷 캡처 실패; 검증 로그는 별도로 보존해요"
            // Only a fixed stage and a known outcome are persisted, never raw RPC/error text.
            try? diagnostic.write(to: context.root.appendingPathComponent("adapter-\(stage).log"), atomically: true, encoding: .utf8)
            try? await activity(context, text: diagnostic)
            try? await preserveEvidence(context, diagnostic: diagnostic)
            throw error
        }
    }
    private func preserveEvidence(_ context: Context, diagnostic: String) async throws {
        guard let execution = executions[context.run.id], let workspace = execution.workspace else { return }
        let previous = execution.lastResult
        let result: RunResult
        do {
            guard let policy = execution.capturePolicy else { throw HirdError.workspace }
            result = try HirdWorkspace.preserveRunEvidence(previous: previous, workspace: workspace, root: context.root,
                verifications: execution.verifications, summary: diagnostic, reportPath: execution.reportPath, policy: policy)
        } catch {
            executions[context.run.id]?.captureFailureStages.insert("archive.evidence")
            try? await activity(context, text: "[artifact_failed] stage=archive.evidence · 검증 artifact 무결성 보존도 실패했어요. 원래 로그 참조와 이전 스냅샷 참조는 유지했어요.")
            result = RunResult(worktreePath: workspace.worktreePath, branch: previous?.branch ?? workspace.branch,
                commit: previous?.commit, diffPath: previous?.diffPath,
                summary: diagnostic + " · artifact 보존 실패; 원래 검증 로그와 이전 스냅샷 참조만 유지했어요",
                verifications: execution.verifications, reportPath: execution.reportPath ?? previous?.reportPath,
                artifactManifestPath: previous?.artifactManifestPath, artifactManifestMetadata: previous?.artifactManifestMetadata)
        }
        let outcome = try await event(context, .saveResult(result))
        guard outcome == .applied || outcome == .duplicate else { throw HirdError.staleRun }
        executions[context.run.id]?.lastResult = result
    }
    /// Intermediate snapshots are best effort: a failed capture records its stage and keeps
    /// the last successful result, but never aborts the run. Completion capture stays authoritative.
    @discardableResult private func checkpoint(_ context: Context, summary: String, stage: String = "tool.capture") async -> HirdCaptureSnapshot? {
        if stage == "tool.capture" || stage == "verification.capture" {
            guard let execution = executions[context.run.id], let policy = execution.capturePolicy else { return nil }
            let now = ContinuousClock.now
            if let previous = execution.lastCheckpointAttempt,
               previous.duration(to: now) < .seconds(policy.checkpointIntervalSeconds) { return nil }
            // Bound unsuccessful attempts too; no periodic timer or idle polling.
            executions[context.run.id]?.lastCheckpointAttempt = now
        }
        guard let captured = try? await capture(context, summary: summary, stage: stage) else { return nil }
        guard (try? await event(context, .saveResult(captured.0))) != nil else { return nil }
        executions[context.run.id]?.lastResult = captured.0
        return captured.1
    }
    private func receive(_ frame: OMPJSON, context: Context) async throws -> Bool {
        let id = context.run.id
        switch frame["type"]?.string {
        case "host_tool_call":
            try await reportStage(frame, context: context)
        case "message_end":
            if let message = frame["message"], message["role"]?.string == "assistant" {
                let content = message["content"]?.array ?? []
                let text = content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
                let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasToolCall = content.contains { $0["type"]?.string == "toolCall" }
                let thinkingOnly = !hasText && !hasToolCall && content.contains { $0["type"]?.string == "thinking" }
                let output = message["usage"]?["output"]?.integer
                let limit = executions[id]?.modelMaxTokens
                let stoppedForLength = message["stopReason"]?.string == "length"
                let exhausted = stoppedForLength || (output.map { output in limit.map { $0 > 0 && output >= $0 } ?? false } ?? false)
                executions[id]?.interruptedResponse = stoppedForLength
                    ? "모델이 출력 길이 제한으로 응답을 중단했어요"
                    : exhausted ? "출력 토큰 \(output!)/\(limit!)로 모델 출력 한도에 도달했어요"
                    : thinkingOnly ? "글·도구 호출 없이 생각 블록만 남았어요" : nil
                // Only the latest, non-truncated tool-free answer is a final report.
                // Retain old files as evidence, never as the current turn's completion proof.
                executions[id]?.reportPath = nil
                if hasText && !hasToolCall && !thinkingOnly && !exhausted {
                    let path = context.root.appendingPathComponent("report-" + UUID().uuidString + ".md")
                    try text.write(to: path, atomically: true, encoding: .utf8)
                    executions[id]?.reportPath = path.path
                }
            } else if let message = frame["message"], message["role"]?.string == "custom",
                      message["customType"]?.string == "async-result" {
                try await recordBackgroundDelivery(message, context: context)
            }
        case "subagent_lifecycle", "subagent_progress":
            guard let text = executions[id]?.subagents.receive(frame, at: .now) else { break }
            try await activity(context, text: text, command: currentCommand(context))
            if let count = executions[id]?.subagents.active.count, count > 0 {
                try await stateActivity(context, .subagents(count, at: .now))
            }
        case "message_update":
            guard let state = Self.messageActivity(frame, at: .now) else { break }
            try await stateActivity(context, state)
        case "tool_execution_start":
            let tool = OMPToolActivity(frame)
            let command = tool.command
            let toolActivity = HirdActivity.tool(tool.name, arguments: frame["args"] ?? .null, at: .now)
            if !["read", "grep", "glob", "ls", "todo", "ask", "report_stage"].contains(tool.name) { executions[id]?.lastMutationAt = .now }
            if let call = tool.callID {
                executions[id]?.commands[call] = command; executions[id]?.commandStarts[call] = .now
                executions[id]?.toolActivities[call] = toolActivity
                if tool.name == "read" { executions[id]?.inspectionRequests[call] = frame["args"] }
                if tool.name == "lsp" { executions[id]?.lspRequests[call] = frame["args"] }
                if !(context.run.stagePlan ?? []).isEmpty, ["edit", "write", "bash", "ast_edit"].contains(tool.name) {
                    executions[id]?.mutationCalls.insert(call)
                }
            }
            try await stateActivity(context, toolActivity)
        case "tool_execution_end":
            let capturedVerification: Bool
            if frame["toolName"]?.string == "bash" { capturedVerification = try await recordVerification(frame, context: context) }
            else if frame["toolName"]?.string == "read" { capturedVerification = try await recordInspection(frame, context: context) }
            else { capturedVerification = false }
            if frame["toolName"]?.string == "lsp", let result = frame["result"] {
                let log = context.root.appendingPathComponent("lsp-\(UUID()).log")
                let output = (result["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                try output.write(to: log, atomically: true, encoding: .utf8)
                let details = result["details"] ?? .null
                let request = executions[id]?.lspRequests.removeValue(forKey: frame["toolCallId"]?.string ?? "")
                try await event(context, .recordLSP(.init(action: details["action"]?.string ?? request?["action"]?.string ?? "unknown",
                    file: details["request"]?["file"]?.string ?? request?["file"]?.string, server: details["serverName"]?.string,
                    succeeded: frame["isError"]?.bool != true && details["success"]?.bool == true,
                    logPath: log.path, finishedAt: .now)))
            }
            if let call = frame["toolCallId"]?.string {
                executions[id]?.inspectionRequests.removeValue(forKey: call)
                executions[id]?.commands.removeValue(forKey: call)
                executions[id]?.commandStarts.removeValue(forKey: call)
                executions[id]?.toolActivities.removeValue(forKey: call)
            }
            if let execution = executions[id] {
                let latest = execution.commandStarts.max { $0.value < $1.value }?.key
                let remaining = latest.flatMap { execution.toolActivities[$0] }
                let state = remaining ?? (execution.subagents.active.isEmpty
                    ? HirdActivity(kind: .idle, at: .now)
                    : .subagents(execution.subagents.active.count, at: .now))
                try await stateActivity(context, state)
            }
            _ = try await refreshTodos(context)
            // Read-only tools cannot change the worktree. Keep progress events, but avoid
            // four Git processes and an identical archived result after every read.
            if !capturedVerification && !["read", "grep", "glob", "ls", "report_stage"].contains(frame["toolName"]?.string ?? "") {
                _ = await checkpoint(context, summary: "도구 실행 뒤 보존된 변경")
            }
            try await recordFileChanges(frame, context: context)
        case "extension_ui_request":
            try await question(frame, context: context)
        case "prompt_result":
            guard let execution = executions[id] else { throw HirdError.staleRun }
            if let actual = frame["id"]?.string {
                guard actual == execution.promptID else { break }
            } else if execution.verificationRetries > 0 || execution.continuationRetries > 0 { break }
            guard !execution.promptCompleted else { break }
            guard frame["status"]?.string == "completed" else {
                let reported = frame["status"]?.string
                let status = ["error", "aborted"].contains(reported) ? reported! : "unknown"
                try? await activity(context, text: "[prompt_\(status)] stage=prompt.result cause=unknown · OMP가 보고한 상태만 기록했으며 질문 취소나 사용자 실행 취소를 원인으로 단정하지 않았어요")
                throw HirdError.promptNotCompleted(status)
            }
            executions[id]?.promptCompleted = true
            if frame["sessionSettled"]?.bool == false { break }
            return try await complete(context)
        case "session_settled":
            guard let execution = executions[id], execution.promptCompleted else { break }
            // This event has no prompt ID. A queued old event must not settle a newer turn.
            let state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))
            try live(context)
            guard executions[id]?.promptID == execution.promptID,
                  executions[id]?.promptCompleted == true, state["data"]?["isSettled"]?.bool == true else { break }
            return try await complete(context)
        default: break
        }
        return false
    }

    private struct StageRequest: Decodable {
        let action: StageReport.Action
        let stageID: String?
        let note: String?
        let verificationIDs: [String]?
        let plan: [IssueStage]?
        let reason: String?
    }

    /// Host ownership is never accepted as model input. Bad reports are tool errors,
    /// not transport failures, and successful replies reflect the repository's saved projection.
    private func reportStage(_ frame: OMPJSON, context: Context) async throws {
        guard let call = frame["id"]?.string else { return }
        let runID = context.run.id
        if let old = executions[runID]?.stageCalls[call] {
            guard old == frame else { return }
            if let reply = executions[runID]?.stageReplies[call] {
                try await context.rpc.send("host_tool_result", fields: reply)
            }
            return
        }
        executions[runID]?.stageCalls[call] = frame
        var reply: [String: OMPJSON]
        do {
            try live(context)
            guard frame["toolName"]?.string == "report_stage",
                  case .object(let args) = frame["arguments"],
                  Set(args.keys).isSubset(of: ["action", "stageID", "note", "verificationIDs", "plan", "reason"]) else { throw HirdError.staleRun }
            if let plan = args["plan"] {
                guard let rows = plan.array, rows.allSatisfy({ row in
                    guard case .object(let item) = row else { return false }
                    return Set(item.keys).isSubset(of: ["id", "title", "evidence", "criterion"])
                }) else { throw HirdError.staleRun }
            }
            let input = try JSONDecoder().decode(StageRequest.self, from: JSONEncoder().encode(OMPJSON.object(args)))
            // Reads are not checkpointed individually. Persist their existing logs before
            // the repository resolves explicit verification IDs, without requiring a code capture.
            if let execution = executions[runID], !execution.verifications.isEmpty,
               execution.lastResult?.verifications != execution.verifications {
                try await preserveEvidence(context, diagnostic: "단계 보고 전에 수집된 검증 근거를 보존했어요")
            }
            try live(context)
            // Observe outstanding/background edits before fixing this report's boundary.
            try await recordFileChanges(context)
            try live(context)
            let report = StageReport(at: .now, action: input.action, stageID: input.stageID ?? "",
                note: input.note, verificationIDs: input.verificationIDs ?? [], plan: input.plan, reason: input.reason)
            let outcome = try await event(context, .stage(report), at: report.at)
            guard outcome == .applied || outcome == .duplicate else { throw HirdError.staleRun }
            let snapshot = try await repository.snapshot(includeHistory: false)
            guard let saved = snapshot.runs.first(where: { $0.id == runID && $0.ownershipToken == context.run.ownershipToken }) else { throw HirdError.staleRun }
            let progress = StallariReadback.progress(saved.stageProgress)
            reply = ["id": .string(call), "result": .object([
                "content": .array([.object(["type": .string("text"),
                    "text": .string(String(decoding: try JSONEncoder().encode(progress), as: UTF8.self))])]),
                "details": progress])]
        } catch {
            reply = ["id": .string(call), "isError": .bool(true), "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(
                    "단계 보고를 저장하지 못했어요. 현재 실행의 승인된 단계 ID, 보고 형식, 전체 변경 계획과 사유, 저장된 검증 ID를 확인하세요. runID·issueID는 입력할 수 없어요.")])]),
                "details": .object(["error": .string("stage_report_rejected")])])]
        }
        if let generation = frame["knarrRPCGeneration"] { reply["knarrRPCGeneration"] = generation }
        executions[runID]?.stageReplies[call] = reply
        try await context.rpc.send("host_tool_result", fields: reply)
    }

    private func mutationSnapshot(_ context: Context) async -> HirdCaptureSnapshot? {
        guard let execution = executions[context.run.id], let workspace = execution.workspace,
              let policy = execution.capturePolicy else { return nil }
        let stamp = try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)
        if let stamp, let cache = execution.verificationCache, stamp == cache.stamp { return cache.snapshot }
        guard let snapshot = try? await HirdWorkspace.verificationSnapshot(workspace: workspace,
            root: context.root, base: execution.base, policy: policy) else { return nil }
        if let stamp, stamp == (try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)) {
            executions[context.run.id]?.verificationCache = (stamp, snapshot)
        }
        return snapshot
    }

    private func recordFileChanges(_ frame: OMPJSON, context: Context) async throws {
        guard let call = frame["toolCallId"]?.string,
              executions[context.run.id]?.mutationCalls.remove(call) != nil else { return }
        try await recordFileChanges(context)
    }

    private func recordFileChanges(_ context: Context) async throws {
        guard !(context.run.stagePlan ?? []).isEmpty else { return }
        let before = executions[context.run.id]?.mutationBaseline
        // One baseline per run prevents overlapping calls from reporting the same edit twice.
        // Actual partial edits count even if the tool fails; no-op completions add no evidence.
        let after = await mutationSnapshot(context)
        executions[context.run.id]?.mutationBaseline = after
        guard let before, let after else { return }
        for (path, original) in before.files where after.files[path] != original {
            try await event(context, .fileChanged(path: path))
        }
        for path in after.files.keys where before.files[path] == nil {
            try await event(context, .fileChanged(path: path))
        }
    }
    /// Retain only content actually delivered by OMP, including attached images.
    private func persistContent(_ content: OMPJSON, context: Context, prefix: String) throws -> (parts: [String], attachments: [String]) {
        var parts: [String] = []
        var attachments: [String] = []
        if let text = content.string { parts.append(text) }
        for item in content.array ?? [] {
            if let text = item["text"]?.string, !text.isEmpty { parts.append(text) }
            if item["type"]?.string == "image", let data = item["data"]?.string.flatMap({ Data(base64Encoded: $0) }) {
                let suffix = item["mimeType"]?.string == "image/jpeg" ? "jpg" : "png"
                let image = context.root.appendingPathComponent("\(prefix)-\(UUID()).\(suffix)")
                try data.write(to: image, options: .atomic)
                attachments.append(image.path)
                parts.append("Observed image: " + image.path)
            }
        }
        return (parts, attachments)
    }

    private func recordBackgroundDelivery(_ message: OMPJSON, context: Context) async throws {
        try live(context)
        let content = try persistContent(message["content"] ?? .null, context: context, prefix: "background")
        let log = context.root.appendingPathComponent("background-\(UUID()).log")
        try (["OMP async-result · 구조화된 종료 코드 미제공"] + content.parts)
            .joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        var jobs = message["details"]?["jobs"]?.array ?? []
        if jobs.isEmpty { jobs.append(.object([:])) }
        let deliveredAt = Date()
        for job in jobs {
            let original = job["jobId"]?.string.flatMap { executions[context.run.id]?.backgroundChecks.removeValue(forKey: $0) }
            let record = VerificationRecord(id: "background:" + context.run.id.rawValue + ":" + UUID().uuidString,
                command: original?.command ?? [job["label"]?.string ?? "OMP async-result"],
                workingDirectory: original?.workingDirectory ?? executions[context.run.id]?.workspace?.worktreePath ?? "",
                startedAt: original?.startedAt ?? deliveredAt, finishedAt: deliveredAt, exitCode: nil, logPath: log.path,
                summary: "백그라운드 최종 전달 원문 · 구조화된 종료 코드는 확인되지 않았어요", kind: .command,
                attachmentPaths: content.attachments.isEmpty ? nil : content.attachments)
            executions[context.run.id]?.verifications.append(record)
        }
        // The supported custom message has no exitCode/status. Its text is evidence,
        // not an execution result to parse into a pass or a checked code snapshot.
        executions[context.run.id]?.verifiedDiff = nil
        try await activity(context, text: "[background_result] stage=background.delivery exit=unknown · 실제 전달된 출력과 이미지를 보존했으며 최종 전경 검사가 필요해요",
            command: currentCommand(context))
        _ = await checkpoint(context, summary: "백그라운드 최종 전달 출력과 이미지를 보존했어요", stage: "background.capture")
    }

    /// Save observed text/image content rather than requiring a dummy shell command for review.
    private func recordInspection(_ frame: OMPJSON, context: Context) async throws -> Bool {
        guard frame["isError"]?.bool != true, let call = frame["toolCallId"]?.string,
              let execution = executions[context.run.id], let command = execution.commands[call],
              let started = execution.commandStarts[call], let content = frame["result"]?["content"],
              !(content.array ?? []).isEmpty else { return false }
        let args = execution.inspectionRequests[call] ?? .null
        let description = command + " " + String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let observed = try persistContent(content, context: context, prefix: "inspection")
        let parts = [description] + observed.parts
        guard parts.count > 1 else { return false }
        let log = context.root.appendingPathComponent("inspection-\(UUID()).log")
        try parts.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let record = VerificationRecord(id: "inspection:" + context.run.id.rawValue + ":" + call,
            command: [description], workingDirectory: execution.workspace?.worktreePath ?? "", startedAt: started,
            finishedAt: .now, exitCode: nil, logPath: log.path, summary: "실제로 읽은 문서·화면 근거", kind: .inspection,
            attachmentPaths: observed.attachments.isEmpty ? nil : observed.attachments)
        executions[context.run.id]?.verifications.append(record)
        // Read-only evidence is archived at the next checkpoint/completion, without spawning
        // Git processes after every read. It never refreshes a prior command's checked diff.
        return true
    }

    private func recordVerification(_ frame: OMPJSON, context: Context) async throws -> Bool {
        guard let call = frame["toolCallId"]?.string, let command = executions[context.run.id]?.commands[call],
              let started = executions[context.run.id]?.commandStarts[call], let result = frame["result"] else { return false }
        let log = context.root.appendingPathComponent("verify-\(UUID()).log")
        let output = (result["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        try output.write(to: log, atomically: true, encoding: .utf8)
        let details = result["details"] ?? .null
        var code = details["exitCode"]?.integer.flatMap(Int32.init(exactly:))
        // 18.7.0 #buildCompletedResult emits exitCode only for nonzero exits.
        // #throwIfUnfinished rejects missing exit status/cancel, and timeout isError.
        // Require foreground timing metadata; async/service admission is never a pass.
        let unfinished = details["timedOut"]?.bool == true || details["async"] != nil || details["service"] != nil
        if unfinished { if code == 0 { code = nil } }
        else if details["exitCode"] == nil, code == nil, frame["isError"]?.bool == false,
                case .number(let wallTime)? = details["wallTimeMs"], wallTime.isFinite, wallTime >= 0 { code = 0 }
        let record = VerificationRecord(id: "verification:" + context.run.id.rawValue + ":" + call, command: [command],
            workingDirectory: executions[context.run.id]?.workspace?.worktreePath ?? "", startedAt: started, finishedAt: .now,
            exitCode: frame["isError"]?.bool == true ? (code == 0 ? nil : code) : code, logPath: log.path, summary: "OMP bash 도구의 실제 실행 결과")
        executions[context.run.id]?.verifications.append(record)
        if let job = details["async"]?["jobId"]?.string { executions[context.run.id]?.backgroundChecks[job] = record }
        // Keep each command's code identity separate from the periodic recovery archive.
        // Skipping an archive must not reuse an older command's verification identity.
        let archived = await checkpoint(context, summary: "실제 bash 도구 결과와 보존된 변경", stage: "verification.capture")
        var checked = archived
        if archived == nil, !unfinished, record.exitCode != nil, let execution = executions[context.run.id],
           let workspace = execution.workspace, let policy = execution.capturePolicy {
            do {
                let before = try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)
                if let before, let cached = execution.verificationCache, before == cached.stamp {
                    checked = cached.snapshot
                } else {
                    checked = try await HirdWorkspace.verificationSnapshot(workspace: workspace, root: context.root,
                        base: execution.base, policy: policy)
                    if let before, let checked, before == (try? await HirdWorkspace.verificationStamp(workspace: workspace, policy: policy)) {
                        executions[context.run.id]?.verificationCache = (before, checked)
                    } else { executions[context.run.id]?.verificationCache = nil }
                }
            } catch {
                executions[context.run.id]?.verificationCache = nil
                executions[context.run.id]?.captureFailureStages.insert("verification.capture")
                try? await activity(context, text: "[capture_failed] stage=verification.capture · 검사 시점의 코드 상태를 확인하지 못했어요")
            }
        }

        // The snapshot the last finished check ran against, pass or fail. Stallari judges the result; a failing
        // check cannot prove a criterion (StallariSession.judge), but its log explains what is wrong.
        // A timed-out or backgrounded check (no exit code) checked nothing and clears the proof.
        // When the check itself finished but the snapshot could not be taken, the previous verified
        // snapshot stands: completion then compares the current files against it and asks for a fresh
        // check whenever they differ.
        if unfinished || record.exitCode == nil { executions[context.run.id]?.verifiedDiff = nil }
        else if let checked { executions[context.run.id]?.verifiedDiff = checked }
        return true
    }
    private func question(_ frame: OMPJSON, context: Context) async throws {
        guard let rpcID = frame["id"]?.string, let method = frame["method"]?.string else { return }
        if method == "cancel", let target = frame["targetId"]?.string,
           let qid = executions[context.run.id]?.questions.first(where: { $0.value.rpcID == target })?.key {
            _ = try await repository.cancelQuestion(qid, runID: context.run.id, at: .now)
            try await activity(context, text: "[question_cancelled] source=omp stage=question.cancel · 질문만 닫았으며 실행 취소로 해석하지 않았어요", command: currentCommand(context))
            return
        }
        guard let route = OMPExtensionDialog(frame) else { return }
        let qid = "hird-question:\(context.run.id.rawValue):\(rpcID)"
        if let old = executions[context.run.id]?.questions[qid] { guard old == route else { throw HirdError.conflictingDelivery }; return }
        let prompt = route.prompt
        executions[context.run.id]?.questions[qid] = route
        try await event(context, .ask(.init(id: qid, runID: context.run.id, issueID: context.run.issueID, prompt: prompt, options: route.options, createdAt: .now, source: .hird)))
    }
    public func steer(_ text: String, runID: HirdRun.ID) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let execution = executions[runID] else { throw HirdError.staleRun }
        let context = execution.context
        try live(context)
        let snapshot = try await repository.snapshot(includeHistory: false)
        guard snapshot.runs.contains(where: { $0.id == runID && $0.ownershipToken == context.run.ownershipToken && !$0.state.isTerminal }) else { throw HirdError.staleRun }
        let state = try await context.rpc.request("get_state", fields: [:], timeout: .seconds(10))
        try live(context)
        // steer queues an instruction for an active turn; an idle blocked turn needs prompt.
        let command = state["data"]?["isStreaming"]?.bool == true ? "steer" : "prompt"
        if command == "prompt" {
            executions[runID]?.promptCompleted = false
            executions[runID]?.interruptedResponse = nil
            executions[runID]?.reportPath = nil
        }
        let response = try await context.rpc.request(command, fields: ["message": .string(text)], timeout: .seconds(10))
        if command == "prompt" {
            try live(context)
            executions[runID]?.promptID = response["id"]?.string
        }
        try live(context)
    }
    public func deliver(_ resolution: QuestionResolution) async throws {
        guard let execution = executions[resolution.runID] else { throw HirdError.staleRun }
        let context = execution.context
        try live(context)
        guard context.run.issueID == resolution.issueID else { throw HirdError.staleRun }
        let route = execution.questions[resolution.questionID]
        if let old = execution.deliveries[resolution.deliveryID] { guard old == resolution else { throw HirdError.conflictingDelivery }; return }
        // An in-flight duplicate must wait for or retry the actual acceptance, never acknowledge early.
        guard !execution.inFlightDeliveries.contains(resolution.deliveryID) else { throw HirdError.conflictingDelivery }
        executions[resolution.runID]?.inFlightDeliveries.insert(resolution.deliveryID)
        defer { executions[resolution.runID]?.inFlightDeliveries.remove(resolution.deliveryID) }
        let snapshot = try await repository.snapshot(includeHistory: false)
        guard let run = snapshot.runs.first(where: { $0.id == resolution.runID }), !run.state.isTerminal,
              run.ownershipToken == context.run.ownershipToken,
              let question = snapshot.questions.first(where: { $0.id == resolution.questionID }), question.runID == run.id,
              question.issueID == resolution.issueID, question.state != .pending,
              question.answer == resolution.answer, (question.state == .cancelled) == resolution.cancelled else { throw HirdError.staleRun }
        try live(context)
        if let route {
            try await context.rpc.send("extension_ui_response", fields: route.response(resolution.cancelled ? nil : resolution.answer))
        } else {
            // ask_user is a Stallari host question, not an OMP extension dialog.
            // The durable identity/answer above is checked before sending to this exact Hird.
            guard question.source == .stallari else { throw HirdError.staleRun }
            let answer = resolution.answer.map { try? JSONEncoder().encode($0) } ?? nil
            let text = answer.map { String(decoding: $0, as: UTF8.self) } ?? "null"
            try await steer("Question questionID=\(resolution.questionID) runID=\(resolution.runID.rawValue) issueID=\(resolution.issueID.rawValue) cancelled=\(resolution.cancelled) answer=\(text)", runID: resolution.runID)
        }
        try live(context)
        if resolution.cancelled {
            try await activity(context, text: "[question_cancelled] source=user stage=question.delivery · 질문 취소 응답만 전달했으며 실행 취소 요청은 보내지 않았어요", command: currentCommand(context))
        }
        executions[resolution.runID]?.deliveries[resolution.deliveryID] = resolution
    }
    private func complete(_ context: Context) async throws -> Bool {
        try live(context)
        await flushActivity(context)
        let steps = try await refreshTodos(context)
        let snapshot = try await repository.snapshot(includeHistory: false)
        if snapshot.questions.contains(where: { $0.runID == context.run.id && $0.state == .pending }) { return false }
        try live(context)
        guard let execution = executions[context.run.id], execution.workspace != nil else { throw HirdError.workspace }
        if let reason = execution.interruptedResponse {
            return try await requestContinuation(context, reason: reason, interrupted: true)
        }
        let (result, current) = try await capture(context,
            summary: context.run.mode == .inspect ? "읽기 전용 조사 결과와 검증을 보존했어요" : "격리 작업 경로에 변경과 검증 결과를 보존했어요",
            stage: "completion.capture")
        try live(context)
        if context.run.mode != .inspect && current.isEmpty && execution.reportPath == nil {
            return try await requestContinuation(context, reason: "변경 없이 종료: 작업 사본 diff가 비어 있고 최종 보고서도 없어요", interrupted: false)
        }
        let unfinished = steps.filter { $0.state != .done }
        if !unfinished.isEmpty {
            let reason = unfinished.map { $0.title + ($0.blocker.map { " · " + $0 } ?? "") }.joined(separator: "; ")
            return try await requestVerification(context, reason: "미완료 todo: " + reason)
        }
        try live(context)
        guard !execution.verifications.isEmpty else {
            return try await requestVerification(context, reason: HirdError.noVerification.reason)
        }
        let commandEvidence = execution.verifications.filter { !$0.isInspection }
        if commandEvidence.isEmpty {
            guard let read = execution.verifications.last,
                  read.finishedAt >= (execution.lastMutationAt ?? .distantPast) else {
                return try await requestVerification(context, reason: "마지막 변경 뒤 문서·화면 확인 근거가 없어요")
            }
        } else if execution.verifiedDiff == nil {
            let command = commandEvidence.last?.command.joined(separator: " ") ?? "bash"
            let reason = commandEvidence.last?.exitCode == nil
                ? HirdError.unfinishedVerification.reason + " 마지막 명령: " + command
                : "마지막 검사 뒤 스냅샷을 남기지 못해 검사 시점의 코드 상태를 확인할 수 없어요. 마지막 명령: " + command
            return try await requestVerification(context, reason: reason)
        }
        if let verified = execution.verifiedDiff {
            let changed = current.changedFiles(comparedTo: verified)
            if !changed.allSatisfy(Self.isEvidenceReport) {
                return try await requestVerification(context, reason: "마지막 검사 뒤 파일이 바뀜: " + changed.joined(separator: ", "))
            }
        }
        if context.run.mode == .inspect && !current.isEmpty { throw HirdError.inspectionModified }
        if context.run.mode == .inspect && execution.reportPath == nil { throw HirdError.noReport }
        try live(context)
        // Reclaim BEFORE storing success. A turn-ending event is only the trigger for these checks.
        executions[context.run.id]?.active = false
        let exit = await context.rpc.shutdown(cancel: false)
        exits[context.run.id] = exit
        guard exit.remainingProcessIDs.isEmpty, exit.reason == .normal, !tombstones.contains(context.run.id) else { throw HirdError.cleanup }
        _ = try await repository.markProcessEnded(context.run.id, at: .now)
        try await event(context, .complete(result, notificationID: "hird-completion:" + context.run.id.rawValue))
        return true
    }
    /// Only a matching completed prompt can enter here; reset that latch before suspending.
    private func requestVerification(_ context: Context, reason: String) async throws -> Bool {
        try live(context)
        let id = context.run.id
        guard let execution = executions[id] else { throw HirdError.staleRun }
        guard execution.verificationRetries < 2 else {
            throw HirdError.verificationRetriesExhausted(reason)
        }
        let attempt = execution.verificationRetries + 1
        executions[id]?.verificationRetries = attempt
        let message = """
            작업·검증 보정 재요청 \(attempt)/2. \(reason).
            실제 사람의 답이 필요하면 ask로 구체적으로 질문하세요. 그 외에는 미완료 todo를 마치고 같은 실행에서 이어가세요. 바뀐 코드에 필요한 검사를 실행하거나 문서·화면을 read로 확인하고 결과를 보고하세요. 최종 답변은 보고서로 자동 저장됩니다. 명령에는 유한한 timeout을 두세요. 멈췄다면 스택과 마지막 명령으로 진단하고 무작정 wait하지 마세요.
            """
        return try await requestFollowup(context, message: message)
    }

    private func requestContinuation(_ context: Context, reason: String, interrupted: Bool) async throws -> Bool {
        try live(context)
        let id = context.run.id
        guard let execution = executions[id], let policy = execution.continuationPolicy else { throw HirdError.staleRun }
        guard execution.continuationRetries < policy.maximumAttempts else {
            throw HirdError.continuationRetriesExhausted(policy.maximumAttempts, reason)
        }
        let attempt = execution.continuationRetries + 1
        executions[id]?.continuationRetries = attempt
        let prompt = interrupted ? policy.interruptedPrompt : policy.emptyResultPrompt
        return try await requestFollowup(context,
            message: "[hird_continuation] 자동 이어 가기 \(attempt)/\(policy.maximumAttempts). \(reason).\n\(prompt)")
    }

    /// Reset per-turn proof before suspension; old completions cannot settle the admitted prompt.
    private func requestFollowup(_ context: Context, message: String) async throws -> Bool {
        try live(context)
        let id = context.run.id
        executions[id]?.promptCompleted = false
        executions[id]?.promptID = nil
        executions[id]?.interruptedResponse = nil
        executions[id]?.reportPath = nil
        try await activity(context, text: message)
        try live(context)
        let response = try await context.rpc.request("prompt", fields: ["message": .string(message)], timeout: .seconds(10))
        try live(context)
        // Without an admission ID a late completion cannot be distinguished from this turn.
        guard let promptID = response["id"]?.string else { throw OMPRPCError.invalidFrame("missing followup prompt ID") }
        executions[id]?.promptID = promptID
        return false
    }

    /// Only dedicated evidence documents/assets are exempt. Product Markdown, source,
    /// configuration and scripts still invalidate the check.
    private static func isEvidenceReport(_ path: String) -> Bool {
        (path.hasPrefix("docs/evidence/") || path.hasPrefix(".agent/")) &&
            ["md", "txt", "log", "png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public func modelForNewRuns() -> String? { expectedModel }
    public func setModel(_ model: String) { expectedModel = model }
    public func remainingProcessIDs() -> [Int32] { Array(Set(exits.values.flatMap(\.remainingProcessIDs))).sorted() }
    public func terminationConfirmed(_ runID: HirdRun.ID) async -> Bool {
        guard executions[runID] == nil else { return false }
        if let exit = exits[runID] { return exit.remainingProcessIDs.isEmpty }
        return tombstones.contains(runID)
    }

    public func cancel(_ runID: HirdRun.ID) async {
        await cancel(runID, source: "user")
    }
    private func cancel(_ runID: HirdRun.ID, source: String) async {
        tombstones.insert(runID)
        stopActivityFlush(runID)
        let execution = executions[runID]
        executions[runID]?.activity.discardPending()
        executions[runID]?.active = false
        if let execution {
            try? await activity(execution.context, text: "[run_cancelled] source=\(source) stage=run.cancel · 명시적인 실행 취소 요청을 기록했어요")
        }
        _ = try? await repository.cancelRun(runID, at: .now, reason: "[run_cancelled] source=\(source) · Hird 실행을 취소했어요")
        if let execution {
            _ = await execution.context.rpc.shutdown(cancel: true)
            if !finished.contains(runID) { await withCheckedContinuation { finishWaiters[runID, default: []].append($0) } }
        }
        if await terminationConfirmed(runID) { _ = try? await repository.markProcessEnded(runID, at: .now) }
    }
}
