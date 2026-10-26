import Foundation

/// What a group of processes is doing. Drives the memory bar, legend and section order.
public enum Bucket: String, Codable, Sendable, CaseIterable, Comparable {
    case agents, stacks, build, shared, leaked, other

    public var label: String {
        switch self {
        case .agents: "Agents"
        case .stacks: "Servers"
        case .build: "Builds"
        case .shared: "Shared"
        case .leaked: "Leaked"
        case .other: "Other"
        }
    }

    public static func < (lhs: Bucket, rhs: Bucket) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Memory split by bucket.
public struct Breakdown: Codable, Sendable, Hashable {
    public var agents: UInt64 = 0
    public var stacks: UInt64 = 0
    public var build: UInt64 = 0
    public var shared: UInt64 = 0
    public var leaked: UInt64 = 0
    public var other: UInt64 = 0

    public init() {}

    public subscript(bucket: Bucket) -> UInt64 {
        get {
            switch bucket {
            case .agents: agents
            case .stacks: stacks
            case .build: build
            case .shared: shared
            case .leaked: leaked
            case .other: other
            }
        }
        set {
            switch bucket {
            case .agents: agents = newValue
            case .stacks: stacks = newValue
            case .build: build = newValue
            case .shared: shared = newValue
            case .leaked: leaked = newValue
            case .other: other = newValue
            }
        }
    }

    public var total: UInt64 { agents + stacks + build + shared + leaked + other }

    public static func + (lhs: Breakdown, rhs: Breakdown) -> Breakdown {
        var sum = lhs
        for bucket in Bucket.allCases { sum[bucket] += rhs[bucket] }
        return sum
    }
}

/// A coding agent CLI or runtime that Corral knows how to label (and usually resume).
public enum Harness: String, Codable, Sendable, CaseIterable {
    case claude, codex, opencode, pi, ohMyPi, gemini, cursor, devin, amp, copilot, goose, aider, crush, kiro, qwen

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .ohMyPi: "oh-my-pi"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor Agent"
        case .devin: "Devin"
        case .amp: "Amp"
        case .copilot: "Copilot CLI"
        case .goose: "Goose"
        case .aider: "Aider"
        case .crush: "Crush"
        case .kiro: "Kiro"
        case .qwen: "Qwen Code"
        }
    }
}

/// Where an agent runs: a terminal tab, a desktop app, an editor, or nothing at all.
public struct AgentHost: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case terminal, app, editor, multiplexer, background
    }

    public var kind: Kind
    public var name: String
    public var bundleID: String?

    public init(kind: Kind, name: String, bundleID: String? = nil) {
        self.kind = kind
        self.name = name
        self.bundleID = bundleID
    }

    public static let background = AgentHost(kind: .background, name: "Background")
}

public enum AgentState: String, Codable, Sendable {
    case working
    case idle
    /// Stopped on a question or permission prompt for you.
    case waiting
}

/// How to bring a hibernated session back.
public enum Resume: Codable, Sendable, Hashable {
    /// Run `argv` in a terminal, in `cwd`.
    case command(argv: [String], cwd: String)
    /// Open a URL, e.g. a Claude Desktop deep link to the session.
    case url(String)
    /// Bring the host app forward; it restores the session on its own.
    case app(bundleID: String)

    /// The command as a line you could paste into a shell.
    public var shellLine: String? {
        guard case let .command(argv, cwd) = self else { return nil }
        return "cd \(Shell.quote(cwd)) && " + argv.map(Shell.quote).joined(separator: " ")
    }
}

public struct Agent: Codable, Sendable, Hashable {
    public var harness: Harness
    public var host: AgentHost
    public var sessionID: String?
    public var title: String?
    public var state: AgentState
    /// Last time the agent did work. Idle time is measured from here.
    public var lastActive: Date
    public var resume: Resume?
    public var tty: String?
    /// True when Corral can stop the agent and bring the session back later.
    public var canHibernate: Bool

    public init(
        harness: Harness, host: AgentHost, sessionID: String? = nil, title: String? = nil,
        state: AgentState, lastActive: Date, resume: Resume? = nil, tty: String? = nil,
        canHibernate: Bool = false
    ) {
        self.harness = harness
        self.host = host
        self.sessionID = sessionID
        self.title = title
        self.state = state
        self.lastActive = lastActive
        self.resume = resume
        self.tty = tty
        self.canHibernate = canHibernate
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return harness.displayName
    }

    public func idleFor(now: Date) -> TimeInterval {
        state == .working ? 0 : max(0, now.timeIntervalSince(lastActive))
    }
}

/// One process inside a group.
public struct Proc: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var name: String
    public var command: String
    public var memory: UInt64
    public var startedAt: Date

    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32, pgid: Int32, name: String, command: String, memory: UInt64, startedAt: Date) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.name = name
        self.command = command
        self.memory = memory
        self.startedAt = startedAt
    }
}

