import Foundation

/// Codex keeps each thread's transcript (a "rollout" JSONL) open while the thread is loaded, so
/// the open files of a codex process say which threads it serves. Titles come from Codex's
/// state database, falling back to `session_index.jsonl`.
final class CodexSessions {
    private let home: String
    private var titles: [String: String] = [:]
    private var cwds: [String: String] = [:]
    private var titlesLoadedAt = Date.distantPast
    private var pendingIDs = Set<String>()

    init(home: String = Paths.home + "/.codex") {
        self.home = home
    }

    func info(for record: ProcessRecord, now: Date) -> SessionInfo? {
        let rollouts = ProcessIdentity.openFiles(of: record.pid)
            .filter { $0.contains("/sessions/") && Paths.name($0).hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .compactMap { path -> (id: String, modified: Date)? in
                guard let id = Self.threadID(fromRollout: path) else { return nil }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                return (id, modified ?? record.startedAt)
            }
            .sorted { $0.modified > $1.modified }
        guard let latest = rollouts.first else { return nil }

        loadTitlesIfNeeded(for: rollouts.map(\.id), now: now)
        let state: AgentState = now.timeIntervalSince(latest.modified) < 15 ? .working : .idle
        return SessionInfo(
            id: latest.id,
            title: titles[latest.id],
            cwd: cwds[latest.id],
            state: state,
            lastActive: latest.modified,
            otherTitles: rollouts.dropFirst().compactMap { titles[$0.id] }
        )
    }

    /// "rollout-2026-10-15T15-06-04-01a13fe2-64f6-7211-8ff1-07e780baa4ce.jsonl" → the trailing UUID.
    static func threadID(fromRollout path: String) -> String? {
        let name = Paths.name(path).replacingOccurrences(of: ".jsonl", with: "")
        guard name.count >= 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id) != nil ? id : nil
    }

    private func loadTitlesIfNeeded(for ids: [String], now: Date) {
        let missing = ids.filter { titles[$0] == nil && !pendingIDs.contains($0) }
        guard !missing.isEmpty || now.timeIntervalSince(titlesLoadedAt) > 60 else { return }
        titlesLoadedAt = now
        let wanted = Set(ids)

        if let database = newestStateDatabase() {
            let placeholders = Array(repeating: "?", count: wanted.count).joined(separator: ",")
            let rows = SQLiteReader.query(
                database,
                "SELECT id, cwd, COALESCE(NULLIF(name, ''), NULLIF(title, ''), '') AS label FROM threads WHERE id IN (\(placeholders))",
                Array(wanted)
            )
            for row in rows {
                guard let id = row["id"] else { continue }
                if let label = row["label"], !label.isEmpty { titles[id] = label }
                if let cwd = row["cwd"], !cwd.isEmpty { cwds[id] = cwd }
            }
        }
        let stillMissing = wanted.filter { titles[$0] == nil }
        if !stillMissing.isEmpty {
            for (id, name) in sessionIndexNames() where stillMissing.contains(id) { titles[id] = name }
        }
        pendingIDs.formUnion(wanted.filter { titles[$0] == nil })
    }

    private func newestStateDatabase() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return nil }
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else { return nil }
            return (version, home + "/" + name)
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    /// The tail of `session_index.jsonl`: one `{"id","thread_name"}` line per rename.
    private func sessionIndexNames() -> [String: String] {
        let path = home + "/session_index.jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd() else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String
            else { continue }
            names[id] = name
        }
        return names
    }
}
