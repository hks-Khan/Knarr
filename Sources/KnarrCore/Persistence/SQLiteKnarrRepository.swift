import Foundation
import CSQLite

/// Serialized durable storage, independent of OMP transport and KnarrStore.
/// No public mutation starts a process, resumes a session, judges an Issue or merges code.
public actor SQLiteKnarrRepository {
    private(set) var snapshotBuildCount = 0
    private(set) var decodedPayloadBytes = 0
    private var snapshotPublication: Task<Void, Never>?
    private struct CachedEntity { let row: [String]; var value: Any? }
    private final class EntityTable {
        var rows: [Int64: CachedEntity] = [:]
        var order: [Int64] = []
        var collection: Any?
        var chatItems: [ChatItem]?
        // Only the activities table uses these. Keep unchanged per-issue Array buffers shared
        // across snapshots so every conversation's Issue equality skips their full history.
        var activityRows: [String: Set<Int64>] = [:]
        var activityHistories: [String: [ActivityEvent]] = [:]
    }
    private var entityTables: [String: EntityTable] = [:]
    private var cachedEpoch = 0
    private var resultCacheBytes = 0
    private var verificationCacheBytes = 0
    private var snapshotSubscribers: [UUID: AsyncStream<PersistenceUpdate>.Continuation] = [:]
    /// Monotonic per committed write; stamped on every snapshot so consumers can drop stale values.
    private var writeRevision = 0
    /// SQLite's view counter at the last labeled read, so an external writer also advances the
    /// revision and its change is never mistaken for a duplicate of the previous snapshot.
    private var observedDataVersion: String?
    /// Event-driven snapshots for the Live Store; there is no idle polling task.
    /// `initial` yields the state at subscription time. Callers that read the snapshot themselves
    /// after subscribing pass `false`, so a value captured before their read cannot arrive later
    /// and rewind it.
    public func subscribe(initial: Bool = true) throws -> AsyncStream<PersistenceUpdate> {
        let id = UUID(), pair = AsyncStream<PersistenceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshotSubscribers[id] = pair.continuation
        if initial { pair.continuation.yield(.init(revision: writeRevision, snapshot: try snapshot(includeHistory: false))) }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return pair.stream
    }
    private func removeSubscriber(_ id: UUID) { snapshotSubscribers.removeValue(forKey: id) }
    private func publishSnapshot() {
        // Persistence has already committed. Coalesce *before* any read/projection work.
        writeRevision += 1
        guard !snapshotSubscribers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if snapshotPublication == nil { firstUnpublishedWrite = now }
        // A burst of Hird tool writes becomes one snapshot: each write restarts a short timer, and
        // the oldest waiting write forces a flush so a subscriber never lags past the cap.
        let waited = now - (firstUnpublishedWrite ?? now)
        let remaining = min(Self.snapshotDebounce, Self.snapshotMaximumDelay - waited)
        let wait = remaining > 0 ? Duration.milliseconds(Int(remaining * 1000)) : .zero
        snapshotPublication?.cancel()
        snapshotPublication = Task { [weak self] in
            if wait > .zero { do { try await Task.sleep(for: wait) } catch { return } }
            else { await Task.yield() }
            await self?.flushSnapshot()
        }
    }
    /// Quiet time a burst must reach before its snapshot is built.
    static let snapshotDebounce: TimeInterval = 0.025
    /// The longest a committed write waits for a subscriber-visible snapshot.
    static let snapshotMaximumDelay: TimeInterval = 0.25
    private var firstUnpublishedWrite: TimeInterval?
    private func flushSnapshot() {
        snapshotPublication = nil
        firstUnpublishedWrite = nil
        // The revision and the read happen together on this actor, so the label always matches the
        // delivered contents; consumers only need it to drop values older than their own reads.
        guard !snapshotSubscribers.isEmpty,
              let value = try? PersistenceUpdate(revision: writeRevision, snapshot: snapshot(includeHistory: false)) else { return }
        for subscriber in snapshotSubscribers.values { subscriber.yield(value) }
    }
    // Only snapshots populate this cache, after reading a coherent committed transaction.
    // Writes invalidate before execution, including failed/rolled-back writes. External writers
    // invalidate through SQLite data_version, so old decoded histories never mask DB changes.
    private var snapshotRuns: [String: PersistedRun] = [:]
    private struct ProjectedIssue {
        let source: Issue
        let runs: [PersistedRun]
        let events: [ActivityEvent]
        let value: Issue
    }
    private var projectedIssues: [Issue.ID: ProjectedIssue] = [:]
    private var snapshotDataVersion: String?
    private var runStartsSuspended = false
    private var projectSessionPolicy = ProjectSessionPolicy.current
    func setProjectSessionPolicy(_ policy: ProjectSessionPolicy) { projectSessionPolicy = policy }
    private let connection: SQLiteConnection
    /// Read-only v1 preflight translates schema identifiers and typed payload keys in memory.
    private let legacySchema: Bool
    private let threadSchema: Bool
    private var normalizedSchema: Bool
    private var transferSchema: Bool
    private var milestoneSchema: Bool
    private var weekPlanSchema: Bool
    private var preparationSchema: Bool
    private var resultCache: [String: RunResult] = [:]
    private var verificationCache: [String: VerificationRecord] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let applicationID = 1_263_419_730 // KNAR
    private init(_ connection: SQLiteConnection, legacySchema: Bool = false, threadSchema: Bool = true, normalizedSchema: Bool = true, transferSchema: Bool = true, milestoneSchema: Bool = true, weekPlanSchema: Bool = true, preparationSchema: Bool = true) {
        self.connection = connection
        self.legacySchema = legacySchema
        self.threadSchema = threadSchema
        self.normalizedSchema = normalizedSchema
        self.transferSchema = transferSchema
        self.milestoneSchema = milestoneSchema
        self.weekPlanSchema = weekPlanSchema
        self.preparationSchema = preparationSchema
        encoder.outputFormatting = [.sortedKeys]
    }

    /// Atomic with run insertion: host-tool dispatch cannot race an installation handoff.
    public func beginInstallation() throws {
        let runs: [PersistedRun] = try records("runs")
        guard !runStartsSuspended, !runs.contains(where: { !$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil) }) else {
            throw LiveKnarrError.installBusy
        }
        runStartsSuspended = true
    }
    public func cancelInstallation() { runStartsSuspended = false }

    public func prepareForAppShutdown(at: Date) throws -> [HirdRun.ID] {
        runStartsSuspended = true
        let runs: [PersistedRun] = try records("runs")
        let active = runs.filter { !$0.state.isTerminal || ($0.cancellationRequestedAt != nil && $0.processEndedAt == nil) }
        for run in active {
            _ = try cancelRun(run.id, at: at, reason: "앱 종료로 중단됨 · 다시 시작")
        }
        return active.map(\.id)
    }

    public static func open(at url: URL, now: Date = .now,
                            probe: @Sendable (PersistedRun) -> OwnedRunLiveness = { _ in .unverified }) async throws -> SQLiteKnarrRepository {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw PersistenceError(databasePath: url.path, message: "저장소의 절대 파일 경로가 필요해요")
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            do {
                try await preflight(path: url.path, flags: SQLITE_OPEN_READONLY)
            } catch let error as PersistenceError {
                // A real crash can leave a hot rollback journal. Verify recovery on an owned
                // copy first, so a damaged original is never mutated in order to diagnose it.
                guard error.sqliteCode.map({ $0 & 0xff == SQLITE_READONLY }) == true,
                      FileManager.default.fileExists(atPath: url.path + "-journal") else { throw error }
                try await preflightHotJournalCopy(at: url)
            }
        }
        let connection = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READWRITE | (exists ? 0 : SQLITE_OPEN_CREATE))
        do {
            try connection.execute("PRAGMA foreign_keys = ON")
            try connection.execute("PRAGMA legacy_alter_table = OFF")
            try connection.execute("PRAGMA synchronous = FULL")
            if !exists { try createSchema(connection) }
            let version = try connection.rows("PRAGMA user_version")
            let number = Int(version.first?.first ?? "") ?? 0
            let hasEvidence = number >= 4
            let repository = SQLiteKnarrRepository(connection, normalizedSchema: hasEvidence,
                transferSchema: number >= 5, milestoneSchema: number >= 6, weekPlanSchema: number >= 7, preparationSchema: number >= 8)
            let migrateV1 = exists && number == 1
            // SQLite disallows ADD REFERENCES with a non-null default while FK enforcement
            // is enabled. Preflight already checked the old graph; validate again before commit.
            if !hasEvidence { try connection.execute("PRAGMA foreign_keys = OFF") }
            try await repository.recover(now: now, probe: probe, migrateV1: migrateV1,
                migrateThreads: number == 1 || number == 2, migrateEvidence: !hasEvidence,
                migrateTransfers: number < 5, migrateMilestones: number < 6, migrateWeekPlans: number < 7, migratePreparations: number < 8)
            try connection.execute("PRAGMA foreign_keys = ON")
            return repository
        } catch {
            try? connection.close()
            throw error
        }
    }

    private static func preflight(path: String, flags: Int32) async throws {
        let check = try SQLiteConnection(path: path, flags: flags)
        do {
            let version = try check.rows("PRAGMA user_version")
            guard try check.rows("PRAGMA integrity_check") == [["ok"]],
                  try check.rows("PRAGMA application_id") == [[String(applicationID)]],
                  version.count == 1, let number = version.first?.first.flatMap(Int.init), (1...8).contains(number),
                  try check.rows("PRAGMA foreign_key_check").isEmpty else {
                throw check.failure("손상, 다른 저장소 또는 지원하지 않는 스키마입니다")
            }
            let reader = SQLiteKnarrRepository(check, legacySchema: number == 1,
                threadSchema: number >= 3, normalizedSchema: number >= 4,
                transferSchema: number >= 5, milestoneSchema: number >= 6, weekPlanSchema: number >= 7, preparationSchema: number >= 8)
            _ = try await reader.snapshot()
            try await reader.validateStoredLinks()
            try await reader.close()
        } catch {
            try? check.close()
            if let error = error as? PersistenceError { throw error }
            throw PersistenceError(databasePath: path, message: "저장 내용 해석 실패: \(error)")
        }
    }

    private static func preflightHotJournalCopy(at url: URL) async throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent().appendingPathComponent(".knarr-preflight-\(UUID())")
        var created = false
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            created = true
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                if files.fileExists(atPath: source.path) {
                    try files.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
            try await preflight(path: copy.path, flags: SQLITE_OPEN_READWRITE)
            try files.removeItem(at: directory)
        } catch {
            if created {
                do { try files.removeItem(at: directory) }
                catch { throw PersistenceError(databasePath: url.path, message: "원본 보존 검사용 사본 정리 실패: \(directory.path); \(error)") }
            }
            throw PersistenceError(databasePath: url.path, message: "journal 복구 사본 검증 실패 (원본 보존): \(error)")
        }
    }

    private static func createSchema(_ db: SQLiteConnection) throws {
        try db.transaction {
            for statement in [
                "CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)",
                "CREATE TABLE threads (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)",
                "CREATE TABLE issues (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), payload TEXT NOT NULL, thread_id TEXT NOT NULL DEFAULT 'default' REFERENCES threads(id), UNIQUE(id, project_id))",
                "CREATE TABLE runs (id TEXT PRIMARY KEY NOT NULL, issue_id TEXT NOT NULL, project_id TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(id, issue_id), UNIQUE(id, issue_id, project_id), FOREIGN KEY(issue_id, project_id) REFERENCES issues(id, project_id))",
                "CREATE TABLE chat (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), issue_id TEXT, run_id TEXT, payload TEXT NOT NULL, thread_id TEXT NOT NULL DEFAULT 'default' REFERENCES threads(id), FOREIGN KEY(issue_id, project_id) REFERENCES issues(id, project_id), FOREIGN KEY(run_id, issue_id, project_id) REFERENCES runs(id, issue_id, project_id))",
                "CREATE TABLE activities (id TEXT PRIMARY KEY NOT NULL, issue_id TEXT NOT NULL REFERENCES issues(id), run_id TEXT, payload TEXT NOT NULL, FOREIGN KEY(run_id, issue_id) REFERENCES runs(id, issue_id))",
                "CREATE TABLE questions (id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL, issue_id TEXT NOT NULL, payload TEXT NOT NULL, FOREIGN KEY(run_id, issue_id) REFERENCES runs(id, issue_id))",
                "CREATE TABLE notifications (id TEXT PRIMARY KEY NOT NULL, run_id TEXT UNIQUE NOT NULL REFERENCES runs(id), payload TEXT NOT NULL)",
                "CREATE TABLE thread_deliveries (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL REFERENCES threads(id), issue_id TEXT NOT NULL REFERENCES issues(id), run_id TEXT REFERENCES runs(id), payload TEXT NOT NULL)",
                "CREATE TABLE run_events (id TEXT PRIMARY KEY NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id), sequence INTEGER NOT NULL CHECK(sequence > 0), payload TEXT NOT NULL, outcome TEXT NOT NULL, UNIQUE(run_id, sequence))",
                "CREATE INDEX runs_issue ON runs(issue_id)",
                "CREATE INDEX questions_run ON questions(run_id)",
                "CREATE INDEX activities_run ON activities(run_id)",
                "PRAGMA application_id = \(applicationID)", "PRAGMA user_version = 8"
            ] { try db.execute(statement) }
            try createEvidenceSchema(db)
            try createProjectTransferSchema(db)
            try createMilestoneSchema(db)
            try createWeekPlanSchema(db)
            try createPreparationSchema(db)
            let payload = String(decoding: try JSONEncoder().encode(ConversationThread.default), as: UTF8.self)
            try db.execute("INSERT INTO threads(id,payload) VALUES(?,?)", [ConversationThread.defaultID, payload])
        }
    }
    /// Durable, project-bound outbox; no source chat or Issue is created or modified.
    public func enqueueProjectTransfer(id: String, originThreadID: String, requestMessageID: UUID,
                                       summary: String, messageIDs: [UUID]) throws -> ProjectTransfer {
        defer { publishSnapshot() }
        return try connection.transaction {
            try validateID(id)
            guard id.utf8.count <= 256 else { throw error("전달 요청 식별자가 너무 길어요") }
            guard summary.count <= projectSessionPolicy.handoffMaximumCharacters else { throw error("전달 요약이 너무 길어요") }
            let source = try projectTransferSource(originThreadID: originThreadID, requestMessageID: requestMessageID,
                                                   summary: summary, messageIDs: messageIDs, requireActive: true)
            let existing: ProjectTransfer?
            if let byID: ProjectTransfer = try record("project_transfers", id) { existing = byID }
            else {
                existing = try rows("SELECT payload FROM project_transfers WHERE request_message_id=?", [requestMessageID.uuidString])
                    .first.map { try decode(ProjectTransfer.self, $0[0]) }
            }
            if let existing {
                guard existing.originProjectID == source.project.id, existing.originThreadID == originThreadID,
                      existing.requestMessageID == requestMessageID, existing.requestText == source.requestText,
                      existing.summary == summary, existing.messageIDs == source.messageIDs,
                      existing.attachments == source.attachments else { throw error("프로젝트 전달 요청 식별자 충돌") }
                return existing
            }
            let transfer = ProjectTransfer(id: id, originProjectID: source.project.id, originThreadID: originThreadID,
                projectName: source.project.name, requestMessageID: requestMessageID, requestText: source.requestText,
                summary: summary, messageIDs: source.messageIDs, attachments: source.attachments, createdAt: .now)
            try connection.execute("INSERT INTO project_transfers(id,project_id,thread_id,request_message_id,payload) VALUES(?,?,?,?,?)",
                [id, transfer.originProjectID, originThreadID, requestMessageID.uuidString, try encode(transfer)])
            for (ordinal, messageID) in transfer.messageIDs.enumerated() {
                try connection.execute("INSERT INTO project_transfer_messages(transfer_id,message_id,ordinal) VALUES(?,?,?)",
                    [id, messageID.uuidString, String(ordinal)])
            }
            return transfer
        }
    }

    public func projectTransfers() throws -> [ProjectTransfer] {
        guard transferSchema else { return [] }
        // This table is read directly, outside the entity-table update-hook cache.
        return try rows("SELECT payload FROM project_transfers ORDER BY rowid").map { try decode(ProjectTransfer.self, $0[0]) }
    }

    /// Internal admission acknowledgements cannot be invoked by a bridge tool.
    func markProjectTransferDelivered(_ id: String, at: Date) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            guard var transfer: ProjectTransfer = try record("project_transfers", id) else { throw error("프로젝트 전달 요청이 없어요") }
            guard transfer.deliveredAt == nil else { return }
            transfer.deliveredAt = at; transfer.lastError = nil
            try writeProjectTransfer(transfer)
        }
    }

    func failProjectTransfer(_ id: String, unsupported: Bool = false) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            guard var transfer: ProjectTransfer = try record("project_transfers", id) else { throw error("프로젝트 전달 요청이 없어요") }
            guard transfer.deliveredAt == nil else { return }
            transfer.lastError = unsupported ? ProjectTransfer.unsupportedFailureMessage : ProjectTransfer.deliveryFailureMessage
            try writeProjectTransfer(transfer)
        }
    }

    public func retryProjectTransfer(_ id: String, originThreadID: String) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            guard var transfer: ProjectTransfer = try record("project_transfers", id),
                  transfer.originThreadID == originThreadID else { throw error("프로젝트 전달 소유권이 달라요") }
            let source = try projectTransferSource(originThreadID: originThreadID, requestMessageID: transfer.requestMessageID,
                summary: transfer.summary, messageIDs: transfer.messageIDs, requireActive: true)
            guard transfer.originProjectID == source.project.id else { throw error("프로젝트 전달 원본이 달라요") }
            guard transfer.deliveredAt == nil else { return }
            transfer.lastError = nil
            try writeProjectTransfer(transfer)
        }
    }

    private func writeProjectTransfer(_ transfer: ProjectTransfer) throws {
        try connection.execute("UPDATE project_transfers SET payload=? WHERE id=?", [try encode(transfer), transfer.id])
    }

    private struct ProjectTransferSource {
        let project: StoredProject
        let requestText: String
        let messageIDs: [UUID]
        let attachments: [ProjectTransfer.AttachmentReference]
    }

    private func projectTransferSource(originThreadID: String, requestMessageID: UUID, summary: String,
                                       messageIDs: [UUID], requireActive: Bool) throws -> ProjectTransferSource {
        guard let thread: ConversationThread = try record("threads", originThreadID),
              thread.id == originThreadID, thread.id != ConversationThread.defaultID,
              thread.issueID == nil, thread.originThreadID == nil,
              let projectID = thread.projectID, projectID != StoredProject.hubID,
              let project: StoredProject = try record("projects", projectID), project.id == projectID,
              !requireActive || project.archivedAt == nil else { throw error("전달할 활성 프로젝트 대화가 없어요") }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messageIDs.isEmpty, messageIDs.count <= 100, Set(messageIDs).count == messageIDs.count,
              messageIDs.contains(requestMessageID) else { throw error("전달 요약 또는 원본 메시지 참조가 잘못됐어요") }
        let canonicalIDs = messageIDs.sorted { $0.uuidString < $1.uuidString }
        var requestText: String?
        var attachments: [ProjectTransfer.AttachmentReference] = []
        for messageID in canonicalIDs {
            guard let row = try rows("SELECT project_id,thread_id,issue_id,run_id,payload FROM chat WHERE id=?", [messageID.uuidString]).first,
                  row[0] == projectID, row[1] == originThreadID, row[2].isEmpty, row[3].isEmpty else {
                throw error("전달 메시지의 원본 대화 연결이 달라요")
            }
            let stored = try decode(StoredChat.self, row[4])
            guard stored.link.chatID == messageID, stored.link.projectID == projectID,
                  stored.link.conversationThreadID == originThreadID, stored.link.issueID == nil,
                  stored.link.runID == nil else { throw error("전달 메시지의 저장 연결이 달라요") }
            let item = try stored.item()
            if messageID == requestMessageID {
                guard case .user(let text) = item.kind else { throw error("사용자의 원본 전달 요청이 필요해요") }
                requestText = text
            }
            for url in item.attachments {
                guard url.isFileURL else { throw error("원본 파일 첨부만 전달할 수 있어요") }
                try validatePath(url.path)
                guard attachments.count < 100 else { throw error("전달 첨부는 100개까지 선택할 수 있어요") }
                attachments.append(.init(messageID: messageID, url: url))
            }
        }
        guard let requestText else { throw error("사용자의 원본 전달 요청이 없어요") }
        return .init(project: project, requestText: requestText, messageIDs: canonicalIDs, attachments: attachments)
    }

    private static func createProjectTransferSchema(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE project_transfers (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), thread_id TEXT NOT NULL REFERENCES threads(id), request_message_id TEXT UNIQUE NOT NULL REFERENCES chat(id), payload TEXT NOT NULL)")
        try db.execute("CREATE TABLE project_transfer_messages (transfer_id TEXT NOT NULL REFERENCES project_transfers(id), message_id TEXT NOT NULL REFERENCES chat(id), ordinal INTEGER NOT NULL CHECK(ordinal>=0), PRIMARY KEY(transfer_id,message_id), UNIQUE(transfer_id,ordinal))")
    }

    /// Project-scoped milestones. Prerequisites, ordering and issue links stay inside one project.
    private static func createMilestoneSchema(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE milestones (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), payload TEXT NOT NULL, UNIQUE(id,project_id))")
        try db.execute("CREATE INDEX milestones_project ON milestones(project_id)")
    }

    /// Project-level weekly plans. Only the server's current week can be written; earlier rows
    /// are history and never rewritten.
    private static func createWeekPlanSchema(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE project_weeks (project_id TEXT NOT NULL REFERENCES projects(id), week_start REAL NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(project_id, week_start))")
    }

    public func weekPlans(projectID: String) throws -> [ProjectWeekPlan] {
        guard weekPlanSchema else { return [] }
        return try rows("SELECT payload FROM project_weeks WHERE project_id=? ORDER BY week_start", [projectID])
            .map { try decode(ProjectWeekPlan.self, $0[0]) }
    }

    /// Writes only this week's plan for one project. A past or future week, a dropped history row
    /// or a plan for another week is rejected against the server clock.
    public func saveWeekPlan(_ plan: ProjectWeekPlan, at now: Date = .now) throws {
        defer { publishSnapshot() }
        guard weekPlanSchema else { throw error("주간 계획 저장을 지원하지 않는 저장소예요") }
        try connection.transaction {
            guard let project: StoredProject = try record("projects", plan.projectID), project.archivedAt == nil else {
                throw error("활성 프로젝트에만 주간 계획을 저장할 수 있어요")
            }
            let current = ProjectWeek.start(containing: now)
            guard plan.weekStart == current else { throw error("이번 주 계획만 저장할 수 있어요") }
            let existing: [ProjectWeekPlan] = try rows("SELECT payload FROM project_weeks WHERE project_id=?", [plan.projectID])
                .map { try decode(ProjectWeekPlan.self, $0[0]) }
            guard existing.allSatisfy({ $0.weekStart <= current }) else { throw error("지난 주간 계획은 바꿀 수 없어요") }
            var value = plan
            value.plan = ProjectWeekPlan.lines(plan.plan)
            value.recordedAt = now
            try connection.execute("INSERT INTO project_weeks(project_id,week_start,payload) VALUES(?,?,?) ON CONFLICT(project_id,week_start) DO UPDATE SET payload=excluded.payload",
                                   [value.projectID, String(value.weekStart.timeIntervalSinceReferenceDate), try encode(value)])
        }
    }

    /// Ordered by planned position; a project's list is small and bounded by the UI.
    public func milestones(projectID: String) throws -> [Milestone] {
        guard milestoneSchema else { return [] }
        return try rows("SELECT payload FROM milestones WHERE project_id=? ORDER BY rowid", [projectID])
            .map { try decode(Milestone.self, $0[0]) }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    public func milestone(_ id: Milestone.ID) throws -> Milestone? {
        guard milestoneSchema else { return nil }
        return try record("milestones", id.rawValue)
    }

    /// Creates or edits a project milestone. Existing weekly records are history and cannot be
    /// rewritten or dropped; the newest week may be revised. Completion needs verified criteria.
    public func saveMilestone(_ milestone: Milestone) throws {
        defer { publishSnapshot() }
        guard milestoneSchema else { throw error("마일스톤 저장을 지원하지 않는 저장소예요") }
        try connection.transaction {
            try validateID(milestone.id.rawValue)
            guard milestone.id.rawValue.utf8.count <= 256 else { throw error("마일스톤 식별자가 너무 길어요") }
            guard let project: StoredProject = try record("projects", milestone.projectID), project.archivedAt == nil else {
                throw error("활성 프로젝트에만 마일스톤을 저장할 수 있어요")
            }
            let others: [Milestone] = try rows("SELECT payload FROM milestones WHERE project_id=? AND id<>?", [milestone.projectID, milestone.id.rawValue])
                .map { try decode(Milestone.self, $0[0]) }
            let old: Milestone? = try record("milestones", milestone.id.rawValue)
            if let old { guard old.projectID == milestone.projectID else { throw error("마일스톤의 프로젝트는 바꿀 수 없어요") } }
            let value: Milestone
            do { value = try milestone.preparedForSave(over: old, at: .now) }
            catch let failure as MilestoneError { throw error(failure.errorDescription ?? "마일스톤 내용이 잘못됐어요") }
            do { try value.validate(inProject: milestone.projectID, existing: others) }
            catch let failure as MilestoneError { throw error(failure.errorDescription ?? "마일스톤 내용이 잘못됐어요") }
            if old == nil {
                guard value.createdAt <= .now.addingTimeInterval(60) else { throw error("마일스톤 생성 시각이 잘못됐어요") }
            }
            try connection.execute("INSERT INTO milestones(id,project_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                                   [value.id.rawValue, value.projectID, try encode(value)])
        }
    }

    /// Applies a full order for one project in a single transaction, so a swap never leaves
    /// two milestones at the same position.
    public func reorderMilestones(projectID: String, orderedIDs: [Milestone.ID]) throws {
        defer { publishSnapshot() }
        guard milestoneSchema else { return }
        try connection.transaction {
            var stored: [Milestone] = try rows("SELECT payload FROM milestones WHERE project_id=?", [projectID])
                .map { try decode(Milestone.self, $0[0]) }
            guard Set(stored.map(\.id)) == Set(orderedIDs), stored.count == orderedIDs.count else {
                throw error("마일스톤 순서가 저장된 목록과 달라요")
            }
            for (index, id) in orderedIDs.enumerated() {
                guard let position = stored.firstIndex(where: { $0.id == id }) else { continue }
                var value = stored[position]
                value.order = index
                value.updatedAt = .now
                stored[position] = value
            }
            do { try Milestone.validate(stored, projectID: projectID) }
            catch let failure as MilestoneError { throw error(failure.errorDescription ?? "마일스톤 내용이 잘못됐어요") }
            for value in stored {
                try connection.execute("INSERT INTO milestones(id,project_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                                       [value.id.rawValue, projectID, try encode(value)])
            }
        }
    }

    /// Only an unreferenced milestone can be deleted; issues keep their stored history.
    public func deleteMilestone(_ id: Milestone.ID) throws {
        defer { publishSnapshot() }
        guard milestoneSchema else { return }
        try connection.transaction {
            guard let milestone: Milestone = try record("milestones", id.rawValue) else { throw error("마일스톤을 찾을 수 없어요") }
            let dependents: [Milestone] = try rows("SELECT payload FROM milestones WHERE project_id=? AND id<>?", [milestone.projectID, id.rawValue])
                .map { try decode(Milestone.self, $0[0]) }
            guard !dependents.contains(where: { $0.prerequisites.contains(id) }) else {
                throw error("다른 마일스톤이 선행 조건으로 쓰고 있어요")
            }
            let issues: [Issue] = try rows("SELECT payload FROM issues WHERE project_id=?", [milestone.projectID])
                .map { try decode(Issue.self, $0[0]) }
            guard !issues.contains(where: { $0.milestoneID == id }) else {
                throw error("이 마일스톤으로 만든 이슈가 있어 지울 수 없어요")
            }
            try connection.execute("DELETE FROM milestones WHERE id=?", [id.rawValue])
        }
    }

    /// Open-time check for the milestone graph and every issue's stored milestone link.
    private func validateMilestones(projects: [String: StoredProject], issueProjects: [Issue.ID: String]) throws {
        guard milestoneSchema else { return }
        var byProject: [String: [Milestone]] = [:]
        for row in try rows("SELECT id,project_id,payload FROM milestones") {
            let milestone = try decode(Milestone.self, row[2])
            guard milestone.id.rawValue == row[0], milestone.projectID == row[1], projects[row[1]] != nil else {
                throw error("마일스톤 연결 손상")
            }
            try validateID(milestone.id.rawValue)
            byProject[milestone.projectID, default: []].append(milestone)
        }
        for (projectID, list) in byProject {
            do { try Milestone.validate(list, projectID: projectID) }
            catch let failure as MilestoneError { throw error(failure.errorDescription ?? "마일스톤 내용 손상") }
        }
        for row in try rows("SELECT id,project_id,payload FROM issues") where !row[2].isEmpty {
            let issue = try decode(Issue.self, row[2])
            guard let milestoneID = issue.milestoneID else { continue }
            guard let owner = byProject[issueProjects[issue.id] ?? ""]?.first(where: { $0.id == milestoneID }) else {
                throw error("이슈의 마일스톤 연결 손상")
            }
            guard owner.projectID == issueProjects[issue.id] else { throw error("이슈와 마일스톤의 프로젝트가 달라요") }
        }
    }

    private func validateProjectTransfers() throws {
        guard transferSchema else { return }
        for row in try rows("SELECT id,project_id,thread_id,request_message_id,payload FROM project_transfers") {
            let transfer = try decode(ProjectTransfer.self, row[4])
            try validateID(transfer.id)
            let source = try projectTransferSource(originThreadID: transfer.originThreadID, requestMessageID: transfer.requestMessageID,
                summary: transfer.summary, messageIDs: transfer.messageIDs, requireActive: false)
            let messageRows = try rows("SELECT message_id,ordinal FROM project_transfer_messages WHERE transfer_id=? ORDER BY ordinal", [transfer.id])
            guard [transfer.id, transfer.originProjectID, transfer.originThreadID, transfer.requestMessageID.uuidString] == Array(row.prefix(4)),
                  transfer.originProjectID == source.project.id, transfer.requestText == source.requestText,
                  transfer.messageIDs == source.messageIDs, transfer.attachments == source.attachments,
                  !transfer.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  transfer.lastError == nil || transfer.lastError == ProjectTransfer.deliveryFailureMessage || transfer.lastError == ProjectTransfer.unsupportedFailureMessage,
                  transfer.deliveredAt == nil || transfer.lastError == nil,
                  messageRows == transfer.messageIDs.enumerated().map({ [$0.element.uuidString, String($0.offset)] }) else {
                throw error("프로젝트 전달 원본 또는 상태 연결 손상")
            }
        }
    }


    /// Issue-level activity also supports Stallari/user entries without a Hird run.
    public func appendActivity(_ activity: ActivityEvent, issueID: Issue.ID, runID: HirdRun.ID? = nil) throws {
        defer { publishSnapshot() }
        try connection.transaction { try insertActivity(activity, issueID: issueID, runID: runID) }
    }

    private func insertActivity(_ activity: ActivityEvent, issueID: Issue.ID, runID: HirdRun.ID?) throws {
        if let runID {
            guard try requireRun(runID).issueID == issueID else { throw error("활동의 실행 연결이 달라요") }
        }
        let payload = try encode(activity)
        if let old = try rows("SELECT issue_id,run_id,payload FROM activities WHERE id=?", [activity.id.uuidString]).first {
            guard old == [issueID.rawValue, runID?.rawValue ?? "", payload] else { throw error("활동 식별자 충돌") }
            return
        }
        try connection.execute("INSERT INTO activities(id,issue_id,run_id,payload) VALUES(?,?,?,?)",
                               [activity.id.uuidString, issueID.rawValue, runID?.rawValue, payload])
    }

    public func close() throws {
        snapshotPublication?.cancel(); snapshotPublication = nil
        for subscriber in snapshotSubscribers.values { subscriber.finish() }
        snapshotSubscribers.removeAll()
        try connection.close()
    }

    public func projectID(forIssue id: Issue.ID) throws -> String {
        guard let row = try rows("SELECT project_id FROM issues WHERE id=?", [id.rawValue]).first else {
            throw error("이슈를 찾을 수 없어요")
        }
        return row[0]
    }

    public func saveProject(_ project: StoredProject) throws {
        defer { publishSnapshot() }
        try validateID(project.id)
        try validatePath(project.absolutePath)
        try connection.transaction {
            if let old: StoredProject = try record("projects", project.id), old.absolutePath != project.absolutePath {
                throw error("프로젝트 경로 변경은 새 프로젝트 식별자가 필요해요")
            }
            try connection.execute("INSERT INTO projects(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                                   [project.id, try encode(project)])
        }
    }

    public func saveThread(_ thread: ConversationThread) throws {
        defer { publishSnapshot() }
        try validateID(thread.id)
        guard !thread.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error("스레드 이름이 비었어요") }
        guard thread.issueID == nil || thread.projectID == nil else { throw error("프로젝트와 이슈 대화 소유권은 함께 사용할 수 없어요") }
        try connection.transaction {
            if let old: ConversationThread = try record("threads", thread.id) {
                guard old.createdAt == thread.createdAt, old.issueID == thread.issueID,
                      old.projectID == thread.projectID, old.projectHandoffDeliveredAt == thread.projectHandoffDeliveredAt,
                      old.originThreadID == thread.originThreadID else { throw error("스레드 생성 시각과 소유권·인계 기록은 바꿀 수 없어요") }
                if let issueID = old.issueID {
                    guard thread.name == (try requireIssue(issueID)).title else { throw error("이슈 대화 이름은 이슈 제목을 사용해요") }
                }
            } else if thread.issueID != nil || thread.projectID != nil || thread.originThreadID != nil || thread.projectHandoffDeliveredAt != nil {
                throw error("소유 대화는 전용 생성 API를 사용하세요")
            }
            try connection.execute("INSERT INTO threads(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                                   [thread.id, try encode(thread)])
        }
    }

    /// BEGIN IMMEDIATE makes discovery and insertion atomic even across repository actors.
    /// A caller's unsaved composer thread ID is adopted only for the first conversation.
    public func createProjectConversation(projectID: String, threadID: String? = nil) throws -> ConversationThread {
        defer { publishSnapshot() }
        try validateID(projectID)
        return try connection.transaction { try projectConversationInTransaction(projectID: projectID, threadID: threadID) }
    }
    private func projectConversationInTransaction(projectID: String, threadID: String? = nil) throws -> ConversationThread {
        guard let project: StoredProject = try record("projects", projectID) else { throw error("프로젝트를 찾을 수 없어요") }
        if let row = try rows("SELECT payload FROM threads WHERE json_extract(payload,'$.projectID')=? LIMIT 1", [projectID]).first {
            return try decode(ConversationThread.self, row[0])
        }
        let thread = ConversationThread(id: threadID ?? UUID().uuidString, name: project.name, projectID: projectID)
        try validateID(thread.id)
        guard thread.id != ConversationThread.defaultID,
              !thread.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error("프로젝트 대화 식별자 또는 이름이 잘못됐어요") }
        try connection.execute("INSERT INTO threads(id,payload) VALUES(?,?)", [thread.id, try encode(thread)])
        return thread
    }

    /// Only a successful project-context RPC admission may advance this durable marker.
    public func markProjectHandoffDelivered(threadID: String, at: Date) throws {
        var updated = false
        defer { if updated { publishSnapshot() } }
        try connection.transaction {
            guard var thread: ConversationThread = try record("threads", threadID),
                  thread.projectID != nil, thread.issueID == nil else { throw error("프로젝트 대화가 없어요") }
            guard thread.projectHandoffDeliveredAt == nil else { return }
            thread.projectHandoffDeliveredAt = at
            try connection.execute("UPDATE threads SET payload=? WHERE id=?", [try encode(thread), threadID])
            updated = true
        }
    }

    /// Creates the dedicated conversation, compact first context and proposal card in one commit.
    @discardableResult
    public func createIssueConversation(_ issue: Issue, projectID: String, originThreadID: String,
                                        handoffSummary: String) throws -> Bool {
        defer { publishSnapshot() }
        return try connection.transaction {
            guard let origin: ConversationThread = try record("threads", originThreadID),
                  origin.id != issue.conversationThreadID, origin.issueID == nil, origin.originThreadID == nil,
                  origin.projectID == nil || origin.projectID == projectID else { throw error("원래 대화의 프로젝트 또는 소유권이 달라요") }
            guard let _: StoredProject = try record("projects", projectID) else { throw error("프로젝트를 찾을 수 없어요") }
            if let old: Issue = try record("issues", issue.id.rawValue) {
                if let fingerprint = issue.creationRequestFingerprint {
                    guard old.creationRequestFingerprint == fingerprint,
                          try self.projectID(forIssue: old.id) == projectID,
                          let owner: ConversationThread = try record("threads", old.conversationThreadID),
                          owner.issueID == old.id, owner.originThreadID == originThreadID else { throw StallariError.conflictingID }
                    return false
                }
                guard old.title == issue.title, old.acceptance.map(\.text) == issue.acceptance.map(\.text),
                      old.proposal == issue.proposal, old.milestoneID == issue.milestoneID,
                      try self.projectID(forIssue: old.id) == projectID,
                      let owner: ConversationThread = try record("threads", old.conversationThreadID),
                      owner.issueID == old.id, owner.originThreadID == originThreadID else { throw StallariError.conflictingID }
                return false
            }
            let thread = ConversationThread(id: issue.conversationThreadID, name: issue.title, createdAt: issue.startedAt,
                                            issueID: issue.id, originThreadID: originThreadID)
            try validateID(thread.id)
            try connection.execute("INSERT INTO threads(id,payload) VALUES(?,?)", [thread.id, try encode(thread)])
            guard let proposal = issue.proposal else { throw error("이슈 대화의 저장된 제안이 없어요") }
            let context = handoffSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = context.isEmpty ? issue.title : context
            // Context precedes the proposal card in both durable row order and display time.
            try saveIssueInTransaction(issue, projectID: projectID, expectedJudgementRun: nil, appendCard: false)
            let item = ChatItem(at: issue.startedAt, kind: .stallari(summary, project: issue.projectName))
            let stored = StoredChat(item, link: .init(chatID: item.id, projectID: projectID, issueID: issue.id, runID: nil, threadID: thread.id))
            try connection.execute("INSERT INTO chat(id,project_id,issue_id,run_id,payload,thread_id) VALUES(?,?,?,?,?,?)",
                [item.id.uuidString, projectID, issue.id.rawValue, nil, try encode(stored), thread.id])
            try appendProposalCard(issueID: issue.id, projectID: projectID, version: proposal.version, at: issue.startedAt)
            return true
        }
    }

    /// Explicit selection/approval queues initial context before opening an issue RPC.
    func prepareIssueHandoff(threadID: String) throws {
        var inserted = false
        defer { if inserted { publishSnapshot() } }
        try connection.transaction {
            guard let thread: ConversationThread = try record("threads", threadID), let issueID = thread.issueID,
                  try requireIssue(issueID).archivedAt == nil else { return }
            let deliveryID = "issue-handoff:" + issueID.rawValue
            if let _: ThreadDelivery = try record("thread_deliveries", deliveryID) { return }
            let chats: [StoredChat] = try records("chat", whereSQL: "thread_id=?", values: [threadID])
            guard let first = chats.first, case .stallari(let text, _) = try first.item().kind else { throw error("이슈 인계 문맥이 없어요") }
            try insertThreadDelivery(id: deliveryID, issueID: issueID, runID: nil,
                                     at: thread.createdAt, kind: .handoff(text))
            inserted = true
        }
    }

    /// Saves view metadata and criteria; runs/activity must be written through their own APIs.
    public func saveIssue(_ issue: Issue, projectID: String, expectedJudgementRun: PersistedRun? = nil) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            try saveIssueInTransaction(issue, projectID: projectID, expectedJudgementRun: expectedJudgementRun)
        }
    }
    private func saveIssueInTransaction(_ issue: Issue, projectID: String, expectedJudgementRun: PersistedRun?,
                                       appendCard: Bool = true) throws {
        try validateID(issue.id.rawValue)
        guard let thread: ConversationThread = try record("threads", issue.conversationThreadID),
              thread.projectID == nil, thread.issueID == nil || thread.issueID == issue.id else { throw error("이슈의 대화 소유권이 달라요") }
        guard issue.hirds.isEmpty, issue.events.isEmpty else { throw error("실행과 활동은 전용 저장 API로 저장하세요") }
            var saved = issue
            saved.latestResult = nil; saved.executionModel = nil; saved.executionThinking = nil
            if let old: Issue = try record("issues", issue.id.rawValue) {
                guard old.conversationThreadID == issue.conversationThreadID else { throw error("이슈의 스레드는 바꿀 수 없어요") }
                if let thread: ConversationThread = try record("threads", issue.conversationThreadID), thread.issueID == issue.id {
                    guard old.archivedAt == nil else { throw error("닫힌 이슈 대화는 읽기 전용이에요") }
                    guard old.title == issue.title else { throw error("이슈 대화의 제목은 저장된 이슈 제목과 같아야 해요") }
                }
                guard issue.proposal == old.proposal, issue.approval == old.approval,
                      issue.approvalHistory == old.approvalHistory,
                      issue.proposalHistory == nil || issue.proposalHistory == old.proposalHistory,
                      issue.proposalReviewNote == old.proposalReviewNote else {
                    throw error("제안·승인 변경은 전용 API를 사용하고 최신 이슈를 다시 확인하세요")
                }
                saved.proposalHistory = old.proposalHistory
                saved.creationRequestFingerprint = old.creationRequestFingerprint
                if old.state == .awaitingApproval || old.state == .rejected { saved.state = old.state }
                saved.completedAt = old.completedAt
            } else if let proposal = saved.proposal {
                try validateProposal(proposal, criterionCount: saved.acceptance.count)
                guard proposal.version == 1, saved.state == .awaitingApproval,
                      saved.approval == nil, saved.approvalHistory?.isEmpty != false else {
                    throw error("새 이슈 제안의 초기 상태가 잘못됐어요")
                }
                guard saved.proposalHistory == nil || saved.proposalHistory == [proposal] else { throw error("새 이슈의 제안 이력이 잘못됐어요") }
                saved.proposalHistory = [proposal]
                if let previous = proposal.previousRunID {
                    let run = try requireRun(previous)
                    guard run.issueID == saved.id, run.projectID == projectID, run.state.isTerminal else {
                        throw error("이전 실행은 같은 이슈·프로젝트의 종료된 실행이어야 해요")
                    }
                }
            } else if saved.proposalHistory?.isEmpty == false || saved.approval != nil || saved.approvalHistory?.isEmpty == false {
                throw error("제안 없는 승인은 저장할 수 없어요")
            }
            if let expected = expectedJudgementRun {
                var expectedState = expected
                if normalizedSchema { expectedState.resultHistory = [] }
                let own: [PersistedRun] = try records("runs").filter { $0.issueID == issue.id }
                // Judgement output is not an execution generation/result change.
                expectedState.acceptanceEvidence = own.last?.acceptanceEvidence
                guard let latest = own.last, latest == expectedState, latest.projectID == projectID,
                      latest.state == .succeeded, latest.result != nil,
                      let old: Issue = try record("issues", issue.id.rawValue),
                      old.state != .awaitingApproval, old.state != .rejected,
                      old.proposal == nil || (old.approval?.version == old.proposal?.version && old.approval?.runID == latest.id),
                      old.acceptance.map(\.text) == issue.acceptance.map(\.text),
                      !issue.acceptance.isEmpty, issue.acceptance.allSatisfy({ $0.state != .pending && !$0.evidence.isEmpty }),
                      issue.state == (issue.acceptance.allSatisfy({ $0.state == .met }) ? .done : .failed) else {
                    throw error("판정 중 이슈·승인 제안·완료 조건 또는 최신 실행이 달라졌어요")
                }
                saved.confirmed = old.confirmed
                if issue.state == .done { saved.completedAt = old.completedAt ?? .now }
            }
            if let row = try rows("SELECT project_id FROM issues WHERE id=?", [issue.id.rawValue]).first,
               row[0] != projectID { throw error("이슈를 다른 프로젝트에 연결할 수 없어요") }
            if milestoneSchema {
                if let milestoneID = issue.milestoneID {
                    guard let milestone: Milestone = try record("milestones", milestoneID.rawValue),
                          milestone.projectID == projectID else { throw error("이슈의 마일스톤이 이 프로젝트에 없어요") }
                }
                if let old: Issue = try record("issues", issue.id.rawValue), old.milestoneID != issue.milestoneID {
                    throw error("이슈의 마일스톤은 만든 뒤에 바꿀 수 없어요")
                }
            }
            try connection.execute("INSERT INTO issues(id,project_id,payload,thread_id) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                                   [issue.id.rawValue, projectID, try encode(saved), saved.conversationThreadID])
            try preserveAcceptanceEvidence(for: saved)
            if let run = expectedJudgementRun, saved.state == .done, let result = run.result {
                let notices: [CompletionNotification] = try records("notifications", whereSQL: "run_id=?", values: [run.id.rawValue])
                if let notice = notices.last {
                    try insertMainDelivery(id: "hird-complete:" + notice.id, issueID: saved.id, runID: run.id,
                        at: saved.completedAt ?? .now, kind: .completion(notificationID: notice.id, summary: result.summary))
                }
            }
            if appendCard, let proposal = saved.proposal, saved.state == .awaitingApproval {
                try appendProposalCard(issueID: saved.id, projectID: projectID, version: proposal.version, at: .now)
            }
    }

    public func saveIssueProposal(issueID: Issue.ID, proposal: IssueProposal, expectedVersion: Int?) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            var issue = try requireWritableIssue(issueID)
            var proposal = proposal
            if proposal.stages == nil { proposal.stages = issue.proposal?.stages }
            try validateProposal(proposal, criterionCount: issue.acceptance.count)
            try requireNoActiveRun(issueID)
            guard issue.proposal?.version == expectedVersion,
                  proposal.version == (issue.proposal?.version ?? 0) + 1 else { throw error("제안 버전이 달라졌어요") }
            if let previous = proposal.previousRunID {
                let run = try requireRun(previous)
                guard run.issueID == issueID, run.projectID == (try projectID(forIssue: issueID)),
                      run.state.isTerminal else { throw error("이전 실행은 같은 이슈의 종료된 실행이어야 해요") }
            }
            var history = issue.proposalHistory ?? issue.proposal.map { [$0] } ?? []
            history.append(proposal)
            issue.proposalHistory = history
            issue.proposal = proposal; issue.approval = nil; issue.proposalReviewNote = nil
            issue.state = .awaitingApproval; issue.confirmed = false
            try writeIssue(issue)
            try appendProposalCard(issueID: issueID, projectID: try projectID(forIssue: issueID), version: proposal.version, at: .now)
        }
    }

    /// Backfill only on connection, never on a render or periodic refresh.
    public func ensureProposalCards() throws {
        defer { publishSnapshot() }
        try connection.transaction {
            for issue: Issue in try records("issues") where issue.state == .awaitingApproval {
                if let proposal = issue.proposal {
                    try appendProposalCard(issueID: issue.id, projectID: try projectID(forIssue: issue.id), version: proposal.version, at: .now)
                }
            }
        }
    }

    private func appendProposalCard(issueID: Issue.ID, projectID: String, version: Int, at: Date) throws {
        let existing: [StoredChat] = try records("chat", whereSQL: "issue_id=?", values: [issueID.rawValue])
        guard !existing.contains(where: { if case .proposal(let id, let v) = $0.kind { id == issueID && v == version } else { false } }) else { return }
        let item = ChatItem(at: at, kind: .proposal(issueID, version: version))
        let threadID = try requireIssue(issueID).conversationThreadID
        let wire = StoredChat(item, link: .init(chatID: item.id, projectID: projectID, issueID: issueID, runID: nil, threadID: threadID))
        try connection.execute("INSERT INTO chat(id,project_id,issue_id,run_id,payload,thread_id) VALUES(?,?,?,?,?,?)",
                               [item.id.uuidString, projectID, issueID.rawValue, nil, try encode(wire), threadID])
    }

    public func confirmAppResult(issueID: Issue.ID, note: String, at: Date) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            var issue = try requireIssue(issueID)
            let own: [PersistedRun] = try records("runs", whereSQL: "issue_id=?", values: [issueID.rawValue])
            let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard issue.archivedAt == nil, issue.needsAppConfirmation, !note.isEmpty,
                  let latest = own.last, latest.state == .succeeded, latest.result != nil else { throw error("실제 앱 확인만 남은 최신 성공 실행에 확인 사유를 남겨 주세요") }
            issue.userAppConfirmation = .init(at: at, note: note, runID: latest.id)
            try writeIssue(issue)
        }
    }

    @discardableResult
    public func closeIssue(_ id: Issue.ID, reason: IssueCloseReason, at: Date, note: String = "", supersededBy: Issue.ID? = nil,
                           includedIssueIDs: [Issue.ID] = [], expectedVersion: Int? = nil) throws -> [Issue.ID: String] {
        defer { publishSnapshot() }
        return try connection.transaction {
            try requireNoActiveRun(id)
            var issue = try requireIssue(id)
            if let expectedVersion {
                guard issue.proposal?.version == expectedVersion else { throw error("제안 버전이 달라졌어요") }
                if issue.archivedAt != nil {
                    guard issue.archiveReason == reason.rawValue,
                          issue.archiveNote == note.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        throw error("이미 다른 내용으로 닫힌 이슈예요")
                    }
                }
            }
            let projectID = try projectID(forIssue: id)
            if let replacement = supersededBy {
                guard reason == .superseded, replacement != id,
                      try self.projectID(forIssue: replacement) == projectID else { throw error("같은 프로젝트의 다른 대체 이슈를 지정하세요") }
                _ = try requireIssue(replacement)
            }
            guard includedIssueIDs.isEmpty || reason == .applied else { throw error("포함 이슈는 반영됨으로 닫을 때만 지정할 수 있어요") }
            guard Set(includedIssueIDs).count == includedIssueIDs.count,
                  !includedIssueIDs.contains(id) else { throw error("포함 이슈는 중복 없이 다른 이슈를 지정하세요") }
            let included = try includedIssueIDs.map { includedID in
                let value = try requireIssue(includedID)
                guard try self.projectID(forIssue: includedID) == projectID else { throw error("같은 프로젝트의 포함 이슈를 지정하세요") }
                return value
            }
            let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if issue.archivedAt == nil {
                issue.archivedAt = at; issue.archiveReason = reason.rawValue
                issue.archiveNote = note; issue.supersededBy = supersededBy
                try writeIssue(issue)
            }
            var skipped: [Issue.ID: String] = [:]
            for var includedIssue in included {
                if includedIssue.archivedAt != nil {
                    skipped[includedIssue.id] = "이미 닫힌 이슈예요"
                    continue
                }
                if try hasActiveRun(includedIssue.id) {
                    skipped[includedIssue.id] = "진행 중인 이슈 실행이 있어요"
                    continue
                }
                includedIssue.archivedAt = at; includedIssue.archiveReason = IssueCloseReason.applied.rawValue
                includedIssue.archiveNote = note; includedIssue.integratedInto = id
                try writeIssue(includedIssue)
            }
            return skipped
        }
    }

    public func approveIssueProposal(issueID: Issue.ID, version: Int, at: Date, source: String? = nil) throws -> IssueProposal {
        defer { publishSnapshot() }
        return try connection.transaction {
            try requireExecutionIssue(issueID)
            var issue = try requireWritableIssue(issueID)
            let proposal = try requireProposal(issue, version: version)
            if issue.approval?.version == version {
                guard source != "phone" else { throw error("이미 처리한 제안 승인이에요") }
                return proposal
            }
            if source == "phone", issue.proposalReviewNote != nil { throw error("수정 요청한 제안은 새 버전으로 승인해 주세요") }
            try requireNoActiveRun(issueID)
            guard issue.state == .awaitingApproval else { throw error("승인 대기 중인 제안만 승인할 수 있어요") }
            let approval = IssueApproval(version: version, approvedAt: at, runID: nil, source: source)
            issue.approval = approval
            issue.approvalHistory = (issue.approvalHistory ?? []) + [approval]
            issue.proposalReviewNote = nil
            try writeIssue(issue)
            return proposal
        }
    }

    public func requestIssueProposalChanges(issueID: Issue.ID, version: Int, note: String, source: String? = nil) throws {
        try reviewIssueProposal(issueID: issueID, version: version, note: note, rejected: false, source: source)
    }
    public func rejectIssueProposal(issueID: Issue.ID, version: Int, note: String, source: String? = nil) throws {
        try reviewIssueProposal(issueID: issueID, version: version, note: note, rejected: true, source: source)
    }
    private func reviewIssueProposal(issueID: Issue.ID, version: Int, note: String, rejected: Bool, source: String?) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            var issue = try requireWritableIssue(issueID)
            _ = try requireProposal(issue, version: version)
            if source == "phone" {
                guard issue.state == .awaitingApproval, issue.approval == nil, issue.proposalReviewNote == nil else {
                    throw error("이미 처리한 제안이에요. 최신 버전을 확인해 주세요")
                }
            }
            try requireNoActiveRun(issueID)
            guard issue.approval?.runID == nil else { throw error("이미 실행한 제안은 새 버전으로 수정하세요") }
            issue.approval = nil; issue.proposalReviewNote = note
            issue.state = rejected ? .rejected : .awaitingApproval
            try writeIssue(issue)
            if !rejected {
                try insertThreadDelivery(id: "proposal-revision:\(issueID.rawValue):\(version):\(ResponseRulesFile.version(of: note))",
                    issueID: issueID, runID: nil, at: .now, kind: .proposalRevision(version: version, note: note))
            }
        }
    }

    /// Approval consumption and run creation commit together. Only .applied permits launch.
    public func createApprovedRun(_ run: PersistedRun, proposalVersion: Int) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            var issue = try requireIssue(run.issueID)
            let proposal = try requireProposal(issue, version: proposalVersion)
            var run = run
            guard run.stagePlan == nil || run.stagePlan == proposal.stages else { throw error("승인한 단계 계획과 실행 내용이 달라요") }
            run.stagePlan = proposal.stages
            guard var approval = issue.approval, approval.version == proposalVersion,
                  run.hird.role == proposal.instruction, run.requestedModel == proposal.model,
                  run.mode == proposal.mode, run.previousRunID == proposal.previousRunID,
                  proposal.thinking == nil || run.requestedThinking == proposal.thinking else {
                throw error("승인한 제안과 실행 내용이 달라요")
            }
            if let consumed = approval.runID {
                guard consumed == run.id else { throw error("이미 다른 실행에서 소비한 승인이에요") }
                guard try createRunInTransaction(run) == .duplicate else { throw error("소비한 승인의 실행이 없어요") }
                return .duplicate
            }
            try requireNoActiveRun(run.issueID)
            let ownerID = try projectID(forIssue: run.issueID)
            guard run.projectID == ownerID, issue.archivedAt == nil,
                  let project: StoredProject = try record("projects", ownerID), project.archivedAt == nil else {
                throw error("보관한 이슈·프로젝트나 다른 프로젝트에서는 실행할 수 없어요")
            }
            let projectRuns: [PersistedRun] = try records("runs", whereSQL: "project_id=?", values: [ownerID])
            let activeCount = projectRuns.reduce(0) { count, run in
                count + ((!run.state.isTerminal || (run.state == .cancelled && run.processEndedAt == nil)) ? 1 : 0)
            }
            guard project.settings.allowsAdditionalHird(activeCount: activeCount) else { throw error("프로젝트의 동시 Hird 실행 한도를 넘었어요") }
            let existing: PersistedRun? = try record("runs", run.id.rawValue)
            guard existing == nil else { throw error("승인되지 않은 기존 실행 식별자예요") }
            let outcome = try createRunInTransaction(run)
            approval.runID = run.id
            // Run creation changes view state; keep that state while consuming approval.
            issue = try requireIssue(run.issueID)
            issue.approval = approval
            guard var history = issue.approvalHistory,
                  let index = history.lastIndex(where: { $0 == IssueApproval(version: proposalVersion, approvedAt: approval.approvedAt, runID: nil, source: approval.source) }) else {
                throw error("승인 기록이 없어요")
            }
            history[index] = approval; issue.approvalHistory = history
            try writeIssue(issue)
            return outcome
        }
    }

    private func requireIssue(_ id: Issue.ID) throws -> Issue {
        guard let issue: Issue = try record("issues", id.rawValue) else { throw error("이슈가 없어요: \(id.rawValue)") }
        return issue
    }
    private func requireWritableIssue(_ id: Issue.ID) throws -> Issue {
        let issue = try requireIssue(id)
        if issue.archivedAt != nil, let thread: ConversationThread = try record("threads", issue.conversationThreadID),
           thread.issueID == id { throw error("닫힌 이슈 대화는 읽기 전용이에요") }
        return issue
    }
    private func requireProposal(_ issue: Issue, version: Int) throws -> IssueProposal {
        guard let proposal = issue.proposal, proposal.version == version else { throw error("제안 버전이 달라졌어요") }
        return proposal
    }
    private func hasActiveRun(_ id: Issue.ID) throws -> Bool {
        let runs: [PersistedRun] = try records("runs", whereSQL: "issue_id=?", values: [id.rawValue])
        return runs.contains { !$0.state.isTerminal || ($0.state == .cancelled && $0.processEndedAt == nil) }
    }
    private func requireNoActiveRun(_ id: Issue.ID) throws {
        guard try !hasActiveRun(id) else { throw error("진행 중인 이슈 실행이 있어요") }
    }
    private func validateProposal(_ proposal: IssueProposal, criterionCount: Int) throws {
        guard proposal.version > 0, !proposal.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposal.model.split(separator: "/", maxSplits: 1).count == 2,
              !proposal.model.contains("\n") else { throw error("제안 내용이나 모델이 잘못됐어요") }
        try validateStagePlan(proposal.stagePlan, criterionCount: criterionCount)
    }

    private func validateStagePlan(_ plan: [IssueStage], criterionCount: Int) throws {
        var ids = Set<String>()
        for stage in plan {
            try validateID(stage.id)
            guard stage.id == stage.id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !stage.id.contains(where: \.isWhitespace),
                  ids.insert(stage.id).inserted,
                  !stage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !stage.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  stage.criterion.map({ (1...max(1, criterionCount)).contains($0) && criterionCount > 0 }) ?? true else {
                throw error("단계 ID·제목·확인 방법 또는 완료 조건 번호가 잘못됐어요")
            }
        }
    }
    private func writeIssue(_ issue: Issue) throws {
        try connection.execute("UPDATE issues SET payload=? WHERE id=?", [try encode(issue), issue.id.rawValue])
    }

    /// Call and commit before spawning OMP. Only .applied authorizes the caller to launch.
    public func createRun(_ run: PersistedRun) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction { try createRunInTransaction(run) }
    }

    private func createRunInTransaction(_ run: PersistedRun) throws -> MutationOutcome {
        guard !runStartsSuspended else { throw error("앱 종료·설치 준비 중에는 새 Hird를 시작하지 않아요") }
        try validateID(run.id.rawValue); try validateID(run.ownershipToken)
        guard run.state == .working, run.hird.status == .working, run.lastSequence == 0,
              run.result == nil, run.resultHistory.isEmpty, (run.savedResultCount ?? 0) == 0, run.endedAt == nil, run.stopReason == nil,
              run.cancellationRequestedAt == nil, run.processEndedAt == nil,
              run.observedModel == nil, run.observedThinking == nil,
              run.stageReports?.isEmpty != false, run.lastFileChangeAt == nil else { throw error("새 실행의 초기 상태가 잘못됐어요") }
        if let workspace = run.workspace { try validateWorkspace(workspace) }
        if let session = run.ompSessionID { try validateID(session) }
        do {
            if let existing: PersistedRun = try record("runs", run.id.rawValue) {
                guard existing.projectID == run.projectID, existing.issueID == run.issueID,
                      existing.ownershipToken == run.ownershipToken, existing.startedAt == run.startedAt,
                      existing.previousRunID == run.previousRunID, existing.mode == run.mode,
                      existing.requestedModel == run.requestedModel, existing.requestedThinking == run.requestedThinking,
                      existing.hird.role == run.hird.role, existing.stagePlan == run.stagePlan else { throw error("실행 식별자가 다른 실행에 사용됐어요") }
                return .duplicate
            }
            if let previous = run.previousRunID {
                let old = try requireRun(previous)
                guard old.issueID == run.issueID, old.projectID == run.projectID, old.state.isTerminal else {
                    throw error("재작업은 같은 이슈의 종료된 실행에 연결하세요")
                }
            }
            try requireExecutionIssue(run.issueID)
        var target = try requireWritableIssue(run.issueID)
            try validateStagePlan(run.stagePlan ?? [], criterionCount: target.acceptance.count)
            // Older payloads may only retain the last judgement on the Issue.
            // Preserve it on its own terminal run before inserting/resetting the new one.
            try preserveAcceptanceEvidence(for: target)
            try connection.execute("INSERT INTO runs(id,issue_id,project_id,payload) VALUES(?,?,?,?)",
                                   [run.id.rawValue, run.issueID.rawValue, run.projectID, try encode(run)])
            target.state = .running; target.confirmed = false; target.headline = "Hird 실행"; target.detail = run.hird.role
            target.completedAt = nil
            for index in target.acceptance.indices { target.acceptance[index].state = .pending; target.acceptance[index].evidence = "" }
            try connection.execute("UPDATE issues SET payload=? WHERE id=?", [try encode(target), target.id.rawValue])
            return .applied
        }
    }

    public func appendChat(_ item: ChatItem, projectID: String, issueID: Issue.ID? = nil, runID: HirdRun.ID? = nil,
                           threadID: String = ConversationThread.defaultID) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            try appendChatInTransaction(item, projectID: projectID, issueID: issueID, runID: runID, threadID: threadID)
        }
    }

    /// A link groups messages inside the existing thread; it never creates an engine session.
    public func linkMessageConversation(_ id: UUID, threadID: String) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            guard var stored: StoredChat = try record("chat", id.uuidString),
                  stored.link.conversationThreadID == threadID,
                  stored.conversationRootID == nil, stored.activity == nil,
                  case .user = stored.kind else { throw error("이 대화의 사용자 메시지를 선택해 주세요") }
            stored.isConversationLink = true
            try connection.execute("UPDATE chat SET payload=? WHERE id=?", [try encode(stored), id.uuidString])
        }
    }

    /// Resolve assistant ownership and insert atomically, without trusting a UI selection.
    public func appendAssistantChat(_ item: ChatItem, threadID: String) throws {
        defer { publishSnapshot() }
        try connection.transaction {
            guard let thread: ConversationThread = try record("threads", threadID) else { throw error("대화가 없어요") }
            let projectID: String
            if let owner = thread.projectID {
                guard thread.issueID == nil, let project: StoredProject = try record("projects", owner),
                      project.id != StoredProject.hubID else { throw error("프로젝트 대화 소유권이 달라요") }
                projectID = owner
            } else if let issueID = thread.issueID {
                guard try requireIssue(issueID).conversationThreadID == threadID else { throw error("이슈 대화 소유권이 달라요") }
                projectID = try self.projectID(forIssue: issueID)
            } else {
                projectID = StoredProject.hubID
            }
            try appendChatInTransaction(item, projectID: projectID, issueID: thread.issueID, runID: nil, threadID: threadID)
        }
    }

    private func appendChatInTransaction(_ item: ChatItem, projectID: String, issueID: Issue.ID?, runID: HirdRun.ID?, threadID: String) throws {
        if let id = item.preparationID {
            guard let preparation = try preparationItem(id), preparation.projectID == projectID else { throw error("대화와 준비 항목의 프로젝트가 달라요") }
        }
        guard let thread: ConversationThread = try record("threads", threadID),
              thread.projectID == nil || thread.projectID == projectID else { throw error("채팅의 프로젝트 대화 연결이 달라요") }
        if let rootID = item.conversationRootID {
            guard let root: StoredChat = try record("chat", rootID.uuidString),
                  root.link.conversationThreadID == threadID, root.isConversationLink == true,
                  root.conversationRootID == nil, rootID != item.id else { throw error("작은 대화의 원본 메시지를 찾지 못했어요") }
        }
        var attachedIssue = issueID
        switch item.kind {
        case .issue(let id), .proposal(let id, _):
            if let attachedIssue, attachedIssue != id { throw error("채팅 이슈 연결이 달라요") }
            attachedIssue = id
        case .notice(let notice):
            if let attachedIssue, attachedIssue != notice.issue { throw error("통지 이슈 연결이 달라요") }
            attachedIssue = notice.issue
        default: break
        }
        if let runID {
            let run = try requireRun(runID)
            guard run.projectID == projectID, attachedIssue == nil || attachedIssue == run.issueID else { throw error("채팅 실행 연결이 달라요") }
            attachedIssue = run.issueID
        }
        if let attachedIssue {
            guard try requireIssue(attachedIssue).conversationThreadID == threadID else { throw error("채팅의 스레드 연결이 달라요") }
        }
        let stored = StoredChat(item, link: .init(chatID: item.id, projectID: projectID, issueID: attachedIssue, runID: runID, threadID: threadID))
        let payload = try encode(stored)
        if let old = try rows("SELECT payload FROM chat WHERE id=?", [item.id.uuidString]).first {
            guard old[0] == payload else { throw error("채팅 식별자 충돌") }; return
        }
        try connection.execute("INSERT INTO chat(id,project_id,issue_id,run_id,payload,thread_id) VALUES(?,?,?,?,?,?)",
                               [item.id.uuidString, projectID, attachedIssue?.rawValue, runID?.rawValue, payload, threadID])
    }

    /// Event receipt, state, activity/question/result and outbox insertion share one transaction.
    public func apply(_ event: RunEvent) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction { try applyInTransaction(event) }
    }

    private func sameEvent(_ lhs: RunEvent, _ rhs: RunEvent) -> Bool {
        guard lhs.id == rhs.id, lhs.runID == rhs.runID, lhs.sequence == rhs.sequence, lhs.at == rhs.at else { return false }
        if case .stage(var left) = lhs.payload, case .stage(var right) = rhs.payload {
            left.verified = nil; right.verified = nil
            return left == right
        }
        return lhs.payload == rhs.payload
    }

    private func stageCompletionVerified(_ report: StageReport, previous: Date, at: Date,
                                         on run: PersistedRun) throws -> Bool {
        var missing = Set(report.verificationIDs)
        var confirmed = !report.verificationIDs.isEmpty || (run.lastFileChangeAt.map { $0 > previous && $0 <= at } ?? false)
        func consider(_ result: RunResult) {
            for check in result.verifications {
                missing.remove(check.id)
                if !confirmed && check.isSingleCheck && check.exitCode == 0 && check.finishedAt > previous && check.finishedAt <= at {
                    confirmed = true
                }
            }
        }
        if let result = run.result { consider(result) }
        if !missing.isEmpty || !confirmed {
            if normalizedSchema {
                let history = try rows("SELECT result_id FROM run_result_history WHERE run_id=? ORDER BY ordinal DESC",
                                       [run.id.rawValue])
                for row in history.dropFirst() {
                    consider(try loadResult(row[0]))
                    if missing.isEmpty && confirmed { break }
                }
            } else {
                for result in run.resultHistory.dropLast().reversed() {
                    consider(result)
                    if missing.isEmpty && confirmed { break }
                }
            }
        }
        guard missing.isEmpty else { throw error("이 실행에 저장되지 않은 검증 ID는 사용할 수 없어요") }
        return confirmed
    }

    private func saveStageReport(_ input: StageReport, at: Date, on run: inout PersistedRun) throws -> StageReport {
        let previous = run.stageReports?.last?.at ?? run.startedAt
        guard at.timeIntervalSinceReferenceDate.isFinite, input.at == at, at >= previous,
              run.lastFileChangeAt.map({ at >= $0 }) ?? true else { throw error("단계 보고 시각이 실행 이력보다 앞서거나 호스트 시각과 달라요") }
        let current = run.stageReports?.last(where: { $0.action == .replanned })?.plan ?? run.stagePlan ?? []
        guard !current.isEmpty else { throw error("승인된 단계 계획이 없어요") }
        guard Set(input.verificationIDs).count == input.verificationIDs.count else { throw error("중복 검증 ID는 사용할 수 없어요") }
        var report = input
        report.verified = nil
        switch report.action {
        case .replanned:
            guard let plan = report.plan, !plan.isEmpty,
                  let reason = report.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  report.verificationIDs.isEmpty,
                  report.stageID.isEmpty || plan.contains(where: { $0.id == report.stageID }) else {
                throw error("재계획은 전체 순서 있는 계획과 변경 사유가 필요해요")
            }
            let issue = try requireIssue(run.issueID)
            try validateStagePlan(plan, criterionCount: issue.acceptance.count)
        case .started, .completed:
            guard current.contains(where: { $0.id == report.stageID }), report.plan == nil, report.reason == nil else {
                throw error("단계 ID가 현재 계획에 없거나 재계획 필드가 잘못됐어요")
            }
            if report.action == .started {
                guard report.verificationIDs.isEmpty else { throw error("시작 보고에는 완료 검증 ID를 붙일 수 없어요") }
            } else {
                report.verified = try stageCompletionVerified(report, previous: previous, at: at, on: run)
            }
        }
        if run.stageReports == nil { run.stageReports = [] }
        run.stageReports?.append(report)
        return report
    }

    private func applyInTransaction(_ event: RunEvent) throws -> MutationOutcome {
        try validateID(event.id)
        guard event.sequence > 0 else { throw error("이벤트 순서는 1부터 시작해요") }
        var storedEvent = event
        if case .stage(var report) = event.payload {
            report.verified = nil
            storedEvent = .init(id: event.id, runID: event.runID, sequence: event.sequence, at: event.at, payload: .stage(report))
        }
        if let old = try rows("SELECT payload FROM run_events WHERE id=?", [event.id]).first {
            guard try sameEvent(decodeStoredEvent(old[0]), event) else { throw error("이벤트 식별자에 다른 내용이 도착했어요") }
            return .duplicate
        }
        var run = try requireRun(event.runID)
        let outcome: MutationOutcome
        if run.state.isTerminal {
            // Archival data can arrive after teardown/cancel, but never revives state.
            switch event.payload {
            case .saveResult(let result):
                try saveResult(result, on: &run); outcome = .applied
            case .recordWorkspace(let workspace):
                try validateWorkspace(workspace)
                if let old = run.workspace, old.worktreePath != workspace.worktreePath { throw error("실행의 작업 경로는 바꿀 수 없어요") }
                run.workspace = workspace; outcome = .applied
            default: outcome = .ignoredTerminal
            }
            if outcome == .applied { run.lastSequence = max(run.lastSequence, event.sequence); try writeRun(run) }
        }
        else if event.sequence <= run.lastSequence { outcome = .ignoredStale }
        else {
            switch event.payload {
            case .stage(let report):
                let saved = try saveStageReport(report, at: event.at, on: &run)
                run.hird.lastActivityAt = max(run.hird.lastActivityAt, event.at)
                storedEvent = .init(id: event.id, runID: event.runID, sequence: event.sequence, at: event.at, payload: .stage(saved))
            case .fileChanged(let path):
                guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !path.contains("\0"),
                      event.at.timeIntervalSinceReferenceDate.isFinite, event.at >= run.startedAt,
                      run.lastFileChangeAt.map({ event.at >= $0 }) ?? true,
                      run.stageReports?.last.map({ event.at >= $0.at }) ?? true else { throw error("파일 변경 경로나 시각이 잘못됐어요") }
                run.lastFileChangeAt = event.at
            case .recordWorkspace(let workspace):
                try validateWorkspace(workspace)
                if let old = run.workspace, old.worktreePath != workspace.worktreePath {
                    throw error("실행의 작업 경로는 바꿀 수 없어요")
                }
                run.workspace = workspace
            case .saveResult(let result):
                try saveResult(result, on: &run)
            case .bindModel(let model):
                guard model.split(separator: "/", maxSplits: 1).count == 2, !model.contains("\n") else { throw error("모델 식별자가 잘못됐어요") }
                guard run.observedModel == nil || run.observedModel == model else { throw error("실행 중 모델 기록은 바꿀 수 없어요") }
                run.observedModel = model
            case .bindThinking(let thinking):
                guard ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(thinking),
                      run.observedThinking == nil || run.observedThinking == thinking else { throw error("실행의 실제 추론 설정이 달라요") }
                run.observedThinking = thinking
            case .recordResources(let resources):
                guard run.hird.runtimeResources == nil else { throw error("실행 시작 자원 목록은 바꿀 수 없어요") }
                run.hird.runtimeResources = resources
            case .recordLSP(let record):
                if run.hird.lspRecords == nil { run.hird.lspRecords = [] }
                run.hird.lspRecords?.append(record)
            case .bindSession(let session):
                try validateID(session)
                guard run.ompSessionID == nil || run.ompSessionID == session else { throw error("OMP 세션 연결이 달라요") }
                run.ompSessionID = session
            case .activity(let activity, let command, let steps):
                try insertActivity(activity, issueID: run.issueID, runID: run.id)
                run.hird.currentCommand = command
                if let command, HirdProgress.isFileChange(command) { run.hird.lastEditAt = activity.at }
                run.hird.lastActivityAt = max(run.hird.lastActivityAt, activity.at)
                if let steps { run.hird.steps = steps; try updateWaiting(&run, at: event.at) }
            case .activityState(let activity, let command):
                // A repeated delta or the same tool call is not a new record and does not refresh
                // silence: only an actual transition moves the line, the ledger and `lastActivityAt`.
                if run.hird.currentActivity.map({ !$0.sameState(as: activity) }) ?? true {
                    try insertActivity(.init(at: activity.at, actor: run.hird.name, text: activity.displayText,
                                             detail: activity.target), issueID: run.issueID, runID: run.id)
                    run.hird.currentActivity = activity
                    var recent = run.hird.recentActivities ?? []
                    if let last = recent.last, last.sameState(as: activity) { recent.removeLast() }
                    recent.append(activity)
                    run.hird.recentActivities = recent.suffix(HirdActivity.maximumRecent).map { $0 }
                    run.hird.currentCommand = command
                    if activity.kind == .edit { run.hird.lastEditAt = activity.at }
                    run.hird.lastActivityAt = max(run.hird.lastActivityAt, activity.at)
                }
            case .ask(let question):
                try validateID(question.id)
                guard question.runID == run.id, question.issueID == run.issueID,
                      question.state == .pending, question.answer == nil, question.resolvedAt == nil, question.deliveredAt == nil else { throw error("질문의 실행 연결 또는 초기 상태가 잘못됐어요") }
                if let old: PersistedQuestion = try record("questions", question.id) {
                    guard old.runID == question.runID, old.issueID == question.issueID,
                          old.prompt == question.prompt, old.options == question.options,
                          old.createdAt == question.createdAt else { throw error("질문 식별자 충돌") }
                } else {
                    try connection.execute("INSERT INTO questions(id,run_id,issue_id,payload) VALUES(?,?,?,?)",
                                           [question.id, run.id.rawValue, run.issueID.rawValue, try encode(question)])
                }
                try updateWaiting(&run, at: event.at)
                if question.source != .stallari {
                    try insertThreadDelivery(id: "hird-question:" + question.id, issueID: run.issueID, runID: run.id,
                        at: question.createdAt, kind: .question(question.id))
                }
            case .complete(let result, let notificationID):
                try saveResult(result, on: &run); try validateID(notificationID)
                run.state = .succeeded; run.endedAt = event.at
                run.hird.status = .done(at: event.at); run.hird.currentCommand = nil
                try closeQuestions(run.id, at: event.at)
                let notification = CompletionNotification(id: notificationID, runID: run.id, createdAt: event.at)
                try connection.execute("INSERT INTO notifications(id,run_id,payload) VALUES(?,?,?)",
                                       [notificationID, run.id.rawValue, try encode(notification)])
            case .fail(let reason):
                stop(&run, state: .failed, at: event.at, reason: reason)
                try closeQuestions(run.id, at: event.at)
                try insertThreadDelivery(id: "hird-stopped:" + run.id.rawValue, issueID: run.issueID, runID: run.id,
                    at: event.at, kind: .stopped(reason))
            }
            run.lastSequence = event.sequence
            try writeRun(run)
            outcome = .applied
        }
        try connection.execute("INSERT INTO run_events(id,run_id,sequence,payload,outcome) VALUES(?,?,?,?,?)",
                               [event.id, event.runID.rawValue, String(event.sequence), try encodeStoredEvent(storedEvent), outcome.rawValue])
        return outcome
    }

    /// Shared Hird/Stallari ingress. Retries retain the original sequence; new events
    /// allocate the next sequence inside this actor, avoiding competing producers.
    public func recordEvent(id: String, runID: HirdRun.ID, at: Date, payload: RunEvent.Payload) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            if let row = try rows("SELECT payload FROM run_events WHERE id=?", [id]).first {
                let old = try decodeStoredEvent(row[0])
                let incoming = RunEvent(id: id, runID: runID, sequence: old.sequence, at: at, payload: payload)
                guard sameEvent(old, incoming) else { throw error("이벤트 식별자에 다른 내용이 도착했어요") }
                return try applyInTransaction(old)
            }
            let run = try requireRun(runID)
            let ledgerSequence = try rows("SELECT COALESCE(MAX(sequence),0) FROM run_events WHERE run_id=?", [runID.rawValue]).first?[0]
            let next = max(run.lastSequence, Int64(ledgerSequence ?? "0") ?? 0) + 1
            return try applyInTransaction(.init(id: id, runID: runID, sequence: next, at: at, payload: payload))
        }
    }

    /// Acknowledgement only; external delivery must have succeeded first.
    public func markQuestionDelivered(id: String, runID: HirdRun.ID, at: Date) throws -> MutationOutcome {
        try connection.transaction {
            var question = try requireQuestion(id, runID: runID)
            guard question.state != .pending else { throw error("미응답 질문은 전달 완료로 저장할 수 없어요") }
            if question.deliveredAt != nil { return .duplicate }
            question.deliveredAt = at
            try writeQuestion(question)
            return .applied
        }
    }

    public func answerQuestion(_ id: String, runID: HirdRun.ID, answer: QuestionAnswer, at: Date, requirePending: Bool = false) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            var question = try requireQuestion(id, runID: runID)
            var run = try requireRun(runID)
            if requirePending {
                guard question.state == .pending, !run.state.isTerminal else { throw error("진행 중인 실행의 미응답 질문만 답변할 수 있어요") }
            }
            if question.state == .answered {
                guard question.answer == answer else { throw error("이미 다른 답변이 저장됐어요") }
                return .duplicate
            }
            guard question.state == .pending, !run.state.isTerminal else { return .ignoredTerminal }
            guard Set(answer.selectedOptions).count == answer.selectedOptions.count,
                  answer.selectedOptions.allSatisfy(question.options.contains),
                  !answer.selectedOptions.isEmpty || !(answer.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { throw error("답변 내용이나 선택지가 잘못됐어요") }
            question.state = .answered; question.answer = answer; question.resolvedAt = at
            try writeQuestion(question)
            try updateWaiting(&run, at: at); try writeRun(run)
            return .applied
        }
    }

    public func cancelQuestion(_ id: String, runID: HirdRun.ID, at: Date) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            var question = try requireQuestion(id, runID: runID)
            if question.state == .cancelled { return .duplicate }
            if question.state == .answered { return .ignoredTerminal }
            question.state = .cancelled; question.resolvedAt = at; try writeQuestion(question)
            var run = try requireRun(runID)
            if !run.state.isTerminal { try updateWaiting(&run, at: at); try writeRun(run) }
            return .applied
        }
    }

    public func cancelRun(_ id: HirdRun.ID, at: Date, reason: String) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            var run = try requireRun(id)
            if run.state == .cancelled { return .duplicate }
            guard !run.state.isTerminal else { return .ignoredTerminal }
            run.cancellationRequestedAt = at
            stop(&run, state: .cancelled, at: at, reason: reason)
            run.endedAt = run.processEndedAt
            if let ended = run.processEndedAt { run.hird.status = .failed(at: ended) }
            try writeRun(run); try closeQuestions(id, at: at)
            try insertThreadDelivery(id: "hird-stopped:" + run.id.rawValue, issueID: run.issueID, runID: run.id,
                at: at, kind: .stopped(reason))
            return .applied
        }
    }

    /// Only the owning adapter may attest that this exact run has no remaining processes.
    public func markProcessEnded(_ id: HirdRun.ID, at: Date) throws -> MutationOutcome {
        defer { publishSnapshot() }
        return try connection.transaction {
            var run = try requireRun(id)
            if run.processEndedAt != nil { return .duplicate }
            run.processEndedAt = at
            if run.state == .cancelled { run.endedAt = at; run.hird.status = .failed(at: at) }
            try writeRun(run)
            return .applied
        }
    }

    public func markNotificationDelivered(id: String, runID: HirdRun.ID, at: Date) throws -> MutationOutcome {
        try connection.transaction {
            guard var notice: CompletionNotification = try record("notifications", id), notice.runID == runID else { throw error("완료통지의 실행 연결이 달라요") }
            if notice.deliveredAt != nil { return .duplicate }
            let run = try requireRun(runID)
            guard run.state == .succeeded, run.result != nil else { throw error("완료 결과가 없는 통지예요") }
            notice.deliveredAt = at
            try connection.execute("UPDATE notifications SET payload=? WHERE id=?", [try encode(notice), id])
            return .applied
        }
    }

    public func pendingNotifications() throws -> [CompletionNotification] {
        try records("notifications").filter { (n: CompletionNotification) in n.deliveredAt == nil }
    }

    private func insertThreadDelivery(id: String, issueID: Issue.ID, runID: HirdRun.ID?, at: Date, kind: ThreadDelivery.Kind) throws {
        let threadID = try requireIssue(issueID).conversationThreadID
        try saveThreadDelivery(.init(id: id, threadID: threadID, issueID: issueID, runID: runID, createdAt: at, kind: kind))
        switch kind {
        case .question, .stopped:
            try insertMainDelivery(id: id, issueID: issueID, runID: runID, at: at, kind: kind)
        case .handoff, .proposalRevision, .completion: break
        }
    }
    private func insertMainDelivery(id: String, issueID: Issue.ID, runID: HirdRun.ID?, at: Date, kind: ThreadDelivery.Kind) throws {
        let issue = try requireIssue(issueID)
        guard let owner: ConversationThread = try record("threads", issue.conversationThreadID),
              owner.issueID == issueID, let originID = owner.originThreadID,
              let origin: ConversationThread = try record("threads", originID) else { return }
        // The issue session owns questions, failures and correction. Only accepted results
        // wake the project for integration; parent cards already reflect saved issue state.
        guard case .completion = kind else { return }
        let projectID = try self.projectID(forIssue: issueID)
        let destination: ConversationThread
        if origin.id == ConversationThread.defaultID {
            destination = try projectConversationInTransaction(projectID: projectID)
        } else {
            guard origin.projectID == projectID, origin.issueID == nil else { return }
            destination = origin
        }
        try saveThreadDelivery(.init(id: "owner:" + id, threadID: destination.id,
            issueID: issueID, runID: runID, createdAt: at, kind: kind))
    }
    private func saveThreadDelivery(_ delivery: ThreadDelivery) throws {
        if let _: ThreadDelivery = try record("thread_deliveries", delivery.id) { return }
        try connection.execute("INSERT INTO thread_deliveries(id,thread_id,issue_id,run_id,payload) VALUES(?,?,?,?,?)",
            [delivery.id, delivery.threadID, delivery.issueID.rawValue, delivery.runID?.rawValue, try encode(delivery)])
    }
    func pendingThreadDeliveries(threadID: String) throws -> [ThreadDelivery] {
        try rows("SELECT payload FROM thread_deliveries WHERE thread_id=? ORDER BY rowid", [threadID])
            .map { try decode(ThreadDelivery.self, $0[0]) }.filter { $0.deliveredAt == nil }
    }
    func markThreadDelivery(_ id: String, threadID: String, at: Date, forwardingAcceptedCompletion: Bool = false) throws {
        var updated = false
        defer { if updated { publishSnapshot() } }
        try connection.transaction {
            guard var delivery: ThreadDelivery = try record("thread_deliveries", id), delivery.threadID == threadID else { throw error("스레드 알림 연결이 달라요") }
            if delivery.deliveredAt != nil { return }
            // Upgrade a pending old main mirror atomically, including issues judged by an
            // older app. Retiring it must not drop the project's accepted-result handoff.
            if forwardingAcceptedCompletion, delivery.id.hasPrefix("main:"),
               case .completion(let notificationID, _) = delivery.kind,
               let issue: Issue = try record("issues", delivery.issueID.rawValue),
               issue.state == .done, issue.archivedAt == nil,
               let notice: CompletionNotification = try record("notifications", notificationID) {
                let own: [PersistedRun] = try records("runs", whereSQL: "issue_id=?", values: [issue.id.rawValue])
                if let latest = own.last, latest.id == delivery.runID, notice.runID == latest.id,
                   latest.state == .succeeded, let result = latest.result {
                    try insertMainDelivery(id: "hird-complete:" + notificationID, issueID: issue.id, runID: latest.id,
                        at: at, kind: .completion(notificationID: notificationID, summary: result.summary))
                }
            }
            delivery.deliveredAt = at
            try connection.execute("UPDATE thread_deliveries SET payload=? WHERE id=?", [try encode(delivery), id])
            updated = true
        }
    }

    /// The same snapshot read, labeled with the revision it reflects. Read together under the
    /// actor so the label cannot belong to a different write than the contents.
    public func snapshotUpdate(includeHistory: Bool = false) throws -> PersistenceUpdate {
        // Another connection can write between our own writes; SQLite reports that through its
        // data version. Treat it as a revision of its own so ordering stays meaningful.
        if let version = try rows("PRAGMA data_version").first?.first, version != observedDataVersion {
            observedDataVersion = version
            writeRevision += 1
        }
        let value = try snapshot(includeHistory: includeHistory)
        return PersistenceUpdate(revision: writeRevision, snapshot: value)
    }

    /// A single SQLite read transaction gives the screen one coherent committed view.
    public func snapshot(includeHistory: Bool = true) throws -> PersistenceSnapshot {
        snapshotBuildCount += 1
        try connection.execute("BEGIN")
        do {
            let projects: [StoredProject] = try records("projects")
            let threads: [ConversationThread] = threadSchema ? try records("threads") : [.default]
            try synchronizeCaches()
            let ids = try rows("SELECT id FROM runs ORDER BY rowid").map { $0[0] }
            let liveIDs = Set(ids)
            snapshotRuns = snapshotRuns.filter { liveIDs.contains($0.key) }
            let runs: [PersistedRun] = try ids.map { id in
                let full: PersistedRun
                if let cached = snapshotRuns[id] { full = cached }
                else { full = try requireRun(.init(id)); snapshotRuns[id] = full }
                if includeHistory { return try hydrateRun(full, includeHistory: true) }
                var summary = full; summary.resultHistory = []; return summary
            }
            let questions: [PersistedQuestion] = try records("questions")
            let threadDeliveries: [ThreadDelivery] = threadSchema ? try records("thread_deliveries") : []
            let notifications: [CompletionNotification] = try records("notifications")
            let transfers = try projectTransfers()
            let milestones: [Milestone] = try milestoneSchema
                ? rows("SELECT payload FROM milestones ORDER BY rowid").map { try decode(Milestone.self, $0[0]) }
                    .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
                : []
            let weekPlans: [ProjectWeekPlan] = try weekPlanSchema
                ? rows("SELECT payload FROM project_weeks ORDER BY project_id,week_start").map { try decode(ProjectWeekPlan.self, $0[0]) }
                : []
            let preparationItems: [PreparationItem] = preparationSchema ? try records("project_preparations") : []
            let chat: [StoredChat] = try records("chat")
            let activityTable = try cachedTable("activities")
            for (issueID, rowIDs) in activityTable.activityRows where activityTable.activityHistories[issueID] == nil {
                // Row order is the persisted activity order, not the event timestamp. Only an
                // issue whose rows changed needs rebuilding; other histories remain untouched.
                activityTable.activityHistories[issueID] = try rowIDs.sorted().map {
                    try cachedValue($0, table: activityTable) as ActivityEvent
                }
            }
            let activities = activityTable.activityHistories
            var issues: [Issue] = try records("issues")
            let runsByIssue = Dictionary(grouping: runs, by: \.issueID)
            let liveIssueIDs = Set(issues.map(\.id))
            projectedIssues = projectedIssues.filter { liveIssueIDs.contains($0.key) }
            for i in issues.indices {
                let source = issues[i]
                let own = runsByIssue[source.id] ?? []
                let events = activities[source.id.rawValue] ?? []
                if let cached = projectedIssues[source.id], cached.source == source,
                   cached.runs == own, cached.events == events {
                    issues[i] = cached.value
                    continue
                }
                // Preserve each run's plan and reports through execution, judgement and integration.
                issues[i].hirds = own.map { run in
                    var hird = run.hird
                    hird.startedAt = run.startedAt
                    if !run.state.isTerminal || !(run.stagePlan ?? []).isEmpty || !(run.stageReports ?? []).isEmpty {
                        hird.stageProgress = run.stageProgress
                    }
                    return hird
                }
                if issues[i].state == .done, issues[i].completedAt == nil {
                    issues[i].completedAt = own.compactMap { run in
                        if case .done(let at) = run.hird.status { return at }
                        return nil
                    }.max()
                }
                issues[i].events = events
                // Hird success leaves Issue judgement to Stallari; interruption/cancel is visible today.
                if issues[i].state == .running || issues[i].state == .needsInput, !own.isEmpty {
                    if own.contains(where: { $0.state == .waitingOnHuman }) { issues[i].state = .needsInput }
                    else if own.contains(where: { $0.state == .working }) { issues[i].state = .running }
                    else if let stopped = own.last, stopped.state != .succeeded {
                        issues[i].state = .failed
                        issues[i].headline = stopped.stopReason?.contains("앱 종료") == true ? "앱 종료로 중단됨 · 다시 시작" : stopped.state == .cancelled ? "취소됨" : stopped.state == .interrupted ? "실행 중단" : "실행 실패"
                        issues[i].detail = stopped.stopReason ?? "실행이 중단됐어요"
                    }
                }
                if let latest = own.last {
                    issues[i].latestResult = latest.result
                    issues[i].executionModel = latest.observedModel
                    issues[i].executionThinking = latest.observedThinking
                }
                projectedIssues[source.id] = .init(source: source, runs: own, events: events, value: issues[i])
            }
            let chatTable = try cachedTable("chat")
            let items: [ChatItem]
            if let cached = chatTable.chatItems { items = cached }
            else { items = try chat.map { try $0.item() }; chatTable.chatItems = items }
            let issueTable = try cachedTable("issues")
            let issueProjects = Dictionary(uniqueKeysWithValues: try issueTable.order.map { id -> (Issue.ID, String) in
                let value: Issue = try cachedValue(id, table: issueTable)
                return (value.id, issueTable.rows[id]!.row[1])
            })
            try connection.execute("COMMIT")
            let pendingThreads = Set(threadDeliveries.filter { $0.deliveredAt == nil }.map(\.threadID))
                .union(notifications.filter { $0.deliveredAt == nil }.compactMap { notice in
                    runs.first { $0.id == notice.runID }.flatMap { run in issues.first { $0.id == run.issueID }?.conversationThreadID }
                })
                .union(transfers.contains { $0.state == .pending } ? [ConversationThread.defaultID] : [])
            return .init(projects: projects, threads: threads, issues: issues, issueProjects: issueProjects, chat: items, chatLinks: chat.map(\.link), runs: runs,
                         questions: questions, notifications: notifications, projectTransfers: transfers,
                         milestones: milestones, weekPlans: weekPlans, pendingDeliveryThreadIDs: pendingThreads, preparationItems: preparationItems)
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func recover(now: Date, probe: @Sendable (PersistedRun) -> OwnedRunLiveness, migrateV1: Bool = false, migrateThreads: Bool = false, migrateEvidence: Bool = false, migrateTransfers: Bool = false, migrateMilestones: Bool = false, migrateWeekPlans: Bool = false, migratePreparations: Bool = false) throws {
        try connection.transaction {
            if migrateV1 { try migrateV1InTransaction() }
            if migrateThreads {
                try connection.execute("CREATE TABLE threads (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)")
                try connection.execute("INSERT INTO threads(id,payload) VALUES(?,?)", [ConversationThread.defaultID, try encode(ConversationThread.default)])
                for table in ["issues", "chat"] {
                    try connection.execute("ALTER TABLE \(table) ADD COLUMN thread_id TEXT NOT NULL DEFAULT 'default' REFERENCES threads(id)")
                }
                try connection.execute("CREATE TABLE thread_deliveries (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL REFERENCES threads(id), issue_id TEXT NOT NULL REFERENCES issues(id), run_id TEXT REFERENCES runs(id), payload TEXT NOT NULL)")
                try connection.execute("PRAGMA user_version = 3")
                try validateStoredLinks()
                let brokenLinks = try rows("PRAGMA foreign_key_check")
                guard brokenLinks.isEmpty else { throw error("이전한 연결이 손상됐어요: \(brokenLinks)") }
            }
            if migrateEvidence {
                try Self.createEvidenceSchema(connection)
                let legacyRuns: [PersistedRun] = try records("runs")
                for run in legacyRuns {
                    for (ordinal, result) in run.resultHistory.enumerated() {
                        let key = try storeResult(result)
                        try connection.execute("INSERT INTO run_result_history(run_id,ordinal,result_id) VALUES(?,?,?)", [run.id.rawValue, String(ordinal), key])
                    }
                    var compact = run; compact.result = nil; compact.resultHistory = []; compact.savedResultCount = run.resultHistory.count
                    try connection.execute("UPDATE runs SET payload=? WHERE id=?", [try encode(compact), run.id.rawValue])
                }
                normalizedSchema = true
                try connection.execute("PRAGMA user_version = 4")
                try validateStoredLinks()
                guard try rows("PRAGMA foreign_key_check").isEmpty else { throw error("결과 이력 이전 연결 손상") }
            }
            if migrateTransfers {
                try Self.createProjectTransferSchema(connection)
                transferSchema = true
                try connection.execute("PRAGMA user_version = 5")
                try validateStoredLinks()
                guard try rows("PRAGMA foreign_key_check").isEmpty else { throw error("프로젝트 전달 이전 연결 손상") }
            }
            if migrateMilestones {
                try Self.createMilestoneSchema(connection)
                milestoneSchema = true
                try connection.execute("PRAGMA user_version = 6")
                try validateStoredLinks()
                guard try rows("PRAGMA foreign_key_check").isEmpty else { throw error("마일스톤 이전 연결 손상") }
            }
            if migrateWeekPlans {
                try Self.createWeekPlanSchema(connection)
                weekPlanSchema = true
                try connection.execute("PRAGMA user_version = 7")
                try validateStoredLinks()
                guard try rows("PRAGMA foreign_key_check").isEmpty else { throw error("주간 계획 이전 연결 손상") }
            }
            if migratePreparations {
                try Self.createPreparationSchema(connection)
                preparationSchema = true
                try connection.execute("PRAGMA user_version = 8")
                try validateStoredLinks()
                guard try rows("PRAGMA foreign_key_check").isEmpty else { throw error("준비 자료 이전 연결 손상") }
            }
            let runs: [PersistedRun] = try records("runs")
            for var run in runs where !run.state.isTerminal {
                let alive: Bool
                switch probe(run) {
                case .alive(let owner, let session): alive = owner == run.ownershipToken && session == run.ompSessionID
                case .dead, .unverified: alive = false
                }
                if !alive {
                    stop(&run, state: .interrupted, at: now, reason: "소유 실행의 생존을 확인하지 못했어요. 기존 결과와 질문을 확인한 뒤 명시적으로 재작업하세요.")
                    try writeRun(run)
                    try insertThreadDelivery(id: "hird-stopped:" + run.id.rawValue, issueID: run.issueID, runID: run.id,
                        at: now, kind: .stopped(run.stopReason ?? "실행 중단"))
                    // Retain pending questions on their original run, never auto-answer/restart them.
                }
            }
        }
    }

    private func migrateV1InTransaction() throws {
        // SQLite DDL and every payload update roll back together, including restart recovery.
        // A backup is not created: read-only preflight rejects corruption before this write,
        // and FULL synchronous SQLite journaling owns atomic crash/failure rollback.
        try connection.execute("ALTER TABLE things RENAME TO issues")
        for table in ["runs", "chat", "activities", "questions"] {
            try connection.execute("ALTER TABLE \(table) RENAME COLUMN thing_id TO issue_id")
        }
        try connection.execute("DROP INDEX runs_thing")
        try connection.execute("CREATE INDEX runs_issue ON runs(issue_id)")
        for table in ["runs", "questions", "chat", "run_events"] {
            for row in try rows("SELECT id,payload FROM \(table) ORDER BY rowid") {
                do {
                    let payload = try IssueSchemaMigration.payload(row[1], table: table)
                    try connection.execute("UPDATE \(table) SET payload=? WHERE id=?", [payload, row[0]])
                } catch let failure as PersistenceError { throw failure }
                catch { throw self.error("v1 이슈 이전 실패: \(error)") }
            }
        }
    }

    // Open-time checks run read-only, including logical corruption of valid SQLite pages.
    // The event ledger is checked only at open, never reprocessed in a screen render.
    private func validateStoredLinks() throws {
        try validateProjectTransfers()
        try validatePreparations()
        if threadSchema {
            let threads: [ConversationThread] = try records("threads")
            guard threads.contains(where: { $0.id == ConversationThread.defaultID }) else { throw error("기본 스레드가 없어요") }
            for row in try rows("SELECT id,payload FROM threads") {
                let thread = try decode(ConversationThread.self, row[1])
                try validateID(thread.id)
                guard thread.id == row[0], !thread.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error("스레드 기록 손상") }
            }
            for row in try rows("SELECT thread_id,payload FROM issues") {
                guard try decode(Issue.self, row[1]).conversationThreadID == row[0] else { throw error("이슈 스레드 연결 손상") }
            }
            for row in try rows("SELECT thread_id,payload FROM chat") {
                guard try decode(StoredChat.self, row[1]).link.conversationThreadID == row[0] else { throw error("채팅 스레드 연결 손상") }
            }
        }
        var projects: [String: StoredProject] = [:]
        for row in try rows("SELECT id,payload FROM projects") {
            let p = try decode(StoredProject.self, row[1])
            guard p.id == row[0] else { throw error("프로젝트 식별자 손상") }
            try validateID(p.id); try validatePath(p.absolutePath); projects[p.id] = p
        }
        var issueProjects: [Issue.ID: String] = [:]
        var issues: [Issue.ID: Issue] = [:]
        for row in try rows("SELECT id,project_id,payload FROM issues") {
            let t = try decode(Issue.self, row[2])
            guard t.id.rawValue == row[0], projects[row[1]] != nil, t.hirds.isEmpty, t.events.isEmpty else { throw error("이슈 연결 손상") }
            try validateID(t.id.rawValue); issueProjects[t.id] = row[1]
            if let proposal = t.proposal { try validateProposal(proposal, criterionCount: t.acceptance.count) }
            if let history = t.proposalHistory {
                guard !history.isEmpty, history.last == t.proposal,
                      zip(history, history.dropFirst()).allSatisfy({ pair in pair.0.version < pair.1.version }) else { throw error("제안 이력 버전 손상") }
                for proposal in history { try validateProposal(proposal, criterionCount: t.acceptance.count) }
            }
            if let approval = t.approval {
                guard approval.version == t.proposal?.version,
                      t.approvalHistory?.contains(approval) == true else { throw error("제안 승인 기록 손상") }
            }
            for approval in t.approvalHistory ?? [] {
                guard approval.version > 0, approval.version <= (t.proposal?.version ?? 0) else { throw error("승인 이력 버전 손상") }
            }
            issues[t.id] = t
        }
        try validateMilestones(projects: projects, issueProjects: issueProjects)
        if threadSchema {
            let threads: [ConversationThread] = try records("threads")
            let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
            var ownedProjects: Set<String> = []
            for thread in threads {
                guard thread.issueID == nil || thread.projectID == nil else { throw error("대화의 프로젝트·이슈 소유권 손상") }
                if let projectID = thread.projectID {
                    try validateID(projectID)
                    guard thread.id != ConversationThread.defaultID, projects[projectID] != nil,
                          thread.originThreadID == nil, ownedProjects.insert(projectID).inserted else { throw error("프로젝트 대화 소유권 손상") }
                } else if thread.projectHandoffDeliveredAt != nil { throw error("프로젝트 없는 인계 완료 기록 손상") }
                if let issueID = thread.issueID {
                    guard let issue = issues[issueID], issue.conversationThreadID == thread.id,
                          thread.id != ConversationThread.defaultID, thread.name == issue.title,
                          let originID = thread.originThreadID, originID != thread.id, let origin = byID[originID],
                          origin.issueID == nil, origin.originThreadID == nil,
                          origin.projectID == nil || origin.projectID == issueProjects[issueID] else { throw error("이슈 대화 소유권 손상") }
                } else if thread.originThreadID != nil { throw error("이슈 없는 대화 인계 소유권 손상") }
            }
            for issue in issues.values {
                guard let thread = byID[issue.conversationThreadID], thread.projectID == nil,
                      thread.issueID == nil || thread.issueID == issue.id else { throw error("이슈의 대화 소유권 연결 손상") }
            }
        }
        var runs: [HirdRun.ID: PersistedRun] = [:]
        for row in try rows("SELECT id,issue_id,project_id,payload FROM runs") {
            let r = try hydrateRun(decode(PersistedRun.self, row[3]), includeHistory: true)
            guard [r.id.rawValue, r.issueID.rawValue, r.projectID] == Array(row.prefix(3)),
                  issueProjects[r.issueID] == r.projectID, r.lastSequence >= 0,
                  r.state.isTerminal == (r.endedAt != nil || (r.state == .cancelled && r.cancellationRequestedAt != nil)),
                  r.resultHistory.last == r.result else { throw error("실행 식별자 또는 상태 손상") }
            try validateID(r.id.rawValue); try validateID(r.ownershipToken)
            if let session = r.ompSessionID { try validateID(session) }
            if let workspace = r.workspace { try validateWorkspace(workspace) }
            for result in r.resultHistory { try validateResult(result, mode: r.mode) }
            switch (r.state, r.hird.status) {
            case (.working, .working), (.waitingOnHuman, .waitingOnHuman): break
            case (.succeeded, .done(let at)):
                guard at == r.endedAt, r.result != nil else { throw error("완료 상태 손상") }
            case (.failed, .failed(let at)), (.interrupted, .failed(let at)):
                guard at == r.endedAt else { throw error("종료 상태 손상") }
            case (.cancelled, .failed(let at)):
                guard at == (r.endedAt ?? r.cancellationRequestedAt),
                      r.cancellationRequestedAt == nil || r.endedAt == r.processEndedAt else { throw error("취소 상태 손상") }
            default: throw error("화면 실행 상태와 영속 상태가 달라요")
            }
            runs[r.id] = r
        }
        for issue in issues.values {
            if let proposal = issue.proposal, let previous = proposal.previousRunID {
                guard let run = runs[previous], run.issueID == issue.id,
                      run.projectID == issueProjects[issue.id], run.state.isTerminal else { throw error("제안 이전 실행 연결 손상") }
            }
            for approval in issue.approvalHistory ?? [] {
                if let id = approval.runID, runs[id]?.issueID != issue.id { throw error("소비한 승인 실행 연결 손상") }
            }
            if let approval = issue.approval, let id = approval.runID {
                guard let run = runs[id], let proposal = issue.proposal,
                      run.hird.role == proposal.instruction, run.requestedModel == proposal.model,
                      run.mode == proposal.mode, run.previousRunID == proposal.previousRunID,
                      proposal.thinking == nil || run.requestedThinking == proposal.thinking else { throw error("소비한 승인 실행 내용 손상") }
            }
        }
        for run in runs.values {
            if let previous = run.previousRunID {
                guard let old = runs[previous], old.id != run.id, old.issueID == run.issueID,
                      old.projectID == run.projectID, old.state.isTerminal else { throw error("재작업 연결 손상") }
            }
        }
        if threadSchema {
            for row in try rows("SELECT id,thread_id,issue_id,run_id,payload FROM thread_deliveries") {
                let delivery = try decode(ThreadDelivery.self, row[4])
                let issue = issues[delivery.issueID]
                let owner: ConversationThread? = try issue.flatMap { try record("threads", $0.conversationThreadID) }
                let origin: ConversationThread? = try (owner?.originThreadID).flatMap { try record("threads", $0) }
                let projectOrigin = origin?.projectID != nil && origin?.projectID == issueProjects[delivery.issueID] &&
                    origin?.issueID == nil && owner?.issueID == delivery.issueID
                let mainMirror: Bool
                let projectOwner: Bool
                switch delivery.kind {
                case .question, .stopped, .completion:
                    mainMirror = delivery.threadID == ConversationThread.defaultID && delivery.id.hasPrefix("main:") &&
                        owner?.issueID == delivery.issueID && (origin?.id == ConversationThread.defaultID || projectOrigin)
                    let destination: ConversationThread? = try record("threads", delivery.threadID)
                    let mainOriginCompletion: Bool
                    if case .completion = delivery.kind {
                        mainOriginCompletion = owner?.issueID == delivery.issueID && origin?.id == ConversationThread.defaultID &&
                            destination?.projectID != nil && destination?.projectID == issueProjects[delivery.issueID] && destination?.issueID == nil
                    } else { mainOriginCompletion = false }
                    projectOwner = delivery.id.hasPrefix("owner:") && ((projectOrigin && delivery.threadID == origin?.id) || mainOriginCompletion)
                case .handoff, .proposalRevision: mainMirror = false; projectOwner = false
                }
                guard [delivery.id, delivery.threadID, delivery.issueID.rawValue, delivery.runID?.rawValue ?? ""] == Array(row.prefix(4)),
                      issue?.conversationThreadID == delivery.threadID || mainMirror || projectOwner else { throw error("스레드 알림 연결 손상") }
                if let runID = delivery.runID, runs[runID]?.issueID != delivery.issueID { throw error("스레드 알림 실행 연결 손상") }
            }
        }
        for row in try rows("SELECT id,run_id,issue_id,payload FROM questions") {
            let q = try decode(PersistedQuestion.self, row[3])
            guard [q.id, q.runID.rawValue, q.issueID.rawValue] == Array(row.prefix(3)),
                  runs[q.runID]?.issueID == q.issueID else { throw error("질문 실행 연결 손상") }
            switch q.state {
            case .pending: guard q.answer == nil, q.resolvedAt == nil else { throw error("대기 질문 상태 손상") }
            case .answered: guard q.answer != nil, q.resolvedAt != nil else { throw error("답변 상태 손상") }
            case .cancelled: guard q.answer == nil, q.resolvedAt != nil else { throw error("질문 취소 상태 손상") }
            }
        }
        let notices: [CompletionNotification] = try records("notifications")
        for row in try rows("SELECT id,run_id,payload FROM notifications") {
            let n = try decode(CompletionNotification.self, row[2])
            guard [n.id, n.runID.rawValue] == Array(row.prefix(2)), runs[n.runID]?.state == .succeeded else { throw error("완료통지 연결 손상") }
        }
        for r in runs.values where r.state == .succeeded {
            guard notices.contains(where: { $0.runID == r.id }) else { throw error("완료통지 누락") }
        }
        for row in try rows("SELECT id,project_id,issue_id,run_id,payload FROM chat") {
            let c = try decode(StoredChat.self, row[4]); let link = c.link
            guard [link.chatID.uuidString, link.projectID, link.issueID?.rawValue ?? "", link.runID?.rawValue ?? ""] == Array(row.prefix(4)),
                  projects[link.projectID] != nil else { throw error("채팅 연결 손상") }
            if threadSchema {
                guard let thread: ConversationThread = try record("threads", link.conversationThreadID),
                      thread.projectID == nil || thread.projectID == link.projectID else { throw error("채팅 프로젝트 대화 소유권 손상") }
            }
            if let issue = link.issueID, issueProjects[issue] != link.projectID { throw error("채팅 이슈 연결 손상") }
            if let issue = link.issueID, issues[issue]?.conversationThreadID != link.conversationThreadID { throw error("채팅 이슈 스레드 연결 손상") }
            if let id = link.runID, runs[id]?.issueID != link.issueID || runs[id]?.projectID != link.projectID { throw error("채팅 실행 연결 손상") }
            switch try c.item().kind {
            case .issue(let id), .proposal(let id, _): guard id == link.issueID else { throw error("채팅 이슈 카드 연결 손상") }
            case .notice(let n): guard n.issue == link.issueID else { throw error("채팅 통지 연결 손상") }
            default: break
            }
        }
        for row in try rows("SELECT id,issue_id,run_id,payload FROM activities") {
            let a = try decode(ActivityEvent.self, row[3])
            guard a.id.uuidString == row[0], issueProjects[Issue.ID(row[1])] != nil else { throw error("활동 식별자 손상") }
            if !row[2].isEmpty, runs[HirdRun.ID(row[2])]?.issueID.rawValue != row[1] { throw error("활동 실행 연결 손상") }
        }
        for row in try rows("SELECT id,run_id,sequence,payload,outcome FROM run_events") {
            let e = try decodeStoredEvent(row[3])
            guard [e.id, e.runID.rawValue, String(e.sequence)] == Array(row.prefix(3)),
                  runs[e.runID] != nil, MutationOutcome(rawValue: row[4]) != nil else { throw error("이벤트 원장 손상") }
        }
    }

    private static func createEvidenceSchema(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE run_verifications (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)")
        try db.execute("CREATE TABLE run_results (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL)")
        try db.execute("CREATE TABLE run_result_history (run_id TEXT NOT NULL REFERENCES runs(id), ordinal INTEGER NOT NULL CHECK(ordinal>=0), result_id TEXT NOT NULL REFERENCES run_results(id), PRIMARY KEY(run_id,ordinal))")
    }
    private func resultMetadata(_ result: RunResult) -> RunResult {
        .init(worktreePath: result.worktreePath, branch: result.branch, commit: result.commit, diffPath: result.diffPath,
              summary: result.summary, verifications: [], reportPath: result.reportPath,
              artifactManifestPath: result.artifactManifestPath, artifactManifestMetadata: result.artifactManifestMetadata)
    }
    private func storeResult(_ result: RunResult) throws -> String {
        let keys = try result.verifications.map { verification -> String in
            let payload = try encode(verification), key = ResponseRulesFile.version(of: payload)
            try connection.execute("INSERT OR IGNORE INTO run_verifications(id,payload) VALUES(?,?)", [key, payload])
            return key
        }
        let payload = try encode(NormalizedRunResult(metadata: resultMetadata(result), verificationKeys: keys))
        let key = ResponseRulesFile.version(of: payload)
        try connection.execute("INSERT OR IGNORE INTO run_results(id,payload) VALUES(?,?)", [key, payload])
        return key
    }
    private func loadResult(_ key: String) throws -> RunResult {
        if let result = resultCache[key] { return result }
        guard let payload = try rows("SELECT payload FROM run_results WHERE id=?", [key]).first?.first,
              ResponseRulesFile.version(of: payload) == key else { throw error("결과 참조 또는 내용 해시 손상") }
        let stored = try decode(NormalizedRunResult.self, payload)
        guard stored.metadata.verifications.isEmpty else { throw error("정규화 결과 메타데이터 손상") }
        let verifications = try stored.verificationKeys.map { key -> VerificationRecord in
            if let value = verificationCache[key] { return value }
            guard let payload = try rows("SELECT payload FROM run_verifications WHERE id=?", [key]).first?.first,
                  ResponseRulesFile.version(of: payload) == key else { throw error("검증 참조 또는 내용 해시 손상") }
            let value = try decode(VerificationRecord.self, payload)
            let cost = payload.utf8.count
            if cost <= 256 * 1024 {
                if verificationCache.count >= 1024 || verificationCacheBytes + cost > 4 * 1024 * 1024 {
                    verificationCache.removeAll(); verificationCacheBytes = 0
                }
                verificationCache[key] = value; verificationCacheBytes += cost
            }
            return value
        }
        let value = RunResult(worktreePath: stored.metadata.worktreePath, branch: stored.metadata.branch,
            commit: stored.metadata.commit, diffPath: stored.metadata.diffPath, summary: stored.metadata.summary,
            verifications: verifications, reportPath: stored.metadata.reportPath,
            artifactManifestPath: stored.metadata.artifactManifestPath, artifactManifestMetadata: stored.metadata.artifactManifestMetadata)
        let cost = payload.utf8.count + verifications.reduce(0) { $0 + $1.summary.utf8.count + $1.logPath.utf8.count + $1.workingDirectory.utf8.count + $1.command.reduce(0) { $0 + $1.utf8.count } + 128 }
        if cost <= 256 * 1024 {
            if resultCache.count >= 128 || resultCacheBytes + cost > 4 * 1024 * 1024 { resultCache.removeAll(); resultCacheBytes = 0 }
            resultCache[key] = value; resultCacheBytes += cost
        }
        return value
    }
    private func hydrateRun(_ compact: PersistedRun, includeHistory: Bool) throws -> PersistedRun {
        guard normalizedSchema else { return compact }
        var run = compact
        if includeHistory {
            let keys = try rows("SELECT ordinal,result_id FROM run_result_history WHERE run_id=? ORDER BY ordinal", [run.id.rawValue])
            guard keys.count == (run.savedResultCount ?? 0), keys.enumerated().allSatisfy({ Int($0.element[0]) == $0.offset }) else { throw error("결과 이력 순서 또는 개수 손상") }
            run.resultHistory = try keys.map { try loadResult($0[1]) }
            run.result = run.resultHistory.last
        } else {
            let latest = try rows("SELECT ordinal,result_id FROM run_result_history WHERE run_id=? ORDER BY ordinal DESC LIMIT 1", [run.id.rawValue]).first
            let count = latest.flatMap { Int($0[0]) }.map { $0 + 1 } ?? 0
            guard count == (run.savedResultCount ?? 0) else { throw error("최근 결과와 저장된 이력 개수 불일치") }
            run.resultHistory = []
            run.result = try latest.map { try loadResult($0[1]) }
        }
        return run
    }
    private func encodeStoredEvent(_ event: RunEvent) throws -> String {
        guard normalizedSchema else { return try encode(event) }
        let result: RunResult, payload: RunEvent.Payload
        switch event.payload {
        case .saveResult(let value): result = value; payload = .saveResult(resultMetadata(value))
        case .complete(let value, let notificationID): result = value; payload = .complete(resultMetadata(value), notificationID: notificationID)
        default: return try encode(event)
        }
        let metadata = RunEvent(id: event.id, runID: event.runID, sequence: event.sequence, at: event.at, payload: payload)
        return try encode(NormalizedRunEvent(metadata: metadata, resultKey: storeResult(result)))
    }
    private func decodeStoredEvent(_ payload: String) throws -> RunEvent {
        if let stored = try? decoder.decode(NormalizedRunEvent.self, from: Data(payload.utf8)) {
            let result = try loadResult(stored.resultKey), event = stored.metadata
            let value: RunEvent.Payload
            switch event.payload {
            case .saveResult(let metadata):
                guard metadata == resultMetadata(result) else { throw error("이벤트 결과 메타데이터 손상") }
                value = .saveResult(result)
            case .complete(let metadata, let notificationID):
                guard metadata == resultMetadata(result) else { throw error("이벤트 결과 메타데이터 손상") }
                value = .complete(result, notificationID: notificationID)
            default: throw error("정규화 이벤트 종류 손상")
            }
            return .init(id: event.id, runID: event.runID, sequence: event.sequence, at: event.at, payload: value)
        }
        return try decode(RunEvent.self, payload)
    }

    private func validateWorkspace(_ workspace: RunWorkspace) throws {
        try validatePath(workspace.worktreePath)
        if let session = workspace.ompSessionPath { try validatePath(session) }
    }
    private func saveResult(_ result: RunResult, on run: inout PersistedRun) throws {
        try validateResult(result, mode: run.mode)
        if let workspace = run.workspace, workspace.worktreePath != result.worktreePath { throw error("결과의 작업 경로가 달라요") }
        if normalizedSchema {
            if run.result != result {
                let key = try storeResult(result)
                try connection.execute("INSERT INTO run_result_history(run_id,ordinal,result_id) SELECT ?,COALESCE(MAX(ordinal),-1)+1,? FROM run_result_history WHERE run_id=?", [run.id.rawValue, key, run.id.rawValue])
                run.savedResultCount = (run.savedResultCount ?? 0) + 1
            }
        } else if run.resultHistory.last != result { run.resultHistory.append(result) }
        run.result = result
    }

    private func stop(_ run: inout PersistedRun, state: DurableRunState, at: Date, reason: String) {
        run.state = state; run.endedAt = at; run.stopReason = reason
        run.hird.status = .failed(at: at); run.hird.currentCommand = nil
    }
    private func updateWaiting(_ run: inout PersistedRun, at: Date) throws {
        let questions: [PersistedQuestion] = try records("questions", whereSQL: "run_id=?", values: [run.id.rawValue])
        if let oldest = questions.first(where: { $0.state == .pending }) {
            run.state = .waitingOnHuman; run.hird.status = .waitingOnHuman(since: oldest.createdAt)
        } else { run.state = .working; run.hird.status = .working }
    }
    private func closeQuestions(_ runID: HirdRun.ID, at: Date) throws {
        let questions: [PersistedQuestion] = try records("questions", whereSQL: "run_id=?", values: [runID.rawValue])
        for var q in questions where q.state == .pending { q.state = .cancelled; q.resolvedAt = at; try writeQuestion(q) }
    }
    public func readRun(_ id: HirdRun.ID, includeHistory: Bool = true) throws -> PersistedRun {
        try connection.execute("BEGIN")
        do {
            try synchronizeCaches()
            let run = try hydrateRun(requireRun(id), includeHistory: includeHistory)
            try connection.execute("COMMIT")
            return run
        } catch { try? connection.execute("ROLLBACK"); throw error }
    }

    /// Whole-record saves reject stale review snapshots as well as changed execution results.
    public func saveReview(_ review: StallariReview, runID: HirdRun.ID, at: Date = .now,
                           expectedResultVersion: String? = nil) throws -> StallariReview {
        defer { publishSnapshot() }
        return try connection.transaction {
            var run = try requireRun(runID)
            try requireReviewResult(run, expectedVersion: expectedResultVersion)
            guard (review.revision ?? 0) == (run.review?.revision ?? 0) else {
                throw error("검토 기록이 바뀌었어요. 최신 기록을 다시 읽고 저장하세요")
            }
            return try writeReview(review, on: &run, at: at)
        }
    }

    /// Apply one tool's change to the latest review inside the same transaction. Concurrent
    /// note/read/refresh calls therefore preserve each other's records without model retries.
    func updateReview(runID: HirdRun.ID, expectedResultVersion: String? = nil,
                      update: @Sendable (StallariReview?, Issue, PersistedRun) throws -> StallariReview?) throws -> StallariReview? {
        defer { publishSnapshot() }
        return try connection.transaction {
            var run = try requireRun(runID)
            try requireReviewResult(run, expectedVersion: expectedResultVersion)
            let issue = try requireIssue(run.issueID)
            guard let review = try update(run.review, issue, run) else { return run.review }
            return try writeReview(review, on: &run, at: .now)
        }
    }

    private func requireReviewResult(_ run: PersistedRun, expectedVersion: String?) throws {
        if let expectedVersion, StallariReview.version(of: run.result) != expectedVersion {
            throw error("검토 중 실행 결과가 바뀌었어요. get_run(view: review)로 다시 확인하세요")
        }
    }

    private func writeReview(_ review: StallariReview, on run: inout PersistedRun, at: Date) throws -> StallariReview {
        guard run.issueID.rawValue == review.issueID, run.id.rawValue == review.runID else {
            throw error("검토 기록의 실행·이슈 연결이 달라요")
        }
        var value = review
        value.updatedAt = at
        value.revision = (run.review?.revision ?? 0) + 1
        value.reads = value.reads.map { read in
            var read = read
            if read.at > at { read.at = at }
            return read
        }
        value = value.bounded()
        run.review = value
        try writeRun(run)
        return value
    }

    private func requireRun(_ id: HirdRun.ID) throws -> PersistedRun {
        guard let run: PersistedRun = try record("runs", id.rawValue) else { throw error("실행이 없어요: \(id.rawValue)") }
        return run
    }
    private func requireQuestion(_ id: String, runID: HirdRun.ID) throws -> PersistedQuestion {
        guard let question: PersistedQuestion = try record("questions", id), question.runID == runID else { throw error("질문의 실행 연결이 달라요") }
        return question
    }
    private func preserveAcceptanceEvidence(for issue: Issue) throws {
        guard issue.acceptance.contains(where: { $0.state != .pending || !$0.evidence.isEmpty }) else { return }
        let runs: [PersistedRun] = try records("runs", whereSQL: "issue_id=?", values: [issue.id.rawValue])
        guard var latest = runs.last, latest.state.isTerminal, latest.acceptanceEvidence != issue.acceptance else { return }
        latest.acceptanceEvidence = issue.acceptance
        try writeRun(latest)
    }
    private func writeRun(_ run: PersistedRun) throws {
        snapshotRuns.removeValue(forKey: run.id.rawValue)
        var compact = run
        if normalizedSchema { compact.result = nil; compact.resultHistory = []; compact.savedResultCount = run.savedResultCount ?? 0 }
        try connection.execute("UPDATE runs SET payload=? WHERE id=?", [try encode(compact), run.id.rawValue])
    }
    private func writeQuestion(_ q: PersistedQuestion) throws { try connection.execute("UPDATE questions SET payload=? WHERE id=?", [try encode(q), q.id]) }
    private func record<T: Decodable>(_ table: String, _ id: String) throws -> T? {
        try synchronizeCaches()
        return try rows("SELECT payload FROM \(table) WHERE id=?", [id]).first.map { try decode(T.self, $0[0]) }
    }
    private func records<T: Decodable>(_ table: String, whereSQL: String? = nil, values: [String?] = []) throws -> [T] {
        try synchronizeCaches()
        if whereSQL == nil {
            let cached = try cachedTable(table)
            if let collection = cached.collection as? [T] { return collection }
            let collection: [T] = try cached.order.map { try cachedValue($0, table: cached) }
            cached.collection = collection
            return collection
        }
        let predicate = whereSQL.map { " WHERE \($0)" } ?? ""
        return try rows("SELECT payload FROM \(table)\(predicate) ORDER BY rowid", values).map { try decode(T.self, $0[0]) }
    }
    private func synchronizeCaches() throws {
        let version = try rows("PRAGMA data_version").first?.first
        if snapshotDataVersion != version || cachedEpoch != connection.cacheEpoch {
            entityTables.removeAll(); snapshotRuns.removeAll()
            projectedIssues.removeAll()
            resultCache.removeAll(); verificationCache.removeAll()
            resultCacheBytes = 0; verificationCacheBytes = 0
            snapshotDataVersion = version; cachedEpoch = connection.cacheEpoch
        }
    }
    private func cachedTable(_ name: String) throws -> EntityTable {
        try synchronizeCaches()
        let changed = connection.takeChangedRowIDs(name)
        let columns = name == "activities" ? "rowid,issue_id,payload" : name == "issues" ? "rowid,project_id,payload" : "rowid,payload"
        let table: EntityTable
        let selected: [[String]]
        if let known = entityTables[name], let changed {
            table = known
            if changed.isEmpty { return table }
            // Hook values are SQLite rowids, never external SQL input.
            let ids = changed.sorted().map(String.init).joined(separator: ",")
            selected = try rows("SELECT \(columns) FROM \(name) WHERE rowid IN (\(ids)) ORDER BY rowid")
            for id in changed {
                if name == "activities", let old = table.rows[id] {
                    let issueID = old.row[1]
                    table.activityRows[issueID]?.remove(id)
                    if table.activityRows[issueID]?.isEmpty == true { table.activityRows.removeValue(forKey: issueID) }
                    table.activityHistories.removeValue(forKey: issueID)
                }
                table.rows.removeValue(forKey: id)
            }
        } else {
            table = EntityTable()
            selected = try rows("SELECT \(columns) FROM \(name) ORDER BY rowid")
        }
        table.collection = nil; table.chatItems = nil
        for row in selected {
            guard let id = Int64(row[0]) else { throw error("행 식별자 손상") }
            table.rows[id] = CachedEntity(row: row)
            if name == "activities" {
                table.activityRows[row[1], default: []].insert(id)
                table.activityHistories.removeValue(forKey: row[1])
            }
        }
        table.order = table.rows.keys.sorted()
        entityTables[name] = table
        return table
    }
    private func cachedValue<T: Decodable>(_ id: Int64, table: EntityTable) throws -> T {
        guard var entry = table.rows[id], let payload = entry.row.last else { throw error("행 캐시 연결 손상") }
        if let value = entry.value as? T { return value }
        let value = try decode(T.self, payload)
        entry.value = value; table.rows[id] = entry
        return value
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        decodedPayloadBytes += text.utf8.count
        do {
            var payload = text
            if legacySchema {
                let table: String
                switch type {
                case is PersistedRun.Type: table = "runs"
                case is PersistedQuestion.Type: table = "questions"
                case is StoredChat.Type: table = "chat"
                case is RunEvent.Type: table = "run_events"
                default: table = ""
                }
                if !table.isEmpty { payload = try IssueSchemaMigration.payload(text, table: table) }
            }
            let value = try decoder.decode(type, from: Data(payload.utf8))
            if let run = value as? PersistedRun, normalizedSchema { return try hydrateRun(run, includeHistory: false) as! T }
            return value
        } catch { throw self.error("저장 내용 해석 실패: \(error)") }
    }
    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        let query = legacySchema
            ? sql.replacingOccurrences(of: "issues", with: "things").replacingOccurrences(of: "issue_id", with: "thing_id")
            : sql
        return try connection.rows(query, values)
    }
    private func error(_ message: String) -> PersistenceError { .init(databasePath: connection.path, message: message) }
    private func validateID(_ id: String) throws { guard !id.isEmpty, !id.contains("\0") else { throw error("빈 식별자 또는 NUL 문자를 사용할 수 없어요") } }
    private func validatePath(_ path: String) throws { guard path.hasPrefix("/"), !path.contains("\0") else { throw error("절대 경로가 필요해요") } }
    private func validateResult(_ result: RunResult, mode: HirdRunMode?) throws {
        if let report = result.reportPath { try validatePath(report) }
        try validatePath(result.worktreePath)
        let hasManifest: Bool
        switch (result.artifactManifestPath, result.artifactManifestMetadata) {
        case (nil, nil): hasManifest = false
        case (.some(let path), .some(let metadata)):
            try validatePath(path)
            guard metadata.sha256.count == 64, metadata.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  metadata.artifactCount > 0, metadata.totalBytes >= 0 else { throw error("artifact manifest 메타데이터가 잘못됐어요") }
            hasManifest = true
        default: throw error("artifact manifest 경로와 무결성 메타데이터가 함께 필요해요")
        }
        // Incomplete archival failures retain actual check references, not a
        // recoverable code snapshot. prepare/apply still require commit/patch.
        guard result.commit?.isEmpty == false || result.diffPath?.isEmpty == false || hasManifest || !result.verifications.isEmpty ||
                (mode == .inspect && result.reportPath?.isEmpty == false) else { throw error("보존된 코드·검증 근거 또는 조사 보고서 경로가 필요해요") }
        if let diff = result.diffPath { try validatePath(diff) }
        guard Set(result.verifications.map(\.id)).count == result.verifications.count else { throw error("검증 식별자가 중복됐어요") }
        for check in result.verifications {
            try validateID(check.id); try validatePath(check.workingDirectory); try validatePath(check.logPath)
            for attachment in check.attachmentPaths ?? [] { try validatePath(attachment) }
            guard !check.command.isEmpty, check.finishedAt >= check.startedAt else { throw error("검증 명령이나 시간이 잘못됐어요") }
        }
    }
}


