import CorralCore
import Foundation

/// A believable machine for previews, screenshots and `Corral --demo`: a web app monorepo with
/// worktrees from Claude, Codex and a terminal, leaked dev servers and a container VM.
public enum PreviewData {
    static let home = NSHomeDirectory()
    static let mb: UInt64 = 1 << 20
    static let gb: UInt64 = 1 << 30

    public static func snapshot(now: Date = Date()) -> Snapshot {
        var pid: Int32 = 4000
        func group(
            _ bucket: Bucket, _ title: String, _ memory: UInt64, detail: String? = nil, agent: Agent? = nil,
            orphaned: Bool = false, age: TimeInterval = 3600, cwd: String = "\(home)/Developer/meadow", ports: [Int]? = nil
        ) -> ProcessGroup {
            pid += 17
            let proc = Proc(pid: pid, ppid: 1, pgid: pid, name: "node", command: title, memory: memory, startedAt: now.addingTimeInterval(-age))
            return ProcessGroup(
                id: "g:\(pid)", bucket: bucket, title: title, detail: detail, memory: memory, processes: [proc], rootPID: pid,
                cwd: cwd, agent: agent, isOrphaned: orphaned, startedAt: now.addingTimeInterval(-age),
                ports: ports ?? ProcessGroup.port(in: title).map { [$0] } ?? []
            )
        }
        let desktop = AgentHost(kind: .app, name: "Claude Desktop", bundleID: "com.anthropic.claudefordesktop")
        let iterm = AgentHost(kind: .terminal, name: "iTerm", bundleID: "com.googlecode.iterm2")
        let codexApp = AgentHost(kind: .app, name: "Codex Desktop", bundleID: "com.openai.codex")
        func agent(_ harness: Harness, _ title: String, _ host: AgentHost, idle: TimeInterval?, hibernate: Bool = true) -> Agent {
            Agent(
                harness: harness, host: host, sessionID: UUID().uuidString.lowercased(), title: title,
                state: idle == nil ? .working : .idle, lastActive: now.addingTimeInterval(-(idle ?? 0)),
                resume: .command(argv: ["claude", "--resume", "x"], cwd: home), canHibernate: hibernate
            )
        }

        let meadow = Checkout(
            path: "\(home)/Developer/meadow", name: "meadow", repoName: "meadow", repoPath: "\(home)/Developer/meadow",
            kind: .main, branch: "main",
            groups: [
                group(.shared, "Postgres", 820 * mb, detail: "postgres · 9 workers", ports: [5432]),
                group(.shared, "Redis", 96 * mb, detail: "redis-server", ports: [6379]),
                group(.agents, "Plugin settings page", 520 * mb, agent: agent(.claude, "Plugin settings page", desktop, idle: nil)),
                group(.agents, "Review PR 424: search filters", 610 * mb, agent: agent(.codex, "Review PR 424: search filters", codexApp, idle: 1400, hibernate: false)),
                group(.agents, "Onboarding email copy", 195 * mb, agent: agent(.claude, "Onboarding email copy", desktop, idle: 7400)),
                group(.agents, "Audit empty project states", 380 * mb, agent: agent(.opencode, "Audit empty project states", iterm, idle: 120_000)),
                group(.stacks, "vite dev :5173", 1740 * mb, detail: "node · esbuild", age: 10_800),
            ],
            lastEdited: now.addingTimeInterval(-420)
        )
        let tableColor = Checkout(
            path: "\(home)/Developer/meadow/.claude/worktrees/table-color-ui-design-99dc44", name: "table-color-ui-design",
            repoName: "meadow", repoPath: meadow.path, kind: .worktree, branch: "noah/table-color-ui-design", manager: "Claude",
            groups: [
                group(.agents, "Table color UI/UX design", 240 * mb, agent: agent(.claude, "Table color UI/UX design", desktop, idle: 1560)),
                group(.stacks, "vite dev :5174", 2610 * mb, detail: "pnpm · node", age: 25_200),
            ],
            lastEdited: now.addingTimeInterval(-25_000)
        )
        let visualEdits = Checkout(
            path: "\(home)/Developer/meadow-visual-edits", name: "visual-edits", repoName: "meadow", repoPath: meadow.path,
            kind: .worktree, branch: "noah/visual-edits",
            groups: [
                group(.agents, "Visual edits colour picker", 710 * mb, agent: agent(.claude, "Visual edits colour picker", iterm, idle: 118_000)),
                group(.build, "tsc --watch", 930 * mb),
                group(.build, "vitest watch", 420 * mb),
            ],
            lastEdited: now.addingTimeInterval(-130)
        )
        let publish = Checkout(
            path: "\(home)/Developer/studio-publish", name: "publish-dialog", repoName: "studio", repoPath: "\(home)/Developer/studio",
            kind: .worktree, branch: "publish-dialog", manager: "Codex",
            groups: [
                group(.agents, "Fix flaky publish test", 540 * mb, agent: agent(.codex, "Fix flaky publish test", iterm, idle: 11_000)),
                group(.stacks, "next dev :3000", 1180 * mb, detail: "node · next-server", age: 18_000),
            ],
            lastEdited: now.addingTimeInterval(-1440)
        )
        let postHaste = Checkout(
            path: "\(home)/Developer/misc/post-haste", name: "post-haste", repoName: "post-haste", repoPath: "\(home)/Developer/misc/post-haste",
            kind: .main, branch: "main",
            groups: [group(.leaked, "astro dev :4323", 2380 * mb, detail: "node · esbuild", orphaned: true, age: 950_000)]
        )
        let iframe = Checkout(
            path: "\(home)/Developer/meadow/.claude/worktrees/iframe-block", name: "iframe-block", repoName: "meadow", repoPath: meadow.path,
            kind: .worktree, branch: "noah/iframe-block", manager: "Claude",
            groups: [group(.leaked, "vite dev :5175", 1690 * mb, orphaned: true, age: 1_300_000)], isMissing: true
        )
        let corral = Checkout(
            path: "\(home)/Developer/utils/corral", name: "corral", repoName: "corral", repoPath: "\(home)/Developer/utils/corral", kind: .main,
            branch: "main", groups: [group(.agents, "Corral menu bar app", 210 * mb, agent: agent(.claude, "Corral menu bar app", desktop, idle: nil))],
            lastEdited: now.addingTimeInterval(-40)
        )
        let compassionate = Checkout(
            path: "\(home)/Developer/meadow/.claude/worktrees/compassionate-mclaren", name: "compassionate-mclaren", repoName: "meadow",
            repoPath: meadow.path, kind: .worktree,
            groups: [group(.agents, "Fix drafts leaking into search", 230 * mb, agent: agent(.claude, "Fix drafts leaking into search", desktop, idle: 4400))],
            lastEdited: now.addingTimeInterval(-5200)
        )
        let realtime = Checkout(
            path: "\(home)/.t3/worktrees/meadow/t3code-fab1a30d", name: "realtime-collaborative-editing", repoName: "meadow", repoPath: meadow.path,
            kind: .worktree, branch: "t3code/realtime-collaborative-editing", manager: "T3 Code",
            groups: [group(.leaked, "http.server :4471", 12 * mb, orphaned: true, age: 72_000)]
        )

        return Snapshot(
            takenAt: now,
            checkouts: [meadow, tableColor, postHaste, visualEdits, publish, iframe, compassionate, corral, realtime].sorted { $0.memory > $1.memory },
            shared: [
                group(.shared, "Linux VM (Colima)", 6300 * mb, age: 1_200_000, cwd: "/"),
                group(.shared, "Ollama", 48 * mb, cwd: "/"),
                group(.shared, "Watchman", 16 * mb, cwd: "/"),
            ],
            elsewhere: [
                AppUsage(name: "Google Chrome", memory: 9200 * mb, processCount: 38),
                AppUsage(name: "Claude", memory: 2700 * mb, processCount: 13),
                AppUsage(name: "macOS", memory: 2500 * mb, processCount: 273),
                AppUsage(name: "ChatGPT", memory: 2000 * mb, processCount: 19),
                AppUsage(name: "Figma", memory: 1400 * mb, processCount: 6),
                AppUsage(name: "Slack", memory: 1100 * mb, processCount: 5),
                AppUsage(name: "Zoom", memory: 690 * mb, processCount: 4),
            ],
            system: SystemMemory(physical: 48 * gb, used: 41 * gb, swapUsed: 6 * gb, swapTotal: 8 * gb, pressure: .normal)
        )
    }

