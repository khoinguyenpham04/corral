@testable import CorralCore
import Foundation
import Testing

final class FakeContext: SnapshotContext {
    let resolver = WorktreeResolver(home: "/nonexistent-home", dotGit: Sandbox.dotGit)
    let bundles = BundleCatalog(known: [
        .init(path: "/Applications/Claude.app", identifier: "com.anthropic.claudefordesktop", name: "Claude"),
        .init(path: "/Applications/iTerm.app", identifier: "com.googlecode.iterm2", name: "iTerm"),
        .init(path: "/Applications/Raycast.app", identifier: "com.raycast.macos", name: "Raycast"),
    ])
    var sessions: [Int32: SessionInfo] = [:]
    var busy: [String: Date] = [:]
    var launchAgents = Set<Int32>()
    var listening: [Int32: [Int]] = [:]

    func session(for record: ProcessRecord, harness: Harness, mode: AgentMode, now: Date) -> SessionInfo? { sessions[record.pid] }
    func lastBusy(key: String, cpuTime: UInt64, now: Date) -> Date? { busy[key] }
    func lastEdited(_ root: String) -> Date? { nil }
    func isLaunchAgent(_ record: ProcessRecord) -> Bool { launchAgents.contains(record.pid) }
    func listeningPorts(_ pid: Int32) -> [Int] { listening[pid] ?? [] }
    func folderExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

struct SnapshotTests {
    let me: UInt32 = 501
    let mb: UInt64 = 1024 * 1024
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claudeApp = "/Applications/Claude.app/Contents/MacOS/Claude"
    let disclaimer = "/Applications/Claude.app/Contents/Helpers/disclaimer"
    let desktopCLI = "/Users/me/Library/Application Support/Claude-3p/claude-code/2.1.295/9d64/claude.app/Contents/MacOS/claude"
    let node = "/opt/homebrew/bin/node"