extension SQLiteKnarrRepository {
    private static func createPreparationSchema(_ db: SQLiteConnection) throws {
        try db.execute("CREATE TABLE project_preparations (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), source_issue_id TEXT UNIQUE, payload TEXT NOT NULL, FOREIGN KEY(source_issue_id,project_id) REFERENCES issues(id,project_id))")
        try db.execute("CREATE INDEX preparations_project ON project_preparations(project_id)")
    }
    public func preparationItems(projectID: String) throws -> [PreparationItem] {
        guard preparationSchema else { return [] }
        let items: [PreparationItem] = try records("project_preparations", whereSQL: "project_id=?", values: [projectID])
        return PreparationItem.ordered(items)
    }
    public func preparationItem(_ id: String) throws -> PreparationItem? {
        guard preparationSchema else { return nil }
        return try record("project_preparations", id)
    }
    private func requirePreparationProject(_ id: String) throws {
        guard preparationSchema, let project: StoredProject = try record("projects", id),
              project.archivedAt == nil, project.settings.workspaceStyle == .preparation else {
            throw error("활성 준비·아카이브형 프로젝트에서 저장해 주세요")
        }
    }
    private func validatePreparationFields(_ fields: PreparationItem.Fields) throws {
        guard !fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fields.title.utf8.count <= 4096, fields.organization.utf8.count <= 4096,
              fields.memo.utf8.count <= 100_000, fields.posting.utf8.count <= 1_000_000,
              fields.deadline?.timeIntervalSinceReferenceDate.isFinite != false,
              fields.documentPaths.count <= 100, fields.documentPaths.allSatisfy({ path in
                  !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains("..")
              }) else { throw error("제목과 공고 내용, 프로젝트 안의 문서 경로를 확인해 주세요") }
    }
    private func requireExecutionIssue(_ id: Issue.ID) throws {
        if preparationSchema, try !rows("SELECT id FROM project_preparations WHERE source_issue_id=?", [id.rawValue]).isEmpty {
            throw error("준비 항목의 원본 이슈예요. 실제 실행 작업은 별도 이슈로 만들어 주세요")
        }
    }
    @discardableResult public func savePreparation(id: String, projectID: String, fields: PreparationItem.Fields,
                                                  expectedRevision: Int, sourceIssueID: Issue.ID? = nil,
                                                  at now: Date = .now) throws -> PreparationItem {
        defer { publishSnapshot() }
        let saved = try connection.transaction {
            try requirePreparationProject(projectID); try validateID(id)
            guard id.utf8.count <= 256, expectedRevision >= 0 else { throw error("준비 항목 식별자와 버전을 확인해 주세요") }
            try validatePreparationFields(fields)
            if var existing: PreparationItem = try record("project_preparations", id) {
                guard existing.projectID == projectID, existing.sourceIssueID == sourceIssueID else { throw error("다른 프로젝트나 원본으로 옮길 수 없어요") }
                if expectedRevision == 0, existing.revision == 1, existing.fields == fields { return existing }
                guard existing.revision == expectedRevision else { throw error("다른 곳에서 수정됐어요. 최신 내용을 확인한 뒤 다시 저장해 주세요. 입력한 내용은 남아 있어요") }
                if fields.submission != existing.fields.submission {
                    existing.records.append(.init(id: UUID().uuidString, text: fields.submission.label,
                                                   submission: fields.submission, recordedAt: now))
                }
                existing.fields = fields; existing.revision += 1; existing.updatedAt = now
                try writePreparation(existing); return existing
            }
            guard expectedRevision == 0 else { throw error("준비 항목을 찾지 못했어요") }
            var source: Issue?
            if let sourceIssueID {
                guard try rows("SELECT id FROM project_preparations WHERE source_issue_id=?", [sourceIssueID.rawValue]).isEmpty,
                      try rows("SELECT project_id FROM issues WHERE id=?", [sourceIssueID.rawValue]).first?.first == projectID,
                      try rows("SELECT id FROM runs WHERE issue_id=?", [sourceIssueID.rawValue]).isEmpty else {
                    throw error("이미 옮겼거나 실행 기록이 있는 이슈예요. 원본과 실행 기록은 유지돼요")
                }
                source = try record("issues", sourceIssueID.rawValue)
                guard source?.state == .awaitingApproval, source?.archivedAt == nil else { throw error("실행 전 후보 이슈만 준비 항목으로 옮길 수 있어요") }
            }
            let item = PreparationItem(id: id, projectID: projectID, revision: 1, fields: fields, sourceIssue: source,
                                       createdAt: now, updatedAt: now, drafts: [], records: [])
            try connection.execute("INSERT INTO project_preparations(id,project_id,source_issue_id,payload) VALUES(?,?,?,?)",
                                   [id, projectID, sourceIssueID?.rawValue, try encode(item)])
            return item
        }
        return saved
    }
    @discardableResult public func appendPreparationDraft(itemID: String, projectID: String, expectedRevision: Int,
        documentID: String, title: String, text: String, kind: PreparationItem.Draft.Kind, at now: Date = .now) throws -> PreparationItem {
        defer { publishSnapshot() }
        let saved = try connection.transaction {
            var item = try writablePreparation(itemID, projectID: projectID, revision: expectedRevision)
            try validateID(documentID)
            guard documentID.utf8.count <= 256, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count <= 4096, text.utf8.count <= 1_000_000 else { throw error("작성본 제목과 내용을 확인해 주세요") }
            let version = item.drafts.filter { $0.documentID == documentID }.count + 1
            item.drafts.append(.init(id: UUID().uuidString, documentID: documentID, version: version, title: title,
                                     text: text, kind: kind, savedAt: now))
            item.revision += 1; item.updatedAt = now
            try writePreparation(item); return item
        }
        return saved
    }
    @discardableResult public func appendPreparationRecord(itemID: String, projectID: String, expectedRevision: Int,
        text: String, submission: PreparationItem.Submission? = nil, at now: Date = .now) throws -> PreparationItem {
        defer { publishSnapshot() }
        let saved = try connection.transaction {
            var item = try writablePreparation(itemID, projectID: projectID, revision: expectedRevision)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw error("진행 내용을 적어 주세요") }
            item.records.append(.init(id: UUID().uuidString, text: text, submission: submission, recordedAt: now))
            if let submission { item.fields.submission = submission }
            item.revision += 1; item.updatedAt = now
            try writePreparation(item); return item
        }
        return saved
    }
    private func writablePreparation(_ id: String, projectID: String, revision: Int) throws -> PreparationItem {
        try requirePreparationProject(projectID)
        guard let item: PreparationItem = try record("project_preparations", id), item.projectID == projectID else { throw error("이 프로젝트의 준비 항목을 찾지 못했어요") }
        guard item.revision == revision else { throw error("다른 곳에서 수정됐어요. 최신 내용을 확인한 뒤 다시 저장해 주세요. 입력한 내용은 남아 있어요") }
        return item
    }
    private func writePreparation(_ item: PreparationItem) throws {
        try connection.execute("UPDATE project_preparations SET payload=? WHERE id=?", [try encode(item), item.id])
    }
    private func validatePreparations() throws {
        guard preparationSchema else { return }
        for row in try rows("SELECT id,project_id,source_issue_id,payload FROM project_preparations") {
            let item = try decode(PreparationItem.self, row[3])
            try validateID(item.id); try validatePreparationFields(item.fields)
            guard item.id == row[0], item.projectID == row[1], (item.sourceIssueID?.rawValue ?? "") == row[2],
                  item.revision > 0, item.updatedAt >= item.createdAt,
                  Set(item.drafts.map(\.id)).count == item.drafts.count,
                  Set(item.records.map(\.id)).count == item.records.count else { throw error("준비 자료 연결 또는 이력 손상") }
            var versions: [String: Int] = [:]
            for draft in item.drafts {
                versions[draft.documentID, default: 0] += 1
                guard draft.version == versions[draft.documentID], !draft.documentID.isEmpty, !draft.title.isEmpty, !draft.text.isEmpty else { throw error("작성본 버전 이력 손상") }
            }
        }
    }
}
