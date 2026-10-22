import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdCaptureEconomyTests {
    @Test func rapidCommandsKeepAllEvidenceWithoutArchivingEveryResult() async throws {
        let f = try await HirdFixture.make(temporary: true)
        let task = Task { try await f.adapter.start(f.run, emit: f.sink) }
        do {
            try await HirdVerificationRetryTests.awaitPrompts(1, f)
            let workspace = try #require(try await f.repository.snapshot().runs[0].workspace)
            try "changed\n".write(to: URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            for call in ["one", "two", "three"] {
                await f.rpc.frame(HirdResultTests.start(call))
                await f.rpc.frame(HirdResultTests.end(0, call: call))
            }
            await f.rpc.frame(HirdStopEvidenceTests.question("barrier"))
            let intermediate = try await HirdStopEvidenceTests.wait(f) { !$0.questions.isEmpty }
            #expect(intermediate.runs[0].savedResultCount == 1)
            let q = try #require(intermediate.questions.first)
            _ = try await f.repository.answerQuestion(q.id, runID: f.run.id, answer: .init(selectedOptions: [], text: "continue"), at: .now)
            await f.rpc.frame(HirdVerificationRetryTests.end(1))
            try await task.value
            let final = try await f.repository.snapshot().runs[0]
            #expect(final.state == .succeeded)
            #expect(final.result?.verifications.count == 3)
            #expect(final.result?.artifactManifestPath != nil)
            #expect(final.savedResultCount == 2)
            try await f.cleanup()
        } catch { await f.adapter.cancel(f.run.id); _ = await task.result; try await f.cleanup(); throw error }
    }
}
