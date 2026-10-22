import Foundation
import CSQLite

/// Only used by a single repository actor (or during synchronous open/preflight).
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    let path: String
    private var changedRows: [String: Set<Int64>] = [:]
    private var resetTables: Set<String> = []
    private(set) var cacheEpoch = 0
    private static let observedTables: Set<String> = ["projects", "threads", "issues", "runs", "chat", "activities", "questions", "notifications", "thread_deliveries", "project_preparations"]
    /// nil means a full reload; an empty set means this connection changed no rows.
    func takeChangedRowIDs(_ table: String) -> Set<Int64>? {
        if resetTables.remove(table) != nil { changedRows.removeValue(forKey: table); return nil }
        return changedRows.removeValue(forKey: table) ?? []
    }
    private func changed(_ table: String, row: Int64) {
        guard Self.observedTables.contains(table), !resetTables.contains(table) else { return }
        changedRows[table, default: []].insert(row)
        if changedRows[table, default: []].count > 2048 { changedRows.removeValue(forKey: table); resetTables.insert(table) }
    }
    private func rolledBack() { cacheEpoch += 1; changedRows.removeAll(); resetTables.removeAll() }
    init(path: String, flags: Int32) throws {
        self.path = path
        let code = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = failure("열기 실패", code: code)
            if let handle { sqlite3_close_v2(handle) }; handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 5_000)
        // SQLite callbacks only record invalidation. They never query or mutate this connection.
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_update_hook(handle, { context, _, _, table, row in
            guard let context, let table else { return }
            Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue().changed(String(cString: table), row: row)
        }, context)
        sqlite3_rollback_hook(handle, { context in
            guard let context else { return }
            Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue().rolledBack()
        }, context)
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    func close() throws {
        guard let handle else { return }
        let code = sqlite3_close(handle)
        guard code == SQLITE_OK else { throw failure("닫기 실패", code: code) }
        self.handle = nil
    }
    func failure(_ message: String, code: Int32? = nil) -> PersistenceError {
        let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "저장소가 닫혀 있어요"
        let actualCode = code ?? sqlite3_errcode(handle)
        return .init(databasePath: path, message: "\(message) (SQLite \(actualCode)): \(reason)", sqliteCode: actualCode)
    }
    func execute(_ sql: String, _ values: [String?] = []) throws {
        _ = try rows(sql, values)
    }
    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        guard handle != nil else { throw failure("닫힌 저장소") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure("쿼리 준비 실패", code: code) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let code: Int32
            if let value {
                let utf8Count = value.utf8.count
                guard utf8Count <= Int(Int32.max) else { throw failure("문자열이 너무 커요") }
                code = sqlite3_bind_text(statement, Int32(offset + 1), value, Int32(utf8Count), transient)
            } else { code = sqlite3_bind_null(statement, Int32(offset + 1)) }
            guard code == SQLITE_OK else { throw failure("쿼리 인자 실패", code: code) }
        }
        var output: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return output }
            guard step == SQLITE_ROW else { throw failure("쿼리 실행 실패", code: step) }
            output.append(try (0..<sqlite3_column_count(statement)).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return "" }
                let size = Int(sqlite3_column_bytes(statement, column))
                guard let value = String(bytes: UnsafeBufferPointer(start: text, count: size), encoding: .utf8) else {
                    throw failure("저장된 UTF-8 문자열이 손상됐어요")
                }
                return value
            })
        }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
