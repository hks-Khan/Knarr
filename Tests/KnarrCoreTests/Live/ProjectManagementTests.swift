import Foundation
import Testing
@testable import KnarrCore

/// A real Git repository in a temporary folder.
private struct GitFixture {
    let root: URL

    static func make() throws -> GitFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-project-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sh(["init", "-q", "-b", "main"], root)
        try sh(["config", "user.name", "Test"], root); try sh(["config", "user.email", "t@localhost"], root)
        try write("app.swift", "let a = 1\n", root)
        try sh(["add", "-A"], root); try sh(["commit", "-qm", "첫 커밋"], root)
        return .init(root: root)
    }

    static func write(_ name: String, _ text: String, _ dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult static func sh(_ args: [String], _ dir: URL) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = dir
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .newlines)
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return text
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ProjectGitTests {
    @Test func statusHeaderAndChangesAreRead() {
        let parsed = ProjectGit.parseStatus("## main...origin/main [ahead 2, behind 1]\n M Sources/A.swift\nA  B.swift\n?? notes.md\nR  old.txt -> new.txt")
        #expect(parsed.branch == "main")
        #expect(parsed.ahead == 2 && parsed.behind == 1)
        #expect(parsed.changes == [.init(code: "M", path: "Sources/A.swift"), .init(code: "A", path: "B.swift"),
                                   .init(code: "??", path: "notes.md"), .init(code: "R", path: "new.txt")])
        let local = ProjectGit.parseStatus("## feature/x")
        #expect(local.branch == "feature/x" && local.ahead == nil && local.behind == nil)
        let synced = ProjectGit.parseStatus("## main...origin/main")
        #expect(synced.ahead == 0 && synced.behind == 0)
        #expect(ProjectGit.parseStatus("## HEAD (no branch)").branch == nil)
        #expect(ProjectGit.parseStatus("## No commits yet on main").branch == "main")
    }

    @Test func inspectionReadsBranchChangesCommitsAndAgentsFile() async throws {
        let g = try GitFixture.make(); defer { g.remove() }
        try GitFixture.write("AGENTS.md", "# 규칙\n- swift test\n", g.root)
        try GitFixture.write("app.swift", "let a = 2\n", g.root)
        let inspection = await ProjectGit.inspect(g.root)
        #expect(inspection.problem == nil)
        #expect(inspection.branch == "main")
        #expect(inspection.changes.map(\.path).sorted() == ["AGENTS.md", "app.swift"])
        #expect(inspection.commits.map(\.subject) == ["첫 커밋"])
        #expect(inspection.agents?.text == "# 규칙\n- swift test\n")
        #expect(inspection.agents?.uncommitted == true)
    }

    @Test func aFolderThatIsNotARepositoryIsReported() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-plain-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ProjectGit.inspect(dir).problem == "Git 저장소가 아니에요")
        #expect(await ProjectGit.inspect(dir.appendingPathComponent("gone")).problem == "폴더가 없어요")
    }

    @Test func savingAgentsCommitsOnlyThatFile() async throws {
        let g = try GitFixture.make(); defer { g.remove() }
        // Someone else's work in progress stays staged and uncommitted.
        try GitFixture.write("app.swift", "let a = 3\n", g.root)
        try GitFixture.sh(["add", "app.swift"], g.root)
        try await ProjectGit.saveAgents(g.root, text: "# 새 규칙", expected: nil)
        #expect(try String(contentsOf: g.root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "# 새 규칙\n")
        #expect(try GitFixture.sh(["log", "-1", "--format=%s"], g.root) == "Update AGENTS.md")
        #expect(try GitFixture.sh(["show", "--name-only", "--format=", "HEAD"], g.root) == "AGENTS.md")
        #expect(try GitFixture.sh(["diff", "--cached", "--name-only"], g.root) == "app.swift")
        // Saving the same text again is not a new commit.
        try await ProjectGit.saveAgents(g.root, text: "# 새 규칙\n", expected: "# 새 규칙\n")
        #expect(try GitFixture.sh(["rev-list", "--count", "HEAD"], g.root) == "2")
    }

    @Test func savingRefusesWhenTheFileChangedSinceItWasRead() async throws {
        let g = try GitFixture.make(); defer { g.remove() }
        try GitFixture.write("AGENTS.md", "다른 곳에서 고침\n", g.root)
        await #expect(throws: ProjectGitError.changedOnDisk) {
            try await ProjectGit.saveAgents(g.root, text: "# 내 수정", expected: "처음 읽은 내용\n")
        }
        #expect(try String(contentsOf: g.root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "다른 곳에서 고침\n")
    }
}

