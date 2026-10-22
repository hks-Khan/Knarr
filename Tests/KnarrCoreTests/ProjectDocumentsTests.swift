import Foundation
import Testing
@testable import KnarrCore

struct ProjectReadGitFixture {
    let root: URL
    let project: URL

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-project-read-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fixture = Self(root: root, project: project)
        try fixture.git(["init", "-q", "-b", "main"])
        try fixture.git(["config", "user.name", "Knarr Test"])
        try fixture.git(["config", "user.email", "test@localhost"])
        return fixture
    }

    func write(_ path: String, _ text: String, at directory: URL? = nil) throws {
        let url = (directory ?? project).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = directory ?? project
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"] { environment.removeValue(forKey: key) }
        process.environment = environment
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func commit(_ title: String, at directory: URL? = nil) throws -> String {
        try git(["add", "-A"], at: directory)
        try git(["commit", "-qm", title], at: directory)
        return try git(["rev-parse", "HEAD"], at: directory)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct ProjectDocumentsTests {
    @Test func recursiveDocumentsSortByModificationThenPathAndSearchNameAndBody() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        try fixture.write("docs/Guide.MD", "# CONTENT needle")
        try fixture.write("README.md", "# Home")
        try fixture.write("docs/a.md", "last")
        try fixture.write("not-markdown.txt", "ignored")
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)
        for path in ["docs/Guide.MD", "README.md"] {
            try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: fixture.project.appendingPathComponent(path).path)
        }
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: fixture.project.appendingPathComponent("docs/a.md").path)
        let library = await ProjectDocumentLibrary.read(root: fixture.project)
        #expect(library.problem == nil)
        #expect(library.documents.map(\.relativePath) == ["docs/a.md", "README.md", "docs/Guide.MD"])
        #expect(library.documents.map(\.id) == library.documents.map(\.relativePath))
        #expect(library.documents.first?.modifiedAt == newer)
        #expect(library.search("content NEEDLE").map(\.relativePath) == ["docs/Guide.MD"])
        #expect(library.search("guide").map(\.relativePath) == ["docs/Guide.MD"])
        #expect(library.search("  ") == library.documents)
    }

    @Test func excludesRulesGeneratedTreesAndAllSymbolicLinks() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        for path in [".git/hidden.md", ".build/a.md", "node_modules/a.md", "outputs/a.md", ".worktrees/a.md",
                     "AGENTS.md", "docs/AGENTS.md", "docs/CLAUDE.md", ".github/copilot-instructions.md", ".claude/skills/a.md"] {
            try fixture.write(path, "must not appear")
        }
        try fixture.write("docs/visible.md", "visible")
        let outside = fixture.root.appendingPathComponent("outside")
        try fixture.write("external.md", "external", at: outside)
        try FileManager.default.createSymbolicLink(at: fixture.project.appendingPathComponent("linked.md"), withDestinationURL: outside.appendingPathComponent("external.md"))
        try FileManager.default.createSymbolicLink(at: fixture.project.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.project.appendingPathComponent("internal.md"), withDestinationURL: fixture.project.appendingPathComponent("docs/visible.md"))
        let library = await ProjectDocumentLibrary.read(root: fixture.project)
        #expect(library.problem == nil)
        #expect(library.documents.map(\.relativePath) == ["docs/visible.md"])
    }

    @Test func readsGitCleanModifiedStagedNewUnicodeSpaceAndRenameStatuses() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        for path in ["clean.md", "modified.md", "staged.md", "이전 이름.md", "줄\n바꿈.md"] {
            try fixture.write(path, "original")
        }
        _ = try fixture.commit("initial")
        try fixture.write("modified.md", "changed")
        try fixture.write("staged.md", "staged")
        try fixture.write("줄\n바꿈.md", "newline changed")
        try fixture.git(["add", "--", "staged.md"])
        try fixture.git(["mv", "--", "이전 이름.md", "새 이름.md"])
        try fixture.write("새 문서.md", "new")
        try fixture.write("added.md", "added")
        try fixture.git(["add", "--", "added.md"])
        let library = await ProjectDocumentLibrary.read(root: fixture.project)
        let statuses = Dictionary(uniqueKeysWithValues: library.documents.map { ($0.relativePath, $0.gitStatus) })
        #expect(library.problem == nil)
        #expect(statuses["clean.md"] == .clean)
        #expect(statuses["modified.md"] == .uncommitted)
        #expect(statuses["staged.md"] == .uncommitted)
        #expect(statuses["새 이름.md"] == .uncommitted)
        #expect(statuses["줄\n바꿈.md"] == .uncommitted)
        #expect(statuses["새 문서.md"] == .new)
        #expect(statuses["added.md"] == .new)
        #expect(statuses["이전 이름.md"] == nil)
    }

    @Test func ignoredUntrackedDocumentsAreNewRatherThanCommitted() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        try fixture.write("tracked.md", "committed")
        _ = try fixture.commit("base")
        try fixture.write(".gitignore", "private-docs/\nignored-note.md\n")
        try fixture.write("private-docs/guide.md", "synthetic ignored folder document")
        try fixture.write("ignored-note.md", "synthetic ignored file")
        let library = await ProjectDocumentLibrary.read(root: fixture.project)
        let statuses = Dictionary(uniqueKeysWithValues: library.documents.map { ($0.relativePath, $0.gitStatus) })
        #expect(library.problem == nil)
        #expect(statuses["tracked.md"] == .clean)
        #expect(statuses["private-docs/guide.md"] == .new)
        #expect(statuses["ignored-note.md"] == .new)
    }

    @Test func reportsMissingRootAndNonGitFolderWithoutDiscardingReadableDocuments() async throws {
        let fixture = try ProjectReadGitFixture.make()
        defer { fixture.cleanup() }
        let missing = await ProjectDocumentLibrary.read(root: fixture.root.appendingPathComponent("missing"))
        #expect(missing.problem != nil)
        let plain = fixture.root.appendingPathComponent("plain")
        try fixture.write("readme.md", "plain", at: plain)
        let library = await ProjectDocumentLibrary.read(root: plain)
        #expect(library.documents.map(\.text) == ["plain"])
        #expect(library.problem != nil)
    }
}
