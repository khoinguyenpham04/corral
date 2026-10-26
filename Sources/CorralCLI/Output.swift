import CorralCore
import Darwin
import Foundation

/// Terminal rendering for the CLI: aligned columns, ember orange where it helps.
struct Output {
    let color: Bool
    let width: Int

    init(color: Bool) {
        self.color = color
        var size = winsize()
        width = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 40 ? min(Int(size.ws_col), 120) : 100
    }

    private func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ text: String) -> String { paint(text, "1") }
    func dim(_ text: String) -> String { paint(text, "2") }
    func ember(_ text: String) -> String { paint(text, "38;2;255;82;20") }
    func moon(_ text: String) -> String { paint(text, "38;2;255;184;52") }

    func tint(_ bucket: Bucket, _ text: String) -> String {
        switch bucket {
        case .agents: paint(text, "38;2;255;82;20")
        case .stacks: paint(text, "38;2;255;184;52")
        case .build: paint(text, "38;2;189;122;255")
        case .leaked: paint(text, "38;2;255;105;103")
        case .shared, .other: dim(text)
        }
    }

    func line(_ text: String) { print(text) }

    /// A column `length` characters wide that always ends in at least one space, truncating
    /// with an ellipsis when needed.
    func fit(_ text: String, _ length: Int) -> String {
        if text.count < length { return text.padding(toLength: length, withPad: " ", startingAt: 0) }
        return String(text.prefix(max(0, length - 2))) + "… "
    }

    func right(_ text: String, _ length: Int) -> String {
        String(repeating: " ", count: max(0, length - text.count)) + text
    }

    func list(_ snapshot: Snapshot, idleAfter: TimeInterval) {
        let now = Date()
        let system = snapshot.system
        var header = bold("Corral") + dim(" · ") + Format.bytes(snapshot.trackedMemory) + dim(" in worktrees")
        header += dim(" · pressure ") + (system.pressure == .normal ? system.pressure.rawValue : ember(system.pressure.rawValue))
        if system.swapUsed > 0 { header += dim(" · swap ") + Format.bytes(system.swapUsed) }
        line(header)
        line("")

        if snapshot.checkouts.isEmpty { line(dim("  Nothing is running in a git checkout.")) }
        let nameWidth = max(24, width - 46)
        for checkout in snapshot.checkouts {
            let idle = checkout.agents.filter { ($0.agent?.idleFor(now: now) ?? 0) >= idleAfter }.count
            var context: [String] = []
            if checkout.kind == .worktree { context.append(checkout.repoName) }
            if checkout.kind == .main { context.append("main checkout") }
            if checkout.kind == .project { context.append("not in git") }
            if let edited = checkout.lastEdited { context.append("edited " + Format.ago(now.timeIntervalSince(edited))) }
            let moonText = idle > 0 ? moon(" ☾\(idle)") : ""
            line(bold(fit(checkout.name, nameWidth)) + dim(fit(context.joined(separator: " · "), 30)) + right(Format.bytes(checkout.memory), 9) + moonText)
            for group in checkout.groups where group.memory >= 5 << 20 || group.agent != nil {
                groupLine(group, now: now, nameWidth: nameWidth)
            }
        }

        if !snapshot.shared.isEmpty {
            line("")
            line(bold(fit("Shared", nameWidth)) + dim(fit("not tied to one checkout", 30)) + right(Format.bytes(snapshot.sharedMemory), 9))
            for group in snapshot.shared.prefix(8) { groupLine(group, now: now, nameWidth: nameWidth) }
        }

        line("")
        line(bold(fit("Other apps", nameWidth)) + dim(fit("everything else you run", 30)) + right(Format.bytes(snapshot.elsewhereMemory), 9))
        for app in snapshot.elsewhere.prefix(6) {
            let count = app.processCount > 1 ? "\(app.processCount) processes" : ""
            line("  " + fit(app.name, nameWidth - 2) + dim(fit(count, 30)) + right(Format.bytes(app.memory), 9))
        }

        let idle = snapshot.agents.filter { ($0.agent?.canHibernate ?? false) && ($0.agent?.idleFor(now: now) ?? 0) >= idleAfter }
        line("")
        if idle.isEmpty {
            line(dim("No agents idle for \(Format.duration(idleAfter)) or more."))
        } else {
            let freed = Format.bytes(idle.reduce(0) { $0 + $1.memory })
            line(moon("☾ ") + "\(idle.count) idle agent\(idle.count == 1 ? "" : "s") · \(freed)" + dim("  →  ") + bold("corral hibernate"))
        }
    }

    func groupLine(_ group: ProcessGroup, now: Date, nameWidth: Int) {
        let kind: String
        var status: String
        switch group.bucket {
        case .agents: kind = "agent"
        case .stacks: kind = "stack"
        case .build: kind = "build"
        case .shared: kind = "shared"
        case .leaked: kind = "leaked"
        case .other: kind = "other"
        }
        var working = false
        if let agent = group.agent {
            working = agent.state == .working
            let idle = agent.state == .waiting ? "needs you" : Format.idle(agent.idleFor(now: now)).lowercased()
            status = agent.host.name + " · " + (working ? "working" : idle)
        } else if group.isOrphaned {
            status = "orphaned · started " + Format.ago(now.timeIntervalSince(group.startedAt))
        } else {
            status = group.detail ?? ""
        }
        let cell = fit(status, 30)
        line("  " + tint(group.bucket, fit(kind, 7)) + fit(group.displayTitle, nameWidth - 9) + (working ? ember(cell) : dim(cell)) + right(Format.bytes(group.memory), 9))
    }

    func agents(_ groups: [ProcessGroup], snapshot: Snapshot) {
        if groups.isEmpty { line(dim("No agent sessions running.")); return }
        for group in groups { agentLine(group, snapshot: snapshot) }
    }

    func agentLine(_ group: ProcessGroup, snapshot: Snapshot) {
        guard let agent = group.agent else { return }
        let now = Date()
        let place = snapshot.checkout(containing: group.id)?.name ?? "—"
        let state = agent.state == .working ? ember(fit("working", 12))
            : agent.state == .waiting ? moon(fit("needs you", 12)) : fit(Format.idle(agent.idleFor(now: now)).lowercased(), 12)
        let id = dim(fit(String(group.rootPID), 7))
        line(id + fit(agent.displayTitle, max(20, width - 70)) + "  " + state + dim(fit(agent.host.name, 16)) + dim(fit(place, 22)) + right(Format.bytes(group.memory), 9))
    }

    /// "Oct 16 15:02  stopped     astro dev :4323     post-haste      2.3 GB  from the panel".
    func activityLine(_ entry: ActivityEntry) {
        let date = entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let verb: String
        switch entry.action {
        case .hibernated: verb = moon(fit("hibernated", 12))
        case .stopped: verb = ember(fit("stopped", 12))
        case .failed: verb = paint(fit("didn't stop", 12), "38;2;255;105;103")
        case .woke: verb = fit("woke", 12)
        case .forgot: verb = dim(fit("forgot", 12))
        case .trashed: verb = paint(fit("trashed", 12), "38;2;255;105;103")
        case .restored: verb = fit("put back", 12)
        }
        let memory = [.woke, .forgot, .restored].contains(entry.action) ? "" : Format.bytes(entry.memory)
        line(dim(fit(date, 15)) + verb + fit(entry.title, max(20, width - 76)) + dim(fit(entry.checkout ?? "", 22)) + right(memory, 8) + "  " + dim(entry.source.label))
    }

    /// Idle worktrees, biggest first, by what moving each to the Trash frees.
    func disk(_ report: DiskReport) {
        let items = report.worktrees
        guard !items.isEmpty else {
            line(dim("No idle worktrees. Corral looks in repos it has seen something run in, and in agents' worktree folders."))
            return
        }
        let now = Date()
        line(bold("Idle worktrees") + dim(" · \(items.count) with nothing running in them · removing them all would free ") + Format.bytes(report.freeable))
        line("")
        let nameWidth = max(24, width - 60)
        for item in items {
            var context = [item.worktree.repoName]
            if let manager = item.worktree.manager { context.append(manager) }
            let hold = item.holds.first
            if let hold {
                context.append(hold.caption)
            } else if let edited = item.usage?.lastEdited {
                context.append("edited " + Format.ago(now.timeIntervalSince(edited)))
            }
            let cell = fit(context.joined(separator: " · "), 38)
            let size = item.usage.map { Format.bytes($0.freeable) } ?? "—"
            // Not when pnpm's or bun's packages were left out of what it takes on disk.
            let shared = item.usage.map { $0.shared >= 100 << 20 && $0.sampled != true ? dim("  of " + Format.bytes($0.allocated)) : "" } ?? ""
            line(fit(item.worktree.name, nameWidth) + (hold == nil ? dim(cell) : moon(cell)) + right(size, 9) + shared)
        }
        line("")
        let safe = report.safe
        if !safe.isEmpty {
            let freed = Format.bytes(safe.reduce(0) { $0 + ($1.usage?.freeable ?? 0) })
            line("\(safe.count) can go to the Trash and free \(freed)" + dim(": the Disk tab in Corral's panel."))
        }
        line(dim("Sizes are what moving to the Trash frees. Files shared with other copies, like pnpm's store, stay, so they don't count."))
    }

    func recordLine(_ record: HibernationRecord) {
        let id = String(record.id.uuidString.prefix(6)).lowercased()
        let age = Format.ago(Date().timeIntervalSince(record.hibernatedAt))
        line(moon("☾ ") + dim(id + "  ") + fit(record.title, max(20, width - 56)) + dim(fit(record.host.name, 16)) + dim(fit(age, 12)) + right(Format.bytes(record.memory), 9))
    }
}