@Suite struct ProjectSettingsTests {
    @Test func projectsSavedBeforeSettingsExistedStillLoad() throws {
        let old = #"{"id":"p","name":"옛 프로젝트","absolutePath":"/tmp/p"}"#
        let project = try JSONDecoder().decode(StoredProject.self, from: Data(old.utf8))
        #expect(project.settings == ProjectSettings())
        #expect(project.archivedAt == nil)
        let partial = #"{"criteria":["테스트 통과"]}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(partial.utf8))
        #expect(settings.criteria == ["테스트 통과"] && settings.maxHirds == 2 && settings.resultMode == .merge)
    }
}

@MainActor @Suite(.serialized) struct ProjectManagementTests {
    @Test func renameArchiveAndSettingsAreSavedAndShown() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create()
            f.store.renameProject("p", to: "  새 이름  "); try await f.store.whenIdle()
            #expect(f.store.projects.first { $0.id == "p" }?.name == "새 이름")
            #expect(f.store.issues.first?.projectName == "새 이름")
            #expect(f.store.issues(inProject: "p").map(\.id) == ["t"])
            #expect(f.store.issues(inProject: "other").isEmpty)
            f.store.renameProject("p", to: "   "); try await f.store.whenIdle()
            #expect(f.store.projects.first { $0.id == "p" }?.name == "새 이름")

            var settings = ProjectSettings()
            settings.criteria = ["스냅샷을 남긴다"]; settings.memo = "금요일엔 배포 안 함"; settings.maxHirds = 1
            settings.verification = [.init(name: "테스트", command: "swift test", timing: .always)]
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            #expect(f.store.projects.first { $0.id == "p" }?.settings == settings)
            #expect(try await f.repository.snapshot().projects.first { $0.id == "p" }?.settings == settings)

            f.store.setProjectArchived("other", true); try await f.store.whenIdle()
            #expect(f.store.projects.first { $0.id == "other" }?.archived == true)
            #expect(try await f.session.listProjects().map(\.id) == ["p"])
            await #expect(throws: StallariError.self) {
                _ = try await f.session.createIssue(id: "x", title: "보관된 곳 작업", criteria: ["a"], instruction: "수정해요", projectID: "other")
            }
            // Adding the same folder again brings it back without losing its name.
            let path = try #require(f.store.projects.first { $0.id == "other" }?.path)
            try await f.repository.saveProject(.init(id: "other", name: "다른 프로젝트", absolutePath: path, archivedAt: .now))
            f.store.setProjectArchived("other", false); try await f.store.whenIdle()
            #expect(f.store.projects.first { $0.id == "other" }?.archived == false)
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func archivingStopsRunningHirds() async throws {
        let f = try await LiveFixture.make()
        do {
            try await f.create(); try await f.dispatch()
            f.store.setProjectArchived("p", true); try await f.store.whenIdle()
            #expect(await f.hird.cancelled.contains("r"))
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func stallariSeesProjectRulesAndAddsDefaultCriteria() async throws {
        let f = try await LiveFixture.make()
        do {
            var settings = ProjectSettings()
            settings.criteria = ["스냅샷을 남긴다", "합계 검사 통과"]
            settings.memo = "금요일엔 배포 안 함"
            settings.verification = [.init(name: "테스트", command: "swift test", timing: .always)]
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            try await f.create()
            let issue = try #require(try await f.repository.snapshot().issues.first { $0.id == "t" })
            #expect(issue.acceptance.map(\.text) == ["합계 검사 통과", "스냅샷을 남긴다"])
            // Replaying the same create_issue call is still the same Issue.
            try await f.create()
            let listed = try await f.session.performTool("list_projects", arguments: .object([:]))
            let p = try #require(listed["projects"]?.array?.first { $0["projectID"]?.string == "p" })
            #expect(p["memo"]?.string == "금요일엔 배포 안 함")
            #expect(p["defaultCriteria"]?.array?.compactMap(\.string) == ["스냅샷을 남긴다", "합계 검사 통과"])
            #expect(p["verification"]?.array?.first?["command"]?.string == "swift test")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }

    @Test func aProjectRunsNoMoreHirdsAtOnceThanItsLimit() async throws {
        let f = try await LiveFixture.make()
        do {
            var settings = ProjectSettings(); settings.maxHirds = 1
            f.store.updateProjectSettings("p", settings); try await f.store.whenIdle()
            try await f.create("t"); try await f.create("u")
            try await f.dispatch("r", issue: "t")
            _ = try await f.repository.approveIssueProposal(issueID: "u", version: 1, at: .now)
            await #expect(throws: StallariError.self) {
                _ = try await f.session.dispatch(issueID: "u", runID: "r2")
            }
            // A replay of the running dispatch is still accepted.
            #expect(try await f.session.dispatch(issueID: "t", runID: "r") == "r")
            try await f.cleanup()
        } catch { try await f.cleanup(); throw error }
    }
}
