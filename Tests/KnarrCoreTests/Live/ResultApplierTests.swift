import Foundation
import Testing
@testable import KnarrCore

/// Real Git repositories in a temporary folder: an original project and a Hird worktree of it.
private struct ApplyFixture {
    let root: URL
    let project: URL
    let tree: URL
    let branch = "knarr/hird/test"
    let patch: URL

    static func make(change: String = "def add(a, b):\n    return a + b\n") throws -> ApplyFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-apply-\(UUID())")
        let project = root.appendingPathComponent("project"), tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try sh(["init", "-q", "-b", "main"], project)
        try sh(["config", "user.name", "Test"], project); try sh(["config", "user.email", "t@localhost"], project)
        try "def add(a, b):\n    return a - b\n".write(to: project.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try sh(["add", "-A"], project); try sh(["commit", "-qm", "start"], project)
        try sh(["worktree", "add", "-q", "-b", "knarr/hird/test", tree.path, "HEAD"], project)
        try change.write(to: tree.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        let diff = try sh(["diff", "--binary", "HEAD", "--"], tree)
        let patch = root.appendingPathComponent("changes.patch")
        try (diff + "\n").write(to: patch, atomically: true, encoding: .utf8)
        return .init(root: root, project: project, tree: tree, patch: patch)
    }

    var result: RunResult {
        .init(worktreePath: tree.path, branch: branch, commit: (try? Self.sh(["rev-parse", "HEAD"], tree)) ?? "",
              diffPath: patch.path, summary: "add 수정", verifications: [])
    }

    @discardableResult static func sh(_ args: [String], _ dir: URL) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = dir
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return text
    }
    func git(_ args: [String], _ dir: URL? = nil) throws -> String { try Self.sh(args, dir ?? project) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct ResultApplierTests {
    @Test func capturedCodeAppliesWithoutCommittingCacheOrEvidence() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        let cache = f.tree.appendingPathComponent(".build-hive")
        let evidence = f.tree.appendingPathComponent("docs/evidence/check")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try "generated cache".write(to: cache.appendingPathComponent("object.o"), atomically: true, encoding: .utf8)
        try "actual check exit 1".write(to: evidence.appendingPathComponent("verify.log"), atomically: true, encoding: .utf8)
        try "new source\n".write(to: f.tree.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
        let workspace = RunWorkspace(worktreePath: f.tree.path, branch: f.branch, ompSessionPath: nil)
        let base = try f.git(["rev-parse", "HEAD"], f.tree)
        let (result, _) = try await HirdWorkspace.capture(workspace: workspace,
            root: f.root.appendingPathComponent("result"), base: base, verifications: [], summary: "capture")
        let applied = try await ResultApplier.apply(result, toProject: f.project, title: "code only", merge: false)
        let paths = try f.git(["ls-tree", "-r", "--name-only", applied.commit], f.tree)
        #expect(paths.contains("new.swift"))
        #expect(!paths.contains(".build-hive"))
        #expect(!paths.contains("docs/evidence/check"))
        #expect(try String(contentsOf: evidence.appendingPathComponent("verify.log"), encoding: .utf8) == "actual check exit 1")
        #expect(await ResultApplier.included(result, application: nil, in: f.project) == nil)
    }

    @Test func largeSavedPatchAppliesAndInclusionUsesCommittedContentOnly() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        let asset = f.tree.appendingPathComponent("large-asset.txt")
        try Data(repeating: 65, count: 18 * 1_048_576).write(to: asset)
        let workspace = RunWorkspace(worktreePath: f.tree.path, branch: f.branch, ompSessionPath: nil)
        let (result, _) = try await HirdWorkspace.capture(workspace: workspace,
            root: f.root.appendingPathComponent("result"), base: try f.git(["rev-parse", "HEAD"], f.tree),
            verifications: [], summary: "large source asset")
        #expect(try HirdWorkspace.fingerprint(URL(fileURLWithPath: #require(result.diffPath))).byteCount > 16_777_216)
        #expect(await ResultApplier.included(result, application: nil, in: f.project) == nil)
        _ = try await ResultApplier.apply(result, toProject: f.project, title: "large asset")
        #expect(try HirdWorkspace.fingerprint(asset) == HirdWorkspace.fingerprint(f.project.appendingPathComponent("large-asset.txt")))
        #expect(await ResultApplier.included(result, application: nil, in: f.project) != nil)
    }

    @MainActor @Test func appConfirmationNeedsSeparateExplicitApplyAndPreservesJudgement() async throws {
        let git = try ApplyFixture.make(); defer { git.cleanup() }
        let live = try await LiveFixture.make()
        do {
            try await live.repository.saveProject(.init(id: "git", name: "project", absolutePath: git.project.path))
            try await live.create(title: "확인 후 반영", criteria: ["사용자 화면 확인"], instruction: "수정", projectID: "git")
            try await live.dispatch()
            let result = RunResult(worktreePath: git.tree.path, branch: git.branch, commit: git.result.commit,
                diffPath: git.patch.path, summary: "확인할 결과", verifications: live.result().verifications)
            _ = try await live.session.receive(.init(id: "complete", runID: "r", at: .now, payload: .complete(result, notificationID: "complete")))
            var issue = try #require(try await live.repository.snapshot().issues.first)
            issue.state = .failed; issue.hirds = []; issue.events = []
            issue.acceptance = [.init(text: "사용자 화면 확인", state: .unmet, evidence: "실제 앱 확인 필요: 직접 확인")]
            try await live.repository.saveIssue(issue, projectID: "git")
            let head = try git.git(["rev-parse", "HEAD"])
            live.store.perform(.confirmAppResult(note: "직접 창에서 확인함"), on: "t")
            try await live.store.whenIdle()
            #expect(try git.git(["rev-parse", "HEAD"]) == head)
            #expect(try await live.repository.snapshot().issues.first?.application == nil)
            live.store.perform(.confirmResult, on: "t")
            try await live.store.whenIdle()
            #expect(try git.git(["show", "HEAD:calc.py"]).contains("a + b"))
            let applied = try #require(try await live.repository.snapshot().issues.first)
            #expect(applied.isApplied)
            #expect(applied.acceptance[0].state == .unmet)
            #expect(applied.userAppConfirmation?.runID == "r")
            try await live.cleanup()
        } catch { try await live.cleanup(); throw error }
    }
    @Test func externallyCommittedEquivalentPatchIsRecognizedWithoutTouchingOriginalIndex() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        let result = f.result
        #expect(await ResultApplier.included(result, application: nil, in: f.project) == nil)
        try FileManager.default.copyItem(at: f.tree.appendingPathComponent("calc.py"), to: f.project.appendingPathComponent("external.py"))
        try "def add(a, b):\n    return a + b\n".write(to: f.project.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try f.git(["add", "calc.py"])
        let staged = try f.git(["diff", "--cached"])
        #expect(await ResultApplier.included(result, application: nil, in: f.project) == nil)
        #expect(try f.git(["diff", "--cached"]) == staged)
        try f.git(["commit", "-qm", "external equivalent fix"])
        let before = try f.git(["status", "--porcelain"])
        let applied = await ResultApplier.included(result, application: nil, in: f.project)
        #expect(applied?.branch == "main")
        #expect(applied?.commit == (try f.git(["rev-parse", "HEAD"])))
        #expect(try f.git(["status", "--porcelain"]) == before)
    }

    @Test func externalCommitWithNoSavedPatchIsRecognizedButBaseCommitWithPatchIsNot() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        #expect(await ResultApplier.included(f.result, application: nil, in: f.project) == nil)
        try f.git(["commit", "-qam", "worker fix"], f.tree)
        let committed = try f.git(["rev-parse", "HEAD"], f.tree)
        try f.git(["cherry-pick", committed])
        let result = RunResult(worktreePath: f.tree.path, branch: f.branch, commit: committed,
            diffPath: nil, summary: "worker fix", verifications: [])
        #expect(await ResultApplier.included(result, application: nil, in: f.project) != nil)
    }
    @Test func mergesTheJudgedChangeIntoTheCurrentBranch() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        let before = try f.git(["rev-parse", "HEAD"])
        let applied = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        #expect(applied.branch == "main")
        #expect(try f.git(["rev-parse", "HEAD"]) == applied.commit)
        #expect(try f.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3) // a merge commit
        #expect(try f.git(["show", "HEAD:calc.py"]).contains("a + b"))
        #expect(try f.git(["log", "-1", "--format=%s"]).contains("add 수정"))
        #expect(try f.git(["status", "--porcelain"]).isEmpty)
        #expect(try f.git(["rev-parse", "HEAD~1"]) == before)
    }

    @Test func dirtyOriginalIsLeftAlone() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        try "local edit\n".write(to: f.project.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        let before = try f.git(["rev-parse", "HEAD"])
        await #expect(throws: ResultApplier.Problem.uncommittedChanges) {
            _ = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        }
        #expect(try f.git(["rev-parse", "HEAD"]) == before)
        #expect(try String(contentsOf: f.project.appendingPathComponent("calc.py"), encoding: .utf8) == "local edit\n")
    }

    @Test func changeAfterJudgementIsRefused() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        try "def add(a, b):\n    return 42\n".write(to: f.tree.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        let before = try f.git(["rev-parse", "HEAD"])
        await #expect(throws: ResultApplier.Problem.changedSinceJudgement) {
            _ = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        }
        #expect(try f.git(["rev-parse", "HEAD"]) == before)
    }

    @Test func conflictIsAbortedAndTheOriginalRestored() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        try "def add(a, b):\n    return b - a\n".write(to: f.project.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try f.git(["commit", "-qam", "someone else edited add"])
        let before = try f.git(["rev-parse", "HEAD"])
        await #expect(throws: ResultApplier.Problem.conflict) {
            _ = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        }
        #expect(try f.git(["rev-parse", "HEAD"]) == before)
        #expect(try f.git(["status", "--porcelain"]).isEmpty)
    }

    @Test func branchModeKeepsTheChangeOnTheHirdBranchOnly() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        // A dirty original does not matter: nothing is merged into it.
        try "local edit\n".write(to: f.project.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        let before = try f.git(["rev-parse", "HEAD"])
        let kept = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정", merge: false)
        #expect(kept.branch == f.branch)
        #expect(try f.git(["rev-parse", f.branch]) == kept.commit)
        #expect(try f.git(["show", "\(f.branch):calc.py"]).contains("a + b"))
        #expect(try f.git(["rev-parse", "HEAD"]) == before)
        #expect(try String(contentsOf: f.project.appendingPathComponent("calc.py"), encoding: .utf8) == "local edit\n")
    }

    @Test func secondApplyAfterSuccessDoesNothing() async throws {
        let f = try ApplyFixture.make(); defer { f.cleanup() }
        let first = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        let again = try await ResultApplier.apply(f.result, toProject: f.project, title: "add 수정")
        #expect(again.commit == first.commit)
        #expect(try f.git(["rev-list", "--count", "HEAD"]) == "3")
    }
}