    public static func hibernated(now: Date = Date()) -> [HibernationRecord] {
        [
            HibernationRecord(
                harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "b78d0274", title: "Speed up preview reloads",
                cwd: "\(home)/Developer/meadow", checkout: "meadow",
                resume: .command(argv: ["claude", "--resume", "b78d0274"], cwd: "\(home)/Developer/meadow"),
                tty: "ttys008", memory: 820 * mb, hibernatedAt: now.addingTimeInterval(-7300)
            ),
            HibernationRecord(
                harness: .claude, host: AgentHost(kind: .app, name: "Claude Desktop", bundleID: "com.anthropic.claudefordesktop"), sessionID: "54a5abbb",
                title: "Plan mode copy pass", cwd: "\(home)/Developer/meadow", checkout: "meadow",
                resume: .url("claude://code/continue?session=local_54a5abbb"), tty: nil, memory: 690 * mb, hibernatedAt: now.addingTimeInterval(-26_000)
            ),
        ]
    }

    public static func activity(now: Date = Date()) -> [ActivityEntry] {
        [
            ActivityEntry(date: now.addingTimeInterval(-600), action: .stopped, source: .panel, title: "astro dev :4323", checkout: "post-haste", memory: 2380 * mb),
            ActivityEntry(date: now.addingTimeInterval(-7300), action: .hibernated, source: .panel, title: "Speed up preview reloads", checkout: "meadow", memory: 820 * mb),
            ActivityEntry(date: now.addingTimeInterval(-26_000), action: .hibernated, source: .auto, title: "Plan mode copy pass", checkout: "meadow", memory: 690 * mb),
            ActivityEntry(date: now.addingTimeInterval(-200_000), action: .woke, source: .cli, title: "Fix flaky publish test", checkout: "publish-dialog", memory: 540 * mb),
        ]
    }

