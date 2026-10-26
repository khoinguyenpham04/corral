import Darwin
import Foundation

/// One thing Corral did: stopped a server, hibernated or woke an agent, moved a worktree to the Trash.
public struct ActivityEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case hibernated, stopped, woke, forgot
        /// Asked to stop, but it was still running afterwards.
        case failed
        /// A worktree moved to the Trash, and one put back with Undo.
        case trashed, restored
    }

    /// Where the request came from.
    public enum Source: String, Codable, Sendable {
        case panel, menu, notification, auto, cli

        public var label: String {
            switch self {
            case .panel: "from the panel"
            case .menu: "from the menu bar"
            case .notification: "from a notification"
            case .auto: "automatically"
            case .cli: "from the command line"
            }
        }
    }

    public struct Process: Codable, Sendable, Hashable {
        public var pid: Int32
        public var command: String
    }

    public var id: UUID
    public var date: Date
    public var action: Action
    public var source: Source
    public var title: String
    public var checkout: String?
    /// What it freed: memory for stops and hibernates, disk for a worktree moved to the Trash.
    public var memory: UInt64
    public var processes: [Process]

    public init(
        id: UUID = UUID(), date: Date = Date(), action: Action, source: Source, title: String, checkout: String?,
        memory: UInt64, processes: [Process] = []
    ) {
        self.id = id
        self.date = date
        self.action = action
        self.source = source
        self.title = title
        self.checkout = checkout
        self.memory = memory
        self.processes = processes
    }

    public init(_ action: Action, _ group: ProcessGroup, checkout: String?, source: Source, date: Date = Date()) {
        self.init(
            date: date, action: action, source: source, title: group.displayTitle, checkout: checkout, memory: group.memory,
            processes: group.processes.prefix(12).map { Process(pid: $0.pid, command: Redact.command($0.command)) }
        )
    }

    public init(_ action: Action, _ record: HibernationRecord, source: Source, date: Date = Date()) {
        self.init(date: date, action: action, source: source, title: record.title, checkout: record.checkout, memory: record.memory)
    }

    public init(_ action: Action, _ worktree: TrashedWorktree, source: Source, date: Date = Date()) {
        self.init(date: date, action: action, source: source, title: worktree.name, checkout: worktree.repoName, memory: worktree.freeable)
    }
}

/// Everything Corral stops, hibernates, wakes or moves to the Trash, in
/// ~/Library/Application Support/Corral/activity.jsonl. The app and the CLI both write to it,
/// so "did Corral stop my server?" always has an answer. Command lines are masked, and it
/// keeps the newest 2,000 entries.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    public let url: URL
    private let limit: Int
    private let lock = NSLock()

    public static var defaultURL: URL {
        HibernationStore.defaultURL.deletingLastPathComponent().appendingPathComponent("activity.jsonl")
    }

    public init(url: URL = ActivityLog.defaultURL, limit: Int = 2000) {
        self.url = url
        self.limit = limit
    }

    public func append(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        locked {
            let file = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
            guard file >= 0 else { return }
            // Start on a fresh line if a crash cut the last one short, so this entry isn't lost with it.
            let size = lseek(file, 0, SEEK_END)
            var last: UInt8 = 0x0A
            if size > 0, pread(file, &last, 1, size - 1) == 1, last != 0x0A { data.insert(0x0A, at: 0) }
            _ = data.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
            close(file)
            trimIfNeeded()
        }
    }

    /// The newest entries first.
    public func recent(limit: Int = 200) -> [ActivityEntry] {
        locked { Array(readAll().suffix(limit).reversed()) }
    }

    /// When the log last changed, to reload it only when needed.
    public var modified: Date? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1e9)
    }

    private func readAll() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // A line cut short by a crash is skipped, not fatal.
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0)) }
    }

    /// Past `limit` × 700 bytes, keeps the newest entries that fill half that, and at most
    /// `limit` of them. Trimming to half means the next trim is a while off, however long the
    /// entries are.
    private func trimIfNeeded() {
        let budget = Int64(limit) * 700
        var status = stat()
        guard stat(url.path, &status) == 0, status.st_size > budget else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var lines: [Data] = []
        var size: Int64 = 0
        for entry in readAll().suffix(limit).reversed() {
            guard let line = try? encoder.encode(entry) else { continue }
            size += Int64(line.count + 1)
            if size > budget / 2, !lines.isEmpty { break }
            lines.append(line)
        }
        var data = Data()
        for line in lines.reversed() {
            data.append(line)
            data.append(0x0A)
        }
        let temporary = url.appendingPathExtension("tmp")
        if (try? data.write(to: temporary)) != nil { rename(temporary.path, url.path) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockFile = open(directory.appendingPathComponent(".activity.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFile >= 0 { flock(lockFile, LOCK_EX) }
        defer {
            if lockFile >= 0 {
                flock(lockFile, LOCK_UN)
                close(lockFile)
            }
        }
        return body()
    }
}
