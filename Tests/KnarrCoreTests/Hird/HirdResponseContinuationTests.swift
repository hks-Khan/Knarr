import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdResponseContinuationTests {
    private static func message(_ content: [OMPJSON], output: Int? = 1, stopReason: String = "stop") -> OMPJSON {
        .object(["type": .string("message_end"), "message": .object([
            "role": .string("assistant"), "content": .array(content),
            "stopReason": .string(stopReason), "usage": .object(output.map { ["output": .number(Double($0))] } ?? [:])
        ])])
    }

    private static func thinking(output: Int = 8192) -> OMPJSON {
        message([.object(["type": .string("thinking"), "thinking": .string("구현과 검증 방법을 생각하고 있어요")])], output: output)
    }

    private static func report(output: Int = 1) -> OMPJSON {
        message([.object(["type": .string("text"), "text": .string("original.txt를 확인했으며 이미 요구사항을 만족하므로 변경하지 않았어요. 확인 결과와 변경 없음 사유를 보고해요.")])], output: output)
    }

    // The base fixture supplies the real repository, Git worktree and scripted transport.
    // Only the advertised model output limit is injected; no production or shared fake API changes.
    private static func exercise(maxTokens: Int? = nil,
                                 _ body: (HirdFixture, OMPHirdAdapter) async throws -> Void) async throws {
        let f = try await HirdFixture.make(temporary: true)
        var adapter = f.adapter
        do {
            if let maxTokens {
                let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let executable = ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
                    ?? base.appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp")
                let rpc = HirdResponseLimitRPC(base: f.rpc, maxTokens: maxTokens)
                adapter = OMPHirdAdapter(repository: f.repository, installation: try OMPInstallation(executable: executable),
                    resultRoot: f.directory.appendingPathComponent("results"), expectedModel: "ollama/gemma4:12b", makeRPC: { rpc })
            }
            let runningAdapter = adapter
            let task = Task { try await runningAdapter.start(f.run, emit: f.sink) }
            do {
                try await HirdVerificationRetryTests.awaitPrompts(1, f)
                try await body(f, runningAdapter)
                _ = try await HirdStopEvidenceTests.wait(f) { $0.runs[0].state.isTerminal }
                _ = await task.result
                await runningAdapter.cancel(f.run.id)
                try await f.cleanup()
            } catch {
                await runningAdapter.cancel(f.run.id)
                _ = await task.result
                throw error
            }
        } catch {
            await adapter.cancel(f.run.id)
            try await f.cleanup()
            throw error
        }
    }

    private static func complete(_ number: Int, _ f: HirdFixture, message: OMPJSON? = nil) async {
        if let message { await f.rpc.frame(message) }
        await f.rpc.frame(HirdVerificationRetryTests.end(number))
    }

    private static func expectContinuing(_ count: Int, _ f: HirdFixture) async throws {
        try await HirdVerificationRetryTests.awaitPrompts(count + 1, f)
        let snapshot = try await f.repository.snapshot()
        #expect(!snapshot.runs[0].state.isTerminal)
        #expect(snapshot.notifications.isEmpty)
        #expect(snapshot.issues[0].events.filter { $0.text.contains("이어 가기") }.count >= count)
        #expect(await f.rpc.started == 1)
        #expect(await f.rpc.requests.allSatisfy { $0.0 != "abort" && $0.0 != "abort_and_prompt" })
        #expect(await f.rpc.shutdownCancellations.isEmpty)
    }

    private static func expectFailed(_ f: HirdFixture, prompts: Int, empty: Bool = false) async throws {
        let saved = try await HirdStopEvidenceTests.wait(f) { $0.runs[0].state.isTerminal }
        #expect(saved.runs[0].state == .failed)
        #expect(saved.notifications.isEmpty)
        let reason = try #require(saved.runs[0].stopReason)
        if empty {
            #expect(reason.contains("변경 없이 종료"))
        } else {
            #expect(reason.contains("생각") || reason.contains("출력"))
            #expect(reason.contains("상한"))
        }
        #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == prompts)
        #expect(await f.rpc.started == 1)
    }

    private static func expectSucceeded(_ f: HirdFixture, prompts: Int) async throws {
        let saved = try await HirdStopEvidenceTests.wait(f) { $0.runs[0].state.isTerminal }
        #expect(saved.runs[0].state == .succeeded)
        #expect(saved.notifications.count == 1)
        #expect(saved.runs[0].stopReason == nil)
        #expect(saved.runs[0].result != nil)
        #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == prompts)
        #expect(await f.rpc.started == 1)
    }

    @Test func thinkingOnlyStopWithoutAdvertisedLimitContinuesAndRecoversInSameRPC() async throws {
        try await Self.exercise { f, _ in
            let state = await f.rpc.state
            #expect(state["model"]?["maxTokens"] == nil)
            await HirdStopEvidenceTests.readEvidence(f)
            await Self.complete(1, f, message: Self.thinking())
            try await Self.expectContinuing(1, f)

            // A stale completion (with or without ID) and settled event cannot finish the new turn.
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            await f.rpc.frame(.object(["type": .string("session_settled")]))
            await f.rpc.frame(.object(["type": .string("prompt_result"), "status": .string("completed"), "sessionSettled": .bool(true)]))
            await f.rpc.frame(HirdStopEvidenceTests.question("stale-response-barrier"))
            let pending = try await HirdStopEvidenceTests.wait(f) { !$0.questions.isEmpty }
            #expect(!pending.runs[0].state.isTerminal)
            #expect(pending.notifications.isEmpty)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 2)
            let question = try #require(pending.questions.first)
            _ = try await f.repository.answerQuestion(question.id, runID: f.run.id,
                answer: .init(selectedOptions: [], text: "계속"), at: .now)
            await Self.complete(2, f, message: Self.report())
            try await Self.expectSucceeded(f, prompts: 2)
        }
    }

    @Test func fourThinkingOnlyStopsExhaustThreeContinuations() async throws {
        try await Self.exercise { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            for number in 1...4 {
                await Self.complete(number, f, message: Self.thinking())
                if number < 4 { try await Self.expectContinuing(number, f) }
            }
            try await Self.expectFailed(f, prompts: 4)
        }
    }

    @Test(arguments: [8192, 8193])
    func finalTextAtOrAboveAdvertisedOutputLimitStillContinues(output: Int) async throws {
        try await Self.exercise(maxTokens: 8192) { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            await Self.complete(1, f, message: Self.report(output: output))
            try await Self.expectContinuing(1, f)
            await Self.complete(2, f, message: Self.report())
            try await Self.expectSucceeded(f, prompts: 2)
        }
    }

    @Test(arguments: [8191, nil] as [Int?])
    func explicitLengthStopWithTextContinuesEvenWithLowerOrMissingUsage(output: Int?) async throws {
        try await Self.exercise(maxTokens: 8192) { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            let interrupted = Self.message([.object(["type": .string("text"),
                "text": .string("최종 보고서를 작성하던 중 출력이 잘렸어요")])],
                output: output, stopReason: "length")
            await Self.complete(1, f, message: interrupted)
            try await Self.expectContinuing(1, f)
            await Self.complete(2, f, message: Self.report())
            try await Self.expectSucceeded(f, prompts: 2)
        }
    }

    @Test func finalTextBelowAdvertisedOutputLimitDoesNotContinue() async throws {
        try await Self.exercise(maxTokens: 8192) { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            await Self.complete(1, f, message: Self.report(output: 8191))
            try await Self.expectSucceeded(f, prompts: 1)
        }
    }

    @Test func readOnlyEvidenceWithoutDiffOrFinalReportCannotSucceed() async throws {
        try await Self.exercise { f, _ in
            for number in 1...4 {
                await HirdStopEvidenceTests.readEvidence(f, call: "read-\(number)")
                await Self.complete(number, f)
                if number < 4 { try await Self.expectContinuing(number, f) }
            }
            try await Self.expectFailed(f, prompts: 4, empty: true)
        }
    }

    @Test func explicitFinalNoChangeReportAllowsEmptyDiff() async throws {
        try await Self.exercise { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            await Self.complete(1, f, message: Self.report())
            try await Self.expectSucceeded(f, prompts: 1)
            let result = try #require(try await f.repository.snapshot().runs[0].result)
            let diff = try #require(result.diffPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: diff)).isEmpty)
            #expect(result.verifications.contains { $0.isInspection })
        }
    }

    @Test(arguments: [false, true])
    func intermediateToolCallMessageIsNotTruncationOrFinalReport(withText: Bool) async throws {
        try await Self.exercise { f, _ in
            var content: [OMPJSON] = [.object(["type": .string("thinking"), "thinking": .string("파일을 확인할게요")])]
            if withText {
                content.append(.object(["type": .string("text"), "text": .string("확인 후 최종 보고서를 작성할게요")]))
            }
            content.append(.object(["type": .string("toolCall"), "id": .string("read-intermediate"),
                                    "name": .string("read"), "arguments": .object(["path": .string("original.txt")])]))
            await f.rpc.frame(Self.message(content, stopReason: "toolUse"))
            await HirdStopEvidenceTests.readEvidence(f, call: "read-intermediate")
            // The tool-bearing message is not a final report, even when it contains text.
            await Self.complete(1, f)
            try await Self.expectContinuing(1, f)
            // Clearing the prior message must avoid classifying this as thinking-only truncation.
            for number in 2...4 {
                await HirdStopEvidenceTests.readEvidence(f, call: "read-\(number)")
                await Self.complete(number, f)
                if number < 4 { try await Self.expectContinuing(number, f) }
            }
            try await Self.expectFailed(f, prompts: 4, empty: true)
        }
    }

    @Test func intermediateThinkingAndToolCallCanFinishWithNormalFinalText() async throws {
        try await Self.exercise { f, _ in
            await f.rpc.frame(Self.message([
                .object(["type": .string("thinking"), "thinking": .string("확인할게요")]),
                .object(["type": .string("toolCall"), "id": .string("read-final"), "name": .string("read"),
                         "arguments": .object(["path": .string("original.txt")])])
            ], stopReason: "toolUse"))
            await HirdStopEvidenceTests.readEvidence(f, call: "read-final")
            await Self.complete(1, f, message: Self.report())
            try await Self.expectSucceeded(f, prompts: 1)
        }
    }

    @Test func commentaryFromEarlierTurnDoesNotBecomeCurrentFinalReport() async throws {
        try await Self.exercise { f, _ in
            await HirdStopEvidenceTests.readEvidence(f)
            await f.rpc.frame(Self.report())
            await Self.complete(1, f, message: Self.thinking())
            try await Self.expectContinuing(1, f)
            for number in 2...4 {
                await HirdStopEvidenceTests.readEvidence(f, call: "read-\(number)")
                await Self.complete(number, f)
                if number < 4 { try await Self.expectContinuing(number, f) }
            }
            try await Self.expectFailed(f, prompts: 4, empty: true)
        }
    }

    @Test func emptyResultsAndTruncatedResponsesShareOneRunWideContinuationLimit() async throws {
        try await Self.exercise { f, _ in
            for number in 1...4 {
                await HirdStopEvidenceTests.readEvidence(f, call: "read-\(number)")
                await Self.complete(number, f, message: number.isMultiple(of: 2) ? nil : Self.thinking())
                if number < 4 { try await Self.expectContinuing(number, f) }
            }
            try await Self.expectFailed(f, prompts: 4, empty: true)
        }
    }

    @Test func threeResponseContinuationsDoNotConsumeTwoVerificationRetries() async throws {
        try await Self.exercise { f, _ in
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            try "changed\n".write(to: URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("original.txt"),
                                  atomically: true, encoding: .utf8)
            for number in 1...3 {
                await Self.complete(number, f, message: Self.thinking())
                try await Self.expectContinuing(number, f)
            }
            for number in 4...6 {
                await Self.complete(number, f, message: Self.report())
                if number < 6 { try await HirdVerificationRetryTests.awaitPrompts(number + 1, f) }
            }
            let saved = try await HirdStopEvidenceTests.wait(f) { $0.runs[0].state.isTerminal }
            #expect(saved.runs[0].state == .failed)
            #expect(saved.runs[0].stopReason?.contains("2") == true)
            #expect(saved.notifications.isEmpty)
            #expect(await f.rpc.requests.filter { $0.0 == "prompt" }.count == 6)
            #expect(await f.rpc.started == 1)
        }
    }
}

private actor HirdResponseLimitRPC: HirdRPC {
    let base: ScriptedHirdRPC
    let maxTokens: Int

    init(base: ScriptedHirdRPC, maxTokens: Int) {
        self.base = base
        self.maxTokens = maxTokens
    }

    func start(_ configuration: OMPLaunchConfiguration) async throws { try await base.start(configuration) }
    func subscribe() async -> AsyncStream<OMPEvent> { await base.subscribe() }
    func request(_ command: String, fields: [String: OMPJSON], timeout: Duration) async throws -> OMPJSON {
        let response = await base.request(command, fields: fields, timeout: timeout)
        guard command == "get_state", case .object(var envelope) = response,
              case .object(var state) = envelope["data"], case .object(var model) = state["model"] else { return response }
        model["maxTokens"] = .number(Double(maxTokens))
        state["model"] = .object(model)
        envelope["data"] = .object(state)
        return .object(envelope)
    }
    func send(_ command: String, fields: [String: OMPJSON]) async throws { await base.send(command, fields: fields) }
    func shutdown(cancel: Bool) async -> OMPProcessExit { await base.shutdown(cancel: cancel) }
}