    /// Idle worktrees from Claude, Codex and T3 Code, a few holding work that isn't committed.
    public static func disk(now: Date = Date()) -> DiskReport {
        let repo = "\(home)/Developer/meadow"
        func item(
            _ name: String, _ manager: String?, _ freeable: Double, of allocated: Double, edited days: Double, holds: [Hold] = []
        ) -> IdleWorktree {
            let path = switch manager {
            case "Codex": "\(home)/.codex/worktrees/\(name)/meadow"
            case "T3 Code": "\(home)/.t3/worktrees/meadow/t3code-\(name.prefix(4))f1a3"
            case nil: "\(home)/Developer/meadow-\(name)"
            default: "\(repo)/.claude/worktrees/\(name)"
            }
            let worktree = LinkedWorktree(
                path: path, adminDir: "\(repo)/.git/worktrees/\(name)", repoPath: repo, repoName: "meadow", name: name,
                branch: manager == "Codex" ? nil : "noah/\(name)", detached: manager == "Codex", manager: manager
            )
            let usage = DiskUsage(
                allocated: UInt64(allocated * Double(gb)), freeable: UInt64(freeable * Double(gb)), files: 138_000,
                lastEdited: now.addingTimeInterval(-days * 86_400), device: 1
            )
            return IdleWorktree(worktree: worktree, usage: usage, git: GitState(changes: 0, unsavedCommits: 0, checkedAt: now), holds: holds)
        }
        return DiskReport(worktrees: [
            item("edit-reliability", "Claude", 1.7, of: 5.0, edited: 21),
            item("sync-blog-demos", "Claude", 1.6, of: 4.8, edited: 1.8),
            item("playground-toolbar", "Claude", 1.1, of: 4.3, edited: 7),
            item("media-usage-reconcile", nil, 1.0, of: 3.8, edited: 3, holds: [.changes(4)]),
            item("admin-dropdown-transition", "Claude", 0.7, of: 4.4, edited: 16),
            item("marketing-template", "Claude", 0.6, of: 3.9, edited: 0.3),
            item("comments-page-header", "Codex", 0.32, of: 3.8, edited: 23),
            item("review-pr3582", "Codex", 0.24, of: 3.7, edited: 17, holds: [.unsavedCommits(7)]),
            item("calendar-polish", "T3 Code", 0.2, of: 0.9, edited: 2),
            item("image-toolbar", "Claude", 0.15, of: 0.9, edited: 9, holds: [.changes(1)]),
            item("epic-sanderson", "Claude", 0.03, of: 0.8, edited: 1.2, holds: [.inUse("zsh")]),
        ])
    }

    /// A shorter machine for the README's hero image.
    public static func hero(now: Date = Date()) -> Snapshot {
        let full = snapshot(now: now)
        let keep = ["meadow", "table-color-ui-design", "post-haste", "visual-edits", "publish-dialog"]
        var checkouts = full.checkouts.filter { keep.contains($0.name) }
        if let index = checkouts.firstIndex(where: { $0.name == "meadow" }) {
            // Agents and the dev server only, so the open checkout tells the story in a few rows.
            checkouts[index].groups.removeAll { $0.bucket == .shared }
        }
        var hero = full
        hero.checkouts = checkouts.sorted { $0.memory > $1.memory }
        hero.shared = Array(full.shared.prefix(2))
        return hero
    }
}
