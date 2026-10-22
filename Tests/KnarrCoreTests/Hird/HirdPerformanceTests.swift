import Foundation
import Testing
@testable import KnarrCore

@Suite(.serialized) struct HirdPerformanceTests {
    @Test func unchangedCheckpointReusesPatchAndKeepsPriorBytesImmutable() async throws {
        let f = try await HirdFixture.make()
        do {
            let root = f.directory.appendingPathComponent("capture")
            let (workspace, base) = try await HirdWorkspace.prepare(project: f.directory, root: root, previous: nil)
            let file = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent("original.txt")
            try "changed\n".write(to: file, atomically: true, encoding: .utf8)
            let (first, _) = try await HirdWorkspace.capture(workspace: workspace, root: root, base: base, verifications: [], summary: "checkpoint")
            let (second, _) = try await HirdWorkspace.capture(workspace: workspace, root: root, base: base, verifications: [], summary: "checkpoint")
            #expect(first == second)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: #require(first.diffPath)))
            try "changed again\n".write(to: file, atomically: true, encoding: .utf8)
            let (third, _) = try await HirdWorkspace.capture(workspace: workspace, root: root, base: base, verifications: [], summary: "checkpoint")
            #expect(third.diffPath != first.diffPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: #require(first.diffPath))) == originalBytes)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
    @Test func screenSubscriptionOmitsHistoryWhileArchiveRemainsReadable() async throws {
        let f = try await StallariFixture.make()
        do {
            let issue = try await f.issue("lightweight")
            let run = try await f.dispatch("lightweight-run", issue: issue)
            _ = try await f.session.receive(.init(id: "result", runID: run, at: .now, payload: .saveResult(f.result())))
            let stream = try await f.repository.subscribe()
            var iterator = stream.makeAsyncIterator()
            let screen = try #require(await iterator.next()).snapshot
            #expect(screen.runs.first?.resultHistory.isEmpty == true)
            #expect(screen.runs.first?.result == f.result())
            #expect(try await f.repository.snapshot().runs.first?.resultHistory.count == 1)
            _ = try await f.repository.cancelRun(run, at: .now, reason: "test")
            #expect(try await f.repository.snapshot().runs.first?.state == .cancelled)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
