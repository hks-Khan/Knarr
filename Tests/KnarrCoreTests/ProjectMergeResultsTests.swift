import Foundation
import Testing
@testable import KnarrCore

struct ProjectMergeResultsTests {
    private func issue(_ id: KnarrCore.Issue.ID = "issue", result: RunResult? = nil, state: IssueState = .running) -> KnarrCore.Issue {
        var issue = KnarrCore.Issue(id: id, title: "문서 개선", projectName: "project", state: state,
                          headline: "", detail: "", acceptance: [], hirds: [], events: [], startedAt: .now)
        issue.latestResult = result
        return issue
    }

    private func result(_ commit: String?, tree: URL) -> RunResult {
        .init(worktreePath: tree.path, branch: "knarr/hird/test", commit: commit, diffPath: nil,
              summary: "saved result", verifications: [])
    }

    private func branch(_ fixture: ProjectReadGitFixture) throws -> URL {
        try fixture.write("README.md", "base")
        _ = try fixture.commit("base")
        let tree = fixture.root.appendingPathComponent("hird")
        try fixture.git(["worktree", "add", "-q", "-b", "knarr/hird/test", tree.path, "main"])
        return tree
    }

    @Test func countsActualCommitsAndFilesAgainstMainThenExcludesIncludedResult() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        try fixture.write("README.md", "changed", at: tree)
        _ = try fixture.commit("first", at: tree)
        try fixture.write("docs/한글 이름.md", "new", at: tree)
        let commit = try fixture.commit("second", at: tree)
        // Main also advances: counts are not inferred from HEAD or a stored patch.
        try fixture.write("only-main.txt", "main")
        _ = try fixture.commit("main advances")
        let input = issue(result: result(commit, tree: tree), state: .done)
        let read = await ProjectMergeResults.read(root: fixture.project, issues: [input])
        #expect(read.problem == nil)
        #expect(read.results.count == 1)
        #expect(read.results.first?.issueID == input.id)
        #expect(read.results.first?.commitCount == 2)
        #expect(read.results.first?.changedFileCount == 2)
        #expect(read.results.first?.judgement.contains("완료") == true)
        try fixture.git(["merge", "--no-edit", "knarr/hird/test"])
        let included = await ProjectMergeResults.read(root: fixture.project, issues: [input])
        #expect(included.problem == nil)
        #expect(included.results.isEmpty)
    }

    @Test func showsOnlyLatestTipFromSavedAncestorHistoryAndDeduplicatesLatestProjection() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        try fixture.write("README.md", "first", at: tree)
        let first = result(try fixture.commit("first", at: tree), tree: tree)
        try fixture.write("docs/second.md", "second", at: tree)
        let second = result(try fixture.commit("second", at: tree), tree: tree)
        let hird = HirdRun(id: "run", name: "Hird", role: "write", status: .failed(at: .now),
                           steps: [], currentCommand: nil, lastActivityAt: .now)
        var run = PersistedRun(hird: hird, issueID: "issue", projectID: "project", ompSessionID: nil,
                               ownershipToken: "test", startedAt: .now)
        run.state = .failed
        run.resultHistory = [first, second]
        run.result = second
        let read = await ProjectMergeResults.read(root: fixture.project, issues: [issue(result: second)], runs: [run])
        #expect(read.problem == nil)
        #expect(read.results.count == 1)
        #expect(read.results.first?.commitCount == 2)
        #expect(read.results.first?.changedFileCount == 2)
        #expect(read.results.allSatisfy { $0.judgement.contains("미완료") })
        var unrelated = PersistedRun(hird: hird, issueID: "other", projectID: "other", ompSessionID: nil,
                                    ownershipToken: "other", startedAt: .now)
        unrelated.result = second
        let scoped = await ProjectMergeResults.read(root: fixture.project, issues: [issue()], runs: [unrelated])
        #expect(scoped.results.isEmpty)
        run.state = .succeeded
        let pending = await ProjectMergeResults.read(root: fixture.project, issues: [issue(result: second)], runs: [run])
        #expect(pending.results.first?.judgement.contains("판정 대기") == true)
        run.acceptanceEvidence = [.init(text: "검사", state: .met, evidence: "저장된 검사")]
        let judged = await ProjectMergeResults.read(root: fixture.project, issues: [issue(result: second)], runs: [run])
        #expect(judged.results.first?.judgement == "완료 판정")
        #expect(judged.results.count == 1)
    }

    @Test func preservesIndependentSavedTipsMissingFromLatestResult() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        try fixture.write("README.md", "first branch", at: tree)
        let first = result(try fixture.commit("first branch", at: tree), tree: tree)
        try fixture.git(["checkout", "-q", "--detach", "main"], at: tree)
        try fixture.write("independent.md", "other branch", at: tree)
        let second = result(try fixture.commit("other branch", at: tree), tree: tree)
        let hird = HirdRun(id: "run", name: "Hird", role: "write", status: .failed(at: .now),
                           steps: [], currentCommand: nil, lastActivityAt: .now)
        var run = PersistedRun(hird: hird, issueID: "issue", projectID: "project", ompSessionID: nil,
                               ownershipToken: "test", startedAt: .now)
        run.state = .failed
        run.resultHistory = [first, second]
        run.result = second
        let read = await ProjectMergeResults.read(root: fixture.project, issues: [issue(result: second)], runs: [run])
        #expect(read.problem == nil)
        #expect(read.results.count == 2)
        #expect(Set(read.results.map(\.id)) == Set([first, second].compactMap { $0.commit.map { "issue:" + $0 } }))
        #expect(read.results.map(\.commitCount) == [1, 1])
        #expect(read.results.map(\.changedFileCount) == [1, 1])
    }

    @Test func rejectsOtherProjectEvenWhenCommitObjectExistsLocally() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        try fixture.write("README.md", "result", at: tree)
        let commit = try fixture.commit("result", at: tree)
        let other = fixture.root.appendingPathComponent("other-project")
        try fixture.git(["clone", "-q", fixture.project.path, other.path])
        try fixture.git(["fetch", "-q", "origin", "knarr/hird/test"], at: other)
        let read = await ProjectMergeResults.read(root: other, issues: [issue(result: result(commit, tree: tree))])
        #expect(read.results.isEmpty)
    }

    @Test func reportsMissingMainAndUnresolvedOrAbsentResultCommit() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        let unresolved = await ProjectMergeResults.read(root: fixture.project,
            issues: [issue(result: result("0123456789012345678901234567890123456789", tree: tree))])
        #expect(unresolved.results.isEmpty)
        #expect(unresolved.problem?.contains("커밋") == true)
        let absent = await ProjectMergeResults.read(root: fixture.project, issues: [issue(result: result(nil, tree: tree))])
        #expect(absent.problem?.contains("커밋") == true)
        try fixture.git(["branch", "-m", "main", "trunk"])
        let missingMain = await ProjectMergeResults.read(root: fixture.project, issues: [issue()])
        #expect(missingMain.results.isEmpty)
        #expect(missingMain.problem?.contains("main") == true)
    }

    @MainActor @Test func storeReadsDurableHistoryAndScopesProjectIssues() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let tree = try branch(fixture)
        try fixture.write("README.md", "first", at: tree)
        let first = result(try fixture.commit("first", at: tree), tree: tree)
        try fixture.git(["checkout", "-q", "--detach", "main"], at: tree)
        try fixture.write("second.md", "second", at: tree)
        let second = result(try fixture.commit("second", at: tree), tree: tree)
        let live = try await LiveFixture.make()
        do {
            try await live.repository.saveProject(.init(id: "git", name: "Git", absolutePath: fixture.project.path))
            try await live.repository.saveProject(.init(id: "different", name: "다른 소속", absolutePath: fixture.project.path))
            try await live.create("own", projectID: "git")
            try await live.dispatch("own-run", issue: "own")
            _ = try await live.repository.recordEvent(id: "first", runID: "own-run", at: .now, payload: .saveResult(first))
            _ = try await live.repository.recordEvent(id: "second", runID: "own-run", at: .now, payload: .saveResult(second))
            try await live.create("other", projectID: "different")
            try await live.dispatch("other-run", issue: "other")
            _ = try await live.repository.recordEvent(id: "other", runID: "other-run", at: .now, payload: .saveResult(second))
            let read = await live.store.inspectProjectMergeResults("git")
            #expect(read.problem == nil)
            #expect(read.results.count == 2)
            #expect(read.results.allSatisfy { $0.issueID == "own" })
            let missing = await live.store.inspectProjectMergeResults("missing")
            #expect(missing.problem != nil)
            try await live.cleanup()
        } catch {
            try await live.cleanup()
            throw error
        }
    }
}
