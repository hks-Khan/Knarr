import Foundation
import CSQLite

/// Reads Jitdeck's registered projects, read-only, so Stallari starts out knowing them.
/// Only active entries whose folder still exists as a Git repository come across.
public enum JitdeckProjects {
    public static func read(database: URL) throws -> [StoredProject] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var handle: OpaquePointer?
        // immutable=1: no locks, no journal, never a write to Jitdeck's file.
        let uri = "file:" + database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle); return []
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT name, canonical_path FROM projects WHERE archived_at IS NULL ORDER BY created_at"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var projects: [StoredProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let n = sqlite3_column_text(statement, 0), let p = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: n), path = String(cString: p)
            guard FileManager.default.fileExists(atPath: path + "/.git"), var project = try? StoredProject.at(path: path),
                  !projects.contains(where: { $0.id == project.id }) else { continue }
            project.name = name
            projects.append(project)
        }
        return projects
    }
}
