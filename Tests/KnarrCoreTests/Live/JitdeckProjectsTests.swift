import Foundation
import Testing
@testable import KnarrCore

@Suite struct JitdeckProjectsTests {
    @Test func readsOnlyActiveGitProjectsThatStillExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knarr-jitdeck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent("Gamza Saga"), plain = root.appendingPathComponent("Notes"), archived = root.appendingPathComponent("Old")
        for dir in [git, plain, archived] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: git.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let db = root.appendingPathComponent("jitdeck-v2.sqlite")
        let sql = """
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, canonical_path TEXT NOT NULL, created_at INTEGER NOT NULL, archived_at INTEGER);
        INSERT INTO projects VALUES ('1', 'Gamza Saga', '\(git.path)', 1, NULL);
        INSERT INTO projects VALUES ('2', 'Notes', '\(plain.path)', 2, NULL);
        INSERT INTO projects VALUES ('3', 'Old', '\(archived.path)', 3, 99);
        INSERT INTO projects VALUES ('4', 'Gone', '\(root.path)/gone', 4, NULL);
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3"); p.arguments = [db.path, sql]
        try p.run(); p.waitUntilExit()
        let before = try Data(contentsOf: db)

        let projects = try JitdeckProjects.read(database: db)
        #expect(projects.map(\.name) == ["Gamza Saga"])
        #expect(projects.first?.absolutePath == git.resolvingSymlinksInPath().path)
        #expect(projects.first?.id == (try StoredProject.at(path: git.path)).id)
        #expect(try Data(contentsOf: db) == before) // read-only
    }

    @Test func missingDatabaseMeansNothingToImport() throws {
        #expect(try JitdeckProjects.read(database: URL(fileURLWithPath: "/nonexistent/jitdeck.sqlite")).isEmpty)
    }
}
