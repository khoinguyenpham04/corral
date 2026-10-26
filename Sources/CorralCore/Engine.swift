import Foundation

/// Samples the machine and builds snapshots. All readers and caches live here, isolated to the
/// actor, so the app and the CLI can call it from anywhere.
public actor Engine {
    private let context = LiveContext()
    private let sampler = ProcessSampler()
    private var table: [ProcessRecord] = []

    public init() {}

    public func snapshot() -> Snapshot {
        let now = Date()
        context.prepare(now: now)
        table = sampler.sample()
        let snapshot = SnapshotBuilder(
            records: table, system: .current(), now: now, ownUID: getuid(), context: context
        ).build()
        context.finish(watching: snapshot.checkouts.filter { $0.kind != .project }.map(\.path))
        return snapshot
    }

    /// The raw process table from the last sample, for diagnostics (`corral snapshot --raw`).
    public func processTable() -> [ProcessRecord] { table }
}

/// The live readers behind a snapshot: session files, worktrees, app bundles, CPU history.
final class LiveContext: SnapshotContext {
    let resolver = WorktreeResolver()
    let bundles = BundleCatalog()
    private let claude = ClaudeSessions()
    private let codex = CodexSessions()
    private let opencode = OpenCodeSessions()
    private let pi = PiSessions(root: Paths.home + "/.pi/agent/sessions")
    private let omp = PiSessions(root: Paths.home + "/.omp/agent/sessions")
    private let activity = ActivityTracker()
    private let launchAgents = LaunchAgentIndex()
    private let edits = EditTracker()
    private var roles: [String: Role] = [:]
    private var seenRoles = Set<String>()

    func prepare(now: Date) {
        resolver.expireIfNeeded(now: now)
        launchAgents.refreshIfNeeded(now: now)
        claude.refresh()
    }

    func finish(watching roots: [String]) {
        activity.endSample()
        edits.watch(roots)
        if roles.count > seenRoles.count + 256 { roles = roles.filter { seenRoles.contains($0.key) } }
        seenRoles.removeAll(keepingCapacity: true)
    }

    func role(for record: ProcessRecord) -> Role {
        let key = record.key
        seenRoles.insert(key)
        if let cached = roles[key] { return cached }
        let role = Classifier.classify(record)
        roles[key] = role
        return role
    }

    func session(for record: ProcessRecord, harness: Harness, mode: AgentMode, now: Date) -> SessionInfo? {
        switch harness {
        case .claude: claude.info(for: record)
        case .codex: codex.info(for: record, now: now)
        case .opencode: opencode.info(for: record, now: now)
        case .pi: pi.info(for: record, now: now)
        case .ohMyPi: omp.info(for: record, now: now)
        default: nil
        }
    }

    func lastBusy(key: String, cpuTime: UInt64, now: Date) -> Date? {
        activity.update(key: key, cpuTime: cpuTime, now: now)
    }

    func lastEdited(_ root: String) -> Date? { edits.lastEdited(root) }

    func isLaunchAgent(_ record: ProcessRecord) -> Bool { launchAgents.matches(record) }

    func listeningPorts(_ pid: Int32) -> [Int] { ProcessIdentity.listeningPorts(of: pid) }

    func folderExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}
