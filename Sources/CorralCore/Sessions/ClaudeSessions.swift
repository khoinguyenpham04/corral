import Foundation

/// What an agent's own files say about one running session.
struct SessionInfo: Sendable, Hashable {
    var id: String?
    var title: String?
    var cwd: String?
    var state: AgentState?
    var lastActive: Date?
    /// A deep link that reopens the session in its host app.
    var resumeURL: String?
    /// Other sessions served by the same process (Codex Desktop's app-server serves many).
    var otherTitles: [String] = []
}

/// Claude Code writes `~/.claude/sessions/<pid>.json` for each running session: id, title,
/// working directory, and whether it's busy or idle. Claude Desktop's sessions write it too.
final class ClaudeSessions {
    private struct Entry: Decodable {
        var pid: Int32
        var sessionId: String
        var cwd: String?
        var startedAt: Double?
        var procStart: String?
        var entrypoint: String?
        var hostSessionId: String?
        var name: String?
        var status: String?
        var statusUpdatedAt: Double?
        var updatedAt: Double?
    }

    private let directory: String
    private var entries: [Int32: Entry] = [:]
    private var stamps: [String: Date] = [:]
    private let procStartFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    init(directory: String = Paths.home + "/.claude/sessions") {
        self.directory = directory
    }

    /// Re-reads only the files that changed since the last call.
    func refresh() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            entries.removeAll()
            stamps.removeAll()
            return
        }
        var present = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let path = directory + "/" + name
            present.insert(path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            if let modified, stamps[path] == modified { continue }
            stamps[path] = modified
            guard let data = FileManager.default.contents(atPath: path),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data)
            else { continue }
            entries[entry.pid] = entry
        }
        for path in stamps.keys where !present.contains(path) {
            stamps[path] = nil
            if let pid = Int32(Paths.name(path).replacingOccurrences(of: ".json", with: "")) { entries[pid] = nil }
        }
    }

    func info(for record: ProcessRecord) -> SessionInfo? {
        guard let entry = entries[record.pid], startMatches(entry, record) else { return nil }
        let state: AgentState = switch entry.status {
        case "busy": .working
        case "waiting": .waiting
        default: .idle
        }
        let changed = (entry.statusUpdatedAt ?? entry.updatedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        var info = SessionInfo(id: entry.sessionId, title: entry.name, cwd: entry.cwd, state: state, lastActive: changed)
        if let host = entry.hostSessionId, host.hasPrefix("local_") {
            // Desktop gives the CLI a new session id each time it respawns it; its own id stays put.
            info.id = host
            info.resumeURL = "claude://code/continue?session=\(host)"
        }
        return info
    }

    /// The file is keyed by pid; make sure it describes this process and not an earlier one
    /// that had the same pid. `procStart` is wall-clock text whose time zone varies, so try both.
    private func startMatches(_ entry: Entry, _ record: ProcessRecord) -> Bool {
        if let text = entry.procStart {
            let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            for zone in [TimeZone.current, TimeZone(identifier: "UTC")!] {
                procStartFormat.timeZone = zone
                if let start = procStartFormat.date(from: collapsed), abs(start.timeIntervalSince(record.startedAt)) < 2 { return true }
            }
        }
        // The session can't have started before its process did.
        guard let started = entry.startedAt else { return entry.procStart == nil }
        return started / 1000 >= record.startedAt.timeIntervalSince1970 - 2
    }
}
