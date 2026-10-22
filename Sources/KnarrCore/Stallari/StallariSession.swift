import Foundation

/// One project manager for every registered project, attached to one OMP session. OMP owns RPC, auth and queues.
public actor StallariSession {
    private let repository: SQLiteKnarrRepository
    private let rpc: any StallariRPC
    private let hird: any HirdAdapter
    private let sessionReader: any SessionReading
    public let threadID: String
    public private(set) var responseConversationRootID: UUID?
    public func finishMessageConversationResponse() { responseConversationRootID = nil }
    private let responseRules: ResponseRulesFile?
    /// Root of the user-owned instruction tree, re-read for every request.
    private let instructionsDirectory: URL?
    private let instructionProjectID: String?
    private let projectSessionPolicy: ProjectSessionPolicy
    private let persistThinking: (@MainActor @Sendable (String) -> Void)?
    private let persistModel: (@MainActor @Sendable (String) -> Void)?
    private var requestedThinking: String?
    private var requestedModel: String?
    private var pendingModel: String?
    private var pendingThinking: String?
    private var resettingContext = false
    private var selectingModel = false
    public private(set) var appliedResponseRulesVersion: String?
    public private(set) var appliedInstructionsVersion: String?
    public private(set) var instructionLoadError: String?
    private var closed = false
    private var eventTask: Task<Void, Never>?
    private var starts: [HirdRun.ID: Task<Void, Never>] = [:]
    private var approvalsInFlight: [Issue.ID: (version: Int, task: Task<HirdRun.ID, Error>)] = [:]
    private var approvalTail: Task<HirdRun.ID, Error>?
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var routeApproval: (@Sendable (Issue.ID, Int, String?) async throws -> HirdRun.ID)?
    private var routeQuestionAnswer: (@Sendable (String, HirdRun.ID, Issue.ID, QuestionAnswer) async throws -> MutationOutcome)?
    private var hostCalls: [String: OMPJSON] = [:]
    private var hostReplies: [String: [String: OMPJSON]] = [:]
    private var cancelledCalls: Set<String> = []
    private var flushingNotifications = false
    private var flushingAnswers = false
    private var notificationDrainRequested = false
    private var answerDrainRequested = false
    private var flushingProjectTransfers = false
    private var projectTransferDrainRequested = false
    private var projectTransferDrainTask: Task<Void, Never>?
    private var bridgeGeneration: String?
    public private(set) var lastDeliveryError: String?
    public private(set) var observedEventTypes: [String] = []
    private let extensions: KnarrExtensions?
    private let restartRPC: (@Sendable () async throws -> OMPJSON)?
    private var reloadRequested = false
    private var reloading = false
    private var extensionNotice: String?
    public private(set) var lastExtensionReload: OMPJSON?
    private var initialExtensionFailure: OMPJSON?

    public init(repository: SQLiteKnarrRepository, rpc: any StallariRPC, hird: any HirdAdapter, sessionReader: any SessionReading = LocalSessionAPI(), responseRules: ResponseRulesFile? = nil, instructionsDirectory: URL? = nil, instructionProjectID: String? = nil, requestedModel: String? = nil, projectSessionPolicy: ProjectSessionPolicy = .current, requestedThinking: String? = nil, persistModel: (@MainActor @Sendable (String) -> Void)? = nil, persistThinking: (@MainActor @Sendable (String) -> Void)? = nil, threadID: String = ConversationThread.defaultID, extensions: KnarrExtensions? = nil, restartRPC: (@Sendable () async throws -> OMPJSON)? = nil) {
        self.repository = repository; self.rpc = rpc; self.hird = hird; self.sessionReader = sessionReader
        self.threadID = threadID
        self.extensions = extensions
        self.restartRPC = restartRPC
        self.responseRules = responseRules
        self.instructionsDirectory = instructionsDirectory
        self.instructionProjectID = instructionProjectID
        self.projectSessionPolicy = projectSessionPolicy
        self.persistModel = persistModel
        self.persistThinking = persistThinking
        self.requestedModel = requestedModel
        self.requestedThinking = requestedThinking
    }
    /// The store resolves an owning conversation; no manager sits between Stallari and Hird.
    func setApprovalRouter(_ router: @escaping @Sendable (Issue.ID, Int, String?) async throws -> HirdRun.ID) {
        routeApproval = router
    }
    func setQuestionAnswerRouter(_ router: @escaping @Sendable (String, HirdRun.ID, Issue.ID, QuestionAnswer) async throws -> MutationOutcome) {
        routeQuestionAnswer = router
    }
    public func connect() async throws {
        try ensureOpen()
        guard eventTask == nil else { try await deliverProjectHandoff(); return }
        try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: requestedThinking)
        let stream = await rpc.subscribe()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.observe(event)
            }
        }
        _ = try await rpc.request("set_host_tools", fields: ["tools": .array(StallariTools.definitions)], timeout: .seconds(10))
        try await applyToolBoundary()
        try await checkToolExposure()
        _ = try await rpc.request("set_ask_dialog", fields: ["enabled": .bool(false)], timeout: .seconds(10))
        if case .object(var result) = initialExtensionFailure {
            result["tools"] = StallariTools.toolSnapshot(try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"]?["dumpTools"])
            result["status"] = .string("startup_failed_policy_only")
            lastExtensionReload = .object(result)
            extensionNotice = "Knarr extension startup: " + (try jsonText(.object(result)))
            initialExtensionFailure = nil
        }
        try await deliverProjectHandoff()
        try await repository.prepareIssueHandoff(threadID: threadID)
        try await deliverInitialHandoff()
        try await deliverNotifications()
        try await deliverAnswers()
        // A missing owned extension must fail the request, not the whole chat connection.
        do { try await deliverProjectTransfers(retryFailed: true) }
        catch { lastDeliveryError = "메인 전달 요청은 원본과 함께 보존돼요. 전달 상태에서 다시 시도할 수 있어요." }
    }
    private func deliverInitialHandoff() async throws {
        for delivery in try await repository.pendingThreadDeliveries(threadID: threadID) {
            guard case .handoff(let text) = delivery.kind else { continue }
            if try await scope().issues.first(where: { $0.id == delivery.issueID })?.archivedAt != nil {
                try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now)
                continue
            }
            try await followUp("deliveryID=\(delivery.id)\n" + text)
            try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now)
        }
    }
    private func deliverProjectHandoff() async throws {
        let snapshot = try await scope()
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }),
              let projectID = thread.projectID, thread.projectHandoffDeliveredAt == nil else { return }
        let owner = try project(projectID, in: snapshot)
        let text = projectSessionPolicy.handoff(project: owner, snapshot: snapshot)
        try await followUp("deliveryID=project-handoff:\(threadID)\n" + projectSessionPolicy.roleInstructions + "\n" + text)
        try await repository.markProjectHandoffDelivered(threadID: threadID, at: .now)
    }
    private func applyToolBoundary() async throws {
        let stream = await rpc.subscribe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    if case .frame(let frame) = event, frame["type"]?.string == "extension_ui_request",
                       frame["method"]?.string == "setStatus", frame["statusKey"]?.string == "__knarr_tool_policy__",
                       frame["statusText"]?.string == "ready" { return }
                }
                throw StallariError.rejectedEvidence("Stallari tool policy connection ended before acknowledgement")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw StallariError.rejectedEvidence("Stallari read-only tool policy acknowledgement timed out")
            }
            _ = try await rpc.request("prompt", fields: ["message": .string("/knarr-stallari-tools")], timeout: .seconds(10))
            try await group.next()
            group.cancelAll()
        }
    }
    /// dumpTools is OMP's actual agent.state.tools, not the registration response.
    @discardableResult public func checkToolExposure() async throws -> [String] {
        let response = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))
        let names = response["data"]?["dumpTools"]?.array?.compactMap { $0["name"]?.string } ?? []
        let actual = Set(names)
        guard StallariTools.requiredHostTools.isSubset(of: actual), StallariTools.requiredExecutionTools.isSubset(of: actual),
              actual.isDisjoint(with: StallariTools.forbiddenTools),
              !actual.contains(where: { $0.hasPrefix("mcp__") }) else { throw StallariError.unsafeToolExposure }
        return names
    }
    public func getState() async throws -> OMPJSON {
        try ensureOpen()
        let response = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))
        guard case .object(var frame) = response else { return response }
        frame["data"] = modelState(response["data"] ?? .null)
        return .object(frame)
    }
    /// Reset only this thread's OMP transcript. Knarr's records and Hird runs stay intact.
    func resetContext() async throws -> OMPJSON {
        try ensureOpen()
        guard !resettingContext, !selectingModel, !reloading else { throw ConversationResetError.busy }
        resettingContext = true
        defer { resettingContext = false }
        let before = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        guard before["isStreaming"]?.bool != true, before["isCompacting"]?.bool != true,
              before["isSettled"]?.bool != false else { throw ConversationResetError.busy }
        let result = try await rpc.request("new_session", fields: [:], timeout: .seconds(30))
        guard result["data"]?["cancelled"]?.bool == false else { throw ConversationResetError.cancelled }
        responseConversationRootID = nil
        // OMP keeps an empty new session in memory until its first durable entry.
        // Saving the name forces that file to disk, so --continue cannot restore the old context.
        _ = try await rpc.request("set_session_name", fields: ["name": .string(before["sessionName"]?.string ?? "Stallari")], timeout: .seconds(10))
        let after = try await getState()["data"] ?? .null
        guard let newID = after["sessionId"]?.string, !newID.isEmpty,
              newID != before["sessionId"]?.string else { throw ConversationResetError.unconfirmed }
        return after
    }
    private func ensureOpen() throws { if closed { throw StallariError.closed } }
    private func scope() async throws -> PersistenceSnapshot {
        try ensureOpen()
        return try await repository.snapshot(includeHistory: false)
    }
    private func project(_ id: String, in snapshot: PersistenceSnapshot) throws -> StoredProject {
        guard id != StoredProject.hubID, let project = snapshot.projects.first(where: { $0.id == id }) else { throw StallariError.wrongProject }
        return project
    }
    /// The project a Issue belongs to; stored, never inferred from a display name.
    private func projectID(of issue: Issue.ID) async throws -> String {
        let id = try await repository.projectID(forIssue: issue)
        guard id != StoredProject.hubID else { throw StallariError.wrongProject }
        return id
    }
    private func ensureWritableThread(in snapshot: PersistenceSnapshot) throws {
        if let ownedID = snapshot.threads.first(where: { $0.id == threadID })?.issueID,
           snapshot.issues.first(where: { $0.id == ownedID })?.archivedAt != nil {
            throw StallariError.rejectedEvidence("닫힌 이슈 대화는 읽기 전용이에요.")
        }
    }
    private func issue(_ id: Issue.ID, in snapshot: PersistenceSnapshot, reading: Bool = false) async throws -> Issue {
        _ = try project(try await projectID(of: id), in: snapshot)
        guard let issue = snapshot.issues.first(where: { $0.id == id }) else { throw StallariError.missingIssue }
        guard reading || owns(issue, in: snapshot) else { throw StallariError.missingIssue }
        if !reading {
            try ensureWritableThread(in: snapshot)
            guard issue.archivedAt == nil else { throw StallariError.rejectedEvidence("닫힌 이슈 대화는 읽기 전용이에요.") }
        }
        return issue
    }
    private func owns(_ issue: Issue, in snapshot: PersistenceSnapshot) -> Bool {
        if issue.conversationThreadID == threadID { return true }
        guard let owner = snapshot.threads.first(where: { $0.id == issue.conversationThreadID }),
              owner.issueID == issue.id, owner.originThreadID == threadID else { return false }
        if threadID == ConversationThread.defaultID { return true }
        return snapshot.threads.first(where: { $0.id == threadID })?.projectID == snapshot.issueProjects[issue.id] &&
            snapshot.issueProjects[issue.id] != nil
    }
    private func canRead(_ issue: Issue, in snapshot: PersistenceSnapshot) -> Bool {
        if owns(issue, in: snapshot) { return true }
        // Accepted main-origin results are handed to their project for integration. This
        // grants readback only; proposal changes/approval keep their original ownership.
        if issue.state == .done,
           snapshot.threads.first(where: { $0.id == threadID })?.projectID == snapshot.issueProjects[issue.id],
           snapshot.issueProjects[issue.id] != nil,
           snapshot.threads.first(where: { $0.id == issue.conversationThreadID })?.originThreadID == ConversationThread.defaultID {
            return true
        }
        guard threadID == ConversationThread.defaultID,
              let owner = snapshot.threads.first(where: { $0.id == issue.conversationThreadID }),
              owner.issueID == issue.id, let originID = owner.originThreadID,
              let origin = snapshot.threads.first(where: { $0.id == originID }) else { return false }
        return origin.projectID == snapshot.issueProjects[issue.id] && origin.projectID != nil
    }
    /// Every registered project Stallari can create work in; archived ones are off the list.
    public func listProjects() async throws -> [StoredProject] {
        try await scope().projects.filter { $0.id != StoredProject.hubID && $0.archivedAt == nil }
    }
    /// Project authority comes only from durable thread/issue ownership, never
    /// caller-supplied origin, issue or thread metadata.
    /// The only app-owned write path for the instruction tree. It accepts no path at all: role,
    /// kind and the conversation's own projectID select the file. Expected-hash conflicts,
    /// symlinked directories and non-Markdown names are rejected inside InstructionSources.
    private func writeInstructionFile(_ arguments: OMPJSON) async throws -> OMPJSON {
        try ensureOpen()
        guard let directory = instructionsDirectory, case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["role", "kind", "projectID", "content", "expectedHash"]),
              let roleText = fields["role"]?.string, let role = InstructionRole(rawValue: roleText),
              let kindText = fields["kind"]?.string, let kind = InstructionKind(token: kindText),
              let content = fields["content"]?.string, let expectedHash = fields["expectedHash"]?.string else {
            throw StallariError.invalidArguments
        }
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        let projectID = fields["projectID"]?.string
        switch role {
        case .common, .stallari, .hird:
            guard projectID == nil else { throw StallariError.invalidArguments }
        case .project:
            guard let projectID, projectID == instructionProjectID else {
                throw StallariError.rejectedEvidence("이 대화의 프로젝트 지침만 쓸 수 있어요. 다른 프로젝트 지침은 그 프로젝트 대화에서 수정하세요.")
            }
            guard snapshot.projects.contains(where: { $0.id == projectID && $0.archivedAt == nil }) else {
                throw StallariError.rejectedEvidence("활성 프로젝트의 지침만 쓸 수 있어요.")
            }
        }
        let saved = try InstructionSources.save(dataDirectory: directory, role: role, kind: kind,
                                                 projectID: role == .project ? projectID : nil,
                                                 text: content, expectedHash: expectedHash)
        return .object(["path": .string(saved.path), "version": .string(saved.version),
                        "role": .string(role.rawValue), "kind": .string(kind.token),
                        "projectID": projectID.map(OMPJSON.string) ?? .null])
    }
    private func writeProjectDocument(_ arguments: OMPJSON) async throws -> OMPJSON {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: ["projectID", "path", "content", "expectedHash"]),
              let projectID = fields["projectID"]?.string, !projectID.isEmpty,
              let path = fields["path"]?.string,
              let content = fields["content"]?.string,
              fields["expectedHash"] == nil || fields["expectedHash"]?.string != nil else {
            throw StallariError.rejectedEvidence("projectID·상대 문서 경로·전체 내용을 확인해 주세요.")
        }
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        guard let project = snapshot.projects.first(where: { $0.id == projectID }),
              project.id != StoredProject.hubID, project.archivedAt == nil,
              let thread = snapshot.threads.first(where: { $0.id == threadID }) else {
            throw StallariError.rejectedEvidence("문서를 쓸 활성 프로젝트와 대화를 확인해 주세요.")
        }
        if let issueID = thread.issueID {
            guard thread.projectID == nil,
                  let issue = snapshot.issues.first(where: { $0.id == issueID }),
                  issue.conversationThreadID == thread.id, issue.archivedAt == nil,
                  snapshot.issueProjects[issueID] == projectID,
                  let originID = thread.originThreadID, originID != thread.id,
                  let origin = snapshot.threads.first(where: { $0.id == originID }),
                  origin.issueID == nil, origin.originThreadID == nil,
                  origin.projectID == nil || origin.projectID == projectID else {
                throw StallariError.rejectedEvidence("이 이슈 대화의 프로젝트 문서만 쓸 수 있어요.")
            }
        } else {
            guard thread.originThreadID == nil, thread.projectID == nil || thread.projectID == projectID else {
                throw StallariError.rejectedEvidence("이 대화의 프로젝트 문서만 쓸 수 있어요.")
            }
        }
        return try StallariDocumentWriter.write(root: URL(fileURLWithPath: project.absolutePath, isDirectory: true),
            path: path, content: content, expectedHash: fields["expectedHash"]?.string).json
    }
    /// - Parameter projectID: may be omitted only when exactly one project is registered.
    public func createIssue(id: Issue.ID, title: String, criteria: [String], instruction: String,
                            model: String? = nil, mode: HirdRunMode = .change,
                            previousRunID: HirdRun.ID? = nil, projectID: String? = nil,
                            handoffSummary: String? = nil, milestoneID: Milestone.ID? = nil,
                            stages: [IssueStage]? = nil) async throws -> Issue.ID {
        try await createIssueRecord(id: id, title: title, criteria: criteria, instruction: instruction,
            model: model, mode: mode, previousRunID: previousRunID, projectID: projectID,
            handoffSummary: handoffSummary, milestoneID: milestoneID, stages: stages).id
    }
    func createIssueRecord(id: Issue.ID, title: String, criteria: [String], instruction: String,
                            model: String? = nil, mode: HirdRunMode = .change,
                            previousRunID: HirdRun.ID? = nil, projectID: String? = nil,
                            handoffSummary: String? = nil, milestoneID: Milestone.ID? = nil,
                            stages: [IssueStage]? = nil, creationRequestFingerprint: String? = nil) async throws -> (id: Issue.ID, created: Bool) {
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        let p = try writableProject(projectID, in: snapshot)
        let projectID = p.id
        if let fingerprint = creationRequestFingerprint,
           let existing = snapshot.issues.first(where: { $0.id == id }) {
            guard existing.creationRequestFingerprint == fingerprint,
                  snapshot.issueProjects[id] == projectID,
                  let owner = snapshot.threads.first(where: { $0.id == existing.conversationThreadID }),
                  owner.issueID == id, owner.originThreadID == threadID else { throw StallariError.conflictingID }
            return (id, false)
        }
        if let milestoneID {
            guard let milestone = snapshot.milestones.first(where: { $0.id == milestoneID && $0.projectID == projectID }) else {
                throw StallariError.rejectedEvidence("milestoneID \(milestoneID.rawValue) is not a milestone of project \(projectID): use the milestone ID the user's request names, or omit it")
            }
            guard milestone.status != Milestone.Status.reached else {
                throw StallariError.rejectedEvidence("milestone \(milestone.title) is already reached: attach work to the milestone that is still open")
            }
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !criteria.isEmpty,
              criteria.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw StallariError.invalidArguments }
        // The project's own completion criteria always come with every Issue in it.
        let criteria = criteria + p.settings.criteria.filter { !criteria.contains($0) }
        let proposal = try await resolvedProposal(instruction: instruction, model: model, mode: mode,
                                                  previousRunID: previousRunID, project: p, stages: stages)
        if let existing = snapshot.issues.first(where: { $0.id == id }) {
            guard existing.title == title, existing.acceptance.map(\.text) == criteria,
                  snapshot.issueProjects[id] == projectID, existing.proposal == proposal,
                  existing.milestoneID == milestoneID else { throw StallariError.conflictingID }
            let owner = snapshot.threads.first { $0.id == existing.conversationThreadID }
            guard existing.conversationThreadID == threadID || (owner?.issueID == id && owner?.originThreadID == threadID) else { throw StallariError.conflictingID }
            return (id, false)
        }
        var created = Issue(id: id, title: title, projectName: p.name, state: .awaitingApproval,
            headline: "사용자 승인 대기", detail: "Hird 제안을 확인하고 화면이나 채팅으로 승인해 주세요",
            acceptance: criteria.map { .init(text: $0, state: .pending, evidence: "") },
            hirds: [], events: [], startedAt: .now)
        created.proposal = proposal
        created.creationRequestFingerprint = creationRequestFingerprint
        created.milestoneID = milestoneID
        created.threadID = UUID().uuidString
        let limit = projectSessionPolicy.issueHandoffMaximumCharacters
        let summary = String((handoffSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").prefix(limit))
        let inserted = try await repository.createIssueConversation(created, projectID: projectID, originThreadID: threadID,
            handoffSummary: summary.isEmpty ? title : summary)
        return (id, inserted)
    }
    /// One rule for every project write: a project conversation may name only its own project,
    /// main must name a registered project (or the only one), and archived projects take nothing.
    private func writableProject(_ requested: String?, in snapshot: PersistenceSnapshot) throws -> StoredProject {
        let candidates = snapshot.projects.filter { $0.id != StoredProject.hubID && $0.archivedAt == nil }
        let scopedProject = snapshot.threads.first(where: { $0.id == threadID })?.projectID
        guard scopedProject == nil || requested == nil || requested == scopedProject else {
            throw StallariError.rejectedEvidence(projectSessionPolicy.wrongProjectMessage)
        }
        guard let id = requested ?? scopedProject ?? (candidates.count == 1 ? candidates[0].id : nil) else {
            throw StallariError.rejectedEvidence("projectID is required here: call list_projects and pick the project this task belongs to")
        }
        let project: StoredProject
        do { project = try self.project(id, in: snapshot) }
        catch { throw StallariError.rejectedEvidence("projectID \(id) is not a registered project: call list_projects") }
        guard project.archivedAt == nil else {
            throw StallariError.rejectedEvidence("project \(project.name) is archived: the user took it off the list, so it takes no new work")
        }
        return project
    }

    /// Reads one project's plan; the conversation's own project is the only one it may read.
    private func readableProject(_ requested: String?, in snapshot: PersistenceSnapshot) throws -> StoredProject {
        let scopedProject = snapshot.threads.first(where: { $0.id == threadID })?.projectID
        guard scopedProject == nil || requested == nil || requested == scopedProject else {
            throw StallariError.rejectedEvidence(projectSessionPolicy.wrongProjectMessage)
        }
        guard let id = requested ?? scopedProject else {
            throw StallariError.rejectedEvidence("projectID is required here: call list_projects and pick the project")
        }
        let project: StoredProject
        do { project = try self.project(id, in: snapshot) }
        catch { throw StallariError.rejectedEvidence("projectID \(id) is not a registered project: call list_projects") }
        guard project.archivedAt == nil else {
            throw StallariError.rejectedEvidence("project \(project.name) is archived: the user took it off the list, so it takes no new work")
        }
        return project
    }

    private func resolvedProposal(version: Int = 1, instruction: String, model: String?,
                                  mode: HirdRunMode, previousRunID: HirdRun.ID?,
                                  project: StoredProject, stages: [IssueStage]? = nil) async throws -> IssueProposal {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StallariError.invalidArguments }
        let defaultModel = await hird.modelForNewRuns()
        let available = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))
        let models = Set((available["data"]?["models"]?.array ?? []).compactMap { value -> String? in
            guard let provider = value["provider"]?.string, !provider.isEmpty,
                  let id = value["id"]?.string, !id.isEmpty else { return nil }
            return provider + "/" + id
        })
        // Preserve project-default resolution, but freeze its result before review.
        let preferred = project.settings.hirdModel.map(HiveProviderRuntime.currentModelIdentifier).flatMap { models.contains($0) ? $0 : nil }
        guard model != nil || project.settings.hirdModel == nil || preferred != nil else { throw StallariError.rejectedEvidence("프로젝트의 Hird 모델을 현재 사용할 수 없어요. 설정을 확인해 주세요.") }
        guard let selected = (model ?? preferred ?? defaultModel).map(HiveProviderRuntime.currentModelIdentifier), models.contains(selected) else {
            throw StallariError.rejectedEvidence("제안 모델이 현재 사용 가능한 모델 목록에 없어요. get_runtime으로 확인해 주세요.")
        }
        return .init(version: version, instruction: instruction, model: selected, mode: mode, previousRunID: previousRunID, thinking: project.settings.hirdThinking, stages: stages)
    }

    public func updateIssueProposal(issueID: Issue.ID, expectedVersion: Int, instruction: String,
                                    model: String? = nil, mode: HirdRunMode = .change,
                                    previousRunID: HirdRun.ID? = nil, stages: [IssueStage]? = nil) async throws {
        let snapshot = try await scope()
        let target = try await issue(issueID, in: snapshot)
        let owner = try project(try await projectID(of: issueID), in: snapshot)
        guard owner.archivedAt == nil, target.proposal?.version == expectedVersion else { throw StallariError.invalidArguments }
        let proposal = try await resolvedProposal(version: expectedVersion + 1, instruction: instruction,
            model: model ?? target.proposal?.model, mode: mode, previousRunID: previousRunID, project: owner,
            stages: stages ?? target.proposal?.stages)
        try await repository.saveIssueProposal(issueID: issueID, proposal: proposal, expectedVersion: expectedVersion)
    }

    /// Screen actions and Stallari decisions approve an exact saved version.
    public func approveIssue(issueID: Issue.ID, version: Int, source: String? = nil) async throws -> HirdRun.ID {
        try ensureOpen()
        let snapshot = try await scope()
        let target = try await issue(issueID, in: snapshot, reading: true)
        if target.conversationThreadID != threadID {
            guard owns(target, in: snapshot),
                  let owner = snapshot.threads.first(where: { $0.id == target.conversationThreadID }),
                  owner.issueID == issueID, owner.originThreadID == threadID, target.archivedAt == nil,
                  target.proposal?.version == version, let routeApproval else { throw StallariError.missingIssue }
            return try await routeApproval(issueID, version, source)
        }
        _ = try await issue(issueID, in: snapshot)
        if let pending = approvalsInFlight[issueID] {
            guard source != "phone" else { throw StallariError.rejectedEvidence("이미 처리 중인 제안 승인이에요") }
            guard pending.version == version else { throw StallariError.invalidArguments }
            return try await pending.task.value
        }
        // Admission through screen, chat, and phone is ordered across issues so two
        // approvals cannot both observe the last free project slot.
        let predecessor = approvalTail
        let task = Task { [self] in
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            let snapshot = try await scope()
            let target = try await issue(issueID, in: snapshot)
            if target.approval?.runID == nil {
                let ownerID = try await projectID(of: issueID)
                let owner = try project(ownerID, in: snapshot)
                let active = snapshot.runs.reduce(0) { count, run in
                    count + ((run.projectID == ownerID && (!run.state.isTerminal || (run.state == .cancelled && run.processEndedAt == nil))) ? 1 : 0)
                }
                guard owner.settings.allowsAdditionalHird(activeCount: active) else {
                    throw StallariError.rejectedEvidence("이 프로젝트는 Hird를 동시에 \(owner.settings.maxHirds)명까지만 보내요. 진행 중인 실행이 끝난 뒤 다시 승인해 주세요.")
                }
            }
            _ = try await repository.approveIssueProposal(issueID: issueID, version: version, at: .now, source: source)
            let saved = try await scope().issues.first(where: { $0.id == issueID })
            guard saved?.proposal?.version == version, saved?.approval?.version == version else { throw StallariError.invalidArguments }
            if let consumed = saved?.approval?.runID { return consumed }
            try Task.checkCancellation()
            return try await startApprovedIssue(issueID: issueID, runID: .init("hird-\(UUID())"), approvedVersion: version)
        }
        approvalsInFlight[issueID] = (version, task)
        approvalTail = task
        defer {
            approvalsInFlight.removeValue(forKey: issueID)
            if approvalsInFlight.isEmpty { approvalTail = nil }
        }
        return try await task.value
    }

    public func requestIssueProposalChanges(issueID: Issue.ID, version: Int, note: String, source: String? = nil) async throws {
        _ = try await issue(issueID, in: scope())
        try await repository.requestIssueProposalChanges(issueID: issueID, version: version, note: note, source: source)
        try await deliverNotifications()
    }

    public func rejectIssueProposal(issueID: Issue.ID, version: Int, note: String, source: String? = nil) async throws {
        _ = try await issue(issueID, in: scope())
        try await repository.rejectIssueProposal(issueID: issueID, version: version, note: note, source: source)
    }

    /// Direct retry/rework buttons approve the exact replacement proposal without a model turn.
    public func resumeIssue(issueID: Issue.ID, instruction: String, previousRunID: HirdRun.ID?,
                            mode: HirdRunMode?, model: String?) async throws -> HirdRun.ID {
        let snapshot = try await scope()
        let target = try await issue(issueID, in: snapshot)
        let owner = try project(try await projectID(of: issueID), in: snapshot)
        guard owner.archivedAt == nil else { throw StallariError.wrongProject }
        let version = (target.proposal?.version ?? 0) + 1
        let proposal = try await resolvedProposal(version: version, instruction: instruction, model: model,
            mode: mode ?? .change, previousRunID: previousRunID, project: owner, stages: target.proposal?.stages)
        try await repository.saveIssueProposal(issueID: issueID, proposal: proposal, expectedVersion: target.proposal?.version)
        return try await approveIssue(issueID: issueID, version: version)
    }

    public func dispatch(issueID: Issue.ID, runID: HirdRun.ID) async throws -> HirdRun.ID {
        try await startApprovedIssue(issueID: issueID, runID: runID, approvedVersion: nil)
    }

    private func startApprovedIssue(issueID: Issue.ID, runID: HirdRun.ID, approvedVersion: Int?) async throws -> HirdRun.ID {
        let snapshot = try await scope()
        let target = try await issue(issueID, in: snapshot)
        let projectID = try await projectID(of: issueID)
        guard let proposal = target.proposal, let approval = target.approval,
              approval.version == proposal.version, approvedVersion == nil || approvedVersion == proposal.version else {
            throw StallariError.rejectedEvidence("현재 저장된 제안이 승인되지 않았어요. 사용자 요청 범위에 해당하면 approve_issue로 정확한 버전을 실행하세요.")
        }
        if let consumed = approval.runID {
            guard consumed == runID, snapshot.runs.contains(where: { $0.id == consumed && $0.issueID == issueID }) else {
                throw StallariError.rejectedEvidence("이 버전은 이미 실행했어요. 필요한 보완은 새 제안 버전으로 저장한 뒤 사용자 요청 범위에 따라 approve_issue를 사용하세요.")
            }
            return consumed
        }
        let owner = try project(projectID, in: snapshot)
        guard owner.archivedAt == nil else { throw StallariError.rejectedEvidence("이 프로젝트는 보관돼 있어서 새 Hird를 보내지 않아요.") }
        let active = Set(snapshot.runs.filter { $0.projectID == projectID && !$0.state.isTerminal }.map(\.id))
        guard owner.settings.allowsAdditionalHird(activeCount: active.count) else {
            throw StallariError.rejectedEvidence("이 프로젝트는 Hird를 동시에 \(owner.settings.maxHirds)명까지만 보내요. 진행 중인 실행이 끝난 뒤 다시 보내 주세요.")
        }
        // No model turn or model fallback can rewrite what the user approved.
        let now = Date.now
        let run = PersistedRun(hird: .init(id: runID, name: "Hird", role: proposal.instruction, status: .working, steps: [],
            currentCommand: nil, lastActivityAt: now), issueID: issueID, projectID: projectID, ompSessionID: nil,
            ownershipToken: UUID().uuidString, startedAt: now, previousRunID: proposal.previousRunID,
            mode: proposal.mode, requestedModel: proposal.model,
            requestedThinking: proposal.thinking ?? "xhigh", stagePlan: proposal.stages)
        // Approval consumption and run insertion commit together before spawning.
        if try await repository.createApprovedRun(run, proposalVersion: proposal.version) == .applied {
            let hird = self.hird
            starts[runID] = Task { [weak self] in
                do {
                    try Task.checkCancellation()
                    try await hird.start(run) { [weak self] update in
                        guard update.runID == run.id else { throw StallariError.conflictingID }
                        guard let self else { throw StallariError.closed }
                        return try await self.receive(update)
                    }
                } catch {
                    await self?.startFailed(runID)
                }
            }
        }
        return runID
    }
    private func startFailed(_ runID: HirdRun.ID) async {
        guard !closed else { return }
        let reason = "Hird 시작 또는 실행이 실패했어요"
        _ = try? await repository.recordEvent(id: "launch-failure:\(runID.rawValue)", runID: runID, at: .now, payload: .fail(reason))
        do { try await deliverNotifications() } catch { lastDeliveryError = "멈춤 알림이 저장되어 다음 연결에서 다시 전달돼요" }
    }
    public func receive(_ update: HirdUpdate) async throws -> MutationOutcome {
        try ensureOpen()
        let run = try await getRun(update.runID)
        _ = try await issue(run.issueID, in: scope())
        let outcome = try await repository.recordEvent(id: update.id, runID: update.runID, at: update.at, payload: update.payload)
        // Persistence is committed before the follow-up starts. Delivery failure leaves the outbox.
        do { try await deliverNotifications() } catch { lastDeliveryError = "완료통지 접수 실패; 저장된 통지를 다시 전달할 수 있어요" }
        return outcome
    }
    /// Only a durable OMP custom-message receipt commits delivery. No model turn or approval is created.
    public func deliverProjectTransfers(retryFailed: Bool = false) async throws {
        try ensureOpen()
        guard responseConversationRootID == nil else { return }
        guard threadID == ConversationThread.defaultID else { return }
        projectTransferDrainRequested = true
        guard !flushingProjectTransfers else { return }
        flushingProjectTransfers = true
        defer { flushingProjectTransfers = false }
        var attempted: Set<String> = []
        var firstError: (any Error)?
        repeat {
            projectTransferDrainRequested = false
            let queued = try await repository.projectTransfers().filter {
                $0.deliveredAt == nil && ($0.lastError == nil || retryFailed) && !attempted.contains($0.id)
            }
            guard !queued.isEmpty else { break }
            let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
            guard state["isStreaming"]?.bool != true, state["isCompacting"]?.bool != true,
                  state["isSettled"]?.bool != false else { return }
            for transfer in queued {
                attempted.insert(transfer.id)
                let payload = try ProjectTransferProtocol.payload(transfer, policy: projectSessionPolicy)
                var unsupported = false
                do {
                    let before = try await rpc.request("get_entries", fields: [:], timeout: .seconds(10))
                    if try !ProjectTransferProtocol.hasReceipt(before, payload: payload) {
                        let commands = try await rpc.request("get_available_commands", fields: [:], timeout: .seconds(10))
                        guard commands["data"]?["commands"]?.array?.contains(where: { $0["name"]?.string == ProjectTransferProtocol.admissionCommand }) == true else {
                            unsupported = true
                            throw StallariError.rejectedEvidence("메인 전달 확장 또는 v1 bridge를 지원하지 않는 앱이에요. 호환 앱과 확장을 설치한 뒤 다시 시도해 주세요.")
                        }
                        try await admitProjectTransfer(payload)
                        let after = try await rpc.request("get_entries", fields: [:], timeout: .seconds(10))
                        guard try ProjectTransferProtocol.hasReceipt(after, payload: payload) else {
                            throw StallariError.rejectedEvidence("메인 전달의 영속 접수 기록이 없어요. 완료로 표시하지 않습니다.")
                        }
                    }
                    try await repository.markProjectTransferDelivered(transfer.id, at: .now)
                } catch {
                    if !unsupported {
                        if error is CancellationError { throw error }
                        if let transport = error as? OMPRPCError {
                            switch transport {
                            case .notRunning, .timedOut, .cancelled, .ioFailed, .processExited:
                                // An interrupted acknowledgement says nothing about durable admission.
                                // Keep pending so reconnect/settled can check the same receipt ID.
                                throw error
                            default: break
                            }
                        }
                        if let latest = try? await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"],
                           latest["isStreaming"]?.bool == true || latest["isCompacting"]?.bool == true ||
                           latest["isSettled"]?.bool == false {
                            return
                        }
                    }
                    try await repository.failProjectTransfer(transfer.id, unsupported: unsupported)
                    if firstError == nil { firstError = error }
                }
            }
        } while projectTransferDrainRequested
        if let firstError { throw firstError }
    }
    private func admitProjectTransfer(_ payload: OMPJSON) async throws {
        let stream = await rpc.subscribe()
        let rpc = self.rpc
        let data = try JSONEncoder().encode(payload).base64EncodedString()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // OMP acknowledges routing before the extension handler completes.
                // Subscribe first so a completion preceding the response is retained.
                let response = try await rpc.request("prompt", fields: [
                    "message": .string("/" + ProjectTransferProtocol.admissionCommand + " " + data)
                ], timeout: .seconds(10))
                guard let id = response["id"]?.string else {
                    throw OMPRPCError.invalidFrame("missing project transfer prompt ID")
                }
                for await event in stream {
                    switch event {
                    case .terminated(let exit): throw OMPRPCError.processExited(exit.status)
                    case .frame(let frame):
                        if frame["type"]?.string == "knarr_rpc_restarting" ||
                           frame["type"]?.string == "knarr_rpc_reload_failed" { throw OMPRPCError.notRunning }
                        guard frame["type"]?.string == "prompt_result", frame["id"]?.string == id else { continue }
                        guard frame["status"]?.string == "completed" else { throw OMPRPCError.remoteFailure }
                        return
                    }
                }
                throw OMPRPCError.notRunning
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw OMPRPCError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func scheduleProjectTransferDrain() {
        guard threadID == ConversationThread.defaultID else { return }
        projectTransferDrainRequested = true
        guard projectTransferDrainTask == nil else { return }
        // Admission waits for an extension input reply. The event subscriber must stay
        // free to receive that input; awaiting admission inside observe deadlocks it.
        projectTransferDrainTask = Task { [weak self] in await self?.drainScheduledProjectTransfers() }
    }

    private func drainScheduledProjectTransfers() async {
        defer { projectTransferDrainTask = nil }
        do { try await deliverProjectTransfers() }
        catch { lastDeliveryError = "저장된 메인 전달이 미완료예요. 원본과 요청은 보존돼요." }
    }

    private func performProjectTransferBridge(_ input: OMPJSON) async throws -> OMPJSON {
        try ensureOpen()
        guard case .object(var arguments) = input,
              Set(arguments.keys).isSubset(of: ["operation", "transferID", "requestMessageID", "summary", "messageIDs"]) else {
            throw StallariError.invalidArguments
        }
        let operation = try required(input, "operation")
        if operation == "enqueue" {
            // The host bridge is also model-visible. Match the owned extension's
            // optional references and generate an ID when callers omit it.
            for key in ["transferID", "requestMessageID"] {
                guard let value = arguments[key] else { continue }
                if value == .null || value == .string("") { arguments.removeValue(forKey: key) }
                else if value.string == nil { throw StallariError.invalidArguments }
            }
            if arguments["messageIDs"] == .null || arguments["messageIDs"] == .array([]) {
                arguments.removeValue(forKey: "messageIDs")
            }
        }
        let a = OMPJSON.object(arguments)
        if operation == "admission" {
            guard threadID == ConversationThread.defaultID,
                  Set(arguments.keys) == ["operation", "transferID"],
                  let transfer = try await repository.projectTransfers().first(where: { $0.id == a["transferID"]?.string }) else {
                throw StallariError.wrongProject
            }
            return try ProjectTransferProtocol.payload(transfer, policy: projectSessionPolicy)
        }
        let snapshot = try await scope()
        guard let thread = snapshot.threads.first(where: { $0.id == threadID }),
              let projectID = thread.projectID, thread.issueID == nil,
              snapshot.projects.contains(where: { $0.id == projectID && $0.archivedAt == nil }) else {
            throw StallariError.wrongProject
        }
        if operation == "retry" {
            let id = try required(a, "transferID")
            try await repository.retryProjectTransfer(id, originThreadID: threadID)
            guard let transfer = try await repository.projectTransfers().first(where: { $0.id == id }) else {
                throw StallariError.invalidArguments
            }
            return try projectTransferReadback(transfer)
        }
        let stored = try await repository.snapshot()
        let history = zip(stored.chat, stored.chatLinks).filter { $0.1.conversationThreadID == threadID }.map(\.0)
        let messages = history.filter {
            switch $0.kind { case .user, .stallari: return true; default: return false }
        }
        if operation == "context" {
            var remaining = projectSessionPolicy.handoffMaximumCharacters
            return .object(["bridgeVersion": .number(1), "originProjectID": .string(projectID), "originThreadID": .string(threadID),
                "messages": .array(messages.suffix(20).reversed().map { item in
                    let role: String; let text: String
                    switch item.kind { case .user(let value): role = "user"; text = value
                    case .stallari(let value, _): role = "assistant"; text = value
                    default: role = ""; text = "" }
                    let excerpt = String(text.prefix(min(remaining, projectSessionPolicy.handoffSectionCharacters)))
                    remaining -= excerpt.count
                    return .object(["id": .string(item.id.uuidString), "role": .string(role),
                        "text": .string(excerpt), "attachmentCount": .number(Double(item.attachments.count))])
                })])
        }
        guard operation == "enqueue" else { throw StallariError.invalidArguments }
        let requestID: UUID
        if let raw = a["requestMessageID"]?.string {
            guard let id = UUID(uuidString: raw) else { throw StallariError.invalidArguments }; requestID = id
        } else {
            guard let request = messages.last(where: { if case .user = $0.kind { true } else { false } }) else {
                throw StallariError.invalidArguments
            }
            requestID = request.id
        }
        let refs: [UUID]
        if let value = a["messageIDs"] {
            guard let values = value.array, values.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }) else {
                throw StallariError.invalidArguments
            }
            refs = values.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
        } else { refs = Array(Set(messages.suffix(6).map(\.id) + [requestID])).sorted { $0.uuidString < $1.uuidString } }
        let transferID = a["transferID"] == nil ? UUID().uuidString : try required(a, "transferID")
        let transfer = try await repository.enqueueProjectTransfer(id: transferID, originThreadID: threadID,
            requestMessageID: requestID, summary: required(a, "summary"), messageIDs: refs)
        return try projectTransferReadback(transfer)
    }
    private func projectTransferReadback(_ transfer: ProjectTransfer) throws -> OMPJSON {
        guard case .object(var fields) = try encoded(transfer) else { throw StallariError.invalidArguments }
        fields["state"] = .string(transfer.state.rawValue)
        fields["executionApproval"] = .bool(false)
        return .object(fields)
    }

    private func scheduleProjectTransferInput(_ frame: OMPJSON) {
        guard let id = frame["id"]?.string,
              bridgeGeneration == nil || frame["knarrRPCGeneration"]?.string == bridgeGeneration else { return }
        let key = "project-transfer-ui:" + id
        if let old = hostCalls[key], old != frame { return }
        guard hostTasks[key] == nil else { return }
        hostCalls[key] = frame
        hostTasks[key] = Task { [weak self] in await self?.executeProjectTransferInput(frame, id: id, key: key) }
    }
    private func executeProjectTransferInput(_ frame: OMPJSON, id: String, key: String) async {
        defer { hostTasks.removeValue(forKey: key) }
        var reply = hostReplies[key]
        if reply == nil {
            let envelope: OMPJSON
            do {
                guard let text = frame["placeholder"]?.string, text.utf8.count <= 131_072 else { throw StallariError.invalidArguments }
                let arguments = try JSONDecoder().decode(OMPJSON.self, from: Data(text.utf8))
                envelope = .object(["ok": .bool(true), "result": try await performTool(ProjectTransferProtocol.bridgeTool, arguments: arguments)])
            } catch {
                envelope = .object(["ok": .bool(false), "error": .string("전달 요청의 소유 프로젝트·원본 메시지·저장 상태를 확인해 주세요. 전달은 실행 승인이 아닙니다.")])
            }
            reply = ["id": .string(id), "value": .string((try? jsonText(envelope)) ?? "")]
            if let generation = frame["knarrRPCGeneration"] { reply?["knarrRPCGeneration"] = generation }
            hostReplies[key] = reply
        }
        guard !closed, let reply else { return }
        do { try await rpc.send("extension_ui_response", fields: reply) }
        catch { lastDeliveryError = "전달 요청 응답을 보내지 못했어요. 저장된 전달 상태를 확인하고 같은 ID로 다시 시도해 주세요." }
    }

    public func deliverNotifications() async throws {
        try ensureOpen()
        guard responseConversationRootID == nil else { return }
        notificationDrainRequested = true
        guard !flushingNotifications else { return }
        flushingNotifications = true; defer { flushingNotifications = false }
        var attempted: Set<String> = []
        var firstError: (any Error)?
        repeat {
            notificationDrainRequested = false
            for notice in try await repository.pendingNotifications() where !attempted.contains(notice.id) {
                attempted.insert(notice.id)
                let snapshot = try await scope()
                guard let run = snapshot.runs.first(where: { $0.id == notice.runID }),
                      run.state == .succeeded, let result = run.result else { continue }
                guard snapshot.issues.first(where: { $0.id == run.issueID })?.conversationThreadID == threadID else { continue }
                if snapshot.threads.first(where: { $0.id == threadID })?.issueID == run.issueID,
                   snapshot.issues.first(where: { $0.id == run.issueID })?.archivedAt != nil {
                    _ = try await repository.markNotificationDelivered(id: notice.id, runID: run.id, at: .now)
                    continue
                }
                let message = "Hird completion notificationID=\(notice.id) runID=\(run.id.rawValue) issueID=\(run.issueID.rawValue)\n" +
                    "Saved result: \(result.summary)\nUse get_run for this run and read_run_output for its report and verification logs, then judge_issue against the criteria. Replayed IDs do not create or dispatch another run."
                do {
                    try await followUp(message)
                    _ = try await repository.markNotificationDelivered(id: notice.id, runID: run.id, at: .now)
                } catch { if firstError == nil { firstError = error } }
            }
            for delivery in try await repository.pendingThreadDeliveries(threadID: threadID) where !attempted.contains(delivery.id) {
                attempted.insert(delivery.id)
                do {
                    let snapshot = try await scope()
                    if snapshot.threads.first(where: { $0.id == threadID })?.issueID == delivery.issueID,
                       snapshot.issues.first(where: { $0.id == delivery.issueID })?.archivedAt != nil {
                        try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now)
                        continue
                    }
                    // Retire legacy mirrors without starting another model turn. Cards read durable state.
                    if delivery.id.hasPrefix("main:") || (delivery.id.hasPrefix("owner:") && {
                        if case .completion = delivery.kind { return false }; return true
                    }()) {
                        try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now, forwardingAcceptedCompletion: true)
                        continue
                    }
                    if case .completion = delivery.kind, delivery.id.hasPrefix("owner:") {
                        guard let issue = snapshot.issues.first(where: { $0.id == delivery.issueID }),
                              issue.archivedAt == nil,
                              snapshot.runs.last(where: { $0.issueID == issue.id })?.id == delivery.runID else {
                            try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now)
                            continue
                        }
                        // Old installations may have queued completion before the issue was judged.
                        guard issue.state == .done else { continue }
                    }
                    let context = "threadID=\(threadID) issueID=\(delivery.issueID.rawValue)" +
                        (delivery.runID.map { " runID=\($0.rawValue)" } ?? "")
                    let originID = snapshot.threads.first { $0.issueID == delivery.issueID }?.originThreadID
                    let readOnlyMirror = threadID == ConversationThread.defaultID && delivery.id.hasPrefix("main:") &&
                        snapshot.threads.first { $0.id == originID }?.projectID != nil
                    let message: String?
                    switch delivery.kind {
                    case .handoff(let text):
                        message = text
                    case .question(let id):
                        if let question = snapshot.questions.first(where: { $0.id == id && $0.state == .pending }) {
                            if threadID == ConversationThread.defaultID && delivery.id.hasPrefix("main:") {
                                message = "Hird 질문 questionID=\(id) \(context)\n\(String(question.prompt.prefix(projectSessionPolicy.mirrorMaximumCharacters)))\n저장된 질문 카드를 확인하세요. 답변을 지어내거나 질문·실행을 중복 생성하지 마세요."
                            } else {
                                message = "Hird question questionID=\(id) \(context)\n\(question.prompt)\nOptions: \(question.options.joined(separator: ", "))\nThe saved question card accepts the user's answer. Do not invent an answer or create another question."
                            }
                        } else { message = nil }
                    case .stopped(let reason):
                        if threadID == ConversationThread.defaultID && delivery.id.hasPrefix("main:") {
                            message = "Hird run stopped \(context)\n\(String(reason.prefix(projectSessionPolicy.mirrorMaximumCharacters)))\n저장된 실행 근거를 확인하세요. 명시적 취소·거절은 이전 승인보다 우선하며 알림만으로 재실행하지 마세요."
                        } else {
                            message = "Hird run stopped \(context) reason=\(reason)\nRead get_run and read_run_output for the exact failed run. Continue necessary corrections within the existing user-authorized goal by saving a revised proposal and approving its exact version. Do not ask the user to repeat consent or perform your checks. Do not restart work the user explicitly stopped or rejected. Ask before expanding scope."
                        }
                    case .completion(let notificationID, let summary):
                        let instruction = readOnlyMirror ? projectSessionPolicy.mainReadOnlyMirrorMessage :
                            "이슈 담당이 저장된 완료 조건을 판정하고 보완을 마쳤어요. 저장된 판정·근거를 재사용해 승인된 목표의 통합과 프로젝트 후속 처리를 이어가세요. 알림은 병합이나 새 작업 승인이 아니며, 기존 승인 범위를 지키세요."
                        message = "Hird 완료 notificationID=\(notificationID) \(context)\n\(summary)\n" + instruction
                    case .proposalRevision(let version, let note):
                        if snapshot.issues.first(where: { $0.id == delivery.issueID })?.proposal?.version == version {
                            message = "사용자가 Hird 제안 v\(version)의 수정을 요청했어요. \(context)\n사용자 메모: \(note)\nget_issue로 확인한 뒤 update_issue_proposal로 제안을 수정하세요. 사용자 목표 범위 안이면 Stallari가 새 버전을 재승인하고 실행할 수 있어요. 범위를 넓히거나 거절·중단을 무시하지 마세요."
                        } else { message = nil }
                    }
                    if let message {
                        _ = try await followUp("deliveryID=\(delivery.id)\n" + message +
                            (readOnlyMirror ? "\n" + projectSessionPolicy.mainReadOnlyMirrorMessage : ""))
                    }
                    try await repository.markThreadDelivery(delivery.id, threadID: threadID, at: .now)
                } catch { if firstError == nil { firstError = error } }
            }
        } while notificationDrainRequested
        if let firstError { throw firstError }
        lastDeliveryError = nil
    }
    /// - Parameters:
    ///   - about: a Issue the message is about; its project comes with it.
    ///   - projectID: the project the user picked in the composer, if any.
    @discardableResult
    public func send(_ text: String, about: Issue.ID?, projectID: String? = nil, images: [OMPJSON] = [], messageID: UUID? = nil, conversationRootID: UUID? = nil, preparationID requestedPreparationID: String? = nil) async throws -> OMPJSON {
        try ensureOpen()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StallariError.invalidArguments }
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        let ownedID = snapshot.threads.first(where: { $0.id == threadID })?.issueID
        let about = about ?? ownedID
        let projectOwner = snapshot.threads.first(where: { $0.id == threadID })?.projectID
        guard projectOwner == nil || projectID == nil || projectID == projectOwner else {
            throw StallariError.rejectedEvidence(projectSessionPolicy.wrongProjectMessage)
        }
        var scopeID = projectOwner ?? projectID
        if let about { _ = try await issue(about, in: snapshot); scopeID = try await self.projectID(of: about) }
        let preparationID: String?
        if let rootID = conversationRootID {
            guard let root = snapshot.chat.first(where: { $0.id == rootID }), root.isConversationLink,
                  let link = snapshot.chatLinks.first(where: { $0.chatID == rootID && $0.conversationThreadID == threadID }) else { throw StallariError.invalidArguments }
            // Older issue-topic roots were stored under hub; the durable issue owner
            // already resolved above remains their project scope.
            if link.projectID != StoredProject.hubID {
                guard scopeID == nil || scopeID == link.projectID else { throw StallariError.wrongProject }
                scopeID = link.projectID
            }
            preparationID = root.preparationID
        } else { preparationID = requestedPreparationID }
        var context: String
        if let scopeID {
            let p = try project(scopeID, in: snapshot)
            context = "Project projectID=\(p.id) name=\(p.name) path=\(p.absolutePath)" + (about.map { " issueID=\($0.rawValue)" } ?? "")
        } else {
            context = "All projects (call list_projects to see them)"
        }
        if let scopeID, let owner = snapshot.projects.first(where: { $0.id == scopeID }), owner.settings.workspaceStyle == .preparation {
            context += "\nWorkspace style: preparation/archive. Read saved items with list_preparations; use preparation tools for drafts/progress. Preserve original materials. Submission is unconfirmed unless explicitly recorded."
            if let preparationID {
                guard let item = snapshot.preparationItems.first(where: { $0.id == preparationID && $0.projectID == scopeID }) else { throw StallariError.wrongProject }
                context += "\nSelected preparation itemID=" + item.id + " revision=" + String(item.revision) + ". Selection is context only."
            }
        }
        var sourceContext = ""
        if let rootID = conversationRootID {
            guard let root = snapshot.chat.first(where: { $0.id == rootID }), root.isConversationLink,
                  snapshot.chatLinks.contains(where: { $0.chatID == rootID && $0.conversationThreadID == threadID }) else { throw StallariError.invalidArguments }
            if case .user(let source) = root.kind {
                sourceContext = "Focused conversation source (quoted context): " + source + "\nCurrent reply:\n"
            }
        }
        if conversationRootID == nil, responseConversationRootID != nil,
           try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"]?["isStreaming"]?.bool == true {
            throw StallariSteerError.messageConversationAnswer
        }
        responseConversationRootID = conversationRootID
        let metadata = "\n<knarr-message messageID=\"\(messageID?.uuidString ?? "")\" conversationRootID=\"\(conversationRootID?.uuidString ?? "main")\" />\n"
        return try await followUp(context + metadata + sourceContext + text, images: images, steer: conversationRootID == nil)
    }
    @discardableResult
    private func followUp(_ message: String, images: [OMPJSON] = [], steer: Bool = false) async throws -> OMPJSON {
        try ensureOpen()
        guard !resettingContext, !selectingModel else { throw StallariThinkingError.busy }
        guard !reloading else { throw StallariThinkingError.busy }
        var state = try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: requestedThinking)
        if let pending = pendingModel, state["isStreaming"]?.bool != true {
            selectingModel = true
            defer { selectingModel = false }
            state = try await StallariRuntimePolicy.selectModel(pending, rpc: rpc, hird: hird, thinking: requestedThinking)
            if pendingModel == pending { pendingModel = nil }
        }
        let rules = try responseRules?.load()
        // Sticky rules are re-read here, so settings edits and chat edits apply to the next
        // request without restarting the RPC process. A load failure fails this request closed.
        let currentInstructions: InstructionSet?
        if let instructionsDirectory {
            do {
                let loaded = try InstructionSources.load(dataDirectory: instructionsDirectory, role: .stallari, projectID: instructionProjectID)
                currentInstructions = loaded
                instructionLoadError = nil
            } catch {
                instructionLoadError = error.localizedDescription
                throw StallariError.rejectedEvidence("지침 파일을 읽지 못해 요청을 보내지 않았어요. 설정에서 지침 파일을 확인해 주세요: " + error.localizedDescription)
            }
        } else { currentInstructions = nil }
        let owned = currentInstructions.map { $0.rules.isEmpty ? "" : "Current user-owned rules (Markdown; subordinate to fixed safety/tool contracts; not approval to act):\n" + $0.rules + "\n\n" } ?? ""
        let prepared = owned + (try rules.map { try ResponseRulesFile.applying(text: $0, to: message) } ?? message)
        let notice = extensionNotice
        var fields: [String: OMPJSON] = ["message": .string((notice.map { "<system-reminder>\n\($0)\n</system-reminder>\n" } ?? "") + prepared)]
        if !images.isEmpty { fields["images"] = .array(images) }
        // User input steers at the next engine boundary, including races with a new turn.
        // Completion notifications retain their existing follow-up delivery semantics.
        if steer || state["isStreaming"]?.bool == true {
            fields["streamingBehavior"] = .string(steer ? "steer" : "followUp")
        }
        let response = try await rpc.request("prompt", fields: fields, timeout: .seconds(10))
        if extensionNotice == notice { extensionNotice = nil }
        appliedResponseRulesVersion = rules.map(ResponseRulesFile.version)
        appliedInstructionsVersion = currentInstructions?.version
        return response
        // This is RPC admission, not prompt_result, settled, verification, or judgement.
    }
    public func ask(id: String, runID: HirdRun.ID, issueID: Issue.ID, prompt: String, options: [String]) async throws -> String {
        let snapshot = try await scope()
        _ = try await issue(issueID, in: snapshot)
        guard let run = snapshot.runs.first(where: { $0.id == runID }), run.issueID == issueID else { throw StallariError.missingRun }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Set(options).count == options.count else { throw StallariError.invalidArguments }
        if let old = snapshot.questions.first(where: { $0.id == id }) {
            guard old.runID == runID, old.issueID == issueID, old.prompt == prompt, old.options == options else { throw StallariError.conflictingID }
            return id
        }
        guard !run.state.isTerminal else { throw StallariError.terminalRun }
        let now = Date.now
        let q = PersistedQuestion(id: id, runID: runID, issueID: issueID, prompt: prompt, options: options, createdAt: now, source: .stallari)
        let outcome = try await repository.recordEvent(id: "ask:\(id)", runID: runID, at: now, payload: .ask(q))
        guard outcome == .applied else { throw StallariError.terminalRun }
        return id
    }
    private func question(_ id: String, runID: HirdRun.ID, issueID: Issue.ID) async throws -> PersistedQuestion {
        let snapshot = try await scope()
        _ = try await issue(issueID, in: snapshot)
        guard let q = snapshot.questions.first(where: { $0.id == id }), q.runID == runID, q.issueID == issueID,
              snapshot.runs.contains(where: { $0.id == runID && $0.issueID == issueID }) else { throw StallariError.conflictingID }
        return q
    }
    public func answer(questionID: String, runID: HirdRun.ID, issueID: Issue.ID, answer: QuestionAnswer, requirePending: Bool = false) async throws -> MutationOutcome {
        _ = try await question(questionID, runID: runID, issueID: issueID)
        let outcome = try await repository.answerQuestion(questionID, runID: runID, answer: answer, at: .now, requirePending: requirePending)
        if outcome == .applied || outcome == .duplicate { try await deliverAnswers() }
        return outcome
    }
    public func cancelQuestion(questionID: String, runID: HirdRun.ID, issueID: Issue.ID) async throws -> MutationOutcome {
        _ = try await question(questionID, runID: runID, issueID: issueID)
        let outcome = try await repository.cancelQuestion(questionID, runID: runID, at: .now)
        if outcome == .applied || outcome == .duplicate { try await deliverAnswers() }
        return outcome
    }
    public func deliverAnswers() async throws {
        try ensureOpen()
        guard responseConversationRootID == nil else { return }
        answerDrainRequested = true
        guard !flushingAnswers else { return }
        flushingAnswers = true; defer { flushingAnswers = false }
        var attempted: Set<String> = []
        var firstError: (any Error)?
        repeat {
            answerDrainRequested = false
            let snapshot = try await scope()
            for q in snapshot.questions where q.state != .pending && q.deliveredAt == nil && !attempted.contains(q.id) {
                attempted.insert(q.id)
                guard snapshot.issues.first(where: { $0.id == q.issueID })?.conversationThreadID == threadID else { continue }
                guard let run = snapshot.runs.first(where: { $0.id == q.runID }), !run.state.isTerminal else { continue }
                let fresh = try await scope()
                guard fresh.runs.contains(where: { $0.id == q.runID && !$0.state.isTerminal }) else { continue }
                do {
                    // Adapter must also fence cancelled process generations and deduplicate deliveryID.
                    try await hird.deliver(.init(questionID: q.id, runID: q.runID, issueID: q.issueID, answer: q.answer, cancelled: q.state == .cancelled))
                    if q.source == .stallari {
                        let answer = try q.answer.map { try jsonText(encoded($0)) } ?? "null"
                        try await followUp("Question response questionID=\(q.id) runID=\(q.runID.rawValue) issueID=\(q.issueID.rawValue) cancelled=\(q.state == .cancelled) answer=\(answer)")
                    }
                    _ = try await repository.markQuestionDelivered(id: q.id, runID: q.runID, at: .now)
                } catch { if firstError == nil { firstError = error } }
            }
        } while answerDrainRequested
        if let firstError { throw firstError }
    }
    public func getRun(_ id: HirdRun.ID) async throws -> PersistedRun {
        let snapshot = try await scope()
        guard snapshot.runs.contains(where: { $0.id == id }) else { throw StallariError.missingRun }
        let run = try await repository.readRun(id, includeHistory: false)
        _ = try project(run.projectID, in: snapshot)
        _ = try await issue(run.issueID, in: snapshot, reading: true)
        return run
    }
    public func getRuntime() async throws -> OMPJSON {
        try ensureOpen()
        let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        let available = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))
        let models = (available["data"]?["models"]?.array ?? []).compactMap { value -> OMPJSON? in
            guard let provider = value["provider"]?.string, !provider.isEmpty,
                  let id = value["id"]?.string, !id.isEmpty else { return nil }
            return .string(provider + "/" + id)
        }
        return .object(["stallariModel": state["model"] ?? .null,
            "stallariRequestedThinking": requestedThinking.map(OMPJSON.string) ?? state["thinkingLevel"] ?? .null, "stallariThinking": state["thinkingLevel"] ?? .null,
            "requestedModel": requestedModel.map(OMPJSON.string) ?? .null,
            "pendingModel": pendingModel.map(OMPJSON.string) ?? .null,
            "hirdDefaultModel": await hird.modelForNewRuns().map(OMPJSON.string) ?? .null,
            "hirdRequestedThinking": .string("xhigh"),
            "pendingThinking": pendingThinking.map(OMPJSON.string) ?? .null, "availableModels": .array(models),
            "capabilities": .array((state["dumpTools"]?.array ?? []).compactMap { $0["name"]?.string.map(OMPJSON.string) }),
            "projectTransferBridge": .object(["version": .number(1), "tool": .string(ProjectTransferProtocol.bridgeTool),
                "receiptType": .string(ProjectTransferProtocol.messageType), "contextOnly": .bool(true)]),
            "extensionReload": lastExtensionReload ?? .null,
            "responseRulesPath": responseRules.map { .string($0.url.path) } ?? .null,
            "appliedResponseRulesVersion": appliedResponseRulesVersion.map(OMPJSON.string) ?? .null,
            "instructionsDirectory": instructionsDirectory.map { .string($0.appendingPathComponent(InstructionSources.directoryName).path) } ?? .null,
            "appliedInstructionsVersion": appliedInstructionsVersion.map(OMPJSON.string) ?? .null,
            "instructionLoadError": instructionLoadError.map(OMPJSON.string) ?? .null,
            "activeRuns": .array(try await scope().runs.filter { !$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil) }.suffix(20).map(StallariReadback.run))])
    }
    private func setProjectSettings(_ a: OMPJSON) async throws -> OMPJSON {
        let snapshot = try await scope()
        var owner = try project(required(a, "projectID"), in: snapshot)
        if let projectID = snapshot.threads.first(where: { $0.id == threadID })?.projectID,
           projectID != owner.id { throw StallariError.wrongProject }
        guard owner.archivedAt == nil else { throw StallariError.wrongProject }
        let before = owner.settings
        if let value = a["workspaceStyle"] {
            guard let text = value.string, let style = ProjectSettings.WorkspaceStyle(rawValue: text) else { throw StallariError.invalidArguments }
            owner.settings.workspaceStyle = style
        }
        if let value = a["maxHirds"] {
            guard let n = value.integer, n >= 0 else { throw StallariError.invalidArguments }
            owner.settings.maxHirds = n
        }
        if let value = a["hirdThinking"] {
            guard let level = value.string, ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(level) else { throw StallariThinkingError.unsupported }
            owner.settings.hirdThinking = level
        }
        if let value = a["hirdModel"] {
            if value == .null { owner.settings.hirdModel = nil }
            else {
                let models = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))["data"]?["models"]?.array ?? []
                guard let model = value.string, models.contains(where: { ($0["provider"]?.string ?? "") + "/" + ($0["id"]?.string ?? "") == model }) else { throw StallariError.invalidArguments }
                owner.settings.hirdModel = model
            }
        }
        try await repository.saveProject(owner)
        return .object(["projectID": .string(owner.id), "before": try encoded(before), "after": try encoded(owner.settings), "appliesTo": .string("newProposals"), "activeRunsChanged": .bool(false)])
    }
    public func selectThinking(_ level: String) async throws -> OMPJSON {
        try ensureOpen()
        try ensureWritableThread(in: await scope())
        let state = try await StallariRuntimePolicy.ensureThinking(rpc: rpc, level: level)
        requestedThinking = level
        await persistThinking?(level)
        return state
    }
    @discardableResult public func selectModel(_ model: String) async throws -> OMPJSON {
        try ensureOpen()
        try ensureWritableThread(in: await scope())
        guard !selectingModel else { throw StallariThinkingError.busy }
        selectingModel = true
        defer { selectingModel = false }
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        let models = try await rpc.request("get_available_models", fields: [:], timeout: .seconds(10))["data"]?["models"]?.array ?? []
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              models.contains(where: { $0["provider"]?.string == parts[0] && $0["id"]?.string == parts[1] }) else { throw StallariError.invalidArguments }
        var state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        if state["isStreaming"]?.bool == true {
            pendingModel = model
        } else {
            state = try await StallariRuntimePolicy.selectModel(model, rpc: rpc, hird: hird, thinking: requestedThinking)
            pendingModel = nil
        }
        requestedModel = model
        await persistModel?(model)
        return modelState(state)
    }
    private func modelState(_ state: OMPJSON) -> OMPJSON {
        guard case .object(var values) = state else { return state }
        values["requestedModel"] = requestedModel.map(OMPJSON.string) ?? .null
        values["pendingModel"] = pendingModel.map(OMPJSON.string) ?? .null
        return .object(values)
    }
    public func steerRun(_ id: HirdRun.ID, instruction: String) async throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StallariError.invalidArguments }
        let run = try await getRun(id)
        _ = try await issue(run.issueID, in: scope())
        guard !run.state.isTerminal else { throw StallariError.terminalRun }
        try await hird.steer(instruction, runID: id)
    }
    public func cancelRun(_ id: HirdRun.ID) async throws -> MutationOutcome {
        let run = try await getRun(id)
        _ = try await issue(run.issueID, in: scope())
        let outcome = try await repository.cancelRun(id, at: .now, reason: "사용자가 실행을 취소했어요")
        guard outcome != .ignoredTerminal else { return outcome }
        starts[id]?.cancel()
        await hird.cancel(id)
        if let task = starts.removeValue(forKey: id) { await task.value }
        if await hird.terminationConfirmed(id) { _ = try await repository.markProcessEnded(id, at: .now) }
        do { try await deliverNotifications() } catch { lastDeliveryError = "멈춤 알림이 저장되어 다음 연결에서 다시 전달돼요" }
        return outcome
    }
    @discardableResult public func judge(issueID: Issue.ID, runID: HirdRun.ID, evidence: [CriterionEvidence]) async throws -> Issue {
        try ensureOpen()
        let snapshot = try await repository.snapshot(includeHistory: false)
        var target = try await issue(issueID, in: snapshot)
        let projectID = try await projectID(of: issueID)
        let own = snapshot.runs.filter { $0.issueID == issueID }
        guard target.state != .awaitingApproval, target.state != .rejected,
              target.proposal == nil || (target.approval?.version == target.proposal?.version && target.approval?.runID == runID) else {
            throw StallariError.rejectedEvidence("승인 대기·거절된 제안은 이전 실행 결과로 판정할 수 없어요.")
        }
        guard let run = own.last, run.id == runID, run.projectID == projectID, run.state == .succeeded,
              let result = run.result,
              run.mode == .inspect ? !(result.reportPath?.isEmpty ?? true) : (!(result.commit?.isEmpty ?? true) || !(result.diffPath?.isEmpty ?? true)),
              !target.acceptance.isEmpty, evidence.count == target.acceptance.count,
              Set(evidence.map(\.criterionIndex)) == Set(target.acceptance.indices) else { throw StallariError.missingEvidence }
        // A saved review is the reviewer's record of the evidence it actually examined. When that
        // record no longer matches the current result, criteria wording, selection or delivered
        // bytes, it cannot support a completion: the issue stays open and the reviewer has to
        // re-read the current evidence and re-review explicitly. Recording an unmet criterion is
        // still allowed, and a run without any saved review keeps the legacy path.
        if evidence.allSatisfy(\.met), let review = run.review {
            let stale = invalidations(of: review, issue: target, run: run, latestRunID: run.id.rawValue)
            if stale.isStale {
                let reasons = stale.reasons.isEmpty ? "unknown" : stale.reasons.joined(separator: ", ")
                throw StallariError.rejectedEvidence(
                    "저장된 검토가 현재 결과와 맞지 않아 완료로 판정할 수 없어요 (\(reasons)). "
                    + "현재 증거를 다시 읽은 뒤 save_review(refresh: true)로 검토 기준을 갱신하고, 그다음 judge_issue를 호출하세요.")
            }
        }
        for item in evidence {
            guard !item.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(item.verificationIDs).count == item.verificationIDs.count else { throw StallariError.missingEvidence }
            let records = item.verificationIDs.compactMap { id in result.verifications.first(where: { $0.id == id }) }
            guard records.count == item.verificationIDs.count else { throw StallariError.missingEvidence }
            if item.met {
                guard !records.isEmpty else { throw StallariError.rejectedEvidence("criterion \(item.criterionIndex): cite a saved command or inspection evidence ID, or judge it met=false") }
                for r in records {
                    let facts = StallariReadback.facts(r)
                    if facts.usableAsProof { continue }
                    switch facts.reason {
                    case "compositeCommand":
                        throw StallariError.rejectedEvidence("verification \(r.id) chains several commands (; | || newline &), so its exit code does not prove criterion \(item.criterionIndex). Ask Hird to run each check as its own command, or judge it met=false.")
                    case "nonzeroExit", "exitCodeUnknown":
                        throw StallariError.rejectedEvidence("verification \(r.id) did not exit 0, so it cannot show criterion \(item.criterionIndex) is met. Judge it met=false with the reason.")
                    default:
                        throw StallariError.missingEvidence
                    }
                }
            }
            target.acceptance[item.criterionIndex].state = item.met ? .met : .unmet
            target.acceptance[item.criterionIndex].evidence = item.explanation
                + (item.verificationIDs.isEmpty ? "" : " [" + item.verificationIDs.joined(separator: ", ") + "]")
        }
        let unmet = target.acceptance.filter { $0.state != .met }
        if unmet.isEmpty {
            target.state = .done; target.headline = "완료 조건 충족"; target.detail = result.summary
        } else {
            target.state = .failed; target.headline = "완료 조건 미충족 \(unmet.count)개"
            target.detail = unmet.map { "\($0.text): \($0.evidence)" }.joined(separator: "\n")
        }
        target.hirds = []; target.events = []
        try await repository.saveIssue(target, projectID: projectID, expectedJudgementRun: run)
        // The saved review never substitutes for this judgement. A review is only marked as
        // judged when its recorded basis still matches the run and issue that were just judged;
        // a stale one keeps its earlier notes and stays visibly due for re-review. Judging
        // without any saved review (legacy path) is unchanged.
        _ = try await repository.updateReview(runID: runID) { existing, currentIssue, currentRun in
            guard var review = existing else { return nil }
            let basis = StallariReview.basis(issue: currentIssue, run: currentRun)
            let current = review.runID == run.id.rawValue
                && review.resultVersion == basis.resultVersion
                && review.criteriaHash == basis.criteriaHash
                && review.proposalVersion == basis.proposalVersion
                && review.approvalVersion == basis.approvalVersion
                && review.carriedFromVersion == nil
            if current {
                review.judgedAt = .now
                return review
            }
            return nil
        }
        return target
    }
    private func observe(_ event: OMPEvent) async {
        guard !closed else { return }
        switch event {
        case .terminated: break
        case .frame(let frame):
            guard let type = frame["type"]?.string else { return }
            // Bound diagnostics contain event types only, never arbitrary model/provider payloads.
            if type == "knarr_rpc_ready" { bridgeGeneration = frame["generation"]?.string }
            if type == "knarr_rpc_ready", !reloading, let result = frame["reload"],
               let errors = result["errors"]?.array, !errors.isEmpty { initialExtensionFailure = result }
            if observedEventTypes.count >= 128 { observedEventTypes.removeFirst() }
            observedEventTypes.append(type)
            if ProjectTransferProtocol.isBridgeFrame(frame) { scheduleProjectTransferInput(frame) }
            else if type == "host_tool_call" { scheduleHostCall(frame) }
            else if type == "host_tool_cancel", let target = frame["targetId"]?.string {
                cancelledCalls.insert(target); hostTasks[target]?.cancel()
            } else if type == "session_settled" {
                if reloadRequested {
                    do { _ = try await reloadExtensionsNow() }
                    catch { lastDeliveryError = "확장을 다시 불러오지 못했어요. 연결을 확인해 주세요" }
                }
                do {
                    if let model = pendingModel {
                        _ = try await selectModel(model)
                    }
                    if let thinking = pendingThinking {
                        _ = try await selectThinking(thinking)
                        pendingThinking = nil
                    }
                    try await deliverNotifications(); try await deliverAnswers()
                    scheduleProjectTransferDrain()
                }
                catch { lastDeliveryError = "저장된 후속 전달이 미완료예요" }
            }
        }
    }
    private func scheduleHostCall(_ frame: OMPJSON) {
        guard let id = frame["id"]?.string else { return }
        if let old = hostCalls[id], old != frame { return }
        if hostTasks[id] != nil || cancelledCalls.contains(id) { return }
        hostCalls[id] = frame
        hostTasks[id] = Task { [weak self] in await self?.executeHostCall(frame, id: id) }
    }
    private func executeHostCall(_ frame: OMPJSON, id: String) async {
        defer { hostTasks.removeValue(forKey: id) }
        var reply = hostReplies[id]
        if reply == nil {
            do {
                try Task.checkCancellation()
                let details = try await performTool(frame["toolName"]?.string ?? "", arguments: frame["arguments"] ?? .null)
                reply = ["id": .string(id), "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(try jsonText(details))])]), "details": details])]
            } catch {
                var message = "요청의 식별자·상태·저장된 검증 근거를 확인해 주세요"
                if case StallariError.rejectedEvidence(let reason)? = error as? StallariError { message = reason }
                if let error = error as? SessionAPIError { message = error.localizedDescription }
                reply = ["id": .string(id), "isError": .bool(true), "result": .object(["content": .array([.object([
                    "type": .string("text"), "text": .string(message)])]), "details": .object(["error": .string("stallari_request_rejected")])])]
            }
            if let generation = frame["knarrRPCGeneration"] { reply?["knarrRPCGeneration"] = generation }
            hostReplies[id] = reply
        }
        guard !closed, !cancelledCalls.contains(id), let reply else { return }
        do {
            try await rpc.send("host_tool_result", fields: reply)
        } catch OMPRPCError.invalidFrame {
            // Never leave the model waiting for an oversized reply that cannot be sent.
            var fallback: [String: OMPJSON] = ["id": .string(id), "isError": .bool(true),
                "result": .object(["content": .array([.object(["type": .string("text"),
                    "text": .string("도구 결과가 전송 한도를 넘었어요. get_run 또는 read_run_output을 작은 페이지로 조회해 주세요.")])]),
                    "details": .object(["error": .string("host_tool_response_too_large")])])]
            if let generation = frame["knarrRPCGeneration"] { fallback["knarrRPCGeneration"] = generation }
            hostReplies[id] = fallback
            do { try await rpc.send("host_tool_result", fields: fallback) }
            catch { lastDeliveryError = "도구 결과를 전달하지 못했어요. 연결을 다시 확인해 주세요" }
        } catch {
            lastDeliveryError = "도구 결과를 전달하지 못했어요. 연결을 다시 확인해 주세요"
        }
    }
    private func jsonText(_ value: OMPJSON) throws -> String { String(decoding: try value.jsonLine().dropLast(), as: UTF8.self) }

    // MARK: - Durable review state

    private func latestRunID(issueID: Issue.ID) async throws -> String {
        let snapshot = try await scope()
        return snapshot.runs.last(where: { $0.issueID == issueID })?.id.rawValue ?? ""
    }

    /// A read is only recorded; it never marks anything reviewed or complete. When the basis
    /// changed, the reviewer's own notes and open items carry forward and the record is marked
    /// as needing review. That marker is cleared only by `save_review(refresh: true)` after the
    /// current evidence was actually re-read; a plain read or note save keeps it.
    nonisolated private func reviewForCurrentBasis(_ existing: StallariReview?, issue: Issue, run: PersistedRun) -> StallariReview {
        let basis = StallariReview.basis(issue: issue, run: run)
        let matches = existing?.runID == run.id.rawValue
            && existing?.resultVersion == basis.resultVersion
            && existing?.criteriaHash == basis.criteriaHash
            && existing?.proposalVersion == basis.proposalVersion
            && existing?.approvalVersion == basis.approvalVersion
        if matches, let existing {
            // The record may already sit on the current basis while its notes were carried over
            // from an older one; only the explicit refresh clears that.
            return existing
        }
        var value = StallariReview(issueID: issue.id.rawValue, runID: run.id.rawValue,
            resultVersion: basis.resultVersion, proposalVersion: basis.proposalVersion,
            approvalVersion: basis.approvalVersion, criteriaHash: basis.criteriaHash)
        if let existing {
            value.revision = existing.revision
            value.notes = existing.notes
            value.openItems = existing.openItems
            value.selectedVerificationIDs = existing.selectedVerificationIDs
            value.reads = existing.reads
            value.carriedFromVersion = existing.resultVersion
        }
        return value
    }

    private func recordReviewRead(run: PersistedRun, issue: Issue) async throws {
        guard let result = run.result, !result.verifications.isEmpty else { return }
        _ = try await repository.updateReview(runID: run.id,
            expectedResultVersion: StallariReview.version(of: run.result)) { [self] existing, target, current in
            let value = reviewForCurrentBasis(existing, issue: target, run: current)
            return value == existing ? nil : value
        }
    }

    /// The excerpt owns its delivered bytes and hashes before any suspension. Append to the
    /// current review atomically so a simultaneous note or another log read cannot be lost.
    private func rememberRead(runID: HirdRun.ID, verificationID: String,
                              excerpt: StallariReadback.Excerpt, mode: String,
                              expectedResultVersion: String, basisToken: String) async throws {
        let segments = StallariReadback.segments(for: excerpt)
        guard !segments.isEmpty else { return }
        let read = StallariReview.Read(verificationID: verificationID, logPath: excerpt.path,
            segments: segments, fileBytes: excerpt.total, mode: mode, at: .now, basisVersion: basisToken)
        _ = try await repository.updateReview(runID: runID, expectedResultVersion: expectedResultVersion) { existing, _, _ in
            guard var review = existing else { return nil }
            review.reads.removeAll {
                $0.verificationID == verificationID && $0.mode == mode && $0.segments == segments
            }
            review.reads.append(read)
            review.selectedVerificationIDs.removeAll { $0 == verificationID }
            review.selectedVerificationIDs.append(verificationID)
            return review
        }
    }

    /// One opaque label for the whole basis (result, proposal, approval, criteria wording).
    nonisolated private func basisToken(issue: Issue, run: PersistedRun) -> String {
        let basis = StallariReview.basis(issue: issue, run: run)
        return StallariReview.token(resultVersion: basis.resultVersion, proposalVersion: basis.proposalVersion,
                                    approvalVersion: basis.approvalVersion, criteriaHash: basis.criteriaHash)
    }

    /// The saved review invalidations against the run and issue as they are now. `unreadable`
    /// files count as changed, because their delivered bytes can no longer be confirmed.
    private func invalidations(of review: StallariReview, issue: Issue, run: PersistedRun,
                               latestRunID: String) -> StallariReview.Invalidations {
        let basis = StallariReview.basis(issue: issue, run: run)
        return review.invalidations(
            resultVersion: basis.resultVersion, proposalVersion: basis.proposalVersion,
            approvalVersion: basis.approvalVersion, criteriaHash: basis.criteriaHash,
            latestRunID: latestRunID, availableVerificationIDs: Set((run.result?.verifications ?? []).map(\.id)),
            currentBasisToken: StallariReview.token(resultVersion: basis.resultVersion,
                                                    proposalVersion: basis.proposalVersion,
                                                    approvalVersion: basis.approvalVersion,
                                                    criteriaHash: basis.criteriaHash),
            segmentBytes: { path, start, end in
                let size = StallariReadback.logSize(path)
                guard size >= 0, let data = StallariReadback.readBytes(path, start: start, end: end) else { return nil }
                return (data, size)
            })
    }

    /// One explicit tool call saves the reviewer's own notes; nothing here decides a criterion.
    /// `refresh: true` is the only way to accept a changed basis: it requires that the evidence
    /// for this run was actually re-read under the current basis, then rebases the record and
    /// clears the carried-over marker. Notes and open items are kept either way.
    private func saveReview(_ run: PersistedRun, arguments a: OMPJSON) async throws -> OMPJSON {
        let snapshot = try await scope()
        _ = try await issue(run.issueID, in: snapshot, reading: true)
        guard let saved = try await repository.updateReview(runID: run.id,
            expectedResultVersion: StallariReview.version(of: run.result), update: { [self] existing, target, current in
                try reviewApplying(a, existing: existing, target: target, run: current)
            }) else { throw StallariError.invalidArguments }
        return .object(["status": .string("saved"), "runID": .string(run.id.rawValue),
                        "selectedVerificationIDs": .array(saved.selectedVerificationIDs.map(OMPJSON.string)),
                        "noteCount": .number(Double(saved.notes.count)),
                        "openItems": .array(saved.openItems.map(OMPJSON.string)),
                        "readingIsNotCompletion": .bool(true)])
    }

    nonisolated private func reviewApplying(_ a: OMPJSON, existing: StallariReview?,
                                            target: Issue, run: PersistedRun) throws -> StallariReview {
        let refresh = a["refresh"]?.bool == true
        var review = reviewForCurrentBasis(existing, issue: target, run: run)
        let token = basisToken(issue: target, run: run)
        if refresh {
            let available = Set((run.result?.verifications ?? []).map(\.id))
            let required = review.selectedVerificationIDs.filter(available.contains)
            let requiredSet = required.isEmpty ? available : Set(required)
            // A result token does not change when only a log's bytes change. Validate the
            // delivered ranges as well; a token match alone is not a reread of current bytes.
            let matches = review.reads.map { read in
                guard read.supersededAt == nil,
                      read.basisVersion == nil || read.basisVersion == token else { return false }
                return StallariReview.matchesCurrentFile(read) { path, start, end in
                    let size = StallariReadback.logSize(path)
                    guard size >= 0, let data = StallariReadback.readBytes(path, start: start, end: end) else { return nil }
                    return (data, size)
                }
            }
            let fresh = review.reads.indices.filter { matches[$0] && review.reads[$0].basisVersion == token }
                .map { review.reads[$0] }
            let currentReads = Set(fresh.map(\.verificationID))
            let missing = requiredSet.subtracting(currentReads).sorted()
            guard missing.isEmpty else {
                throw StallariError.rejectedEvidence(
                    "검토 기준을 갱신하려면 현재 결과의 증거를 다시 읽어야 해요: \(missing.joined(separator: ", ")). "
                    + "read_run_output으로 원문을 확인한 뒤 다시 시도하세요.")
            }
            let changed = review.reads.indices.filter {
                let read = review.reads[$0]
                return read.supersededAt == nil && !matches[$0]
                    && (read.basisVersion == nil || read.basisVersion == token)
            }
            // Retire a changed historical read only when current reads cover what it showed.
            // A different, unchanged fragment of the same file cannot clear that obligation.
            func covered(_ prior: StallariReview.Read) -> Bool {
                let replacements = fresh.filter { $0.verificationID == prior.verificationID && $0.logPath == prior.logPath }
                guard let size = replacements.first?.fileBytes,
                      replacements.allSatisfy({ $0.fileBytes == size }) else { return false }
                let ranges = replacements.flatMap(\.segments).sorted { $0.start < $1.start }
                let requiredRanges = size == prior.fileBytes ? prior.segments : [.init(start: 0, end: size, hash: "")]
                return requiredRanges.allSatisfy { needed in
                    var cursor = needed.start
                    for range in ranges where range.end > cursor {
                        guard range.start <= cursor else { return false }
                        cursor = max(cursor, range.end)
                        if cursor >= needed.end { return true }
                    }
                    return cursor >= needed.end
                }
            }
            let uncovered = Set(changed.filter { !covered(review.reads[$0]) }.map { review.reads[$0].verificationID }).sorted()
            guard uncovered.isEmpty else {
                throw StallariError.rejectedEvidence("바뀐 원문 구간을 다시 읽어야 해요: \(uncovered.joined(separator: ", ")).")
            }
            let refreshedAt = Date.now
            for index in changed { review.reads[index].supersededAt = refreshedAt }
            review.carriedFromVersion = nil
            review.judgedAt = nil
        }
        if let note = a["note"]?.string {
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StallariError.invalidArguments }
            var criterion: Int?
            if let input = a["criterion"] {
                guard let index = input.integer, target.acceptance.indices.contains(index) else {
                    throw StallariError.rejectedEvidence("완료 조건 번호가 이 이슈의 범위를 벗어났어요.")
                }
                criterion = index
            }
            review.notes.append(.init(text: text, criterion: criterion, at: .now))
        }
        if let items = a["openItems"]?.array {
            guard items.allSatisfy({ $0.string != nil }) else { throw StallariError.invalidArguments }
            review.openItems = items.compactMap(\.string)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let ids = a["selectedVerificationIDs"]?.array {
            guard ids.allSatisfy({ $0.string != nil }) else { throw StallariError.invalidArguments }
            let values = ids.compactMap(\.string)
            let available = Set((run.result?.verifications ?? []).map(\.id))
            guard Set(values).count == values.count, values.allSatisfy(available.contains) else {
                throw StallariError.rejectedEvidence("이 실행에 저장되지 않은 검증 ID는 선택할 수 없어요.")
            }
            review.selectedVerificationIDs = values
        }
        return review
    }

    private func encoded<T: Encodable>(_ value: T) throws -> OMPJSON { try JSONDecoder().decode(OMPJSON.self, from: JSONEncoder().encode(value)) }
    private func required(_ a: OMPJSON, _ key: String) throws -> String {
        guard let value = a[key]?.string, !value.isEmpty else { throw StallariError.invalidArguments }; return value
    }
    private func stringArray(_ a: OMPJSON, _ key: String) throws -> [String] {
        guard let values = a[key]?.array, values.allSatisfy({ $0.string != nil }) else { throw StallariError.invalidArguments }
        return values.compactMap(\.string)
    }
    private func proposalStages(_ a: OMPJSON) throws -> [IssueStage]? {
        guard let input = a["stages"] else { return nil }
        guard let values = input.array else { throw StallariError.invalidArguments }
        let titles = try values.map { value -> (title: String, evidence: String, criterion: Int?) in
            guard case .object(let fields) = value,
                  Set(fields.keys).isSubset(of: ["title", "evidence", "criterion"]),
                  let title = fields["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let evidence = fields["evidence"]?.string, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StallariError.invalidArguments
            }
            var criterion: Int?
            if let input = fields["criterion"] {
                guard let number = input.integer, number > 0 else { throw StallariError.invalidArguments }
                criterion = number
            }
            return (title, evidence, criterion)
        }
        return IssueStage.plan(titles: titles)
    }
    private func runMode(_ a: OMPJSON) throws -> HirdRunMode {
        guard let value = a["mode"] else { return .change }
        guard let text = value.string, let mode = HirdRunMode(rawValue: text) else { throw StallariError.invalidArguments }
        return mode
    }
    func performTool(_ name: String, arguments a: OMPJSON) async throws -> OMPJSON {
        switch name {
        case "list_preparations", "list_projects", "list_milestones", "get_issue", "get_run", "read_run_output", "get_runtime", "list_sessions", "search_sessions", "read_session": break
        default: try ensureWritableThread(in: await scope())
        }
        switch name {
        case "link_message_conversation":
            try ensureOpen()
            guard let id = UUID(uuidString: try required(a, "messageID")) else { throw StallariError.invalidArguments }
            try await repository.linkMessageConversation(id, threadID: threadID)
            responseConversationRootID = id
            return .object(["messageID": .string(id.uuidString), "status": .string("linked")])
        case ProjectTransferProtocol.bridgeTool:
            return try await performProjectTransferBridge(a)
        case "write_project_document":
            return try await writeProjectDocument(a)
        case "write_instruction_file":
            return try await writeInstructionFile(a)
        case "write_extension":
            try ensureOpen()
            guard let extensions, let source = a["source"]?.string else { throw StallariError.invalidArguments }
            let path = try extensions.writeStallari(name: required(a, "name"), source: source)
            return .object(["path": .string(path.path), "status": .string("written")])
        case "reload_extensions":
            try ensureOpen()
            guard restartRPC != nil else { throw StallariError.invalidArguments }
            reloadRequested = true
            let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
            if state["isStreaming"]?.bool != true && hostTasks.isEmpty { return try await reloadExtensionsNow() }
            return .object(["status": .string("queued_until_session_settled"), "notification": .string("Actual tools and loading errors will be supplied with the next turn.")])
        case "list_sessions", "search_sessions", "read_session":
            guard case .object(var request) = a else { throw StallariError.invalidArguments }
            request["operation"] = .string(name == "list_sessions" ? "list" : name == "search_sessions" ? "search" : "read")
            return try await sessionReader.query(.object(request))
        case "get_runtime": return try await getRuntime()
        case "set_model": return try await selectModel(required(a, "model"))
        case "set_project_settings": return try await setProjectSettings(a)
        case "list_preparations", "save_preparation", "save_preparation_draft", "add_preparation_record":
            return try await preparationTool(name, a)
        case "set_thinking":
            let level = try required(a, "level")
            let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
            let levels = try await rpc.request("get_available_thinking_levels", fields: [:], timeout: .seconds(10))["data"]?["levels"]?.array?.compactMap(\.string) ?? []
            guard levels.contains(level) else { throw StallariThinkingError.unsupported }
            if state["isStreaming"]?.bool == true {
                pendingThinking = level
                return .object(["status": .string("queued"), "before": state["thinkingLevel"] ?? .null, "after": .string(level)])
            }
            return try await selectThinking(level)
        case "approve_issue":
            let issueID = Issue.ID(try required(a, "issueID"))
            guard case .object(let fields) = a, Set(fields.keys).isSubset(of: ["issueID", "version"]),
                  let version = a["version"]?.integer, version > 0 else { throw StallariError.invalidArguments }
            let runID = try await approveIssue(issueID: issueID, version: version)
            return .object(["runID": .string(runID.rawValue), "version": .number(Double(version)), "status": .string("dispatched")])
        case "steer_run":
            let id = HirdRun.ID(try required(a, "runID"))
            try await steerRun(id, instruction: required(a, "instruction"))
            return .object(["run": StallariReadback.run(try await getRun(id)), "status": .string("accepted")])
        case "get_run", "read_run_output", "cancel_run", "save_review":
            let id = HirdRun.ID(try required(a, "runID"))
            let run = try await getRun(id)
            if name == "read_run_output" || name == "save_review" {
                let snapshot = try await scope()
                let target = try await issue(run.issueID, in: snapshot, reading: true)
                guard canRead(target, in: snapshot) else { throw StallariError.missingIssue }
            }
            if name == "cancel_run" {
                _ = try await cancelRun(id)
                let saved = try await getRun(id)
                return .object(["run": StallariReadback.run(saved), "cleanupVerified": .bool(saved.processEndedAt != nil)])
            }
            if name == "save_review" { return try await saveReview(run, arguments: a) }
            let offset = try StallariReadback.number(a, "offset", default: 0, maximum: Int.max / 2)
            if name == "get_run" {
                let limit = try StallariReadback.number(a, "limit", default: 10, maximum: 20)
                guard limit > 0 else { throw StallariError.invalidArguments }
                let view = a["view"]?.string ?? "checks"
                switch view {
                case "checks":
                    // Default stays oldest-first so the existing offset paging contract is
                    // unchanged; use order=newest to start from the latest checks.
                    let order: String
                    switch a["order"]?.string ?? "oldest" {
                    case "newest": order = "newest"
                    case "oldest": order = "oldest"
                    default: throw StallariError.invalidArguments
                    }
                    if let kind = a["kind"]?.string, !["command", "inspection"].contains(kind) { throw StallariError.invalidArguments }
                    if let status = a["status"]?.string,
                       !["passed", "failed", "unknown", "eligible", "ineligible"].contains(status) { throw StallariError.invalidArguments }
                    func time(_ key: String) throws -> Date? {
                        guard let text = a[key] else { return nil }
                        guard let raw = text.string, let value = Self.date(raw) else {
                            throw StallariError.rejectedEvidence("\(key)는 yyyy-MM-dd 또는 ISO 8601 시각이어야 해요.")
                        }
                        return value
                    }
                    let query = StallariReadback.CheckQuery(
                        query: a["query"]?.string, kind: a["kind"]?.string, status: a["status"]?.string,
                        since: try time("since"), until: try time("until"),
                        verificationID: a["verificationID"]?.string, order: order, offset: offset, limit: limit)
                    return try StallariReadback.checks(run, query: query, cursorText: a["cursor"]?.string)
                case "review":
                    let latest = try await latestRunID(issueID: run.issueID)
                    let snapshot = try await scope()
                    let target = try await issue(run.issueID, in: snapshot, reading: true)
                    return StallariReadback.reviewReadback(run: run, issue: target, latestRunID: latest, review: run.review)
                case "status":
                    return .object(["run": StallariReadback.run(run), "resultVersion": .string(StallariReview.version(of: run.result)),
                                    "review": .bool(run.review != nil)])
                default: throw StallariError.invalidArguments
                }
            }
            let limit = try StallariReadback.number(a, "limit", default: 16000, maximum: 32000)
            guard limit > 0 else { throw StallariError.invalidArguments }
            let mode = a["mode"]?.string ?? "range"
            let snapshot = try await scope()
            let target = try await issue(run.issueID, in: snapshot, reading: true)
            let resultVersion = StallariReview.version(of: run.result)
            let currentBasis = basisToken(issue: target, run: run)
            let ids = a["verificationIDs"]?.array.flatMap { $0.compactMap(\.string) } ?? []
            if !ids.isEmpty {
                guard ids.count <= 8, Set(ids).count == ids.count else {
                    throw StallariError.rejectedEvidence("한 번에 최대 8개의 서로 다른 검증 ID만 읽을 수 있어요.")
                }
                let byID = Dictionary(uniqueKeysWithValues: (run.result?.verifications ?? []).map { ($0.id, $0) })
                let missing = ids.filter { byID[$0] == nil }
                guard missing.isEmpty else {
                    throw StallariError.rejectedEvidence("이 실행에 없는 검증 ID예요: \(missing.joined(separator: ", ")). get_run(view: checks)로 확인하세요.")
                }
                try await recordReviewRead(run: run, issue: target)
                var budget = limit
                var excerpts: [OMPJSON] = []
                var omitted: [String] = []
                // The per-ID share is fixed from the requested count up front. A shrinking
                // denominator would let one ID consume a byte after the others were omitted.
                let share = limit / ids.count
                for verificationID in ids {
                    guard share > 0, budget >= share else { omitted.append(verificationID); continue }
                    let record = byID[verificationID]!
                    let allowance = min(share, budget)
                    let excerpt: StallariReadback.Excerpt
                    switch mode {
                    case "tail": excerpt = try StallariReadback.readTail(record.logPath, limit: allowance)
                    case "search":
                        guard let needle = a["query"]?.string, !needle.isEmpty else { throw StallariError.invalidArguments }
                        excerpt = try StallariReadback.search(record.logPath, text: needle, maxMatches: 8,
                                                              context: 240, limit: allowance)
                    case "range": excerpt = try StallariReadback.readRange(record.logPath, offset: offset, limit: allowance)
                    default: throw StallariError.invalidArguments
                    }
                    budget -= excerpt.totalBytes
                    if excerpt.totalBytes == 0, mode == "search" {
                        omitted.append(verificationID)
                        continue
                    }
                    try await rememberRead(runID: run.id, verificationID: verificationID, excerpt: excerpt,
                                           mode: mode, expectedResultVersion: resultVersion, basisToken: currentBasis)
                    excerpts.append(StallariReadback.excerpt(excerpt, verificationID: verificationID, mode: mode))
                }
                return .object(["run": ids.count > 1 ? StallariReadback.runHeader(run) : StallariReadback.run(run),
                                "resultVersion": .string(StallariReview.version(of: run.result)),
                                "budgetBytes": .number(Double(limit)),
                                "returnedBytes": .number(Double(limit - max(0, budget))),
                                "omittedVerificationIDs": .array(omitted.map(OMPJSON.string)),
                                "logs": .array(excerpts)])
            }
            let path: String?
            if let verificationID = a["verificationID"]?.string { path = run.result?.verifications.first { $0.id == verificationID }?.logPath }
            else { path = run.result?.reportPath }
            guard let path else { throw StallariError.rejectedEvidence("요청한 보고서 또는 검증 로그가 이 실행에 없어요. get_run으로 검증 ID를 확인해 주세요. 이전 실행은 최종 보고서가 저장되지 않았을 수 있어요.") }
            try await recordReviewRead(run: run, issue: target)
            let excerpt: StallariReadback.Excerpt
            switch mode {
            case "tail": excerpt = try StallariReadback.readTail(path, limit: limit)
            case "search":
                guard let needle = a["query"]?.string, !needle.isEmpty else { throw StallariError.invalidArguments }
                excerpt = try StallariReadback.search(path, text: needle, maxMatches: 8, context: 240, limit: limit)
            case "range": excerpt = try StallariReadback.readRange(path, offset: offset, limit: limit)
            default: throw StallariError.invalidArguments
            }
            if let verificationID = a["verificationID"]?.string {
                try await rememberRead(runID: run.id, verificationID: verificationID, excerpt: excerpt,
                                       mode: mode, expectedResultVersion: resultVersion, basisToken: currentBasis)
            }
            return StallariReadback.excerpt(excerpt, verificationID: a["verificationID"]?.string ?? "", mode: mode)
        case "list_projects":
            let snapshot = try await scope()
            return .object(["projects": .array(try await listProjects().map { p in
                let preparationSources = Set(snapshot.preparationItems.compactMap(\.sourceIssueID))
                let open = snapshot.issues.filter { snapshot.issueProjects[$0.id] == p.id && $0.needsAttention && !preparationSources.contains($0.id) }.count
                return .object(["projectID": .string(p.id), "name": .string(p.name), "path": .string(p.absolutePath), "openIssues": .number(Double(open)),
                    "workspaceStyle": .string(p.settings.workspaceStyle.rawValue), "memo": .string(p.settings.memo), "defaultCriteria": .array(p.settings.criteria.map(OMPJSON.string)),
                    "verification": .array(p.settings.verification.map { .object(["name": .string($0.name), "command": .string($0.command), "when": .string($0.timing.english)]) }),
                    "maxHirds": .number(Double(p.settings.maxHirds)), "hirdThinking": .string(p.settings.hirdThinking),
                    "result": .string(p.settings.resultMode == .merge ? "confirmed results are merged into the current branch" : "confirmed results stay on their Hird branch")])
            })])
        case "list_milestones":
            let snapshot = try await scope()
            let project = try readableProject(a["projectID"]?.string, in: snapshot)
            let weeks = try await repository.weekPlans(projectID: project.id)
            let currentWeek = ProjectWeek.start(containing: .now)
            return .object([
                "projectID": .string(project.id),
                "milestones": .array(snapshot.milestones.filter { $0.projectID == project.id }
                    .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
                    .map { milestone in
                        .object(["milestoneID": .string(milestone.id.rawValue), "title": .string(milestone.title),
                                 "status": .string(milestone.displayStatus.rawValue),
                                 "criteria": .array(milestone.criteria.map { .object(["text": .string($0.text),
                                     "met": .bool($0.state == .met), "evidence": .string($0.evidence)]) }),
                                 "targetDate": milestone.targetDate.map { .string(Self.day.string(from: $0)) } ?? .null,
                                 "prerequisites": .array(milestone.prerequisites.map { .string($0.rawValue) }),
                                 "order": .number(Double(milestone.order))])
                    }),
                "weekPlan": weeks.first { $0.weekStart == currentWeek }.map { .array($0.plan.map(OMPJSON.string)) } ?? .array([])
            ])
        case "create_milestone":
            return try await createMilestone(a)
        case "update_milestone":
            return try await updateMilestone(a)
        case "set_week_plan":
            let snapshot = try await scope()
            try ensureWritableThread(in: snapshot)
            let project = try writableProject(a["projectID"]?.string, in: snapshot)
            let plan = try stringArray(a, "plan")
            let value = ProjectWeekPlan(projectID: project.id, weekStart: ProjectWeek.start(containing: .now),
                                        plan: plan, recordedAt: .now)
            try await repository.saveWeekPlan(value, at: .now)
            return .object(["projectID": .string(project.id),
                            "weekStart": .string(Self.day.string(from: value.weekStart)),
                            "plan": .array(value.plan.map(OMPJSON.string))])
        case "create_issue":
            let id = try await createIssue(id: .init(required(a, "issueID")), title: required(a, "title"),
                criteria: stringArray(a, "criteria"), instruction: required(a, "instruction"),
                model: a["model"]?.string, mode: try runMode(a),
                previousRunID: a["previousRunID"]?.string.map { HirdRun.ID($0) }, projectID: a["projectID"]?.string,
                handoffSummary: a["handoffSummary"]?.string,
                milestoneID: a["milestoneID"]?.string.map { Milestone.ID($0) }, stages: try proposalStages(a))
            let saved = try await scope().issues.first { $0.id == id }
            return .object(["issueID": .string(id.rawValue), "state": .string("awaitingApproval"),
                            "threadID": saved.map { .string($0.conversationThreadID) } ?? .null,
                            "milestoneID": saved?.milestoneID.map { .string($0.rawValue) } ?? .null])
        case "update_issue_proposal":
            guard let version = a["expectedVersion"]?.integer, version > 0 else { throw StallariError.invalidArguments }
            try await updateIssueProposal(issueID: .init(required(a, "issueID")), expectedVersion: version,
                instruction: required(a, "instruction"), model: a["model"]?.string, mode: try runMode(a),
                previousRunID: a["previousRunID"]?.string.map { HirdRun.ID($0) }, stages: try proposalStages(a))
            return .object(["state": .string("awaitingApproval"), "version": .number(Double(version + 1))])
        case "dispatch_hird":
            guard case .object(let fields) = a, Set(fields.keys).isSubset(of: ["issueID", "runID"]) else { throw StallariError.invalidArguments }
            let id = try await dispatch(issueID: .init(required(a, "issueID")), runID: .init(a["runID"]?.string ?? "hird-\(UUID())"))
            return .object(["runID": .string(id.rawValue), "status": .string("dispatched")])
        case "get_issue":
            let snapshot = try await scope(), id = Issue.ID(try required(a, "issueID"))
            let value = try await issue(id, in: snapshot, reading: true)
            let all = snapshot.runs.filter { $0.issueID == id }.sorted { $0.startedAt > $1.startedAt }
            let offset = try StallariReadback.number(a, "offset", default: 0, maximum: Int.max / 2)
            let limit = try StallariReadback.number(a, "limit", default: 10, maximum: 20)
            guard limit > 0 else { throw StallariError.invalidArguments }
            let end = min(all.count, offset + limit), runs = offset < all.count ? Array(all[offset..<end]) : []
            return .object(["issue": try StallariReadback.issue(value), "runs": .array(runs.map(StallariReadback.run)),
                "nextOffset": end < all.count ? .number(Double(end)) : .null,
                "latestRunState": all.first.map { .string($0.state.rawValue) } ?? .null,
                "questions": try encoded(Array(snapshot.questions.filter { $0.issueID == id }.suffix(20)))])
        case "ask_user":
            let id = try await ask(id: a["questionID"]?.string ?? "question-\(UUID())", runID: .init(required(a, "runID")),
                issueID: .init(required(a, "issueID")), prompt: required(a, "prompt"), options: stringArray(a, "options"))
            return .object(["questionID": .string(id), "status": .string("waitingOnHuman")])
        case "answer_hird_question":
            guard threadID == ConversationThread.defaultID,
                  case .object(let fields) = a,
                  Set(fields.keys).isSubset(of: ["issueID", "runID", "questionID", "selectedOptions", "text"]),
                  a["text"] == nil || a["text"]?.string != nil else { throw StallariError.invalidArguments }
            let issueID = Issue.ID(try required(a, "issueID")), runID = HirdRun.ID(try required(a, "runID"))
            let questionID = try required(a, "questionID"), snapshot = try await scope()
            let value = try await issue(issueID, in: snapshot, reading: true)
            guard value.archivedAt == nil,
                  snapshot.questions.contains(where: { $0.id == questionID && $0.runID == runID && $0.issueID == issueID && $0.state == .pending }),
                  snapshot.runs.contains(where: { $0.id == runID && $0.issueID == issueID && !$0.state.isTerminal }) else { throw StallariError.conflictingID }
            let answer = QuestionAnswer(selectedOptions: a["selectedOptions"] == nil ? [] : try stringArray(a, "selectedOptions"), text: a["text"]?.string)
            if value.conversationThreadID == threadID {
                _ = try await self.answer(questionID: questionID, runID: runID, issueID: issueID, answer: answer, requirePending: true)
            } else {
                guard let routeQuestionAnswer else { throw StallariError.rejectedEvidence("질문의 소유 대화에 연결하지 못했어요.") }
                _ = try await routeQuestionAnswer(questionID, runID, issueID, answer)
            }
            return .object(["issueID": .string(issueID.rawValue), "runID": .string(runID.rawValue),
                "questionID": .string(questionID), "status": .string("answered")])
        case "close_issue":
            let reason: IssueCloseReason
            switch try required(a, "reason") {
            case "applied": reason = .applied
            case "superseded": reason = .superseded
            case "cancelled": reason = .cancelled
            default: throw StallariError.invalidArguments
            }
            let id = Issue.ID(try required(a, "issueID"))
            let snapshot = try await scope()
            let primary = try await issue(id, in: snapshot, reading: threadID == ConversationThread.defaultID)
            guard primary.archivedAt == nil else { throw StallariError.rejectedEvidence("닫힌 이슈 대화는 읽기 전용이에요.") }
            let included = a["includedIssueIDs"] == nil ? [] : try stringArray(a, "includedIssueIDs").map { Issue.ID($0) }
            for includedID in included {
                _ = try await issue(includedID, in: snapshot, reading: threadID == ConversationThread.defaultID)
            }
            let note = try required(a, "note").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { throw StallariError.invalidArguments }
            let expectedVersion: Int?
            if let value = a["expectedVersion"] {
                guard let version = value.integer, version > 0 else { throw StallariError.invalidArguments }
                expectedVersion = version
            } else { expectedVersion = nil }
            let skipped = try await repository.closeIssue(id, reason: reason, at: .now, note: note,
                supersededBy: a["supersededBy"]?.string.map { Issue.ID($0) }, includedIssueIDs: included,
                expectedVersion: expectedVersion)
            return .object(["issueID": .string(id.rawValue), "status": .string("closed"), "reason": .string(reason.rawValue),
                "includedIssues": .array(included.map { includedID in
                    if let reason = skipped[includedID] {
                        return .object(["issueID": .string(includedID.rawValue), "status": .string("skipped"), "reason": .string(reason)])
                    }
                    return .object(["issueID": .string(includedID.rawValue), "status": .string("closed"),
                        "reason": .string(IssueCloseReason.applied.rawValue), "integratedInto": .string(id.rawValue)])
                })])
        case "judge_issue":
            guard let values = a["evidence"]?.array else { throw StallariError.invalidArguments }
            let evidence = try values.map { value -> CriterionEvidence in
                guard let index = value["criterionIndex"]?.integer else { throw StallariError.invalidArguments }
                return .init(criterionIndex: index, verificationIDs: value["verificationIDs"] == nil ? [] : try stringArray(value, "verificationIDs"),
                             explanation: try required(value, "explanation"), met: value["met"]?.bool ?? true)
            }
            let judged = try await judge(issueID: .init(required(a, "issueID")), runID: .init(required(a, "runID")), evidence: evidence)
            return .object(["state": .string(judged.state.rawValue), "confirmed": .bool(judged.confirmed)])
        default: throw StallariError.invalidArguments
        }
    }
    private func preparationTool(_ name: String, _ a: OMPJSON) async throws -> OMPJSON {
        let snapshot = try await scope()
        let thread = snapshot.threads.first { $0.id == threadID }
        let boundProject = thread?.projectID ?? thread?.issueID.flatMap { snapshot.issueProjects[$0] }
        if let boundProject, let requested = a["projectID"]?.string, boundProject != requested { throw StallariError.wrongProject }
        let requested = boundProject ?? a["projectID"]?.string
        let owner = try name == "list_preparations" ? readableProject(requested, in: snapshot) : writableProject(requested, in: snapshot)
        let id = a["itemID"]?.string
        if name == "list_preparations" {
            let items = PreparationItem.ordered(snapshot.preparationItems.filter { $0.projectID == owner.id && (id == nil || $0.id == id) })
            if id != nil, items.isEmpty { throw StallariError.invalidArguments }
            return .object(["projectID": .string(owner.id), "items": .array(try items.map { item in
                if id != nil { return try encoded(item) }
                return .object(["id": .string(item.id), "revision": .number(Double(item.revision)),
                                "fields": try encoded(item.fields), "draftCount": .number(Double(item.drafts.count)),
                                "recordCount": .number(Double(item.records.count))])
            })])
        }
        guard let id, let revision = a["expectedRevision"]?.integer, revision >= 0 else { throw StallariError.invalidArguments }
        let current = snapshot.preparationItems.first { $0.id == id }
        guard current == nil || current?.projectID == owner.id else { throw StallariError.wrongProject }
        do {
            switch name {
            case "save_preparation":
                var fields = current?.fields ?? .init()
                for key in ["organization", "title", "memo", "posting"] where a[key] != nil {
                    guard let text = a[key]?.string else { throw StallariError.invalidArguments }
                    switch key { case "organization": fields.organization = text; case "title": fields.title = text
                    case "memo": fields.memo = text; default: fields.posting = text }
                }
                if let raw = a["deadline"] {
                    guard let text = raw.string else { throw StallariError.invalidArguments }
                    if text.isEmpty { fields.deadline = nil }
                    else { guard let date = Self.date(text) else { throw StallariError.invalidArguments }; fields.deadline = date }
                }
                if let raw = a["priority"] { guard let value = raw.bool else { throw StallariError.invalidArguments }; fields.priority = value }
                if a["documentPaths"] != nil { fields.documentPaths = try stringArray(a, "documentPaths") }
                if let raw = a["submission"] {
                    guard let text = raw.string, let submission = PreparationItem.Submission(rawValue: text) else { throw StallariError.invalidArguments }
                    fields.submission = submission
                }
                let sourceID = a["sourceIssueID"]?.string.map { Issue.ID($0) } ?? current?.sourceIssueID
                if current == nil, fields.posting.isEmpty, let sourceID,
                   let source = snapshot.issues.first(where: { $0.id == sourceID && snapshot.issueProjects[$0.id] == owner.id }) {
                    fields.posting = source.proposal?.instruction ?? source.detail
                }
                return try encoded(await repository.savePreparation(id: id, projectID: owner.id, fields: fields,
                    expectedRevision: revision, sourceIssueID: sourceID))
            case "save_preparation_draft":
                guard let kind = PreparationItem.Draft.Kind(rawValue: try required(a, "kind")) else { throw StallariError.invalidArguments }
                return try encoded(await repository.appendPreparationDraft(itemID: id, projectID: owner.id, expectedRevision: revision,
                    documentID: required(a, "documentID"), title: required(a, "title"), text: required(a, "text"), kind: kind))
            case "add_preparation_record":
                var submission: PreparationItem.Submission?
                if let value = a["submission"] {
                    guard let text = value.string, let state = PreparationItem.Submission(rawValue: text) else { throw StallariError.invalidArguments }
                    submission = state
                }
                return try encoded(await repository.appendPreparationRecord(itemID: id, projectID: owner.id, expectedRevision: revision,
                    text: required(a, "text"), submission: submission))
            default: throw StallariError.invalidArguments
            }
        } catch let error as PersistenceError { throw StallariError.rejectedEvidence(error.localizedDescription) }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
    /// Exact timestamps and plain days both parse; an unparseable filter is rejected.
    static func date(_ text: String) -> Date? {
        if let value = day.date(from: text) { return value }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// All plan writes go through the repository's existing milestone validation; this only
    /// maps arguments onto the stored model and never re-implements ordering, cycle or reached rules.
    private func createMilestone(_ a: OMPJSON) async throws -> OMPJSON {
        try ensureOpen()
        guard case .object(let fields) = a,
              Set(fields.keys).isSubset(of: ["projectID", "title", "criteria", "targetDate", "prerequisites", "order", "status", "blockedReason", "reachedEvidence"]) else {
            throw StallariError.invalidArguments
        }
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        let project = try writableProject(a["projectID"]?.string, in: snapshot)
        let existing = snapshot.milestones.filter { $0.projectID == project.id }
        let order: Int? = fields["order"] == nil ? nil : try StallariReadback.number(a, "order", default: 0, maximum: Int.max / 2)
        let status = try parseStatus(a["status"]?.string) ?? .planned
        var milestone = Milestone(
            id: .init("m-" + UUID().uuidString.lowercased()), projectID: project.id,
            order: order ?? ((existing.map(\.order).max() ?? -1) + 1),
            title: try required(a, "title"),
            status: status == .reached ? .active : status,
            blockedReason: a["blockedReason"]?.string,
            targetDate: try parseDay(a["targetDate"]?.string),
            criteria: try criteria(a), prerequisites: [],
            createdAt: .now)
        milestone.prerequisites = (fields["prerequisites"] == nil ? [] : try stringArray(a, "prerequisites")).map { Milestone.ID($0) }
        if status == .reached { try rejectStored { try milestone.markReached(at: .now) } }
        try await saveRejection { try await repository.saveMilestone(milestone) }
        return .object(["milestoneID": .string(milestone.id.rawValue), "title": .string(milestone.title),
                        "status": .string(milestone.displayStatus.rawValue), "order": .number(Double(milestone.order))])
    }

    private func updateMilestone(_ a: OMPJSON) async throws -> OMPJSON {
        try ensureOpen()
        guard case .object(let fields) = a,
              Set(fields.keys).isSubset(of: ["milestoneID", "title", "criteria", "targetDate", "clearTargetDate", "status", "blockedReason", "prerequisites", "reachedEvidence", "projectID"]) else {
            throw StallariError.invalidArguments
        }
        let snapshot = try await scope()
        try ensureWritableThread(in: snapshot)
        let id = Milestone.ID(try required(a, "milestoneID"))
        guard var milestone = snapshot.milestones.first(where: { $0.id == id }) else {
            throw StallariError.rejectedEvidence("milestoneID \(id.rawValue) is not a milestone: call list_milestones")
        }
        let owner = try writableProject(milestone.projectID, in: snapshot)
        if let requested = a["projectID"]?.string, requested != milestone.projectID {
            throw StallariError.rejectedEvidence("milestoneID \(id.rawValue) belongs to project \(owner.id), not \(requested)")
        }
        if fields["title"] != nil { milestone.title = try required(a, "title") }
        if fields["criteria"] != nil { milestone.criteria = try criteria(a) }
        if fields["prerequisites"] != nil { milestone.prerequisites = try stringArray(a, "prerequisites").map { Milestone.ID($0) } }
        if fields["targetDate"] != nil { milestone.targetDate = try parseDay(a["targetDate"]?.string) }
        if a["clearTargetDate"]?.bool == true { milestone.targetDate = nil }
        if fields["blockedReason"] != nil {
            let reason = a["blockedReason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            milestone.blockedReason = reason.isEmpty ? nil : reason
        }
        if let status = try parseStatus(a["status"]?.string) {
            if status == .reached {
                if !milestone.isReached { try rejectStored { try milestone.markReached(at: .now) } }
            } else {
                if milestone.isReached { milestone.reopen(at: .now) }
                milestone.status = status
                milestone.reachedAt = nil
            }
        }
        try await saveRejection { try await repository.saveMilestone(milestone) }
        let saved = try await repository.milestone(id) ?? milestone
        return .object(["milestoneID": .string(saved.id.rawValue), "title": .string(saved.title),
                        "status": .string(saved.displayStatus.rawValue),
                        "criteria": .array(saved.criteria.map { .object(["text": .string($0.text),
                            "met": .bool($0.state == .met), "evidence": .string($0.evidence)]) })])
    }

    /// The stored validation is the only plan rule; its message goes back to the model verbatim
    /// so a rejected draft can be corrected in the next call.
    private func saveRejection<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw Self.correction(error) }
    }

    private func rejectStored<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw Self.correction(error) }
    }

    private static func correction(_ error: Error) -> StallariError {
        if let error = error as? StallariError { return error }
        if let error = error as? MilestoneError {
            return .rejectedEvidence(error.errorDescription ?? "마일스톤 내용이 잘못됐어요")
        }
        if let error = error as? PersistenceError { return .rejectedEvidence(error.message) }
        return .rejectedEvidence("마일스톤을 저장하지 못했어요")
    }

    private func parseStatus(_ text: String?) throws -> Milestone.Status? {
        guard let text else { return nil }
        guard let status = Milestone.Status(rawValue: text) else { throw StallariError.invalidArguments }
        return status
    }

    private func parseDay(_ text: String?) throws -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard let date = Self.day.date(from: text) else {
            throw StallariError.rejectedEvidence("targetDate must be YYYY-MM-DD")
        }
        return date
    }

    /// Criteria text plus optional per-criterion verification evidence; an evidence entry marks
    /// that criterion met. Counts must match so evidence is never attached to the wrong condition.
    private func criteria(_ a: OMPJSON) throws -> [Criterion] {
        let texts = a["criteria"] == nil ? [] : try stringArray(a, "criteria")
        let evidence = a["reachedEvidence"] == nil ? [] : try stringArray(a, "reachedEvidence")
        guard evidence.isEmpty || evidence.count == texts.count else {
            throw StallariError.rejectedEvidence("reachedEvidence must have one entry per criterion, in order")
        }
        return zip(texts, evidence.isEmpty ? Array(repeating: "", count: texts.count) : evidence).map { text, proof in
            let proof = proof.trimmingCharacters(in: .whitespacesAndNewlines)
            return Criterion(text: text, state: proof.isEmpty ? .pending : .met, evidence: proof)
        }
    }

    private func reloadExtensionsNow() async throws -> OMPJSON {
        guard !reloading, let restartRPC else { throw StallariError.invalidArguments }
        reloading = true; reloadRequested = false
        defer { reloading = false }
        let before = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        var result = try await restartRPC()
        try ensureOpen()
        hostCalls.removeAll(); hostReplies.removeAll(); cancelledCalls.removeAll()
        _ = try await rpc.request("set_host_tools", fields: ["tools": .array(StallariTools.definitions)], timeout: .seconds(10))
        _ = try await rpc.request("set_ask_dialog", fields: ["enabled": .bool(false)], timeout: .seconds(10))
        try await applyToolBoundary()
        _ = try await rpc.request("set_event_filter", fields: ["events": .null, "messageUpdates": .string("delta")], timeout: .seconds(10))
        var errors = result["errors"]?.array ?? []
        if let provider = before["model"]?["provider"]?.string, let model = before["model"]?["id"]?.string {
            do { _ = try await rpc.request("set_model", fields: ["provider": .string(provider), "modelId": .string(model)], timeout: .seconds(10)) }
            catch { errors.append(.object(["kind": .string("previous_model_restore_failed"), "requestedModel": before["model"] ?? .null])) }
        }
        if let thinking = before["thinkingLevel"]?.string {
            do { _ = try await rpc.request("set_thinking_level", fields: ["level": .string(thinking)], timeout: .seconds(10)) }
            catch { errors.append(.object(["kind": .string("previous_thinking_restore_failed"), "requestedThinking": .string(thinking)])) }
        }
        do { _ = try await checkToolExposure() }
        catch { _ = await rpc.shutdown(cancel: true); throw error }
        let state = try await rpc.request("get_state", fields: [:], timeout: .seconds(10))["data"] ?? .null
        if case .object(var fields) = result {
            fields["tools"] = StallariTools.toolSnapshot(state["dumpTools"])
            fields["status"] = .string("restarted")
            fields["errors"] = .array(errors)
            fields["model"] = state["model"] ?? .null
            fields["thinkingLevel"] = state["thinkingLevel"] ?? .null
            result = .object(fields)
        }
        lastExtensionReload = result
        extensionNotice = "Knarr extension reload (RPC process restart, same conversation): " + (try jsonText(result))
        return result
    }
    public func shutdown() async -> OMPProcessExit {
        closed = true
        projectTransferDrainTask?.cancel()
        let approving = approvalsInFlight.values.map(\.task)
        for task in approving { task.cancel() }
        for task in approving { _ = try? await task.value }
        eventTask?.cancel()
        for task in hostTasks.values { task.cancel() }
        for task in starts.values { task.cancel() }
        for id in starts.keys { await hird.cancel(id) }
        for task in starts.values { await task.value }
        starts.removeAll()
        let result = await rpc.shutdown(cancel: true)
        for task in hostTasks.values { await task.value }
        hostTasks.removeAll()
        await eventTask?.value; eventTask = nil
        await projectTransferDrainTask?.value; projectTransferDrainTask = nil
        return result
    }
}
