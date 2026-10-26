import Foundation

/// The outside world, as the snapshot builder sees it. The engine supplies live readers;
/// tests supply fakes.
protocol SnapshotContext: AnyObject {
    var resolver: WorktreeResolver { get }
    var bundles: BundleCatalog { get }
    func session(for record: ProcessRecord, harness: Harness, mode: AgentMode, now: Date) -> SessionInfo?
    /// When the group with this key last used meaningful CPU, given its total CPU time now.
    func lastBusy(key: String, cpuTime: UInt64, now: Date) -> Date?
    func lastEdited(_ root: String) -> Date?
    func isLaunchAgent(_ record: ProcessRecord) -> Bool
    /// What the process is. Its path and arguments don't change, so the engine caches this.
    func role(for record: ProcessRecord) -> Role
    /// The TCP ports a process listens on.
    func listeningPorts(_ pid: Int32) -> [Int]
    func folderExists(_ path: String) -> Bool
}

extension SnapshotContext {
    func role(for record: ProcessRecord) -> Role { Classifier.classify(record) }
    func listeningPorts(_ pid: Int32) -> [Int] { [] }
    func folderExists(_ path: String) -> Bool { true }
}

/// Turns one sample of the process table into a snapshot: groups, agents, checkouts.
struct SnapshotBuilder {
    let records: [ProcessRecord]
    let system: SystemMemory
    let now: Date
    let ownUID: UInt32
    let context: SnapshotContext

    private enum Placement {
        case checkout(WorktreeInfo)
        case shared
        case elsewhere(String)

        var isElsewhere: Bool {
            if case .elsewhere = self { true } else { false }
        }
    }