/// A process tree folded into one row: a dev stack, a build server, an agent session.
public struct ProcessGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var bucket: Bucket
    public var title: String
    public var detail: String?
    public var memory: UInt64
    public var processes: [Proc]
    public var rootPID: Int32
    public var cwd: String?
    public var agent: Agent?
    /// The parent that started this tree has exited and nothing will clean it up.
    public var isOrphaned: Bool
    public var startedAt: Date
    /// A process group that contains exactly these processes, so it can be signalled as one.
    public var signalGroup: Int32?
    /// The TCP ports it listens on, its main process's first. Read from the kernel, or taken
    /// from its command line (`--port 4461`) while it isn't listening yet.
    public var ports: [Int]

    public init(
        id: String, bucket: Bucket, title: String, detail: String? = nil, memory: UInt64,
        processes: [Proc], rootPID: Int32, cwd: String? = nil, agent: Agent? = nil,
        isOrphaned: Bool = false, startedAt: Date, signalGroup: Int32? = nil, ports: [Int] = []
    ) {
        self.id = id
        self.bucket = bucket
        self.title = title
        self.detail = detail
        self.memory = memory
        self.processes = processes
        self.rootPID = rootPID
        self.cwd = cwd
        self.agent = agent
        self.isOrphaned = isOrphaned
        self.startedAt = startedAt
        self.signalGroup = signalGroup
        self.ports = ports
    }

    public var displayTitle: String { agent?.displayTitle ?? title }

    /// The title without the port it ends in, for beside the port itself: "astro dev".
    public var titleWithoutPort: String { Self.withoutPort(title) }

    /// "astro dev :4461" → "astro dev".
    public static func withoutPort(_ title: String) -> String {
        guard port(in: title) != nil, let space = title.lastIndex(of: " ") else { return title }
        return String(title[..<space])
    }

    /// The port a title ends in: "astro dev :4461" → 4461.
    public static func port(in title: String) -> Int? {
        guard let last = title.split(separator: " ").last, last.hasPrefix(":"), let port = Int(last.dropFirst()), port > 0 else { return nil }
        return port
    }
}

/// A git checkout (main or linked worktree), or a plain project folder, with what runs in it.
public struct Checkout: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case main, worktree, project
    }

    public var path: String
    public var name: String
    public var repoName: String
    public var repoPath: String
    public var kind: Kind
    public var branch: String?
    /// The tool that created the worktree, when it's recognisable from the path ("Claude", "Codex", ...).
    public var manager: String?
    public var groups: [ProcessGroup]
    public var lastEdited: Date?
    /// Its folder is gone: a dev server can outlive the worktree it was started in.
    public var isMissing: Bool

    public var id: String { path }

    public init(
        path: String, name: String, repoName: String, repoPath: String, kind: Kind,
        branch: String? = nil, manager: String? = nil, groups: [ProcessGroup] = [], lastEdited: Date? = nil, isMissing: Bool = false
    ) {
        self.path = path
        self.name = name
        self.repoName = repoName
        self.repoPath = repoPath
        self.kind = kind
        self.branch = branch
        self.manager = manager
        self.groups = groups
        self.lastEdited = lastEdited
        self.isMissing = isMissing
    }

    public var memory: UInt64 { groups.reduce(0) { $0 + $1.memory } }

    public var breakdown: Breakdown {
        var result = Breakdown()
        for group in groups { result[group.bucket] += group.memory }
        return result
    }

    public var agents: [ProcessGroup] { groups.filter { $0.agent != nil } }
}

/// Memory used by an app or tool that isn't tied to any checkout.
public struct AppUsage: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var bundleID: String?
    public var bundlePath: String?
    public var memory: UInt64
    public var processCount: Int

    public var id: String { name }

    public init(name: String, bundleID: String? = nil, bundlePath: String? = nil, memory: UInt64, processCount: Int) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.memory = memory
        self.processCount = processCount
    }
}

public struct SystemMemory: Codable, Sendable, Hashable {
    public enum Pressure: String, Codable, Sendable, Comparable {
        case normal, warning, critical

        public var label: String { rawValue.capitalized }

        public static func < (lhs: Pressure, rhs: Pressure) -> Bool {
            let order: [Pressure] = [.normal, .warning, .critical]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var physical: UInt64
    public var used: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: Pressure

    public init(physical: UInt64, used: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: Pressure) {
        self.physical = physical
        self.used = used
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}

public struct Snapshot: Codable, Sendable, Hashable {
    public var takenAt: Date
    public var checkouts: [Checkout]
    /// Infrastructure no single checkout owns: container VMs, databases, local gateways.
    public var shared: [ProcessGroup]
    /// Everything else you run, by app.
    public var elsewhere: [AppUsage]
    public var system: SystemMemory

    public init(takenAt: Date, checkouts: [Checkout], shared: [ProcessGroup], elsewhere: [AppUsage], system: SystemMemory) {
        self.takenAt = takenAt
        self.checkouts = checkouts
        self.shared = shared
        self.elsewhere = elsewhere
        self.system = system
    }

    public static let empty = Snapshot(
        takenAt: .distantPast, checkouts: [], shared: [], elsewhere: [],
        system: SystemMemory(physical: 0, used: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
    )

    public var checkoutMemory: UInt64 { checkouts.reduce(0) { $0 + $1.memory } }
    public var sharedMemory: UInt64 { shared.reduce(0) { $0 + $1.memory } }
    public var elsewhereMemory: UInt64 { elsewhere.reduce(0) { $0 + $1.memory } }

    /// Memory Corral can explain: checkouts plus shared infrastructure.
    public var trackedMemory: UInt64 { checkoutMemory + sharedMemory }

    public var breakdown: Breakdown {
        var result = checkouts.reduce(Breakdown()) { $0 + $1.breakdown }
        result.shared += sharedMemory
        return result
    }

    public var allGroups: [ProcessGroup] { checkouts.flatMap(\.groups) + shared }

    public var agents: [ProcessGroup] { allGroups.filter { $0.agent != nil } }

    public func checkout(containing groupID: String) -> Checkout? {
        checkouts.first { $0.groups.contains { $0.id == groupID } }
    }
}

enum Shell {
    /// Single-quotes `value` for POSIX shells unless it's made only of safe characters.
    static func quote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
