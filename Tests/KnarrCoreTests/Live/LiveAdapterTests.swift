import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct LiveAdapterTests {
    @Test func hirdUsesStallariSelectedModelEvenWhenDefaultDiffers() async throws {
        let f = try await HirdFixture.make()
        let adapter = OMPHirdAdapter(repository: f.repository,
            installation: try OMPInstallation(executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["KNARR_OMP_EXECUTABLE"] ??
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/omp/\(OMPInstallation.version)/omp").path)),
            resultRoot: f.directory.appendingPathComponent("selected-results"), expectedModel: "anthropic/claude-fixture-selected", makeRPC: { f.rpc })
        let task = Task { try await adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<100 {
                let prompted = await f.rpc.requests.contains(where: { $0.0 == "prompt" })
                let failed = try await f.repository.snapshot().runs.first?.state == .failed
                if prompted || failed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await f.rpc.requests.contains { $0.0 == "set_model" && $0.1["provider"]?.string == "anthropic" && $0.1["modelId"]?.string == "claude-fixture-selected" })
            #expect(await f.rpc.requests.contains { $0.0 == "prompt" })
            await adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup()
        } catch { await adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
    @Test func steerAndStallariQuestionUseExactOwnedHirdRPC() async throws {
        let f = try await HirdFixture.make()
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            for _ in 0..<500 { if await f.rpc.requests.contains(where: { $0.0 == "prompt" }) { break }; try await Task.sleep(for: .milliseconds(5)) }
            try await f.adapter.steer("추가 검사", runID: f.run.id)
            #expect(await f.rpc.requests.last?.0 == "steer")
            #expect(await f.rpc.requests.last?.1["message"]?.string == "추가 검사")
            _ = try await f.repository.recordEvent(id: "ask-stallari", runID: f.run.id, at: .now,
                payload: .ask(.init(id: "stallari-q", runID: f.run.id, issueID: f.run.issueID, prompt: "방식", options: ["A"], createdAt: .now, source: .stallari)))
            let answer = QuestionAnswer(selectedOptions: ["A"], text: "설명")
            _ = try await f.repository.answerQuestion("stallari-q", runID: f.run.id, answer: answer, at: .now)
            try await f.adapter.deliver(.init(questionID: "stallari-q", runID: f.run.id, issueID: f.run.issueID, answer: answer, cancelled: false))
            #expect(await f.rpc.requests.last?.1["message"]?.string?.contains("stallari-q") == true)
            #expect(await f.rpc.requests.last?.1["message"]?.string?.contains("설명") == true)
            await f.adapter.cancel(f.run.id); _ = await task.result
            await #expect(throws: (any Error).self) { try await f.adapter.steer("늦은 지시", runID: f.run.id) }
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