    func build() -> Snapshot {
        var roles: [Int32: Role] = [:]
        for record in records { roles[record.pid] = context.role(for: record) }
        var grouper = Grouper(records: records, roles: roles, ownUID: ownUID)
        grouper.run()

        var checkouts: [String: (info: WorktreeInfo, groups: [ProcessGroup])] = [:]
        var shared: [ProcessGroup] = []
        var elsewhere: [String: AppUsage] = [:]

        let me = getpid()
        for draft in grouper.drafts where !draft.members.contains(me) {
            guard let lead = grouper.records[draft.leadPID], let root = grouper.records[draft.rootPID] else { continue }
            let leadRole = roles[lead.pid] ?? .unknown(lead.executable)
            let members = draft.members.compactMap { grouper.records[$0] }
            let memory = members.reduce(0) { $0 + $1.footprint }
            let cpu = members.reduce(0) { $0 + $1.cpuTime }
            let busyAt = context.lastBusy(key: root.key, cpuTime: cpu, now: now)
            let orphaned = root.ppid == 1 && !context.isLaunchAgent(root) && !Self.isDaemon(root)

            var agent: Agent?
            var session: SessionInfo?
            if case let .agent(harness, mode) = leadRole {
                let host = host(for: draft, mode: mode, grouper: grouper, roles: roles)
                session = context.session(for: lead, harness: harness, mode: mode, now: now)
                agent = makeAgent(harness: harness, mode: mode, lead: lead, host: host, session: session, busyAt: busyAt)
            }

            var bucket = leadRole.weight > 0 ? leadRole.bucket : .other
            if agent != nil { bucket = .agents }
            let placement = place(leadRole: leadRole, bucket: bucket, orphaned: orphaned, cwds: [session?.cwd, lead.cwd, root.cwd] + members.map(\.cwd), lead: lead)
            if orphaned, agent == nil, bucket != .shared, case .checkout = placement { bucket = .leaked }
            // Shared infrastructure keeps its title, which merging it relies on, and only the
            // ports it was given: its ephemeral ones are its own business (an SSH mux, a VM's
            // agent).
            let infra = bucket == .shared
            let listening = agent == nil && !placement.isElsewhere ? listeningPorts(lead: lead, members: members, ephemeral: !infra) : []
            // Whatever it is, something in a checkout that listens on a port of its own is a server.
            if bucket == .other, case .checkout = placement, listening.contains(where: { $0 < Self.ephemeralPorts }) { bucket = .stacks }
            let label = title(lead: lead, role: leadRole)

            let group = ProcessGroup(
                id: "g:" + root.key,
                bucket: bucket,
                title: infra ? label : listening.first.map { "\(ProcessGroup.withoutPort(label)) :\($0)" } ?? label,
                detail: detail(members: members, roles: roles, agent: agent, session: session),
                memory: memory,
                processes: members.sorted { $0.footprint > $1.footprint }.map {
                    Proc(pid: $0.pid, ppid: $0.ppid, pgid: $0.pgid, name: $0.executable, command: $0.commandLine, memory: $0.footprint, startedAt: $0.startedAt)
                },
                rootPID: root.pid,
                cwd: session?.cwd ?? lead.cwd ?? root.cwd,
                agent: agent,
                isOrphaned: bucket == .leaked,
                startedAt: root.startedAt,
                signalGroup: grouper.signalGroup(for: draft.members),
                ports: listening.isEmpty ? ProcessGroup.port(in: label).map { [$0] } ?? [] : listening
            )

            switch placement {
            case let .checkout(info):
                checkouts[info.root, default: (info, [])].groups.append(group)
            case .shared:
                shared.append(group)
            case let .elsewhere(fallback):
                // What an app starts for itself (Raycast's node backend) counts as that app.
                let owner = grouper.records[root.ppid].flatMap { parent in
                    grouper.appMembers.contains(parent.pid) ? context.bundles.info(forExecutable: parent.path) : nil
                }
                let name = owner?.name ?? (fallback.isEmpty ? (lead.executable.isEmpty ? "Other" : lead.executable) : fallback)
                var usage = elsewhere[name] ?? AppUsage(name: name, bundleID: owner?.identifier, bundlePath: owner?.path, memory: 0, processCount: 0)
                usage.memory += memory
                usage.processCount += members.count
                elsewhere[name] = usage
            }
        }

        for pid in grouper.appMembers {
            guard let record = grouper.records[pid], record.footprint > 0 else { continue }
            let bundle = context.bundles.info(forExecutable: record.path)
            let name = bundle?.name ?? (roles[pid] == .system ? "macOS" : record.executable)
            var usage = elsewhere[name] ?? AppUsage(name: name, bundleID: bundle?.identifier, bundlePath: bundle?.path, memory: 0, processCount: 0)
            usage.memory += record.footprint
            usage.processCount += 1
            elsewhere[name] = usage
        }

        let built = checkouts.values.map { entry -> Checkout in
            let info = entry.info
            return Checkout(
                path: info.root,
                name: info.displayName,
                repoName: info.repoName,
                repoPath: info.repoRoot,
                kind: info.kind,
                branch: info.branch,
                manager: info.manager,
                groups: entry.groups.sorted { ($0.bucket, $1.memory) < ($1.bucket, $0.memory) },
                lastEdited: info.kind == .project ? nil : context.lastEdited(info.root),
                isMissing: !context.folderExists(info.root)
            )
        }

        return Snapshot(
            takenAt: now,
            checkouts: built.sorted { $0.memory > $1.memory },
            shared: Self.mergeShared(shared).sorted { $0.memory > $1.memory },
            elsewhere: elsewhere.values.filter { $0.memory > 0 }.sorted { $0.memory > $1.memory },
            system: system
        )
    }

    /// One row per piece of infrastructure. The VM is named after the runtime that owns it
    /// ("Linux VM (Colima)") and takes in that runtime's own processes.
    static func mergeShared(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        var merged: [String: ProcessGroup] = [:]
        var order: [String] = []
        for group in groups {
            if var existing = merged[group.title] {
                existing.memory += group.memory
                existing.processes += group.processes
                existing.ports = Array(Set(existing.ports + group.ports)).sorted()
                existing.signalGroup = nil
                merged[group.title] = existing
            } else {
                merged[group.title] = group
                order.append(group.title)
            }
        }
        // A runtime's own processes (colima, limactl, its ssh mux) fold into the VM they run, so
        // the VM is one row with one way to stop it.
        var runtime = ContainerRuntime.allCases.first { merged[$0.rawValue] != nil }
        if runtime == .lima, merged["Lima"]?.processes.contains(where: { $0.command.contains("/.colima/") }) == true {
            runtime = .colima
        }
        if var vm = merged["Linux VM"], let runtime {
            vm.title = "Linux VM (\(runtime.rawValue))"
            for title in runtime == .colima ? ["Colima", "Lima"] : [runtime.rawValue] {
                guard let part = merged.removeValue(forKey: title) else { continue }
                vm.memory += part.memory
                vm.processes += part.processes
                vm.ports = Array(Set(vm.ports + part.ports)).sorted()
                vm.startedAt = min(vm.startedAt, part.startedAt)
            }
            vm.signalGroup = nil
            merged["Linux VM"] = vm
        }
        return order.compactMap { merged[$0] }
    }

