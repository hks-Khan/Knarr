import Foundation
import Testing
@testable import KnarrCore

@Suite struct RunOutputPagingTests {
    @Test func unicodePagesReconstructOutput() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-page-\(UUID()).txt")
        let content = "한😀글\n다음 줄"
        try content.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        var offset = 0, rebuilt = ""
        repeat {
            let page = try StallariReadback.readFile(path.path, offset: offset, limit: 4)
            rebuilt += page["text"]?.string ?? ""
            guard let next = page["nextOffset"]?.integer else { break }
            #expect(next > offset); if next <= offset { break }; offset = next
        } while true
        #expect(rebuilt == content)
    }
}

@MainActor @Suite(.serialized) struct HarnessModelTests {
    @Test func approvedProposalStoresModeAndExplicitModelAndRejectsUnavailableModel() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            let version = try #require(try await f.repository.snapshot().issues.first?.proposal?.version)
            try await f.session.updateIssueProposal(issueID: "t", expectedVersion: version, instruction: "read", model: "anthropic/fixture-claude", mode: .inspect)
            _ = try await f.repository.approveIssueProposal(issueID: "t", version: version + 1, at: .now)
            _ = try await f.session.dispatch(issueID: "t", runID: "read")
            let run = try #require(try await f.repository.snapshot().runs.first)
            #expect(run.mode == .inspect)
            #expect(run.requestedModel == "anthropic/fixture-claude")
            await #expect(throws: StallariError.self) {
                try await f.session.updateIssueProposal(issueID: "t", expectedVersion: version + 1, instruction: "read", model: "anthropic/nonexistent")
            }
            #expect(try await f.repository.snapshot().runs.count == 1)
            _ = try await f.session.cancelRun("read")
            #expect(try await f.repository.snapshot().runs[0].state == .cancelled)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func oldRunPayloadStillDecodesAndModelBindingSurvivesReopen() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            let run = try await f.repository.snapshot().runs[0]
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
            for key in ["mode", "requestedModel", "observedModel"] { object.removeValue(forKey: key) }
            let legacy = try JSONDecoder().decode(PersistedRun.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(legacy.observedModel == nil && legacy.mode == nil)
            _ = try await f.repository.recordEvent(id: "bound-model", runID: "r", at: .now, payload: .bindModel("openai-codex/fixture-gpt"))
            let second = try await SQLiteKnarrRepository.open(at: f.directory.appendingPathComponent("knarr.db"))
            #expect(try await second.snapshot().runs[0].observedModel == "openai-codex/fixture-gpt")
            try await second.close(); try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
