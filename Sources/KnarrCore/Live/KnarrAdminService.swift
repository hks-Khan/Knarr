import Foundation
import CryptoKit

/// Carries out the MCP tools through Knarr's existing store paths: the same proposal
/// save (version check), the same closure (history preserved) and the same snapshot
/// publication the screens observe. Nothing here approves, launches or judges work.
@MainActor
public final class KnarrAdminService: KnarrAdminServing {
    private let repository: SQLiteKnarrRepository
    /// The one fixed Stallari the app lends this endpoint: its main conversation. The adapter
    /// takes no issue, thread or origin argument, so a caller naming a target cannot choose the
    /// context that decides ownership; `StallariSession` keeps applying its own `owns` rule.
    private let session: @MainActor @Sendable () async throws -> StallariSession
    public init(repository: SQLiteKnarrRepository,
                session: @escaping @MainActor @Sendable () async throws -> StallariSession) {
        self.repository = repository
        self.session = session
    }

    public func adminCall(_ operation: String, arguments: OMPJSON) async throws -> OMPJSON {
        guard let name = KnarrAdminOperation(rawValue: operation) else {
            throw KnarrAdminError.invalidRequest("지원하지 않는 작업입니다: \(operation)")
        }
        guard arguments.objectFields != nil else {
            throw KnarrAdminError.invalidRequest("arguments는 JSON 객체여야 합니다.")
        }
        do {
            switch name {
            case .listProjects: return try await listProjects()
            case .listIssues: return try await listIssues(arguments)
            case .getIssue: return try await getIssue(arguments)
            case .createIssue: return try await createIssue(arguments)
            case .updateIssueProposal: return try await updateProposal(arguments)
            case .closeIssue: return try await closeIssue(arguments)
            }
        } catch let error as KnarrAdminError {
            throw error
        } catch let error as PersistenceError {
            throw KnarrAdminError.conflict(error.message)
        } catch let error as StallariError {
            throw Self.map(error)
        } catch {
            throw KnarrAdminError.unavailable("Knarr가 요청을 처리하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private static func map(_ error: StallariError) -> KnarrAdminError {
        switch error {
        case .invalidArguments: .invalidRequest("입력 값을 확인해 주세요.")
        case .missingIssue, .missingRun, .wrongProject: .notFound("해당 프로젝트나 이슈를 찾지 못했습니다.")
        case .conflictingID: .conflict("같은 식별자에 다른 내용이 이미 저장되어 있습니다.")
        case .terminalRun: .conflict("이미 끝난 실행입니다.")
        case .missingEvidence: .rejected("필요한 근거가 저장되어 있지 않습니다.")
        case .unsafeToolExposure: .unavailable("앱의 도구 경계 확인에 실패했습니다.")
        case .closed: .unavailable("Knarr 앱의 Stallari 연결이 종료되었습니다.")
        case .rejectedEvidence(let reason): .rejected(reason)
        }
    }

    // MARK: - Reads

    private func listProjects() async throws -> OMPJSON {
        let snapshot = try await repository.snapshot(includeHistory: false)
        let preparationSources = Set(snapshot.preparationItems.compactMap(\.sourceIssueID))
        let projects = snapshot.projects
            .filter { $0.id != StoredProject.hubID && $0.archivedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { project -> OMPJSON in
                let open = snapshot.issues.filter { snapshot.issueProjects[$0.id] == project.id && $0.needsAttention && !preparationSources.contains($0.id) }.count
                return .object([
                    "projectID": .string(project.id),
                    "name": .string(project.name),
                    "path": .string(project.absolutePath),
                    "openIssues": .number(Double(open))
                ])
            }
        return .object(["projects": .array(projects)])
    }

    private func listIssues(_ a: OMPJSON) async throws -> OMPJSON {
        let arguments = try Arguments(a, allowed: ["projectID", "includeArchived", "offset", "limit"])
        let projectID = try arguments.string("projectID")
        let snapshot = try await repository.snapshot(includeHistory: false)
        try requireProject(projectID, in: snapshot)
        let includeArchived = try arguments.bool("includeArchived") ?? false
        let offset = try arguments.count("offset", default: 0, maximum: 1_000_000)
        let limit = try arguments.count("limit", default: 50, maximum: 200)
        let all = snapshot.issues
            .filter { snapshot.issueProjects[$0.id] == projectID && (includeArchived || $0.archivedAt == nil) }
            .sorted { ($0.startedAt, $0.id.rawValue) > ($1.startedAt, $1.id.rawValue) }
        let end = min(all.count, offset + limit)
        let page = offset < all.count ? Array(all[offset..<end]) : []
        return .object([
            "projectID": .string(projectID),
            "issues": .array(page.map(Self.summary)),
            "nextOffset": end < all.count ? .number(Double(end)) : .null
        ])
    }

    private func getIssue(_ a: OMPJSON) async throws -> OMPJSON {
        let arguments = try Arguments(a, allowed: ["projectID", "issueID"])
        let projectID = try arguments.string("projectID")
        let issueID = Issue.ID(try arguments.string("issueID"))
        let snapshot = try await repository.snapshot(includeHistory: false)
        try requireProject(projectID, in: snapshot)
        guard let issue = snapshot.issues.first(where: { $0.id == issueID }) else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)를 찾지 못했습니다.")
        }
        guard snapshot.issueProjects[issueID] == projectID else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)는 프로젝트 \(projectID)에 속하지 않습니다.")
        }
        let runs = snapshot.runs.filter { $0.issueID == issueID }.sorted { $0.startedAt > $1.startedAt }
        var fields: [String: OMPJSON] = [
            "issue": Self.summary(issue),
            "proposal": Self.proposal(issue.proposal),
            "proposalHistory": .array((issue.proposalHistory ?? issue.proposal.map { [$0] } ?? []).map(Self.proposal)),
            "approval": Self.approval(issue.approval),
            "criteria": .array(issue.acceptance.map {
                .object(["text": .string($0.text), "state": .string(Self.state($0.state)), "evidence": .string($0.evidence)])
            }),
            "runs": .array(runs.prefix(10).map { run in
                .object(["runID": .string(run.id.rawValue), "state": .string(run.state.rawValue),
                         "startedAt": Self.time(run.startedAt), "mode": .string((run.mode ?? .change).rawValue),
                         "summary": run.result.map { .string($0.summary) } ?? .null])
            }),
            "archived": issue.archivedAt == nil ? .null : .object([
                "at": Self.time(issue.archivedAt!),
                "reason": issue.archiveReason.map(OMPJSON.string) ?? .null,
                "note": issue.archiveNote.map(OMPJSON.string) ?? .null
            ])
        ]
        if let latest = runs.first?.result {
            fields["latestResult"] = .object(["summary": .string(latest.summary),
                                              "commit": latest.commit.map(OMPJSON.string) ?? .null])
        }
        return .object(fields)
    }

    // MARK: - Writes

    private func createIssue(_ a: OMPJSON) async throws -> OMPJSON {
        let arguments = try Arguments(a, allowed: ["projectID", "idempotencyKey", "title", "criteria",
                                                  "instruction", "model", "mode", "stages", "handoffSummary"])
        let projectID = try arguments.string("projectID")
        let key = try arguments.string("idempotencyKey")
        guard key.count <= 200 else { throw KnarrAdminError.invalidRequest("idempotencyKey는 200자 이하여야 합니다.") }
        let title = try arguments.string("title")
        let criteria = try arguments.strings("criteria")
        let instruction = try arguments.string("instruction")
        let model = try arguments.optionalString("model")
        let mode = try Self.mode(arguments.optionalString("mode"))
        let stages = try Self.stages(arguments.value("stages"))
        let handoffSummary = try arguments.optionalString("handoffSummary")

        let snapshot = try await repository.snapshot(includeHistory: false)
        try requireProject(projectID, in: snapshot)
        let id = Self.issueID(projectID: projectID, key: key)

        let identity = CreateIdentity(projectID: projectID, title: title, criteria: criteria,
            instruction: instruction, model: model.map(HiveProviderRuntime.currentModelIdentifier), mode: mode,
            stages: stages, handoffSummary: handoffSummary?.trimmingCharacters(in: .whitespacesAndNewlines))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        if let existing = snapshot.issues.first(where: { $0.id == id }) {
            guard snapshot.issueProjects[id] == projectID,
                  existing.creationRequestFingerprint == fingerprint else { throw Self.createConflict }
            return Self.duplicate(existing)
        }
        let session = try await session()
        let receipt = try await session.createIssueRecord(id: id, title: title, criteria: criteria,
            instruction: instruction, model: model, mode: mode, projectID: projectID,
            handoffSummary: handoffSummary, stages: stages, creationRequestFingerprint: fingerprint)
        guard let saved = try await repository.snapshot(includeHistory: false).issues.first(where: { $0.id == id }) else {
            throw KnarrAdminError.unavailable("생성한 이슈를 저장본에서 찾지 못했습니다.")
        }
        if !receipt.created { return Self.duplicate(saved) }
        return .object(["issueID": .string(saved.id.rawValue), "threadID": .string(saved.conversationThreadID),
                        "version": .number(Double(saved.proposal?.version ?? 1)), "state": .string(saved.state.rawValue),
                        "duplicate": .bool(false)])
    }

    private func updateProposal(_ a: OMPJSON) async throws -> OMPJSON {
        let arguments = try Arguments(a, allowed: ["projectID", "issueID", "expectedVersion",
                                                  "instruction", "model", "mode", "stages"])
        let projectID = try arguments.string("projectID")
        let issueID = Issue.ID(try arguments.string("issueID"))
        let expectedVersion = try arguments.count("expectedVersion", minimum: 1, maximum: 100_000)
        let instruction = try arguments.string("instruction")
        let model = try arguments.optionalString("model")
        let mode = try Self.mode(arguments.optionalString("mode"))
        let requestedStages = try Self.stages(arguments.value("stages"))

        let snapshot = try await repository.snapshot(includeHistory: false)
        try requireProject(projectID, in: snapshot)
        guard let issue = snapshot.issues.first(where: { $0.id == issueID }) else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)를 찾지 못했습니다.")
        }
        guard snapshot.issueProjects[issueID] == projectID else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)는 프로젝트 \(projectID)에 속하지 않습니다.")
        }
        guard issue.archivedAt == nil else {
            throw KnarrAdminError.conflict("닫힌 이슈의 제안은 수정할 수 없습니다.")
        }
        let current = issue.proposal?.version ?? 0
        guard current == expectedVersion || current == expectedVersion + 1 else {
            throw KnarrAdminError.conflict("제안 버전이 \(current)로 바뀌었습니다. get_issue로 최신 버전을 확인한 뒤 다시 시도하십시오.")
        }
        let session = try await session()
        do {
            // Authority is decided by the app session before any shortcut: the write below runs
            // `StallariSession`'s own ownership check and version guard.
            try await session.updateIssueProposal(issueID: issueID, expectedVersion: expectedVersion,
                instruction: instruction, model: model, mode: mode, stages: requestedStages)
        } catch StallariError.invalidArguments {
            // The only refusal that can mean "already applied" is the version guard. The saved
            // revision counts as this request only when it equals what the app would have
            // produced from the same base version, so omitted fields never pass as a match.
            let replay = try await repository.snapshot(includeHistory: false)
            guard let savedIssue = replay.issues.first(where: { $0.id == issueID }),
                  let saved = savedIssue.proposal, saved.version == expectedVersion + 1,
                  let base = (savedIssue.proposalHistory ?? []).first(where: { $0.version == expectedVersion }),
                  Self.matchesUpdate(saved, base: base, instruction: instruction, model: model,
                                     mode: mode, stages: requestedStages) else {
                throw KnarrAdminError.conflict("제안 버전이 \(replay.issues.first { $0.id == issueID }?.proposal?.version ?? 0)로 바뀌었습니다. get_issue로 최신 버전을 확인한 뒤 다시 시도하십시오.")
            }
            return .object(["issueID": .string(issueID.rawValue), "version": .number(Double(saved.version)),
                            "state": .string(savedIssue.state.rawValue), "duplicate": .bool(true)])
        }
        let saved = try await repository.snapshot(includeHistory: false).issues.first { $0.id == issueID }
        return .object(["issueID": .string(issueID.rawValue),
                        "version": .number(Double(saved?.proposal?.version ?? expectedVersion + 1)),
                        "state": .string(saved?.state.rawValue ?? IssueState.awaitingApproval.rawValue),
                        "duplicate": .bool(false)])
    }

    private func closeIssue(_ a: OMPJSON) async throws -> OMPJSON {
        let arguments = try Arguments(a, allowed: ["projectID", "issueID", "reason", "note", "expectedVersion"])
        let projectID = try arguments.string("projectID")
        let issueID = Issue.ID(try arguments.string("issueID"))
        let reason = try Self.reason(arguments.string("reason"))
        let note = try arguments.string("note").trimmingCharacters(in: .whitespacesAndNewlines)
        // Closure states the proposal revision it was decided against, like every other write.
        let expectedVersion = try arguments.count("expectedVersion", minimum: 1, maximum: 100_000)
        let snapshot = try await repository.snapshot(includeHistory: false)
        try requireProject(projectID, in: snapshot)
        guard let issue = snapshot.issues.first(where: { $0.id == issueID }) else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)를 찾지 못했습니다.")
        }
        guard snapshot.issueProjects[issueID] == projectID else {
            throw KnarrAdminError.notFound("이슈 \(issueID.rawValue)는 프로젝트 \(projectID)에 속하지 않습니다.")
        }
        if let archivedAt = issue.archivedAt {
            // A closure resend must match the stored reason, note and the revision it closed;
            // a different note is a different request, never a silent duplicate.
            guard issue.archiveReason == reason.rawValue,
                  issue.archiveNote == note,
                  issue.proposal?.version == expectedVersion else {
                throw KnarrAdminError.conflict("이미 \(issue.archiveReason ?? "다른 사유")로 닫힌 이슈입니다. get_issue로 저장된 닫기 기록을 확인하십시오.")
            }
            return .object(["issueID": .string(issueID.rawValue), "status": .string("closed"),
                            "reason": .string(reason.rawValue), "archivedAt": Self.time(archivedAt),
                            "duplicate": .bool(true)])
        }
        guard issue.proposal?.version == expectedVersion else {
            throw KnarrAdminError.conflict("제안 버전이 \(issue.proposal?.version ?? 0)입니다. get_issue로 최신 버전을 확인한 뒤 다시 시도하십시오.")
        }
        if snapshot.runs.contains(where: { $0.issueID == issueID && (!$0.state.isTerminal || $0.processEndedAt == nil) }) {
            throw KnarrAdminError.conflict("진행 중인 Hird 실행이 있어 이슈를 닫지 않았습니다. 앱에서 실행을 멈추거나 끝난 뒤 다시 시도하십시오.")
        }
        // The main conversation's close rule, and the repository's in-transaction active-run
        // guard, stay authoritative; the adapter adds no close path of its own.
        let session = try await session()
        _ = try await session.performTool("close_issue", arguments: .object([
            "issueID": .string(issueID.rawValue), "reason": .string(arguments.string("reason")),
            "note": .string(note), "expectedVersion": .number(Double(expectedVersion))
        ]))
        let saved = try await repository.snapshot(includeHistory: false).issues.first { $0.id == issueID }
        return .object(["issueID": .string(issueID.rawValue), "status": .string("closed"),
                        "reason": .string(reason.rawValue),
                        "archivedAt": saved?.archivedAt.map(Self.time) ?? Self.time(.now),
                        "duplicate": .bool(false)])
    }

    // MARK: - Shared projections

    @discardableResult private func requireProject(_ id: String, in snapshot: PersistenceSnapshot) throws -> StoredProject {
        guard id != StoredProject.hubID, let project = snapshot.projects.first(where: { $0.id == id }) else {
            throw KnarrAdminError.notFound("프로젝트 \(id)를 찾지 못했습니다. list_projects로 확인하십시오.")
        }
        guard project.archivedAt == nil else {
            throw KnarrAdminError.rejected("프로젝트 \(project.name)는 보관되어 새 작업을 받지 않습니다.")
        }
        return project
    }

    /// Compare normalized caller input, never today's defaults or a shortened criteria prefix.
    /// Omitted model/stages remain distinct from explicit values; omitted mode resolves to change.
    /// The hash is saved atomically with the first issue and survives edits, closure and restart.
    private struct CreateIdentity: Codable {
        let projectID: String
        let title: String
        let criteria: [String]
        let instruction: String
        let model: String?
        let mode: HirdRunMode
        let stages: [IssueStage]?
        let handoffSummary: String?
    }
    private static var createConflict: KnarrAdminError {
        .conflict("이미 같은 idempotencyKey로 다른 내용의 이슈가 저장되어 있습니다. 기존 이슈를 get_issue로 확인하십시오.")
    }

    /// A resend of an `update_issue_proposal` that already committed, recomputed from the stored
    /// base version exactly as the app resolves it. Omitted `model` inherits the base model and
    /// omitted `stages` inherit the base plan, so an omission can never pass as "same".
    static func matchesUpdate(_ saved: IssueProposal, base: IssueProposal, instruction: String,
                              model: String?, mode: HirdRunMode, stages: [IssueStage]?) -> Bool {
        saved.instruction == instruction && saved.mode == mode
            && saved.model == (model.map(HiveProviderRuntime.currentModelIdentifier) ?? base.model)
            && (saved.stages ?? []) == (stages ?? base.stages ?? [])
    }

    private static func duplicate(_ issue: Issue) -> OMPJSON {
        .object(["issueID": .string(issue.id.rawValue),
                 "threadID": .string(issue.conversationThreadID),
                 "version": .number(Double(issue.proposal?.version ?? 1)),
                 "state": .string(issue.state.rawValue),
                 "duplicate": .bool(true)])
    }

    /// The durable key never comes from the caller: it is derived from the project and the
    /// caller's own idempotency key, so a resend can only ever address the issue it created.
    static func issueID(projectID: String, key: String) -> Issue.ID {
        let digest = SHA256.hash(data: Data((projectID + "\u{0}" + key).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        return Issue.ID("mcp-" + hex)
    }

    private static func mode(_ text: String?) throws -> HirdRunMode {
        guard let text else { return .change }
        guard let mode = HirdRunMode(rawValue: text) else {
            throw KnarrAdminError.invalidRequest("mode는 inspect 또는 change여야 합니다.")
        }
        return mode
    }

    /// Wire names are stable English keys; `IssueCloseReason.rawValue` stays the durable Korean text.
    private static func reason(_ text: String) throws -> IssueCloseReason {
        switch text {
        case "applied": return .applied
        case "superseded": return .superseded
        case "cancelled": return .cancelled
        default: throw KnarrAdminError.invalidRequest("reason은 applied, superseded, cancelled 중 하나여야 합니다.")
        }
    }

    /// Only shape is checked here; the repository's stored stage-plan validation stays authoritative.
    private static func stages(_ value: OMPJSON?) throws -> [IssueStage]? {
        guard let value else { return nil }
        guard let values = value.array else { throw KnarrAdminError.invalidRequest("stages는 배열이어야 합니다.") }
        return try values.enumerated().map { index, entry in
            guard let fields = entry.objectFields,
                  Set(fields.keys).isSubset(of: ["title", "evidence", "criterion"]),
                  let title = fields["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let evidence = fields["evidence"]?.string, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnarrAdminError.invalidRequest("stages[\(index)]에는 title과 evidence가 필요합니다.")
            }
            var criterion: Int?
            if let raw = fields["criterion"] {
                guard let number = raw.integer, number > 0 else {
                    throw KnarrAdminError.invalidRequest("stages[\(index)].criterion은 1 이상의 정수여야 합니다.")
                }
                criterion = number
            }
            return IssueStage(id: "stage-\(index + 1)", title: title, evidence: evidence, criterion: criterion)
        }
    }

    private static func state(_ state: Criterion.State) -> String {
        switch state {
        case .pending: "pending"
        case .met: "met"
        case .unmet: "unmet"
        }
    }

    private static func summary(_ issue: Issue) -> OMPJSON {
        .object([
            "issueID": .string(issue.id.rawValue),
            "title": .string(issue.title),
            "state": .string(issue.state.rawValue),
            "status": .string(issue.displayStatus.key),
            "statusTitle": .string(issue.displayStatus.title),
            "proposalVersion": issue.proposal.map { .number(Double($0.version)) } ?? .null,
            "approvedVersion": issue.approval.map { .number(Double($0.version)) } ?? .null,
            "startedAt": time(issue.startedAt),
            "completedAt": issue.completedAt.map(time) ?? .null,
            "archivedAt": issue.archivedAt.map(time) ?? .null,
            "archiveReason": issue.archiveReason.map(OMPJSON.string) ?? .null
        ])
    }

    private static func proposal(_ proposal: IssueProposal?) -> OMPJSON {
        guard let proposal else { return .null }
        return .object([
            "version": .number(Double(proposal.version)),
            "instruction": .string(proposal.instruction),
            "model": .string(proposal.model),
            "mode": .string(proposal.mode.rawValue),
            "thinking": proposal.thinking.map(OMPJSON.string) ?? .null,
            "stages": .array(proposal.stagePlan.map {
                .object(["title": .string($0.title), "evidence": .string($0.evidence),
                         "criterion": $0.criterion.map { .number(Double($0)) } ?? .null])
            })
        ])
    }

    private static func approval(_ approval: IssueApproval?) -> OMPJSON {
        guard let approval else { return .null }
        return .object(["version": .number(Double(approval.version)), "approvedAt": time(approval.approvedAt),
                        "runID": approval.runID.map { .string($0.rawValue) } ?? .null,
                        "source": approval.source.map(OMPJSON.string) ?? .null])
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static func time(_ date: Date) -> OMPJSON { .string(formatter.string(from: date)) }
}

/// Strict argument reader: unknown keys are refused instead of ignored, because a typo in
/// a version or an identifier must never silently act on a different target.
struct Arguments {
    private let fields: [String: OMPJSON]
    init(_ value: OMPJSON, allowed: Set<String>) throws {
        guard let fields = value.objectFields else {
            throw KnarrAdminError.invalidRequest("arguments는 JSON 객체여야 합니다.")
        }
        let unknown = Set(fields.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw KnarrAdminError.invalidRequest("알 수 없는 인자: \(unknown.sorted().joined(separator: ", "))")
        }
        self.fields = fields
    }
    func value(_ key: String) -> OMPJSON? {
        guard let value = fields[key], value != .null else { return nil }
        return value
    }
    func string(_ key: String) throws -> String {
        guard let value = fields[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnarrAdminError.invalidRequest("\(key)는 비어 있지 않은 문자열이어야 합니다.")
        }
        return value
    }
    func optionalString(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let text = value.string else { throw KnarrAdminError.invalidRequest("\(key)는 문자열이어야 합니다.") }
        return text
    }
    func strings(_ key: String) throws -> [String] {
        guard let values = fields[key]?.array, values.allSatisfy({ $0.string != nil }) else {
            throw KnarrAdminError.invalidRequest("\(key)는 문자열 배열이어야 합니다.")
        }
        let strings = values.compactMap(\.string)
        guard !strings.isEmpty, strings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw KnarrAdminError.invalidRequest("\(key)는 비어 있지 않은 문자열이어야 합니다.")
        }
        return strings
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = fields[key], value != .null else { return nil }
        guard let flag = value.bool else { throw KnarrAdminError.invalidRequest("\(key)는 참 또는 거짓이어야 합니다.") }
        return flag
    }
    func count(_ key: String, default fallback: Int? = nil, minimum: Int = 0, maximum: Int) throws -> Int {
        guard let value = fields[key], value != .null else {
            if let fallback { return fallback }
            throw KnarrAdminError.invalidRequest("\(key)가 필요합니다.")
        }
        guard let number = value.integer, number >= minimum, number <= maximum else {
            throw KnarrAdminError.invalidRequest("\(key)는 \(minimum)...\(maximum) 사이의 정수여야 합니다.")
        }
        return number
    }
}

extension OMPJSON {
    var objectFields: [String: OMPJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