    // MARK: Ports

    /// Where macOS starts handing out ports to whatever asks for any free one, the way a dev
    /// server's helpers do.
    static let ephemeralPorts = 49152

    /// The ports a group listens on, its lead process's first. Ephemeral ones count only when
    /// there's nothing else, so a dev server shows the port you open, not its helpers'.
    private func listeningPorts(lead: ProcessRecord, members: [ProcessRecord], ephemeral: Bool) -> [Int] {
        var ports: [Int] = []
        for record in [lead] + members.filter({ $0.pid != lead.pid }) {
            for port in context.listeningPorts(record.pid) where !ports.contains(port) { ports.append(port) }
        }
        let chosen = ports.filter { $0 < Self.ephemeralPorts }
        return Array((chosen.isEmpty && ephemeral ? ports : chosen).prefix(4))
    }

    // MARK: Placement

    private func place(leadRole: Role, bucket: Bucket, orphaned: Bool, cwds: [String?], lead: ProcessRecord) -> Placement {
        if case .infra(_, global: true) = leadRole { return .shared }
        let candidates = (cwds.compactMap { $0 } + lead.args.dropFirst().filter { $0.hasPrefix("/") }).filter { $0 != "/" }
        var unique: [String] = []
        for path in candidates where !unique.contains(path) { unique.append(path) }

        for path in unique {
            if let info = context.resolver.worktree(containing: path) { return .checkout(info) }
        }
        if bucket == .agents || bucket == .stacks || bucket == .build || orphaned {
            // A background tool working from its own hidden folder isn't a leaked project server.
            for path in unique where !(orphaned && context.resolver.isToolState(path)) {
                if let info = context.resolver.project(containing: path) { return .checkout(info) }
            }
        }
        if bucket == .agents, let cwd = cwds.compactMap({ $0 }).first, cwd != "/", cwd != Paths.home {
            return .checkout(WorktreeInfo(root: cwd, gitDir: nil, repoRoot: cwd, kind: .project, branch: nil))
        }
        if bucket == .shared { return .shared }
        // An orphaned server whose folder has gone (a deleted scratch copy) still needs a home.
        if orphaned, let cwd = cwds.compactMap({ $0 }).first, cwd != "/", context.resolver.isUserSpace(cwd),
           !context.resolver.isToolState(cwd) {
            return .checkout(WorktreeInfo(root: cwd, gitDir: nil, repoRoot: cwd, kind: .project, branch: nil))
        }
        return .elsewhere(bucket == .agents ? "Agents outside a project" : (leadRole.label ?? lead.executable))
    }

    /// Started to run in the background on purpose, so outliving its shell isn't a leak:
    /// `turbo daemon`, `gradle --daemon`, Gradle's `…GradleDaemon` class.
    static func isDaemon(_ record: ProcessRecord) -> Bool {
        record.args.dropFirst().contains { arg in
            let word = arg.lowercased()
            return word == "daemon" || word == "--daemon" || (word.contains(".") && !word.contains("/") && word.hasSuffix("daemon"))
        }
    }

    // MARK: Agents

    private func host(for draft: GroupDraft, mode: AgentMode, grouper: Grouper, roles: [Int32: Role]) -> AgentHost {
        for ancestor in grouper.ancestors(of: draft.rootPID) {
            switch roles[ancestor.pid] {
            case .multiplexer:
                return AgentHost(kind: .multiplexer, name: ancestor.executable)
            case .login where ancestor.executable.hasPrefix("sshd"):
                return AgentHost(kind: .terminal, name: "SSH")
            case .app:
                guard let info = context.bundles.info(forExecutable: ancestor.path) else { continue }
                var host = BundleCatalog.host(for: info)
                // A TUI inside an app means the app's built-in terminal.
                if mode == .interactive, host.kind == .app { host.kind = .terminal }
                return host
            default:
                continue
            }
        }
        return .background
    }

