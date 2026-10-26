import Foundation
import SQLite3

/// Minimal read-only access to other apps' SQLite databases (Codex, OpenCode). Opens, runs one
/// query, closes. Never writes and never holds a connection between samples.
enum SQLiteReader {
    typealias Row = [String: String]

    static func query(_ path: String, _ sql: String, _ bindings: [String] = []) -> [Row] {
        guard FileManager.default.isReadableFile(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: Row = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, column),
                      let text = sqlite3_column_text(statement, column)
                else { continue }
                row[String(cString: name)] = String(cString: text)
            }
            rows.append(row)
        }
        return rows
    }
}
