import Foundation
import Testing
@testable import KnarrCore

@MainActor @Suite(.serialized) struct LiveFeaturesTests {
    @Test func actualRuntimeCatalogAllowsOtherProvidersButNotUnknownModels() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.store.whenIdle()
            f.store.selectModel("ollama/local-model"); try await f.store.whenIdle()
            #expect(f.store.model == "ollama/local-model")
            #expect(f.store.stallari.engine.contains("ollama/local-model"))
            #expect(await f.hird.model == nil)
            f.store.selectModel("ollama/unavailable"); try await f.store.whenIdle()
            #expect(f.store.model == "ollama/local-model")
            #expect(await f.hird.model == nil)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func stoppedIssueCanStartAgainWithTheSameInstruction() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            _ = try await f.session.cancelRun("r")
            try await f.store.whenIdle()
            #expect(f.store.issues.first?.state == .failed)
            f.store.perform(.resume, on: "t"); try await f.store.whenIdle()
            let runs = try await f.repository.snapshot().runs
            #expect(runs.count == 2)
            #expect(runs.last?.hird.role == runs.first?.hird.role)
            #expect(runs.last?.previousRunID == nil) // the stopped run left no result to build on
            #expect(f.store.issues.first?.state == .running)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func imagesTravelWithTheMessageAndOtherFilesAsPaths() async throws {
        let f = try await LiveFixture.make()
        do {
            let png = f.directory.appendingPathComponent("screen.png"), log = f.directory.appendingPathComponent("crash.log")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
            try "boom".write(to: log, atomically: true, encoding: .utf8)
            f.store.send("이 화면 봐줘", about: nil, project: "p", attachments: [png, log]); try await f.store.whenIdle()
            let prompt = try #require(await f.rpc.prompts.last)
            let images = prompt["images"]?.array ?? []
            #expect(images.count == 1)
            #expect(images.first?["mimeType"]?.string == "image/png")
            #expect(images.first?["data"]?.string == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString())
            #expect(prompt["message"]?.string?.contains(log.path) == true)
            #expect(f.store.chat.contains { $0.attachments.map(\.lastPathComponent) == ["screen.png", "crash.log"] })
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}

@Suite struct WorkspaceCleanupTests {
    private func run(_ id: String, issue: KnarrCore.Issue.ID, _ state: DurableRunState) -> PersistedRun {
        var r = PersistedRun(hird: .init(id: .init(id), name: "Hird", role: "x", status: .working, steps: [], currentCommand: nil, lastActivityAt: .now),
                             issueID: issue, projectID: "p", ompSessionID: nil, ownershipToken: "o", startedAt: .now,
                             workspace: .init(worktreePath: "/results/\(id)/worktree", branch: "knarr/hird/\(id)", ompSessionPath: nil))
        r.state = state
        return r
    }
    private func issue(_ id: KnarrCore.Issue.ID, _ state: IssueState, confirmed: Bool = false, application: ResultApplication? = nil) -> KnarrCore.Issue {
        var t = KnarrCore.Issue(id: id, title: "t", projectName: "p", state: state, confirmed: confirmed, headline: "", detail: "",
                      acceptance: [], hirds: [], events: [], startedAt: .now)
        t.application = application
        return t
    }

    @Test func keepsOnlyWorkCopiesSomeoneMayStillNeed() {
        let runs = [
            run("live", issue: "working", .working),
            run("old", issue: "unconfirmed", .succeeded), run("latest", issue: "unconfirmed", .succeeded),
            run("blocked", issue: "blocked", .succeeded),
            run("merged", issue: "merged", .succeeded),
            run("stopped", issue: "stopped", .interrupted),
        ]
        let issues = [
            issue("working", .running), issue("unconfirmed", .done),
            issue("blocked", .done, confirmed: true, application: .blocked("원본에 변경이 있어요")),
            issue("merged", .done, confirmed: true, application: .applied(branch: "main", commit: "abc")),
            issue("stopped", .failed),
        ]
        let removable = WorkspaceCleanup.removable(runs: runs, issues: issues).map(\.worktreePath)
        #expect(Set(removable) == ["/results/old/worktree", "/results/merged/worktree", "/results/stopped/worktree"])
    }

    @Test func removesARealWorktreeButKeepsItsBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-clean-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), results = root.appendingPathComponent("results")
        let tree = results.appendingPathComponent("run/worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ a: [String], _ d: URL) throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = a; p.currentDirectoryURL = d
            let o = Pipe(); p.standardOutput = o; p.standardError = Pipe(); try p.run(); p.waitUntilExit()
            return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = try git(["init", "-q", "-b", "main"], project)
        _ = try git(["-c", "user.name=t", "-c", "user.email=t@l", "commit", "-q", "--allow-empty", "-m", "start"], project)
        _ = try git(["worktree", "add", "-q", "-b", "knarr/hird/run", tree.path], project)
        try "build output".write(to: tree.appendingPathComponent("big.bin"), atomically: true, encoding: .utf8)

        let freed = try await WorkspaceCleanup.remove(.init(worktreePath: tree.path, branch: "knarr/hird/run", ompSessionPath: nil),
                                                       project: project, resultsRoot: results)
        #expect(freed > 0)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(!(try git(["worktree", "list"], project)).contains(tree.path))
        #expect(try git(["branch", "--list", "knarr/hird/run"], project).contains("knarr/hird/run"))
    }

    @Test func neverTouchesAnythingOutsideTheResultsFolder() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        await #expect(throws: (any Error).self) {
            _ = try await WorkspaceCleanup.remove(.init(worktreePath: outside.path, branch: nil, ompSessionPath: nil),
                                                  project: outside, resultsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("knarr-results-\(UUID())"))
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
