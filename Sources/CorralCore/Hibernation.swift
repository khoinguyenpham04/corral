import Darwin
import Foundation

/// A stopped agent session and how to bring it back.
public struct HibernationRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var harness: Harness
    public var host: AgentHost
    public var sessionID: String?
    public var title: String
    public var cwd: String
    public var checkout: String?
    public var resume: Resume
    public var tty: String?
    public var memory: UInt64
    public var hibernatedAt: Date

    public init(
        id: UUID = UUID(), harness: Harness, host: AgentHost, sessionID: String?, title: String, cwd: String,
        checkout: String?, resume: Resume, tty: String?, memory: UInt64, hibernatedAt: Date
    ) {
        self.id = id
        self.harness = harness
        self.host = host
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.checkout = checkout
        self.resume = resume
        self.tty = tty
        self.memory = memory
        self.hibernatedAt = hibernatedAt
    }
}

/// Hibernated sessions, shared by the app and the `corral` CLI through one JSON file. Every
/// change is a locked read-modify-write, so both can use it at once.
public final class HibernationStore: @unchecked Sendable {
    public static let shared = HibernationStore()

    public let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: Paths.home + "/Library/Application Support")
        return support.appendingPathComponent("Corral/hibernated.json")
    }

    public init(url: URL = HibernationStore.defaultURL) {
        self.url = url
    }

    public func all() -> [HibernationRecord] {
        mutate { _ in }
    }

    @discardableResult
    /// Saves records. A session has one record at most: a newer one replaces the older.
    public func add(_ records: [HibernationRecord]) -> [HibernationRecord] {
        let sessions = Set(records.compactMap(\.sessionID))
        return mutate { existing in
            existing.removeAll { $0.sessionID.map(sessions.contains) ?? false }
            existing.append(contentsOf: records)
        }
    }

    @discardableResult
    public func remove(_ ids: Set<UUID>) -> [HibernationRecord] {
        mutate { $0.removeAll { ids.contains($0.id) } }
    }

    /// Drops records whose session is running again (woken some other way) and anything older
    /// than two weeks. A record from the last 30 seconds stays: Hibernate saves it before the
    /// agent has finished stopping.
    @discardableResult
    public func reconcile(runningSessions: Set<String>, now: Date = Date()) -> [HibernationRecord] {
        mutate { records in
            records.removeAll { record in
                let age = now.timeIntervalSince(record.hibernatedAt)
                if age < 30 { return false }
                if let id = record.sessionID, runningSessions.contains(id) { return true }
                return age > 14 * 86_400
            }
        }
    }

    private func mutate(_ change: (inout [HibernationRecord]) -> Void) -> [HibernationRecord] {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockFile = open(directory.appendingPathComponent(".hibernated.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFile >= 0 { flock(lockFile, LOCK_EX) }
        defer {
            if lockFile >= 0 {
                flock(lockFile, LOCK_UN)
                close(lockFile)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let original = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([HibernationRecord].self, from: $0) } ?? []
        var records = original
        change(&records)
        records.sort { $0.hibernatedAt > $1.hibernatedAt }
        if records != original {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(records) {
                // Write beside the file and rename over it, so a crash never leaves half a file.
                let temporary = url.appendingPathExtension("tmp")
                if (try? data.write(to: temporary)) != nil { rename(temporary.path, url.path) }
            }
        }
        return records
    }
}

/// Stops process groups: SIGTERM first, SIGKILL for whatever is still running after a grace
/// period. Every pid is re-checked against its start time first, so a reused pid is never hit.
public enum ProcessStopper {
    @discardableResult
    public static func stop(_ group: ProcessGroup, grace: TimeInterval = 3) async -> Bool {
        let me = getpid()
        let targets = group.processes.filter {
            $0.pid > 1 && $0.pid != me && ProcessIdentity.matches(pid: $0.pid, startedAt: $0.startedAt)
        }
        guard !targets.isEmpty else { return true }

        // Signal the whole process group when it is exactly this group and its leader is the
        // same process we sampled; otherwise the root first, so it can shut its children down.
        if let pgid = group.signalGroup, targets.contains(where: { $0.pid == pgid }) {
            killpg(pgid, SIGTERM)
        } else {
            for proc in targets.sorted(by: { ($0.pid == group.rootPID ? 0 : 1, $0.pid) < ($1.pid == group.rootPID ? 0 : 1, $1.pid) }) {
                kill(proc.pid, SIGTERM)
            }
        }

        let alive = { targets.filter { ProcessIdentity.matches(pid: $0.pid, startedAt: $0.startedAt) } }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if alive().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for proc in alive() { kill(proc.pid, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(250))
        return alive().isEmpty
    }
}

public enum Hibernator {
    /// Stops each agent that can be resumed and records how to bring it back. Returns the
    /// records for the sessions that stopped. Each record is saved before its agent is
    /// signalled, so a crash part way through never loses the way back.
    public static func hibernate(
        _ groups: [ProcessGroup], in snapshot: Snapshot, source: ActivityEntry.Source,
        store: HibernationStore = .shared, log: ActivityLog = .shared, now: Date = Date()
    ) async -> [HibernationRecord] {
        let planned: [(group: ProcessGroup, record: HibernationRecord)] = groups.compactMap { group in
            guard let agent = group.agent, agent.canHibernate, let resume = agent.resume else { return nil }
            let record = HibernationRecord(
                harness: agent.harness, host: agent.host, sessionID: agent.sessionID, title: agent.displayTitle,
                cwd: group.cwd ?? Paths.home, checkout: snapshot.checkout(containing: group.id)?.name, resume: resume,
                tty: agent.tty, memory: group.memory, hibernatedAt: now
            )
            return (group, record)
        }
        guard !planned.isEmpty else { return [] }
        store.add(planned.map(\.record))

        var stopped = Set<UUID>()
        await withTaskGroup(of: (UUID, Bool).self) { tasks in
            for (group, record) in planned {
                tasks.addTask { (record.id, await ProcessStopper.stop(group)) }
            }
            for await (id, ok) in tasks where ok {
                stopped.insert(id)
            }
        }
        let failed = planned.filter { !stopped.contains($0.record.id) }
        if !failed.isEmpty { store.remove(Set(failed.map(\.record.id))) }
        log.append(planned.map { item in
            ActivityEntry(stopped.contains(item.record.id) ? .hibernated : .failed, item.group, checkout: item.record.checkout, source: source)
        })
        return planned.map(\.record).filter { stopped.contains($0.id) }
    }
}

extension ProcessStopper {
    /// Stops groups side by side, so one slow to quit doesn't hold up the rest, and logs each.
    /// Returns the ones still running.
    public static func stop(
        _ groups: [ProcessGroup], in snapshot: Snapshot, source: ActivityEntry.Source, log: ActivityLog = .shared
    ) async -> [ProcessGroup] {
        guard !groups.isEmpty else { return [] }
        var stopped = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { tasks in
            for group in groups {
                tasks.addTask { (group.id, await stop(group)) }
            }
            for await (id, ok) in tasks where ok {
                stopped.insert(id)
            }
        }
        log.append(groups.map { group in
            ActivityEntry(stopped.contains(group.id) ? .stopped : .failed, group, checkout: snapshot.checkout(containing: group.id)?.name, source: source)
        })
        return groups.filter { !stopped.contains($0.id) }
    }
}
