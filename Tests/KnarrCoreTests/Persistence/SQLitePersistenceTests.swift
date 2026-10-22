import Foundation
import Darwin
import Testing
@testable import KnarrCore

private let date = Date(timeIntervalSince1970: 1_790_000_000.125)

private struct Fixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("knarr.sqlite") }
    init() throws {
        let root = ProcessInfo.processInfo.environment["KNARR_TEST_FIXTURE_ROOT"] ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        directory = URL(fileURLWithPath: root).appendingPathComponent("knarr-persistence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() throws { try FileManager.default.removeItem(at: directory) }
}

private func issue(_ id: KnarrCore.Issue.ID = "issue") -> KnarrCore.Issue {
    KnarrCore.Issue(id: id, title: "저장 데이터 보존", projectName: "Knarr", state: .running,
          headline: "검증 중", detail: "재열기를 확인해요", acceptance: [
            .init(text: "기존 내용 보존", state: .pending, evidence: "검사 대기")
          ], hirds: [], events: [], startedAt: date)
}
private func run(_ id: HirdRun.ID = "run", issueID: KnarrCore.Issue.ID = "issue") -> PersistedRun {
    PersistedRun(hird: HirdRun(id: id, name: "Hird-1", role: "저장 확인", status: .working,
                              steps: [.init(title: "재열기", state: .active)],
                              currentCommand: "swift test", lastActivityAt: date),
                 issueID: issueID, projectID: "project", ompSessionID: "omp-\(id.rawValue)",
                 ownershipToken: "owner-\(id.rawValue)", startedAt: date)
}
private func seed(_ db: SQLiteKnarrRepository) async throws {
    try await db.saveProject(.init(id: "project", name: "Knarr", absolutePath: "/example/projects/Knarr"))
    try await db.saveIssue(issue(), projectID: "project")
    #expect(try await db.createRun(run()) == .applied)
}
private let result = RunResult(worktreePath: "/tmp/knarr-worktree", branch: "hird/save", commit: "abc123",
                               diffPath: "/tmp/knarr-worktree/result.diff", summary: "재열기 성공", verifications: [
                                .init(id: "check-1", command: ["/usr/bin/swift", "test"], workingDirectory: "/tmp/knarr-worktree",
                                      startedAt: date, finishedAt: date.addingTimeInterval(5), exitCode: 0,
                                      logPath: "/tmp/knarr-worktree/test.log", summary: "내용 일치")
                               ])

@Suite(.serialized) struct SQLitePersistenceTests {
    @Test func appliedBatchClosureLinksIncludedIssuesAndPreservesSkippedHistory() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        for id in ["primary", "included", "cancelled", "archived"] {
            try await db.saveIssue(issue(.init(id)), projectID: "project")
        }
        _ = try await db.createRun(run("cancelled-run", issueID: "cancelled"))
        _ = try await db.cancelRun("cancelled-run", at: date, reason: "still stopping")
        try await db.closeIssue("archived", reason: .cancelled, at: date, note: "original")
        let archived = try #require(try await db.snapshot().issues.first { $0.id == "archived" })
        let at = date.addingTimeInterval(10)
        let skipped = try await db.closeIssue("primary", reason: .applied, at: at, note: " integrated ",
                                             includedIssueIDs: ["included", "issue", "cancelled", "archived"])
        #expect(Set(skipped.keys) == Set<KnarrCore.Issue.ID>(["issue", "cancelled", "archived"]))
        #expect(skipped.values.allSatisfy { !$0.isEmpty })
        let snapshot = try await db.snapshot()
        #expect(snapshot.issues.first { $0.id == "archived" } == archived)
        #expect(snapshot.issues.filter { $0.id == "issue" || $0.id == "cancelled" }.allSatisfy {
            $0.archivedAt == nil && $0.integratedInto == nil
        })
        let included = try #require(snapshot.issues.first { $0.id == "included" })
        #expect(included.archivedAt == at && included.archiveReason == IssueCloseReason.applied.rawValue)
        #expect(included.archiveNote == "integrated" && included.integratedInto == "primary")
        #expect(snapshot.issues.first { $0.id == "primary" }?.integratedInto == nil)
        _ = try await db.markProcessEnded("cancelled-run", at: at)
        #expect(try await db.closeIssue("primary", reason: .applied, at: at,
                                       includedIssueIDs: ["cancelled"]).isEmpty)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: at)
        let restored = try await reopened.snapshot()
        #expect(restored.issues.first { $0.id == "included" }?.integratedInto == "primary")
        #expect(restored.issues.first { $0.id == "cancelled" }?.integratedInto == "primary")
        #expect(restored.issues.first { $0.id == "archived" }?.archiveNote == "original")
        try await reopened.close()
    }

    @Test func invalidIncludedClosureListsRejectWithoutAnyWrites() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await db.saveProject(.init(id: "project", name: "Knarr", absolutePath: f.directory.path))
        try await db.saveProject(.init(id: "other", name: "Other", absolutePath: f.directory.appendingPathComponent("other").path))
        try await db.saveIssue(issue(), projectID: "project")
        try await db.saveIssue(issue("included"), projectID: "project")
        try await db.saveIssue(issue("foreign"), projectID: "other")
        let before = try await db.snapshot()
        let invalid: [[KnarrCore.Issue.ID]] = [
            ["included", "foreign"], ["included", "missing"], ["included", "issue"], ["included", "included"]
        ]
        for ids in invalid {
            await #expect(throws: PersistenceError.self) {
                try await db.closeIssue("issue", reason: .applied, at: date, includedIssueIDs: ids)
            }
            #expect(try await db.snapshot() == before)
        }
        for reason in [IssueCloseReason.cancelled, .superseded] {
            await #expect(throws: PersistenceError.self) {
                try await db.closeIssue("issue", reason: reason, at: date, includedIssueIDs: ["included"])
            }
            #expect(try await db.snapshot() == before)
        }
        try await db.close()
    }

    @Test func primaryActiveAndUnreapedCancelledRunsRejectBatchClosure() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        try await db.saveIssue(issue("included"), projectID: "project")
        let before = try await db.snapshot()
        await #expect(throws: PersistenceError.self) {
            try await db.closeIssue("issue", reason: .applied, at: date, includedIssueIDs: ["included"])
        }
        #expect(try await db.snapshot() == before)
        _ = try await db.cancelRun("run", at: date, reason: "stopping")
        let cancelled = try await db.snapshot()
        await #expect(throws: PersistenceError.self) {
            try await db.closeIssue("issue", reason: .applied, at: date, includedIssueIDs: ["included"])
        }
        #expect(try await db.snapshot() == cancelled)
        _ = try await db.markProcessEnded("run", at: date)
        #expect(try await db.closeIssue("issue", reason: .applied, at: date, includedIssueIDs: ["included"]).isEmpty)
        try await db.close()
    }

    @Test func includedClosureWriteFailureRollsBackPrimaryAndEarlierIncludes() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await db.saveProject(.init(id: "project", name: "Knarr", absolutePath: f.directory.path))
        for id in ["issue", "first", "last"] {
            try await db.saveIssue(issue(.init(id)), projectID: "project")
        }
        let raw = try SQLiteConnection(path: f.url.path, flags: 2)
        try raw.execute("CREATE TRIGGER fail_closure BEFORE UPDATE ON issues WHEN NEW.id='last' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        try raw.close()
        let before = try await db.snapshot()
        await #expect(throws: PersistenceError.self) {
            try await db.closeIssue("issue", reason: .applied, at: date, includedIssueIDs: ["first", "last"])
        }
        #expect(try await db.snapshot() == before)
        try await db.close()
    }

    @Test func strictAnswersRejectResolvedAndTerminalQuestionsWithoutChangingDefaultIdempotency() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        for id in ["answered", "cancelled", "pending"] {
            let question = PersistedQuestion(id: id, runID: "run", issueID: "issue", prompt: "Choose", options: ["A"], createdAt: date)
            _ = try await db.recordEvent(id: "ask-\(id)", runID: "run", at: date, payload: .ask(question))
        }
        let answer = QuestionAnswer(selectedOptions: ["A"], text: nil)
        #expect(try await db.answerQuestion("answered", runID: "run", answer: answer, at: date, requirePending: true) == .applied)
        _ = try await db.cancelQuestion("cancelled", runID: "run", at: date)
        let resolved = try await db.snapshot()
        for id in ["answered", "cancelled"] {
            await #expect(throws: PersistenceError.self) {
                try await db.answerQuestion(id, runID: "run", answer: answer, at: date, requirePending: true)
            }
            #expect(try await db.snapshot() == resolved)
        }
        #expect(try await db.answerQuestion("answered", runID: "run", answer: answer, at: date) == .duplicate)
        #expect(try await db.answerQuestion("cancelled", runID: "run", answer: answer, at: date) == .ignoredTerminal)
        _ = try await db.recordEvent(id: "finish", runID: "run", at: date, payload: .complete(result, notificationID: "notice"))
        let terminal = try await db.snapshot()
        #expect(terminal.questions.first { $0.id == "pending" }?.state == .cancelled)
        for id in ["answered", "pending"] {
            await #expect(throws: PersistenceError.self) {
                try await db.answerQuestion(id, runID: "run", answer: answer, at: date, requirePending: true)
            }
            #expect(try await db.snapshot() == terminal)
        }
        #expect(try await db.answerQuestion("answered", runID: "run", answer: answer, at: date) == .duplicate)
        #expect(try await db.answerQuestion("pending", runID: "run", answer: answer, at: date) == .ignoredTerminal)
        try await db.close()
    }

    @Test func requestedAndObservedRuntimeAndCancellationStagesSurviveReopening() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await db.saveProject(.init(id: "project", name: "fixture", absolutePath: f.directory.path))
        try await db.saveIssue(issue(), projectID: "project")
        var requested = run()
        requested.mode = .inspect
        requested.requestedModel = "openai-codex/requested"
        requested.requestedThinking = "off"
        _ = try await db.createRun(requested)
        _ = try await db.recordEvent(id: "model", runID: "run", at: date, payload: .bindModel("openai-codex/observed"))
        _ = try await db.recordEvent(id: "thinking", runID: "run", at: date, payload: .bindThinking("high"))
        _ = try await db.cancelRun("run", at: date, reason: "취소 요청")
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date.addingTimeInterval(1))
        let admitted = try await reopened.snapshot().runs[0]
        #expect(admitted.requestedModel == "openai-codex/requested")
        #expect(admitted.observedModel == "openai-codex/observed")
        #expect(admitted.requestedThinking == "off")
        #expect(admitted.observedThinking == "high")
        #expect(admitted.cancellationRequestedAt == date)
        #expect(admitted.endedAt == nil && admitted.processEndedAt == nil)
        #expect(try await reopened.markProcessEnded("run", at: date.addingTimeInterval(2)) == .applied)
        #expect(try await reopened.markProcessEnded("run", at: date.addingTimeInterval(3)) == .duplicate)
        try await reopened.close()
        let ended = try await SQLiteKnarrRepository.open(at: f.url, now: date.addingTimeInterval(4))
        #expect(try await ended.snapshot().runs[0].endedAt == date.addingTimeInterval(2))
        #expect(try await ended.snapshot().runs[0].processEndedAt == date.addingTimeInterval(2))
        try await ended.close()
    }

    @Test func reopenPreservesScreenAndRunLinks() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        let diagnostic = try SQLiteConnection(path: f.url.path, flags: 1)
        print("Linked SQLite runtime version: \(try diagnostic.rows("SELECT sqlite_version()"))")
        try diagnostic.close()
        let kinds: [ChatItem.Kind] = [.day("오늘"), .user("저장해 주세요"), .stallari("확인해요", project: "Knarr"),
                                      .issue("issue"), .autoCheck(summary: "내용 일치", lines: ["확인 1"]),
                                      .notice(.init(tone: .result, title: "결과", body: "저장됨", issue: "issue", primary: .init("확인", .confirmResult)))]
        for kind in kinds {
            try await db.appendChat(.init(at: date, kind: kind), projectID: "project", issueID: "issue", runID: "run")
        }
        let event = ActivityEvent(at: date, actor: "Hird-1", text: "검증", detail: "로그 보존")
        #expect(try await db.apply(.init(id: "activity-1", runID: "run", sequence: 1, at: date,
                                        payload: .activity(event, currentCommand: "swift test", steps: nil))) == .applied)
        #expect(try await db.apply(.init(id: "finish", runID: "run", sequence: 2, at: date,
                                        payload: .complete(result, notificationID: "notice-1"))) == .applied)
        #expect(try await db.markNotificationDelivered(id: "notice-1", runID: "run", at: date) == .applied)
        let before = try await db.snapshot()
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date.addingTimeInterval(20))
        let after = try await reopened.snapshot()
        #expect(after == before)
        #expect(Panel.sections(for: after.issues) == Panel.sections(for: before.issues))
        #expect(after.runs.first?.result == result)
        #expect(after.notifications.first?.runID == "run")
        #expect(after.notifications.first?.deliveredAt == date)
        #expect(after.chat.map(\.kind) == kinds)
        #expect(after.chatLinks.allSatisfy { $0.runID == "run" && $0.issueID == "issue" })
        try await reopened.close()
    }

    @Test func cancellationWinsOverLateSuccessAnswerAndActivityAcrossRestarts() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        let q = PersistedQuestion(id: "q1", runID: "run", issueID: "issue", prompt: "진행할까요?", options: ["예", "아니오"], createdAt: date)
        #expect(try await db.apply(.init(id: "ask", runID: "run", sequence: 1, at: date, payload: .ask(q))) == .applied)
        #expect(try await db.cancelRun("run", at: date, reason: "사용자가 중지") == .applied)
        #expect(try await db.apply(.init(id: "late-finish", runID: "run", sequence: 9, at: date,
                                        payload: .complete(result, notificationID: "late-notice"))) == .ignoredTerminal)
        #expect(try await db.answerQuestion("q1", runID: "run", answer: .init(selectedOptions: ["예"], text: nil), at: date) == .ignoredTerminal)
        #expect(try await db.createRun(run()) == .duplicate)
        #expect(try await db.apply(.init(id: "late-activity", runID: "run", sequence: 10, at: date,
                                        payload: .activity(.init(at: date, actor: "Hird", text: "늦은 활동"), currentCommand: "late", steps: nil))) == .ignoredTerminal)
        let before = try await db.snapshot()
        #expect(before.runs.first?.state == .cancelled)
        #expect(before.questions.first?.state == .cancelled)
        #expect(before.notifications.isEmpty)
        #expect(before.runs.first?.result == nil)
        try await db.close()
        for _ in 0..<3 {
            let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
            #expect(try await db.createRun(run()) == .duplicate)
            #expect(try await db.apply(.init(id: "late-finish", runID: "run", sequence: 9, at: date,
                                            payload: .complete(result, notificationID: "late-notice"))) == .duplicate)
            #expect(try await db.snapshot() == before)
            try await db.close()
        }
    }

    @Test func outOfOrderEventsCannotOverwriteNewerStateAndReplayIsChecked() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        let newer = RunEvent(id: "e2", runID: "run", sequence: 2, at: date,
                             payload: .activity(.init(at: date, actor: "Hird", text: "새 상태"), currentCommand: "new", steps: nil))
        #expect(try await db.apply(newer) == .applied)
        #expect(try await db.apply(newer) == .duplicate)
        #expect(try await db.apply(.init(id: "e1", runID: "run", sequence: 1, at: date,
                                        payload: .activity(.init(at: date, actor: "Hird", text: "오래된 상태"), currentCommand: "old", steps: nil))) == .ignoredStale)
        let snapshot = try await db.snapshot()
        #expect(snapshot.runs.first?.hird.currentCommand == "new")
        #expect(snapshot.issues.first?.events.count == 1)
        await #expect(throws: PersistenceError.self) {
            try await db.apply(.init(id: "e2", runID: "run", sequence: 2, at: date, payload: .fail("충돌")))
        }
        try await db.close()
    }

    @Test func questionAnswersStayOnTheirRunAndPendingOutboxSurvives() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        _ = try await db.createRun(run("run2"))
        for id in ["run", "run2"] {
            let q = PersistedQuestion(id: "q-\(id)", runID: .init(id), issueID: "issue", prompt: "선택", options: ["A", "B"], createdAt: date)
            _ = try await db.apply(.init(id: "ask-\(id)", runID: .init(id), sequence: 1, at: date, payload: .ask(q)))
        }
        _ = try await db.answerQuestion("q-run2", runID: "run2", answer: .init(selectedOptions: ["B"], text: "둘째"), at: date)
        _ = try await db.answerQuestion("q-run", runID: "run", answer: .init(selectedOptions: ["A"], text: "첫째"), at: date)
        #expect(try await db.answerQuestion("q-run", runID: "run", answer: .init(selectedOptions: ["A"], text: "첫째"), at: date) == .duplicate)
        await #expect(throws: PersistenceError.self) {
            try await db.answerQuestion("q-run", runID: "run2", answer: .init(selectedOptions: ["A"], text: nil), at: date)
        }
        _ = try await db.apply(.init(id: "finish-run", runID: "run", sequence: 2, at: date, payload: .complete(result, notificationID: "n")))
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.questions.map { $0.answer?.text } == ["첫째", "둘째"])
        #expect(try await reopened.pendingNotifications().map(\.id) == ["n"])
        #expect(snapshot.notifications.first?.runID == "run")
        try await reopened.close()
    }

    @Test func deadOwnedProcessIsInterruptedOnOpenAndCannotBeResurrected() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/bin/sleep"),
            workingDirectory: f.directory, arguments: ["60"])) { process in
            print("Owned recovery fixture PID=\(process.id), path=\(f.url.path)")
            let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
            try await seed(db)
            try await db.close()
            let alive = try await SQLiteKnarrRepository.open(at: f.url, now: date, probe: { record in
                process.isRunning ? .alive(ownershipToken: record.ownershipToken, ompSessionID: record.ompSessionID) : .dead
            })
            #expect(try await alive.snapshot().runs.first?.state == .working)
            try await alive.close()
            process.signal(SIGTERM)
            #expect(try await process.waitForExit() == 128 + SIGTERM)
            #expect(!process.isRunning)
            let dead = try await SQLiteKnarrRepository.open(at: f.url, now: date, probe: { _ in .dead })
            #expect(try await dead.snapshot().runs.first?.state == .interrupted)
            #expect(try await dead.snapshot().issues.first?.state == .failed)
            #expect(try await dead.createRun(run()) == .duplicate)
            #expect(try await dead.apply(.init(id: "late", runID: "run", sequence: 2, at: date,
                                              payload: .complete(result, notificationID: "n"))) == .ignoredTerminal)
            try await dead.close()
            let again = try await SQLiteKnarrRepository.open(at: f.url, now: date)
            #expect(try await again.snapshot().runs.count == 1)
            #expect(try await again.snapshot().runs.first?.state == .interrupted)
            try await again.close()
        }
    }

    @Test func damagedDatabaseIsPreservedAndReportsRecoveryPath() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let bytes = Data("SQLite format 3\0this is a damaged database".utf8)
        try bytes.write(to: f.url)
        do {
            let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
            try await db.close()
            Testing.Issue.record("손상 DB 열기가 성공했어요")
        } catch let error as PersistenceError {
            #expect(error.databasePath == f.url.path)
            #expect(!error.recoverySuggestion.isEmpty)
        }
        #expect(try Data(contentsOf: f.url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path) == ["knarr.sqlite"])
    }

    @Test func invalidCompletionRollsBackStateResultAndNotification() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        _ = try await db.createRun(run("run2"))
        _ = try await db.apply(.init(id: "done1", runID: "run", sequence: 1, at: date, payload: .complete(result, notificationID: "same")))
        await #expect(throws: PersistenceError.self) {
            try await db.apply(.init(id: "done2", runID: "run2", sequence: 1, at: date, payload: .complete(result, notificationID: "same")))
        }
        let snapshot = try await db.snapshot()
        #expect(snapshot.runs.last?.state == .working)
        #expect(snapshot.runs.last?.result == nil)
        #expect(snapshot.notifications.count == 1)
        _ = try await db.apply(.init(id: "done2", runID: "run2", sequence: 1, at: date, payload: .complete(result, notificationID: "different")))
        #expect(try await db.snapshot().notifications.count == 2)
        try await db.close()
    }
    @Test func pendingQuestionsAndUnverifiedOwnershipSurviveWithoutWorkingStatus() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        let q = PersistedQuestion(id: "pending", runID: "run", issueID: "issue", prompt: "계속할까요?", options: [], createdAt: date)
        _ = try await db.apply(.init(id: "ask", runID: "run", sequence: 1, at: date, payload: .ask(q)))
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date, probe: { _ in
            .alive(ownershipToken: "wrong-owner", ompSessionID: "omp-run")
        })
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.questions.first == q)
        #expect(snapshot.runs.first?.state == .interrupted)
        #expect(snapshot.runs.first?.ompSessionID == "omp-run")
        #expect(snapshot.issues.first?.headline == "실행 중단")
        #expect(try await reopened.answerQuestion("pending", runID: "run", answer: .init(selectedOptions: [], text: "계속"), at: date) == .ignoredTerminal)
        try await reopened.close()
    }

    @Test func twoQuestionsCancelledAnswerAndReworkLineageRemainSeparate() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        for i in 1...2 {
            let q = PersistedQuestion(id: "q\(i)", runID: "run", issueID: "issue", prompt: "선택", options: ["A"], createdAt: date)
            _ = try await db.apply(.init(id: "ask\(i)", runID: "run", sequence: Int64(i), at: date, payload: .ask(q)))
        }
        _ = try await db.cancelQuestion("q1", runID: "run", at: date)
        #expect(try await db.answerQuestion("q1", runID: "run", answer: .init(selectedOptions: ["A"], text: nil), at: date) == .ignoredTerminal)
        #expect(try await db.snapshot().runs.first?.state == .waitingOnHuman)
        _ = try await db.answerQuestion("q2", runID: "run", answer: .init(selectedOptions: ["A"], text: nil), at: date)
        #expect(try await db.snapshot().runs.first?.state == .working)
        _ = try await db.apply(.init(id: "finish", runID: "run", sequence: 3, at: date, payload: .complete(result, notificationID: "n")))
        let next = PersistedRun(hird: run("rework").hird, issueID: "issue", projectID: "project", ompSessionID: nil,
                                ownershipToken: "new-owner", startedAt: date, previousRunID: "run")
        _ = try await db.createRun(next)
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.runs.count == 2)
        #expect(snapshot.runs.first?.result == result)
        #expect(snapshot.runs.last?.previousRunID == "run")
        #expect(snapshot.questions.map(\.state) == [.cancelled, .answered])
        try await reopened.close()
    }

    @Test func multipleConnectionsCreateOneRunAndCancellationWinsAgainstCompletion() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let first = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await first.saveProject(.init(id: "project", name: "Knarr", absolutePath: "/example/projects/Knarr"))
        try await first.saveIssue(issue(), projectID: "project")
        let second = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        async let a = first.createRun(run())
        async let b = second.createRun(run())
        let outcomes = try await [a, b]
        #expect(outcomes.filter { $0 == .applied }.count == 1)
        #expect(outcomes.filter { $0 == .duplicate }.count == 1)
        _ = try await first.cancelRun("run", at: date, reason: "중지")
        _ = try await second.apply(.init(id: "late", runID: "run", sequence: 1, at: date, payload: .complete(result, notificationID: "n")))
        #expect(try await first.snapshot().runs.first?.state == .cancelled)
        #expect(try await second.snapshot().notifications.isEmpty)
        try await first.close(); try await second.close()
    }

    @Test func zeroByteForeignAndNewerDatabasesAreNeverReinitialized() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        try Data().write(to: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url, now: date) }
        #expect(try Data(contentsOf: f.url).isEmpty)
        try FileManager.default.removeItem(at: f.url)
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db); try await db.close()
        let connection = try SQLiteConnection(path: f.url.path, flags: 2)
        try connection.execute("PRAGMA user_version = 999")
        try connection.close()
        let bytes = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url, now: date) }
        #expect(try Data(contentsOf: f.url) == bytes)
    }

    @Test func invalidProjectAndCrossProjectRunNeverPersist() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        await #expect(throws: PersistenceError.self) { try await db.saveProject(.init(id: "p", name: "bad", absolutePath: "relative")) }
        try await seed(db)
        try await db.saveProject(.init(id: "other", name: "other", absolutePath: "/tmp/other"))
        let wrong = PersistedRun(hird: run("wrong").hird, issueID: "issue", projectID: "other", ompSessionID: nil,
                                 ownershipToken: "owner", startedAt: date)
        await #expect(throws: PersistenceError.self) { try await db.createRun(wrong) }
        #expect(try await db.snapshot().runs.count == 1)
        try await db.close()
    }

    @Test func activeWorkspacePartialResultAndStallariActivitySurviveInterruption() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        let workspace = RunWorkspace(worktreePath: "/tmp/knarr-worktree", branch: "hird/save", ompSessionPath: "/tmp/omp-session.jsonl")
        _ = try await db.apply(.init(id: "workspace", runID: "run", sequence: 1, at: date, payload: .recordWorkspace(workspace)))
        _ = try await db.apply(.init(id: "partial", runID: "run", sequence: 2, at: date, payload: .saveResult(result)))
        let note = ActivityEvent(at: date, actor: "Stallari", text: "조건을 정했어요")
        try await db.appendActivity(note, issueID: "issue")
        try await db.close()
        let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.runs.first?.workspace == workspace)
        #expect(snapshot.runs.first?.result == result)
        #expect(snapshot.runs.first?.resultHistory == [result])
        #expect(snapshot.issues.first?.events == [note])
        #expect(snapshot.notifications.isEmpty)
        #expect(snapshot.runs.first?.state == .interrupted)
        try await reopened.close()
    }

    @Test func logicalIdentifierDamageIsRejectedBeforeRecoveryWrites() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db); try await db.close()
        let connection = try SQLiteConnection(path: f.url.path, flags: 2)
        let wire = try #require(connection.rows("SELECT payload FROM runs").first?.first)
        var json = try #require(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
        json["issueID"] = ["rawValue": "unknown-issue"]
        let changed = String(decoding: try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), as: UTF8.self)
        try connection.execute("UPDATE runs SET payload=?", [changed]); try connection.close()
        let bytes = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url, now: date) }
        #expect(try Data(contentsOf: f.url) == bytes)
    }

    @Test(arguments: [false, true]) func killedWriterRollsBackItsHotJournalBeforeRestartRecovery(unsupportedVersion: Bool) async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db)
        _ = try await db.cancelRun("run", at: date, reason: "완료 후 쓰기 중단 시험")
        let before = try await db.snapshot(); try await db.close()
        let setup = try SQLiteConnection(path: f.url.path, flags: 2)
        try setup.execute("CREATE TABLE crash_padding(payload BLOB)")
        for _ in 0..<40 { try setup.execute("INSERT INTO crash_padding VALUES(zeroblob(65536))") }
        if unsupportedVersion { try setup.execute("PRAGMA user_version = 999") }
        try setup.close()
        let committedBytes = try Data(contentsOf: f.url)
        let ready = f.directory.appendingPathComponent("writer-ready")
        let arguments = ["-c", """
        import sqlite3, sys, time
        from pathlib import Path
        db = sqlite3.connect(sys.argv[1])
        db.execute('PRAGMA cache_size=1')
        db.execute('PRAGMA cache_spill=ON')
        db.execute('BEGIN IMMEDIATE')
        db.execute("UPDATE projects SET payload = 'uncommitted damaged payload'")
        db.execute('UPDATE crash_padding SET payload=randomblob(65536)')
        Path(sys.argv[2]).write_text('ready')
        time.sleep(60)
        """, f.url.path, ready.path]
        try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            workingDirectory: f.directory, arguments: arguments)) { process in
            for _ in 0..<500 {
                if FileManager.default.fileExists(atPath: ready.path) || !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(FileManager.default.fileExists(atPath: ready.path))
            #expect(FileManager.default.fileExists(atPath: f.url.path + "-journal"))
            #expect(try Data(contentsOf: f.url) != committedBytes)
            #expect(try Data(contentsOf: URL(fileURLWithPath: f.url.path + "-journal")).prefix(8) != Data(repeating: 0, count: 8))
            try #require(process.isRunning)
            print("Owned SQLite crash writer PID=\(process.id), fixture=\(f.url.path)")
            process.signal(SIGKILL)
            #expect(try await process.waitForExit() == 128 + SIGKILL)
            #expect(!process.isRunning)
            if unsupportedVersion {
                let original = try Data(contentsOf: f.url)
                let journalURL = URL(fileURLWithPath: f.url.path + "-journal")
                let journal = try Data(contentsOf: journalURL)
                await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url, now: date) }
                #expect(try Data(contentsOf: f.url) == original)
                #expect(try Data(contentsOf: journalURL) == journal)
            } else {
                let reopened = try await SQLiteKnarrRepository.open(at: f.url, now: date)
                #expect(try await reopened.snapshot() == before)
                try await reopened.close()
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).allSatisfy { !$0.hasPrefix(".knarr-preflight-") })
            print("Owned SQLite crash writer PID=\(process.id) exited; hot journal case checked, unsupportedVersion=\(unsupportedVersion)")
        }
    }

    @Test func fixtureExitWaitHasDeadlineAndReapsTimedOutChild() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        try await withTestChildProcess(.init(executable: URL(fileURLWithPath: "/bin/sleep"),
            workingDirectory: f.directory, arguments: ["60"])) { process in
            await #expect(throws: OMPRPCError.timedOut) {
                _ = try await process.waitForExit(timeout: .milliseconds(20))
            }
            let status = try await process.waitForExit()
            #expect(status == 128 + SIGKILL)
        }
    }

    @Test func damagedUTF8IsRejectedWithoutReplacingUserText() async throws {
        let f = try Fixture(); defer { try? f.cleanup() }
        let db = try await SQLiteKnarrRepository.open(at: f.url, now: date)
        try await seed(db); try await db.close()
        var payload = Data(#"{"id":"project","name":""#.utf8)
        payload.append(0xff)
        payload.append(Data(#"","absolutePath":"/example/projects/Knarr"}"#.utf8))
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let writer = try SQLiteConnection(path: f.url.path, flags: 2)
        try writer.execute("UPDATE projects SET payload = CAST(x'\(hex)' AS TEXT)")
        try writer.close()
        let bytes = try Data(contentsOf: f.url)
        await #expect(throws: PersistenceError.self) { try await SQLiteKnarrRepository.open(at: f.url, now: date) }
        #expect(try Data(contentsOf: f.url) == bytes)
    }

}