    func proc(_ pid: Int32, _ ppid: Int32, _ path: String, _ args: [String], cwd: String? = nil, mb size: UInt64 = 1, uid: UInt32? = nil, pgid: Int32? = nil) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, pgid: pgid, uid: uid ?? me, startedAt: now.addingTimeInterval(-3600), path: path, args: args, cwd: cwd, footprint: size * mb)
    }

    func build(_ records: [ProcessRecord], context: FakeContext) -> Snapshot {
        let system = SystemMemory(physical: 48 << 30, used: 30 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal)
        return SnapshotBuilder(records: records, system: system, now: now, ownUID: me, context: context).build()
    }

    @Test func claudeDesktopSessionsAndPreviewServers() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repo("meadow", worktrees: [("meadow/.claude/worktrees/table-color-ui-design-99dc44", "noah/table-color-ui-design-99dc44")])
        let worktree = repo + "/.claude/worktrees/table-color-ui-design-99dc44"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(100, 1, claudeApp, ["Claude"], mb: 400),
            proc(101, 100, "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", ["Claude Helper (Renderer)"], mb: 600),
            proc(110, 100, disclaimer, ["disclaimer", "--pgroup", "--", desktopCLI], cwd: worktree, pgid: 110),
            proc(111, 110, desktopCLI, [desktopCLI, "--output-format", "stream-json", "--input-format", "stream-json"], cwd: worktree, mb: 240, pgid: 110),
            proc(112, 111, node, ["node", "/w/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js"], cwd: worktree, mb: 40, pgid: 110),
            proc(120, 100, disclaimer, ["disclaimer", "--", "/opt/homebrew/bin/pnpm", "dev"], cwd: worktree, pgid: 120),
            proc(121, 120, node, ["node", "/opt/homebrew/bin/pnpm", "exec", "astro", "dev", "--port", "4391"], cwd: worktree, mb: 48, pgid: 120),
            proc(122, 121, node, ["node", "./node_modules/.bin/../astro/bin/astro.mjs", "dev", "--port", "4391"], cwd: worktree, mb: 970, pgid: 120),
        ]
        let context = FakeContext()
        context.sessions[111] = SessionInfo(id: "b78d0274", title: "Table color UI/UX design", cwd: worktree, state: .idle, lastActive: now.addingTimeInterval(-1500), resumeURL: "claude://code/continue?session=local_b78d0274")

        let snapshot = build(records, context: context)
        let checkout = try #require(snapshot.checkouts.first)
        #expect(snapshot.checkouts.count == 1)
        #expect(checkout.name == "table-color-ui-design")
        #expect(checkout.repoName == "meadow")
        #expect(checkout.groups.map(\.bucket) == [.agents, .stacks])

        let agentGroup = checkout.groups[0]
        let agent = try #require(agentGroup.agent)
        #expect(agent.title == "Table color UI/UX design")
        #expect(agent.host.name == "Claude Desktop")
        #expect(agent.state == .idle)
        #expect(agent.canHibernate)
        #expect(agent.resume == .url("claude://code/continue?session=local_b78d0274"))
        #expect(agentGroup.memory == 281 * mb)
        #expect(agentGroup.signalGroup == 110)

        let stack = checkout.groups[1]
        #expect(stack.title == "astro dev :4391")
        #expect(stack.memory == 1019 * mb)
        #expect(!stack.isOrphaned)

        #expect(snapshot.elsewhere.first?.name == "Claude")
        #expect(snapshot.elsewhere.first?.memory == 1000 * mb)
    }

    @Test func terminalAgentSplitsOffTheDevServerItStarted() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repo("api")
        let iterm = "/Applications/iTerm.app/Contents/MacOS/iTerm2"
        let claude = "/Users/me/.local/share/claude/versions/2.1.300"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(200, 1, iterm, ["iTerm2"], mb: 300),
            proc(201, 200, "login", ["login"], uid: 0),
            proc(202, 201, "/bin/zsh", ["-zsh"], cwd: repo, mb: 3, pgid: 202),
            proc(203, 202, claude, ["claude"], cwd: repo, mb: 500, pgid: 203),
            proc(204, 203, "/bin/zsh", ["/bin/zsh", "-c", "pnpm dev"], cwd: repo, pgid: 203),
            proc(205, 204, node, ["node", "/opt/homebrew/bin/pnpm", "dev"], cwd: repo, mb: 50, pgid: 203),
            proc(206, 205, node, ["node", "/w/node_modules/vite/bin/vite.js"], cwd: repo, mb: 400, pgid: 203),
        ]
        let snapshot = build(records, context: FakeContext())
        let checkout = try #require(snapshot.checkouts.first)
        #expect(checkout.kind == .main)
        #expect(checkout.groups.count == 2)
        let agent = try #require(checkout.groups.first { $0.agent != nil })
        #expect(agent.memory == 500 * mb)
        #expect(agent.agent?.host.name == "iTerm")
        #expect(agent.agent?.resume == .command(argv: ["claude", "--continue"], cwd: repo))
        // The agent shares its pgid with the dev server, so it can't be signalled as a group.
        #expect(agent.signalGroup == nil)
        let stack = try #require(checkout.groups.first { $0.bucket == .stacks })
        #expect(stack.title == "vite")
        #expect(stack.memory == 451 * mb)
    }

    @Test func orphanedDevServersAreLeakedButLaunchAgentsAreNot() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repo("post-haste")
        try sandbox.file("scratch/meadow-1.2/package.json", "{}")
        let scratch = sandbox.root + "/scratch/meadow-1.2"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(300, 1, node, ["node", repo + "/node_modules/astro/bin/astro.mjs", "dev", "--port", "4323"], cwd: repo, mb: 135),
            proc(301, 300, repo + "/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd", ["workerd", "serve"], cwd: repo, mb: 668),
            proc(310, 1, node, ["node", scratch + "/node_modules/astro/bin/astro.mjs", "dev"], cwd: scratch, mb: 167),
            proc(320, 1, "/opt/homebrew/bin/watchman", ["watchman", "--foreground"], cwd: "/", mb: 16),
            proc(330, 1, node, ["node", "/Users/me/tools/sync/daemon.js"], cwd: repo, mb: 20),
        ]
        let context = FakeContext()
        context.launchAgents = [330]
        let snapshot = build(records, context: context)

        let main = try #require(snapshot.checkouts.first { $0.path == repo })
        let leaked = try #require(main.groups.first { $0.rootPID == 300 })
        #expect(leaked.bucket == .leaked)
        #expect(leaked.isOrphaned)
        #expect(leaked.memory == 803 * mb)
        #expect(main.groups.first { $0.rootPID == 330 }?.bucket == .other)

        let project = try #require(snapshot.checkouts.first { $0.path == scratch })
        #expect(project.kind == .project)
        #expect(project.groups.first?.bucket == .leaked)

        #expect(snapshot.shared.map(\.title) == ["Watchman"])
    }

    @Test func renamedHelpersCountAsTheirApp() {
        let backend = "/Users/me/Library/Application Support/com.raycast.macos/node/runtime/node-v22/bin/node"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(500, 1, "/Applications/Raycast.app/Contents/MacOS/Raycast", ["Raycast"], mb: 200),
            proc(501, 500, backend, ["Raycast Backend", "", ""], cwd: "/", mb: 175),
        ]
        let snapshot = build(records, context: FakeContext())
        #expect(snapshot.elsewhere.map(\.name) == ["Raycast"])
        #expect(snapshot.elsewhere.first?.memory == 375 * mb)
        #expect(Classifier.classify(records[2]) == .runtime("Raycast"))
    }

    @Test func backgroundToolsAreNotLeaks() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repo("meadow")
        let home = "/nonexistent-home"
        let gone = home + "/.codex/worktrees/a1b2/meadow"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(400, 1, home + "/.git-ai/bin/git-ai", ["git-ai", "bg", "run"], cwd: home + "/.git-ai/internal/daemon", mb: 30),
            proc(410, 1, repo + "/node_modules/turbo-darwin-arm64/bin/turbo", ["turbo", "daemon"], cwd: repo, mb: 40),
            proc(420, 1, node, ["node", gone + "/node_modules/astro/bin/astro.mjs", "dev"], cwd: gone, mb: 300),
        ]
        let snapshot = build(records, context: FakeContext())

        #expect(!snapshot.checkouts.contains { $0.path.hasPrefix(home + "/.git-ai") })
        let main = try #require(snapshot.checkouts.first { $0.path == repo })
        let turbo = try #require(main.groups.first { $0.rootPID == 410 })
        #expect(turbo.bucket != .leaked)
        // A dev server left behind when an agent deleted its worktree is the classic leak.
        let deleted = try #require(snapshot.checkouts.first { $0.path == gone })
        #expect(deleted.groups.first?.bucket == .leaked)
        #expect(deleted.isMissing)
        #expect(!main.isMissing)
    }

    @Test func serversShowThePortTheyListenOn() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repo("meadow")
        let iterm = "/Applications/iTerm.app/Contents/MacOS/iTerm2"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(200, 1, iterm, ["iTerm2"], mb: 300),
            proc(202, 200, "/bin/zsh", ["-zsh"], cwd: repo, pgid: 202),
            // Told one port on its command line, listening on another, with a helper on an ephemeral one.
            proc(210, 202, node, ["node", repo + "/node_modules/astro/bin/astro.mjs", "dev", "--port", "4321"], cwd: repo, mb: 300, pgid: 210),
            proc(211, 210, repo + "/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd", ["workerd", "serve"], cwd: repo, mb: 200, pgid: 210),
            // Not listening yet: the port on its command line stands in.
            proc(220, 202, node, ["node", repo + "/node_modules/vite/bin/vite.js", "--port", "5173"], cwd: repo, mb: 100, pgid: 220),
            // Something Corral doesn't recognise, serving from the checkout.
            proc(230, 202, repo + "/target/debug/api", ["api"], cwd: repo, mb: 40, pgid: 230),
            // Only an ephemeral port: still shown, since it's all there is.
            proc(240, 202, repo + "/bin/sidecar", ["sidecar"], cwd: repo, mb: 10, pgid: 240),
        ]
        let context = FakeContext()
        context.listening = [210: [4462], 211: [9229, 51234], 230: [8080], 240: [50001]]
        let snapshot = build(records, context: context)
        let checkout = try #require(snapshot.checkouts.first)

        let astro = try #require(checkout.groups.first { $0.rootPID == 210 })
        #expect(astro.ports == [4462, 9229])
        #expect(astro.title == "astro dev :4462")
        #expect(astro.titleWithoutPort == "astro dev")

        let vite = try #require(checkout.groups.first { $0.rootPID == 220 })
        #expect(vite.ports == [5173])
        #expect(vite.title == "vite :5173")

        let api = try #require(checkout.groups.first { $0.rootPID == 230 })
        #expect(api.bucket == .stacks)
        #expect(api.ports == [8080])

        let sidecar = try #require(checkout.groups.first { $0.rootPID == 240 })
        #expect(sidecar.bucket == .other)
        #expect(sidecar.ports == [50001])
    }

    @Test func sharedInfrastructureKeepsItsTitle() {
        let colima = "/opt/homebrew/bin/colima"
        let records = [
            proc(1, 0, "launchd", ["launchd"], uid: 0),
            proc(600, 1, "/opt/homebrew/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"], cwd: "/", mb: 800),
            proc(610, 1, colima, ["colima", "daemon", "start", "default"], cwd: "/", mb: 30),
        ]
        let context = FakeContext()
        context.listening = [600: [5432], 610: [58198]]
        let snapshot = build(records, context: context)
        let postgres = snapshot.shared.first { $0.rootPID == 600 }
        #expect(postgres?.ports == [5432])
        #expect(postgres.map { ProcessGroup.port(in: $0.title) } == .some(nil))
        // An ephemeral port of a runtime's own isn't shown, and its title still merges into the VM.
        #expect(snapshot.shared.first { $0.rootPID == 610 }?.ports == [])
    }

    @Test func portsInTitles() {
        #expect(ProcessGroup.port(in: "astro dev :4461") == 4461)
        #expect(ProcessGroup.port(in: "astro dev") == nil)
        #expect(ProcessGroup.port(in: "http.server :") == nil)
        #expect(ProcessGroup.withoutPort("wrangler dev :8787") == "wrangler dev")
        #expect(ProcessGroup.withoutPort("Postgres") == "Postgres")
    }
}

struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(21_100 * 1024 * 1024) == "20.6 GB")
        #expect(Format.bytes(700 * 1024 * 1024) == "0.7 GB")
        #expect(Format.bytes(84 * 1024 * 1024) == "84 MB")
    }

    @Test func durations() {
        #expect(Format.idle(33 * 3600) == "Idle 33 h")
        #expect(Format.idle(4 * 60) == "Idle 4 min")
        #expect(Format.idle(30) == "Idle")
        #expect(Format.idle(3 * 86_400) == "Idle 3 d")
        #expect(Format.ago(120) == "2 min ago")
    }

    @Test func shellQuoting() {
        #expect(Resume.command(argv: ["claude", "--resume", "abc"], cwd: "/Users/me/My Repo").shellLine == "cd '/Users/me/My Repo' && claude --resume abc")
    }
}

struct SessionFileTests {
    @Test func claudeRegistry() throws {
        let sandbox = try Sandbox()
        let start = Date(timeIntervalSince1970: 1_792_144_284)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let json = """
        {"pid":8313,"sessionId":"b78d0274-e882-4b20-8dd2-dfc2d92642b8","cwd":"/w","procStart":"\(formatter.string(from: start))",
         "entrypoint":"claude-desktop-3p","hostSessionId":"local_b78d0274-e882-4b20-8dd2-dfc2d92642b8","name":"Social Media Posting",
         "status":"idle","statusUpdatedAt":1792144000000}
        """
        try sandbox.file("sessions/8313.json", json)
        let sessions = ClaudeSessions(directory: sandbox.root + "/sessions")
        sessions.refresh()

        let record = ProcessRecord(pid: 8313, ppid: 8312, startedAt: start, path: "/x/claude")
        let info = try #require(sessions.info(for: record))
        #expect(info.title == "Social Media Posting")
        #expect(info.state == .idle)
        #expect(info.resumeURL == "claude://code/continue?session=local_b78d0274-e882-4b20-8dd2-dfc2d92642b8")

        // Same pid, different process: the file is stale.
        let reused = ProcessRecord(pid: 8313, ppid: 1, startedAt: start.addingTimeInterval(600), path: "/x/claude")
        #expect(sessions.info(for: reused) == nil)
    }

    @Test func codexRolloutIDs() {
        #expect(CodexSessions.threadID(fromRollout: "/Users/me/.codex/sessions/2026/10/15/rollout-2026-10-15T15-06-04-01a13fe2-64f6-7211-8ff1-07e780baa4ce.jsonl") == "01a13fe2-64f6-7211-8ff1-07e780baa4ce")
    }

    @Test func hibernationStoreRoundTrip() throws {
        let sandbox = try Sandbox()
        let store = HibernationStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/hibernated.json"))
        let record = HibernationRecord(
            harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "abc", title: "Fix flaky test",
            cwd: "/w", checkout: "meadow", resume: .command(argv: ["claude", "--resume", "abc"], cwd: "/w"),
            tty: "ttys008", memory: 1 << 30, hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000.25)
        )
        store.add([record])
        #expect(store.all() == [record])
        store.reconcile(runningSessions: ["abc"], now: record.hibernatedAt.addingTimeInterval(60))
        #expect(store.all().isEmpty)
    }
}
