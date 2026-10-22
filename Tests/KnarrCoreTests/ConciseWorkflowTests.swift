import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct ConciseWorkflowTests {
    static let pendingPreamble = "# 승인 범위\n현재 사용자 요청은 이 계획을 검토 가능한 제안으로 등록하는 데까지다. 구현은 이 Knarr 이슈에서 후속 사용자 요청/승인으로 이어간다. 현재 등록만으로 실행하지 않는다. 아래 내용은 향후 승인 시 수행할 change 작업 계획이다."

    @Test func dispatchedTaskDropsOnlyKnownProposalStagePreamble() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = try HirdPolicyFiles(directory: root).load()
        let task = Self.pendingPreamble + "\n\n# 목표\n스크롤 수정. main 병합은 별도 승인을 받는다."
        let prompt = policy.prompt(mode: .change, task: task)
        #expect(!prompt.contains("현재 등록만으로 실행하지 않는다"))
        #expect(prompt.contains("스크롤 수정"))
        #expect(prompt.contains("main 병합은 별도 승인을 받는다"))
        let specific = "# 승인 범위\n결제 화면은 구현하지 마세요. 스크롤만 수정하세요."
        #expect(policy.prompt(mode: .change, task: specific).contains(specific))
        #expect(policy.prompt(mode: .inspect, task: task).contains("현재 등록만으로 실행하지 않는다"))
    }

    @Test func conversationShowsSummaryAndKeepsExactProposalInStorage() async throws {
        let f = try await StallariFixture.make()
        do {
            let id = try await f.session.createIssue(id: "concise", title: "스크롤 수정", criteria: ["읽던 위치 유지"], instruction: "긴 실행 지시 SECRET-PROPOSAL", handoffSummary: "스크롤 위치를 안정화합니다.")
            let snap = try await f.repository.snapshot()
            let issue = try #require(snap.issues.first { $0.id == id })
            #expect(issue.proposal?.instruction == "긴 실행 지시 SECRET-PROPOSAL")
            let texts = snap.chat.compactMap { item -> String? in
                if case .stallari(let text, _) = item.kind { return text }; return nil
            }
            #expect(texts.contains { $0.contains("스크롤 위치를 안정화합니다.") })
            #expect(!texts.contains { $0.contains("정확한 저장 제안") || $0.contains("SECRET-PROPOSAL") })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func legacyGeneratedChatIsCompactWithoutChangingUserText() throws {
        let legacy = "이슈 인계 issueID=i originThreadID=default\n제목: 수정\n요약: 짧은 요약\n완료 조건:\n- 조건\n정확한 저장 제안: {\"instruction\":\"길고 긴 내부 지시\"}\n같은 목표의 점검·판정·보완은 이 대화에서 이어가세요."
        let item = ChatItem(at: .now, kind: .stallari(legacy, project: "P"))
        let stored = StoredChat(item, link: .init(chatID: item.id, projectID: "p", issueID: "i", runID: nil))
        if case .stallari(let text, _) = try stored.item().kind {
            #expect(!text.contains("정확한 저장 제안"))
            #expect(text.contains("짧은 요약"))
        } else { Testing.Issue.record("Expected assistant summary") }
        let user = ChatItem(at: .now, kind: .user(legacy))
        #expect(try StoredChat(user, link: .init(chatID: user.id, projectID: "p", issueID: "i", runID: nil)).item().kind == user.kind)
    }

    @Test func inspectionEvidenceCanProveVisualOrDocumentCriterion() async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.legacyIssue(id: "visual", title: "문서 정리", criteria: ["제목과 본문이 일치한다"], instruction: "내용 확인")
            let run = try await f.dispatch("r", issue: issue)
            let log = f.directory.appendingPathComponent("inspection.log")
            try "read README.md\n# 새 제목\n검토한 본문".write(to: log, atomically: true, encoding: .utf8)
            var data = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(VerificationRecord(id: "read-v", command: ["read README.md"], workingDirectory: f.directory.path, startedAt: .now, finishedAt: .now, exitCode: nil, logPath: log.path, summary: "내용 대조"))) as? [String: Any])
            data["kind"] = "inspection"
            let record = try JSONDecoder().decode(VerificationRecord.self, from: JSONSerialization.data(withJSONObject: data))
            let result = RunResult(worktreePath: f.directory.path, branch: "test", commit: "fixture", diffPath: nil, summary: "문서 확인", verifications: [record])
            _ = try await f.session.receive(.init(id: "end", runID: run, at: .now, payload: .complete(result, notificationID: "done")))
            try await f.session.judge(issueID: issue, runID: run, evidence: [.init(criterionIndex: 0, verificationIDs: ["read-v"], explanation: "저장된 문서 본문과 제목을 대조했습니다.")])
            #expect(try await f.repository.snapshot().issues.first?.state == .done)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    static func readFrames(_ f: HirdFixture, error: Bool = false) async {
        await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("read-proof"), "toolName": .string("read"), "args": .object(["path": .string("original.txt")])]))
        await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("read-proof"), "toolName": .string("read"), "isError": .bool(error), "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(error ? "missing" : "original")])])])]))
    }
    @Test func actualReadEvidenceDoesNotForceDummyShellCommand() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            try await HirdVerificationRetryTests.invalidate("missing", f)
            await Self.readFrames(f)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            for _ in 0..<300 {
                if try await f.repository.snapshot().runs[0].state.isTerminal { break }
                if await f.rpc.requests.filter({ $0.0 == "prompt" }).count > 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await f.repository.snapshot().runs[0].state == .succeeded)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 1)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func evidenceReportAfterTestDoesNotRequestAnotherTest() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await f.rpc.frame(HirdResultTests.start("test"))
            await f.rpc.frame(HirdResultTests.end(0, call: "test"))
            await f.rpc.frame(.object(["type": .string("extension_ui_request"), "id": .string("barrier"), "method": .string("input")]))
            for _ in 0..<300 {
                if try await f.repository.snapshot().questions.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let snap = try await f.repository.snapshot()
            let q = try #require(snap.questions.first)
            _ = try await f.repository.answerQuestion(q.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
            let tree = URL(fileURLWithPath: try #require(snap.runs[0].workspace).worktreePath)
            let evidence = tree.appendingPathComponent("docs/evidence")
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try "검증 결과 보고서".write(to: evidence.appendingPathComponent("result.md"), atomically: true, encoding: .utf8)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            for _ in 0..<300 {
                if try await f.repository.snapshot().runs[0].state.isTerminal { break }
                if await f.rpc.requests.filter({ $0.0 == "prompt" }).count > 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await f.repository.snapshot().runs[0].state == .succeeded)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 1)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func unchangedShippedHirdPolicyUpgradesButCustomPolicySurvives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = HirdPolicyFiles(directory: root)
        _ = try files.load()
        let old = #"""
You are Hird, the coding worker for this Knarr task. Work only in the current isolated Git worktree. Preserve existing changes. Use OMP tools and todo phases. Do not merge, deploy, or modify the original project. Do not read credentials, tokens, .env, authentication stores or print secrets. Run each check as its own bash command (no ; | || chaining), because each command's exit code is recorded as separate evidence. If blocked, preserve the reason and ask the human with ask.

{{#change}}
Make only the requested changes. After your LAST edit run the actual test command with the built-in bash tool and inspect its result. An already-correct result may have no diff. Preserve your final report.
Finish ALL file changes first, including reports, evidence documents, and temporary-file cleanup. Then run the final actual check with the built-in bash tool, inspect its result, and end the turn without changing any files afterward. Set a finite timeout for commands that may run silently for a long time. If a command stalls, diagnose it using its stack and the last command; report the cause instead of repeatedly waiting without a bound.
Use native lsp diagnostics/definition/references when available. Every LSP call is capped at {{lspTimeoutSeconds}} seconds by OMP; on missing server, timeout or failure, continue with read/grep and compiler checks without retrying LSP or waiting for it. Tool approval policies remain authoritative: do not change approval settings or use another tool to bypass a denied/prompt-gated call. If it blocks required work, explain the exact blocked action using ask and request a revised approved issue.
{{/change}}

{{#inspect}}
READ ONLY: inspect source, process and installation metadata without modifying source, configuration or installed apps. Use read/grep/glob for files. Bash is restricted to these read-only command patterns (no substitutions, redirects or compound commands): {{inspectCommands}}. Use cwd for paths, never cd chains. Preserve a substantive final report and actual command evidence; an empty diff is expected. Do not run builds or tests that write files.
{{/inspect}}

Context economy rules:
- Read PNGs only for necessary scenes; crop to the relevant region before reading instead of retaining full snapshots.
- Read only failure excerpts from test/build logs; do not put complete successful logs into the conversation.
- For any bash command that may exceed 60 seconds, specify a finite timeout argument: full tests timeout: 900, builds and snapshots timeout: 600, filtered tests timeout: 180.
"""#
        let path = root.appendingPathComponent("instructions.md")
        try old.write(to: path, atomically: true, encoding: .utf8)
        let upgraded = try files.load()
        #expect(upgraded.instructions.contains("Your final response is saved as the report automatically"))
        #expect(!upgraded.instructions.contains("Finish ALL file changes first"))
        let custom = old + "\nCustom user rule: keep fixture files."
        try custom.write(to: path, atomically: true, encoding: .utf8)
        #expect(try files.load().instructions == custom)
    }

    @Test func failedReadCannotReplaceEvidence() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            await Self.readFrames(f, error: true)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await HirdVerificationRetryTests.awaitPrompts(2, f)
            #expect(try await f.repository.snapshot().runs[0].result?.verifications.isEmpty ?? true)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func readingSourceAfterCodeChangeDoesNotRefreshOldTest() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            try await HirdVerificationRetryTests.invalidate("changed", f)
            await Self.readFrames(f)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await HirdVerificationRetryTests.awaitPrompts(2, f)
            #expect(try await f.repository.snapshot().runs[0].state != .succeeded)
            await f.adapter.cancel(f.run.id); _ = await task.result
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

    @Test func oldResponseDefaultsUpgradeWithoutChangingCustomPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = ResponseRulesFile(url: root.appendingPathComponent("rules.md"))
        let old = #"""
# Stallari 응답 지침

사용자에게 한국어로 간결하게 답한다. 결론이나 필요한 결정을 먼저 쓴다.
Markdown을 사용한다. 첫 callout은 완료·판정 시 > [!RESULT], 결정 필요 시 > [!DECIDE], 중단 시 > [!STOP], 진행 중에는 > [!INFO]로 쓴다.
긴 답변은 ## 제목, 비교·검사 결과는 표, 코드는 언어를 붙인 fenced block, 긴 근거는 접힌 callout (> [!INFO]- 제목)을 사용한다.
“이번에는 조회만 했습니다”, “수정하지 않았습니다”처럼 하지 않은 일을 나열하지 않는다.
질문과 단순 확인은 직접 읽거나 읽기 전용 scout로 처리한다. 명령 실행이 필요한 조사와 코드 변경은 사용자의 승인 범위 안에서 Hird에 맡긴다.
"""#
        try rules.save(old + "\n")
        #expect(try rules.load().trimmingCharacters(in: .whitespacesAndNewlines) == ResponseRulesFile.defaults)
        let custom = old + "\n나의 추가 말투 규칙"
        try rules.save(custom)
        #expect(try rules.load() == custom)
    }

    @Test func imageReadKeepsActualPixelsSeparateFromTestResults() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            try await HirdVerificationRetryTests.invalidate("missing", f)
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            await f.rpc.frame(.object(["type": .string("tool_execution_start"), "toolCallId": .string("image"), "toolName": .string("read"), "args": .object(["path": .string("screen.png")])]))
            await f.rpc.frame(.object(["type": .string("tool_execution_end"), "toolCallId": .string("image"), "toolName": .string("read"), "isError": .bool(false), "result": .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png)])])])]))
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await task.value
            let snap = try await f.repository.snapshot()
            let result = try #require(snap.runs[0].result)
            let record = try #require(result.verifications.first)
            #expect(record.isInspection && record.exitCode == nil && !record.isSingleCheck)
            let text = try String(contentsOfFile: record.logPath, encoding: .utf8)
            let path = try #require(text.components(separatedBy: "Observed image: ").last)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(base64Encoded: png))
            #expect(snap.runs[0].stageProgress.checks.passed == 0)
            #expect(snap.runs[0].stageProgress.checks.running == 0)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }

}