    private func makeAgent(harness: Harness, mode: AgentMode, lead: ProcessRecord, host: AgentHost, session: SessionInfo?, busyAt: Date?) -> Agent {
        let recentlyBusy = busyAt.map { now.timeIntervalSince($0) < 20 } ?? false
        var state = session?.state ?? (recentlyBusy ? .working : .idle)
        // Claude's own status is authoritative; for the rest, CPU use means it's working.
        if harness != .claude, recentlyBusy { state = .working }
        let candidates = [session?.lastActive, busyAt].compactMap { $0 }
        let lastActive = state == .working ? now : (candidates.max() ?? lead.startedAt)

        let cwd = session?.cwd ?? lead.cwd ?? Paths.home
        var resume: Resume?
        var canHibernate = false
        switch mode {
        case .interactive:
            if let argv = Self.resumeArgv(harness, sessionID: session?.id) {
                resume = .command(argv: argv, cwd: cwd)
                canHibernate = true
            }
        case .hosted:
            if host.bundleID == "com.anthropic.claudefordesktop" {
                resume = session?.resumeURL.map(Resume.url) ?? .app(bundleID: "com.anthropic.claudefordesktop")
                canHibernate = true
            } else if let bundleID = host.bundleID {
                resume = .app(bundleID: bundleID)
            }
        case .server, .oneShot:
            resume = host.bundleID.map { .app(bundleID: $0) }
        }

        return Agent(
            harness: harness, host: host, sessionID: session?.id, title: session?.title, state: state,
            lastActive: lastActive, resume: resume, tty: lead.tty, canHibernate: canHibernate
        )
    }

    static func resumeArgv(_ harness: Harness, sessionID: String?) -> [String]? {
        switch harness {
        case .claude: sessionID.map { ["claude", "--resume", $0] } ?? ["claude", "--continue"]
        case .codex: sessionID.map { ["codex", "resume", $0] } ?? ["codex", "resume", "--last"]
        case .opencode: sessionID.map { ["opencode", "--session", $0] } ?? ["opencode", "--continue"]
        case .pi: sessionID.map { ["pi", "--session", $0] } ?? ["pi", "--continue"]
        case .ohMyPi: sessionID.map { ["omp", "--session", $0] } ?? ["omp", "--continue"]
        case .devin: sessionID.map { ["devin", "--resume", $0] } ?? ["devin", "--continue"]
        default: nil
        }
    }

    // MARK: Labels

    private func title(lead: ProcessRecord, role: Role) -> String {
        switch role {
        case .agent, .stack, .build, .infra, .tool, .processManager:
            return role.label ?? lead.executable
        case .wrapper:
            return Self.compact(lead.args, executable: lead.executable)
        case .helper, .runtime, .unknown:
            let invocation = Invocation(lead)
            if invocation.toolPath != lead.path, !invocation.toolPath.isEmpty {
                return "\(lead.executable) \(Paths.name(invocation.toolPath))"
            }
            return role.label ?? lead.executable
        default:
            return lead.executable
        }
    }

    /// "pnpm --dir demos/simple exec astro dev" → "pnpm exec astro dev".
    static func compact(_ args: [String], executable: String) -> String {
        let invocation = Invocation(path: "", args: args)
        let words = invocation.rest.filter { !$0.hasPrefix("-") && !$0.contains("/") }.prefix(3)
        let name = invocation.tool == invocation.exe ? executable : invocation.tool
        return ([name] + words).joined(separator: " ")
    }

    private func detail(members: [ProcessRecord], roles: [Int32: Role], agent: Agent?, session: SessionInfo?) -> String? {
        if let agent {
            var parts = [agent.host.name]
            if agent.title != nil { parts.append(agent.harness.displayName) }
            if let others = session?.otherTitles, !others.isEmpty { parts.append("+\(others.count) more") }
            return parts.joined(separator: " · ")
        }
        var names: [String] = []
        for member in members.sorted(by: { $0.footprint > $1.footprint }) {
            if case .wrapper = roles[member.pid] { continue }
            let name = member.executable
            if !names.contains(name) { names.append(name) }
            if names.count == 3 { break }
        }
        return names.count > 1 ? names.joined(separator: " · ") : nil
    }
}
