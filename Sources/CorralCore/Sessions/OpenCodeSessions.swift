import Foundation

/// OpenCode stores sessions in SQLite with the directory they ran in. The newest top-level
/// session for a process's working directory is the one it's showing.
final class OpenCodeSessions {
    private let database: String
    private var cache: [String: (info: SessionInfo?, at: Date)] = [:]

    init(database: String = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? Paths.home + "/.local/share") + "/opencode/opencode.db") {
        self.database = database
    }

    func info(for record: ProcessRecord, now: Date) -> SessionInfo? {
        guard let cwd = record.cwd else { return nil }
        if let cached = cache[cwd], now.timeIntervalSince(cached.at) < 10 { return cached.info }
        let rows = SQLiteReader.query(
            database,
            """
            SELECT id, title, time_updated FROM session
            WHERE directory = ? AND parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?
            ORDER BY time_updated DESC LIMIT 1
            """,
            [cwd, String(Int64(record.startedAt.timeIntervalSince1970 * 1000) - 5000)]
        )
        var info: SessionInfo?
        if let row = rows.first, let id = row["id"] {
            let updated = row["time_updated"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let state: AgentState = updated.map { now.timeIntervalSince($0) < 15 } == true ? .working : .idle
            info = SessionInfo(id: id, title: row["title"], cwd: cwd, state: state, lastActive: updated)
        }
        cache[cwd] = (info, now)
        return info
    }
}

/// Pi (and oh-my-pi) write `~/.pi/agent/sessions/--<cwd>--/<timestamp>_<id>.jsonl`. The newest
/// file for the working directory is the live session; a `session_info` entry carries its name.
final class PiSessions {
    private let root: String
    private var titles: [String: (title: String?, modified: Date)] = [:]

    init(root: String) {
        self.root = root
    }

    func info(for record: ProcessRecord, now: Date) -> SessionInfo? {
        guard let cwd = record.cwd else { return nil }
        let trimmed = cwd.hasPrefix("/") ? String(cwd.dropFirst()) : cwd
        let candidates = [
            "--" + trimmed.replacingOccurrences(of: "/", with: "-") + "--",
            "--" + cwd.replacingOccurrences(of: "/", with: "-") + "--",
        ]
        let fm = FileManager.default
        guard let folder = candidates.map({ root + "/" + $0 }).first(where: { fm.fileExists(atPath: $0) }),
              let names = try? fm.contentsOfDirectory(atPath: folder)
        else { return nil }

        let newest = names.filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> (path: String, modified: Date)? in
                let path = folder + "/" + name
                guard let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil else { return nil }
                return (path, modified)
            }
            .filter { $0.modified >= record.startedAt.addingTimeInterval(-5) }
            .max { $0.modified < $1.modified }
        guard let newest else { return nil }

        let id = Paths.name(newest.path).replacingOccurrences(of: ".jsonl", with: "").split(separator: "_").last.map(String.init)
        if titles[newest.path]?.modified != newest.modified {
            titles[newest.path] = (Self.sessionName(at: newest.path), newest.modified)
        }
        let state: AgentState = now.timeIntervalSince(newest.modified) < 15 ? .working : .idle
        return SessionInfo(id: id, title: titles[newest.path]?.title, cwd: cwd, state: state, lastActive: newest.modified)
    }

    /// The last `session_info` name, else the start of the first user message.
    static func sessionName(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 32_000_000 else { return nil }
        var name: String?
        var firstPrompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["type"] as? String == "session_info", let value = object["name"] as? String, !value.isEmpty {
                name = value
            } else if firstPrompt == nil, object["type"] as? String == "message",
                      let message = object["message"] as? [String: Any], message["role"] as? String == "user" {
                firstPrompt = Self.text(of: message["content"])
            }
        }
        return name ?? firstPrompt.map { String($0.prefix(60)) }
    }

    private static func text(of content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.first
        }
        return nil
    }
}
