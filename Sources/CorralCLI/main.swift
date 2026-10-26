import CorralCore
import Darwin
import Foundation

let usage = """
corral: memory by worktree, and hibernate idle coding agents.

USAGE
  corral [ls]                     worktrees, what runs in them, and their memory
  corral agents [--idle]          agent sessions with their state and idle time
  corral hibernate [ID…]          stop idle agents; their sessions stay resumable
      --idle-for 30m                only agents idle at least this long (default: Corral's setting)
      --dry-run                     show what would stop
      --force                       include agents that are working
  corral wake [ID]                resume a hibernated session (here, if it ran in a terminal)
      --list                        list hibernated sessions
      --print                       print the resume command instead of running it
  corral stop PID…                stop the process group a PID belongs to
      --force                       also stop agents mid-task, and things another app owns
  corral disk                     idle worktrees, by the disk space moving each to the Trash frees
  corral log [--all]              what Corral stopped, hibernated and woke, newest last
  corral status                   one line, for shell prompts and status bars
  corral version [--check]        this version; --check asks GitHub for a newer one
  corral update                   install the newest release and reopen Corral
  corral snapshot [--raw]         JSON snapshot for debugging (--raw adds the process table)

  --json works with ls, agents, disk and status. IDs are PIDs or session-id prefixes.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
let command = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "ls"
if command == arguments.first { arguments.removeFirst() }

let out = Output(color: isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
let defaults = UserDefaults(suiteName: "io.github.khoinguyenpham04.corral")
let defaultIdle = TimeInterval((defaults?.object(forKey: "idleMinutes") as? Int) ?? 30) * 60
let readOnly = defaults?.bool(forKey: "readOnly") ?? false
let activity = ActivityLog.shared

/// Read-only mode is a promise that nothing gets stopped, from the app or from here.
@MainActor func refuseIfReadOnly() {
    guard readOnly else { return }
    fail("Corral is in read-only mode, so nothing was stopped. Turn it off in Corral's Settings.")
}

@MainActor func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

@MainActor func positional() -> [String] {
    var result: [String] = []
    var skip = false
    for arg in arguments {
        if skip { skip = false; continue }
        if arg == "--idle-for" { skip = true; continue }
        if !arg.hasPrefix("-") { result.append(arg) }
    }
    return result
}

/// "30m", "2h", "1d", "45" (minutes) → seconds.
func duration(_ text: String) -> TimeInterval? {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
    if let unit = text.last, let scale = units[unit], let value = Double(text.dropLast()) { return value * scale }
    return Double(text).map { $0 * 60 }
}

func matches(_ group: ProcessGroup, _ id: String) -> Bool {
    if let pid = Int32(id), group.processes.contains(where: { $0.pid == pid }) { return true }
    if let session = group.agent?.sessionID, session.hasPrefix(id) { return true }
    return false
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("corral: \(message)\n".utf8))
    exit(1)
}

let engine = Engine()
let store = HibernationStore.shared

switch command {
case "ls", "list":
    let snapshot = await engine.snapshot()
    if json { emit(snapshot) } else { out.list(snapshot, idleAfter: defaultIdle) }

case "agents":
    let snapshot = await engine.snapshot()
    let now = Date()
    var agents = snapshot.agents
    if arguments.contains("--idle") { agents = agents.filter { ($0.agent?.idleFor(now: now) ?? 0) >= defaultIdle } }
    if json { emit(agents) } else { out.agents(agents, snapshot: snapshot) }

case "status":
    let snapshot = await engine.snapshot()
    let idle = snapshot.agents.filter { ($0.agent?.idleFor(now: Date()) ?? 0) >= defaultIdle }
    if json {
        struct Status: Encodable { let worktreeMemory: UInt64; let idleAgents: Int; let pressure: String }
        emit(Status(worktreeMemory: snapshot.trackedMemory, idleAgents: idle.count, pressure: snapshot.system.pressure.rawValue))
    } else {
        var parts = [Format.bytes(snapshot.trackedMemory)]
        if !idle.isEmpty { parts.append("☾\(idle.count)") }
        if snapshot.system.pressure != .normal { parts.append(snapshot.system.pressure.rawValue) }
        print(parts.joined(separator: " · "))
    }

case "hibernate":
    refuseIfReadOnly()
    let threshold = flagValue("--idle-for").flatMap(duration) ?? defaultIdle
    let ids = positional()
    // Two samples a moment apart, so an agent that's busy right now shows as working.
    _ = await engine.snapshot()
    try? await Task.sleep(for: .milliseconds(1200))
    let snapshot = await engine.snapshot()
    let now = Date()
    let candidates = snapshot.agents.filter { group in
        guard let agent = group.agent else { return false }
        if !ids.isEmpty { return ids.contains { matches(group, $0) } }
        return agent.canHibernate && agent.idleFor(now: now) >= threshold
    }
    let blocked = candidates.filter { !($0.agent?.canHibernate ?? false) }
    for group in blocked {
        out.line(out.dim("  can't hibernate ") + (group.agent?.displayTitle ?? group.title) + out.dim(" (\(group.agent?.host.name ?? "") manages it)"))
    }
    // Like the app, leave agents in the middle of a task alone unless told otherwise.
    let force = arguments.contains("--force")
    let busy = force ? [] : candidates.filter { $0.agent?.canHibernate == true && $0.agent?.state == .working }
    for group in busy {
        out.line(out.dim("  skipping ") + (group.agent?.displayTitle ?? group.title) + out.dim(": it's working (--force stops it anyway)"))
    }
    let targets = candidates.filter { group in (group.agent?.canHibernate ?? false) && !busy.contains(group) }
    if targets.isEmpty {
        out.line(ids.isEmpty ? "No agents idle for \(Format.duration(threshold)) or more." : "Nothing to hibernate.")
        exit(blocked.isEmpty ? 0 : 1)
    }
    if arguments.contains("--dry-run") {
        for group in targets { out.agentLine(group, snapshot: snapshot) }
        out.line(out.dim("\(targets.count) agent\(targets.count == 1 ? "" : "s") · \(Format.bytes(targets.reduce(0) { $0 + $1.memory })) would be freed"))
        exit(0)
    }
    let records = await Hibernator.hibernate(targets, in: snapshot, source: .cli, store: store)
    for record in records { out.line(out.moon("☾ ") + record.title + out.dim("  " + Format.bytes(record.memory))) }
    let freed = records.reduce(0) { $0 + $1.memory }
    out.line("Hibernated \(records.count) of \(targets.count) · freed \(Format.bytes(freed)). Resume with " + out.bold("corral wake") + ".")

case "wake":
    let running = Set((await engine.snapshot()).agents.compactMap { $0.agent?.sessionID })
    let records = store.reconcile(runningSessions: running)
    let ids = positional()
    if arguments.contains("--list") || (records.isEmpty && ids.isEmpty) {
        if records.isEmpty { out.line("No hibernated sessions."); exit(0) }
        for record in records { out.recordLine(record) }
        exit(0)
    }
    let here = FileManager.default.currentDirectoryPath
    let chosen: HibernationRecord
    if let id = ids.first {
        guard let match = records.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) || $0.sessionID?.hasPrefix(id) == true })
        else { fail("no hibernated session matches \(id); see corral wake --list") }
        chosen = match
    } else if let match = records.first(where: { $0.cwd == here }) {
        chosen = match
    } else {
        for record in records { out.recordLine(record) }
        out.line(out.dim("Pick one: corral wake ID"))
        exit(0)
    }
    if arguments.contains("--print") {
        switch chosen.resume {
        case .command: print(chosen.resume.shellLine ?? "")
        case let .url(url): print("open '\(url)'")
        case let .app(bundleID): print("open -b \(bundleID)")
        }
        exit(0)
    }
    store.remove([chosen.id])
    activity.append([ActivityEntry(.woke, chosen, source: .cli)])
    switch chosen.resume {
    case let .command(argv, cwd):
        guard isatty(STDIN_FILENO) == 1 else { print(chosen.resume.shellLine ?? ""); exit(0) }
        out.line(out.moon("☾ ") + "Waking " + chosen.title)
        guard chdir(cwd) == 0 else { fail("can't enter \(cwd)") }
        var cArgs = argv.map { strdup($0) } + [nil]
        execvp(argv[0], &cArgs)
        fail("couldn't run \(argv[0]): \(String(cString: strerror(errno)))")
    case let .url(url):
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url]).waitUntilExit()
        out.line(out.moon("☾ ") + "Opened " + chosen.host.name + ". Pick “" + chosen.title + "” there; it resumes when you send a message.")
    case let .app(bundleID):
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-b", bundleID]).waitUntilExit()
        out.line(out.moon("☾ ") + "Opened " + chosen.host.name + " for " + chosen.title)
    }

case "stop":
    refuseIfReadOnly()
    let pids = positional()
    guard !pids.isEmpty else { fail("usage: corral stop PID…") }
    let snapshot = await engine.snapshot()
    for id in pids {
        guard let group = snapshot.allGroups.first(where: { matches($0, id) }) else {
            out.line(out.dim("  no group contains \(id)"))
            continue
        }
        let force = arguments.contains("--force")
        if case let .managed(managed) = StopPolicy.of(group), !force {
            out.line("Not stopping \(group.displayTitle): " + managed.reason + out.dim(" (--force stops it anyway)"))
            continue
        }
        if group.agent?.state == .working, !force {
            out.line("Not stopping \(group.displayTitle): it's working." + out.dim(" (--force stops it anyway)"))
            continue
        }
        if let agent = group.agent, agent.canHibernate {
            let records = await Hibernator.hibernate([group], in: snapshot, source: .cli, store: store)
            out.line(records.isEmpty ? "Couldn't stop \(group.displayTitle)" : out.moon("☾ ") + "Hibernated \(group.displayTitle) · \(Format.bytes(group.memory))")
        } else {
            let stopped = await ProcessStopper.stop([group], in: snapshot, source: .cli).isEmpty
            out.line(stopped ? "Stopped \(group.displayTitle) · \(Format.bytes(group.memory))" : "Couldn't stop \(group.displayTitle)")
        }
    }

case "disk":
    let snapshot = await engine.snapshot()
    let monitor = WorktreeMonitor()
    let worktrees = monitor.discover(snapshot.checkouts)
    let running = Set(snapshot.checkouts.map(\.path))
    var measured = monitor.store.measured
    let stale = worktrees.filter { !running.contains($0.path) && monitor.isStale($0, entry: measured[$0.path]) }
    let progress = isatty(STDERR_FILENO) == 1
    for (index, worktree) in stale.enumerated() {
        if progress { FileHandle.standardError.write(Data("\rMeasuring \(index + 1) of \(stale.count)…".utf8)) }
        if let entry = monitor.measure(worktree) { measured[worktree.path] = entry }
    }
    if progress, !stale.isEmpty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    let report = IdleWorktrees.report(
        worktrees, measured: measured, running: running, processes: await engine.processTable(), hibernated: store.all()
    )
    if json { emit(report) } else { out.disk(report) }

case "log":
    let entries = activity.recent(limit: arguments.contains("--all") ? .max : 30).reversed()
    if json {
        emit(Array(entries))
    } else if entries.isEmpty {
        out.line(out.dim("Corral hasn't stopped, hibernated or woken anything yet."))
    } else {
        for entry in entries { out.activityLine(entry) }
        out.line(out.dim("Log: " + Format.path(activity.url.path)))
    }

case "snapshot":
    let snapshot = await engine.snapshot()
    if arguments.contains("--raw") {
        struct Raw: Encodable { let snapshot: Snapshot; let processes: [ProcessRecord] }
        emit(Raw(snapshot: snapshot, processes: await engine.processTable().map(Redact.record)))
    } else {
        emit(snapshot)
    }

case "help", "-h", "--help":
    print(usage)

case "update":
    let current = UpdateCheck.currentVersion
    guard let latest = await UpdateCheck.latest() else {
        fail("Couldn't check for updates. It needs the network and git.")
    }
    guard UpdateCheck.isNewer(latest, than: current) || arguments.contains("--force") else {
        out.line("Corral \(current) is the newest.")
        exit(0)
    }
    guard let installer = UpdateCheck.installer else {
        fail("This copy of Corral has no installer. Download \(latest) from \(UpdateCheck.Release(version: latest).page.absoluteString)")
    }
    // The installer downloads it, replaces Corral.app and reopens it.
    setenv("CORRAL_VERSION", latest, 1)
    let installArgs = ["/bin/bash", installer.path]
    var cArgs = installArgs.map { strdup($0) } + [nil]
    execvp(installArgs[0], &cArgs)
    fail("couldn't run the installer: \(String(cString: strerror(errno)))")

case "version", "--version":
    let current = UpdateCheck.currentVersion
    print(current)
    if arguments.contains("--check") {
        guard let released = await UpdateCheck.released() else {
            fail("Couldn't check for updates. It needs the network and git.")
        }
        if let latest = released.max(by: { UpdateCheck.isNewer($1, than: $0) }) {
            out.line(UpdateCheck.isNewer(latest, than: current)
                ? out.ember("Corral \(latest) is available: ") + "\(UpdateCheck.releases)/v\(latest)"
                : out.dim("Up to date. The newest release is \(latest)."))
        } else {
            out.line(out.dim("No releases yet."))
        }
    }

default:
    fail("unknown command \(command)\n\n\(usage)")
}
