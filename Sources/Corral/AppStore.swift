import AppKit
import CorralCore
import CorralUI
import Foundation
import SwiftUI

/// Owns the sampling loop and every action the panel, menu, CLI-shared store and notifications
/// can take. Samples every 2 s while the panel is open and every 10 s otherwise.
@MainActor
final class AppStore {
    let settings = CorralSettings()
    let model: PanelModel
    let demo: Bool
    var onSnapshot: (Snapshot) -> Void = { _ in }

    private let engine = Engine()
    private let store = HibernationStore.shared
    private let resumer = Resumer()
    private let alerts = Alerts()
    private var loop: Task<Void, Never>?
    private var toastDismissal: Task<Void, Never>?
    /// The newest sample while the panel is hidden; the panel only re-renders when it's on screen.
    private var pending: (snapshot: Snapshot, records: [HibernationRecord])?
    private(set) var latest: Snapshot = .empty
    private let activity = ActivityLog.shared
    private var activityStamp: Date?
    /// Sessions auto-hibernate tried and couldn't stop.
    private var autoFailed: Set<String> = []
    private let worktrees = WorktreeWatcher()
    /// The process table from the last sample, for what's working in idle worktrees.
    private var processes: [ProcessRecord] = []
    private var volumeCheckedAt: Date?
    /// The last move to the Trash's toast, shown again if the panel closed before it came.
    private var lastTrash: (toast: Toast, at: Date)?
    private(set) lazy var updates = Updates(settings: settings, model: model)

    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            if panelVisible, let pending {
                model.now = Date()
                model.snapshot = pending.snapshot
                model.hibernated = pending.records
                self.pending = nil
            }
            if panelVisible {
                worktrees.panelOpened()
                if let lastTrash, Date().timeIntervalSince(lastTrash.at) < 120 {
                    self.lastTrash = nil
                    show(lastTrash.toast, notifyIfHidden: false, seconds: 12)
                }
                publishDisk()
                reloadActivity()
                model.opensAtLogin = LoginItem.isEnabled
                model.commandLineToolPath = CommandLineTool.installedAt.map { Format.path($0.path) }
            } else {
                model.disarm()
                // It hid under the pointer, which never said it left.
                model.holdsToast = false
            }
            restartLoop()
        }
    }

    init(demo: Bool) {
        self.demo = demo
        model = PanelModel(settings: settings)
        model.showsWelcome = !demo && !UserDefaults.standard.bool(forKey: "welcomeDismissed")
        model.diskNudgeHiddenUntil = UserDefaults.standard.object(forKey: "diskNudgeHiddenUntil") as? Date
        if demo {
            model.snapshot = PreviewData.snapshot()
            model.hibernated = PreviewData.hibernated()
            model.activity = PreviewData.activity()
            model.disk = PreviewData.disk()
        }
        var actions = PanelActions()
        actions.hibernate = { [weak self] groups in self?.hibernate(groups) }
        actions.stop = { [weak self] groups in self?.stop(groups) }
        actions.confirmStop = { [weak self] scope, groups in self?.confirmStop(scope, groups) }
        actions.open = { link in if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
        actions.wake = { [weak self] records in self?.wake(records) }
        actions.forget = { [weak self] records in self?.forget(records) }
        actions.trash = { [weak self] items in self?.trashWorktrees(items) }
        actions.confirmTrash = { [weak self] items in self?.confirmTrash(items) }
        actions.reveal = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        actions.openTerminal = { [weak self] path in self?.resumer.openTerminal(at: path, preferred: self?.settings.resumeTerminal ?? "auto") }
        actions.copy = { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.show(Toast(message: "Copied", detail: Format.path(text)), notifyIfHidden: false)
        }
        actions.refresh = { [weak self] in
            self?.restartLoop()
            self?.worktrees.refresh()
        }
        actions.setOpenAtLogin = { [weak self] enabled in
            LoginItem.set(enabled)
            self?.model.opensAtLogin = LoginItem.isEnabled
        }
        actions.installCommandLineTool = { [weak self] in self?.installCommandLineTool() }
        actions.installUpdate = { [weak self] release in self?.installUpdate(release) }
        actions.checkForUpdates = { [weak self] in
            guard let self else { return }
            show(Toast(message: "Checking for updates…"), notifyIfHidden: false)
            Task {
                let status = await self.updates.check()
                self.show(Toast(message: status), notifyIfHidden: false)
            }
        }
        actions.undo = { [weak self] action in self?.undo(action) }
        actions.sendFeedback = { NSWorkspace.shared.open(UpdateCheck.feedback) }
        actions.quit = { NSApp.terminate(nil) }
        model.actions = actions
    }

    func start() {
        restartLoop()
        guard !demo else { return }
        updates.start()
        worktrees.onChange = { [weak self] in self?.publishDisk() }
        worktrees.onReturn = { [weak self] returned in self?.announce(returned) }
        worktrees.start()
    }

    /// Hands over to the installer, which quits Corral and opens the new version. Without an
    /// installer (a development build), opens the release page instead.
    func installUpdate(_ release: UpdateCheck.Release) {
        guard UpdateCheck.installer != nil else {
            NSWorkspace.shared.open(release.page)
            return
        }
        model.installing = true
        show(Toast(message: "Installing Corral \(release.version)", detail: "Corral will quit and reopen in a moment."), notifyIfHidden: false)
        updates.install(release) { [weak self] reason in
            self?.model.installing = false
            self?.show(Toast(message: "Couldn't install the update", detail: reason))
            NSWorkspace.shared.open(release.page)
        }
    }

    private func installCommandLineTool() {
        do {
            let link = try CommandLineTool.install()
            model.commandLineToolPath = Format.path(link.path)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == link.deletingLastPathComponent().path }
            show(Toast(
                message: "Added corral to \(Format.path(link.deletingLastPathComponent().path))",
                detail: onPath ? "Try corral ls in a new terminal tab." : "Add that folder to your PATH, then try corral ls."
            ), notifyIfHidden: false)
        } catch {
            show(Toast(message: "Couldn't add the corral command", detail: error.localizedDescription), notifyIfHidden: false)
        }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let fast = self?.panelVisible ?? false
                try? await Task.sleep(for: fast ? .seconds(2) : .seconds(10))
            }
        }
    }

    func refresh() async {
        if demo {
            model.now = Date()
            onSnapshot(model.snapshot)
            return
        }
        let snapshot = await engine.snapshot()
        processes = await engine.processTable()
        let running = Set(snapshot.agents.compactMap { $0.agent?.sessionID })
        let records = store.reconcile(runningSessions: running)
        latest = snapshot
        worktrees.observe(snapshot)
        if panelVisible {
            // On screen, a new sample moves things into place rather than jumping: numbers
            // roll, the bar's pieces resize, rows that come or go fade and the rest slide.
            withAnimation(Motion.data) {
                model.now = Date()
                model.snapshot = snapshot
                model.hibernated = records
                publishDisk()
                reloadActivity()
            }
        } else {
            pending = (snapshot, records)
        }
        onSnapshot(snapshot)
        alerts.evaluate(snapshot: snapshot, idle: settings.readOnly ? [] : model.idleAgents(in: snapshot), settings: settings)
        await autoHibernate(snapshot)
    }

    /// Rereads the activity log when it changed, which the CLI can do too.
    private func reloadActivity() {
        guard !demo else { return }
        let stamp = activity.modified
        guard stamp != activityStamp else { return }
        activityStamp = stamp
        model.activity = activity.recent(limit: 50)
    }

    /// Idle worktrees and their sizes, and the disk's free space, on screen when the panel is.
    private func publishDisk() {
        guard panelVisible, !demo else { return }
        let report = worktrees.report(snapshot: latest, processes: processes, hibernated: model.hibernated)
        if report != model.disk { model.disk = report }
        if volumeCheckedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            volumeCheckedAt = Date()
            let volume = VolumeSpace.home()
            if volume != model.volume { model.volume = volume }
        }
    }

    /// Read-only mode promises that nothing gets stopped or moved, whatever asks.
    private func refuseIfReadOnly(_ nothing: String = "Nothing was stopped.") -> Bool {
        guard settings.readOnly else { return false }
        show(Toast(message: "Read-only mode is on", detail: "\(nothing) Change it in Settings."))
        return true
    }

    // MARK: Actions

    /// What a hibernate did: the records it saved, the agents that didn't stop, and the agents
    /// left running because they started working since the panel last looked.
    private struct HibernateResult {
        var records: [HibernationRecord] = []
        var failed: [ProcessGroup] = []
        var busy: [ProcessGroup] = []

        var freed: UInt64 { records.reduce(0) { $0 + $1.memory } }

        var notes: [String] {
            var notes: [String] = []
            if !failed.isEmpty { notes.append("\(Format.names(failed.map(\.displayTitle))) didn't stop") }
            if !busy.isEmpty {
                notes.append("\(Format.names(busy.map(\.displayTitle))) started working, so \(busy.count == 1 ? "it's" : "they're") still running")
            }
            return notes
        }
    }

    func hibernate(_ groups: [ProcessGroup], source: ActivityEntry.Source = .panel) {
        guard !refuseIfReadOnly() else { return }
        let targets = groups.filter(model.canHibernate)
        guard !targets.isEmpty else { return }
        if demo {
            let freed = targets.reduce(0) { $0 + $1.memory }
            show(Toast(message: "Hibernated \(targets.count == 1 ? "1 agent" : "\(targets.count) agents") · freed \(Format.bytes(freed))", detail: Format.names(targets.map(\.displayTitle), limit: 1)))
            return
        }
        Task {
            let result = await hibernateNow(targets, source: source)
            if source == .auto {
                // Don't try again every few seconds on an agent that won't stop.
                autoFailed.formUnion(result.failed.compactMap { $0.agent?.sessionID })
                if !result.records.isEmpty {
                    Notifier.shared.post(
                        id: "auto-hibernate",
                        title: "Hibernated \(result.records.count) idle agent\(result.records.count == 1 ? "" : "s") · freed \(Format.bytes(result.freed))",
                        body: "\(Format.names(result.records.map(\.title), limit: 3)), idle over \(settings.autoHibernateHours) h. Wake them from Corral.",
                        offerHibernate: false
                    )
                } else if let toast = toast(for: result) {
                    show(toast)
                }
            } else if let toast = toast(for: result) {
                show(toast)
            }
            await refresh()
        }
    }

    /// Looks again right before stopping anything, so an agent that started working since the
    /// last sample is left alone. Meanwhile its row says "Hibernating…" and can't be clicked again.
    private func hibernateNow(_ targets: [ProcessGroup], source: ActivityEntry.Source) async -> HibernateResult {
        guard !targets.isEmpty else { return HibernateResult() }
        let ids = Set(targets.map(\.id))
        model.stopping.formUnion(ids)
        defer { model.stopping.subtract(ids) }
        let fresh = await engine.snapshot()
        let current = fresh.agents.filter { ids.contains($0.id) }
        let ready = current.filter { $0.agent?.state != .working }
        let records = await Hibernator.hibernate(ready, in: fresh, source: source, store: store)
        // In place before the toast, so its Undo finds them.
        model.hibernated = store.all()
        let saved = Set(records.compactMap(\.sessionID))
        return HibernateResult(
            records: records,
            failed: ready.filter { !($0.agent?.sessionID.map(saved.contains) ?? false) },
            busy: current.filter { $0.agent?.state == .working }
        )
    }

    /// "Hibernated 3 agents · freed 2.1 GB", naming them underneath, with Undo.
    private func toast(for result: HibernateResult) -> Toast? {
        let records = result.records
        guard !records.isEmpty else {
            guard !result.notes.isEmpty else { return nil }
            return Toast(message: result.failed.isEmpty ? "Nothing to hibernate" : "Couldn't hibernate", detail: result.notes.joined(separator: " · "))
        }
        let count = result.failed.isEmpty
            ? (records.count == 1 ? "1 agent" : "\(records.count) agents")
            : "\(records.count) of \(records.count + result.failed.count) agents"
        return Toast(
            message: "Hibernated \(count) · freed \(Format.bytes(result.freed))",
            detail: result.notes.isEmpty ? Format.names(records.map(\.title), limit: 1) : result.notes.joined(separator: " · "),
            action: .wake(records.map(\.id)), actionTitle: "Undo"
        )
    }

    func hibernateIdle(source: ActivityEntry.Source) {
        hibernate(model.idleAgents(in: latest), source: source)
    }

    /// Stops groups the user confirmed in the panel. Resumable agents hibernate instead, and
    /// anything another app or tool owns is left alone. One toast sums it all up.
    func stop(_ groups: [ProcessGroup]) {
        guard !refuseIfReadOnly() else { return }
        let resumable = groups.filter(model.canHibernate)
        let others = groups.filter { model.policy(for: $0) == .stop && !model.stopping.contains($0.id) }
        guard !resumable.isEmpty || !others.isEmpty else { return }
        if demo {
            let names = others.map(\.displayTitle)
            show(Toast(message: "Stopped \(others.count == 1 ? names[0] : "\(others.count) servers") · freed \(Format.bytes(others.reduce(0) { $0 + $1.memory }))"))
            return
        }
        let ids = Set(others.map(\.id))
        model.stopping.formUnion(ids)
        let snapshot = latest
        Task {
            async let hibernation = hibernateNow(resumable, source: .panel)
            async let stillRunning = ProcessStopper.stop(others, in: snapshot, source: .panel)
            let (result, failed) = await (hibernation, stillRunning)
            model.stopping.subtract(ids)
            if let toast = stopToast(others, failed: failed, hibernation: result) { show(toast) }
            await refresh()
        }
    }

    private func stopToast(_ others: [ProcessGroup], failed: [ProcessGroup], hibernation: HibernateResult) -> Toast? {
        guard !others.isEmpty else { return toast(for: hibernation) }
        let failedIDs = Set(failed.map(\.id))
        let stopped = others.filter { !failedIDs.contains($0.id) }
        let records = hibernation.records
        var notes = hibernation.notes
        if !failed.isEmpty { notes.insert("\(Format.names(failed.map(\.displayTitle))) didn't stop", at: 0) }
        guard !stopped.isEmpty || !records.isEmpty else {
            return Toast(message: "Couldn't stop \(Format.names(failed.map(\.displayTitle), limit: 1))", detail: "\(failed.count == 1 ? "It's" : "They're") still running.")
        }
        var parts: [String] = []
        if !stopped.isEmpty {
            parts.append("Stopped " + (!failed.isEmpty ? "\(stopped.count) of \(others.count) servers" : others.count == 1 ? stopped[0].displayTitle : "\(stopped.count) servers"))
        }
        if !records.isEmpty {
            parts.append((parts.isEmpty ? "Hibernated " : "hibernated ") + (records.count == 1 ? "1 agent" : "\(records.count) agents"))
        }
        let freed = stopped.reduce(0) { $0 + $1.memory } + hibernation.freed
        return Toast(
            message: parts.joined(separator: " and ") + " · freed \(Format.bytes(freed))",
            detail: notes.isEmpty ? (stopped.count > 1 && records.isEmpty ? Format.names(stopped.map(\.displayTitle), limit: 1) : nil) : notes.joined(separator: " · "),
            action: records.isEmpty ? nil : .wake(records.map(\.id)), actionTitle: records.isEmpty ? nil : "Undo"
        )
    }

    /// Asks in a dialog that lists what will stop, then stops it. For the row menu's "Stop
    /// Everything Here…", where nothing was confirmed in place.
    func confirmStop(_ scope: String, _ groups: [ProcessGroup]) {
        guard !refuseIfReadOnly() else { return }
        let resumable = groups.filter(model.canHibernate)
        let others = groups.filter { model.policy(for: $0) == .stop }
        let left = groups.count - resumable.count - others.count
        guard !resumable.isEmpty || !others.isEmpty else {
            show(Toast(message: "Nothing here can be stopped from Corral", detail: "Its apps and tools own what's running."))
            return
        }
        var lines: [String] = []
        if !others.isEmpty {
            let listed = others.prefix(4).map { "\($0.displayTitle) (\(Format.bytes($0.memory)))" }
            lines.append("Stops \(Format.names(listed + (others.count > 4 ? ["\(others.count - 4) more"] : []), limit: 5)). They won't restart on their own, and unsaved work in them is lost.")
        }
        if !resumable.isEmpty {
            lines.append("Hibernates \(Format.names(resumable.map(\.displayTitle), limit: 3)). You can wake \(resumable.count == 1 ? "it" : "them") later.")
        }
        if left > 0 {
            lines.append("Leaves \(left == 1 ? "1 thing" : "\(left) things") running that \(left == 1 ? "is" : "are") working, or that another app owns.")
        }
        guard confirm("Stop \(scope)?", detail: lines.joined(separator: "\n\n"), button: others.count + resumable.count == 1 ? "Stop" : "Stop All")
        else { return }
        stop(groups)
    }

    func wake(_ records: [HibernationRecord]) {
        guard !records.isEmpty else { return }
        Task { await wakeNow(records) }
    }

    private func wakeNow(_ records: [HibernationRecord]) async {
        // A tab is free to type into when nothing but its shell is running on its tty.
        let table = demo ? [] : await engine.processTable()
        let busy = Set(table.filter { $0.tty?.isEmpty == false && Classifier.classify($0) != .shell }.compactMap(\.tty))
        var copied = false
        var failed: [HibernationRecord] = []
        for record in records {
            switch resumer.resume(record, preferred: settings.resumeTerminal, ttyIsBusy: { tty in busy.contains(tty) }) {
            case .copied: copied = true
            case .failed: failed.append(record)
            case .opened: break
            }
        }
        // A session that didn't resume keeps its record, so Wake can be tried again.
        let woken = records.filter { !failed.contains($0) }
        if !demo {
            model.hibernated = store.remove(Set(woken.map(\.id)))
            activity.append(woken.map { ActivityEntry(.woke, $0, source: .panel) })
            reloadActivity()
        } else {
            model.hibernated.removeAll { woken.contains($0) }
        }
        if !failed.isEmpty {
            show(Toast(
                message: "Couldn't wake \(Format.names(failed.map(\.title), limit: 1))",
                detail: "\(failed.count == 1 ? "It stays" : "They stay") in the list, so you can try again."
            ))
        } else if copied {
            show(Toast(message: "Resume command copied · paste it in a terminal"))
        } else if records.count == 1, records[0].host.bundleID == "com.anthropic.claudefordesktop" {
            // Some Claude Desktop builds ignore session links, so say where to look.
            show(Toast(message: "Pick “\(records[0].title.prefix(32))” in Claude Desktop to continue"))
        } else {
            show(Toast(message: records.count == 1 ? "Waking \(records[0].title)" : "Waking \(records.count) sessions"))
        }
    }

    /// Takes sessions off the Hibernated list, with Undo. Their agents still have them.
    func forget(_ records: [HibernationRecord]) {
        guard !records.isEmpty else { return }
        if demo {
            model.hibernated.removeAll { records.contains($0) }
        } else {
            model.hibernated = store.remove(Set(records.map(\.id)))
            activity.append(records.map { ActivityEntry(.forgot, $0, source: .panel) })
            reloadActivity()
        }
        show(Toast(
            message: records.count == 1 ? "Removed \(records[0].title)" : "Removed \(records.count) sessions",
            detail: "Still in \(records.count == 1 ? "its agent's" : "their agents'") history",
            action: .restore(records), actionTitle: "Undo"
        ), notifyIfHidden: false)
    }

    /// A toast's Undo, from its button or ⌘Z.
    func undo(_ action: Toast.Action) {
        switch action {
        case let .wake(ids):
            wake((demo ? model.hibernated : store.all()).filter { ids.contains($0.id) })
        case let .restore(records):
            if demo { model.hibernated += records } else { model.hibernated = store.add(records) }
        case let .putBack(ids):
            putBack(ids)
        }
    }

    /// ⌘Z in the panel: the Undo of the toast on screen, if it has one.
    func undoLast() {
        guard let action = model.toast?.action else { return }
        model.toast = nil
        undo(action)
    }

    // MARK: Worktrees

    /// Moves worktrees confirmed in the panel to the Trash. Each is checked again right before
    /// it moves, so one that changed since it was measured stays. One toast sums it up, with Undo.
    func trashWorktrees(_ items: [IdleWorktree]) {
        guard !refuseIfReadOnly("Nothing was moved.") else { return }
        let targets = items.filter { $0.canTrash && !model.trashing.contains($0.id) }
        guard !targets.isEmpty else { return }
        if demo {
            let ids = Set(targets.map(\.id))
            model.disk?.worktrees.removeAll { ids.contains($0.id) }
            let trashed = targets.map {
                TrashedWorktree(
                    name: $0.worktree.name, repoName: $0.worktree.repoName, path: $0.worktree.path, trashedPath: $0.worktree.path,
                    adminDir: $0.worktree.adminDir, repoPath: $0.worktree.repoPath, branch: $0.worktree.branch,
                    freeable: $0.usage?.freeable ?? 0, trashedAt: Date()
                )
            }
            show(trashToast(WorktreeTrash.Result(trashed: trashed), asked: targets.count), seconds: 12)
            return
        }
        let ids = Set(targets.map(\.id))
        model.trashing.formUnion(ids)
        let engine = self.engine
        Task {
            let result = await worktrees.trash(targets, hibernated: store.all()) {
                // What runs where right now, by the same reckoning as the list's.
                let snapshot = await engine.snapshot()
                let running = Dictionary(
                    snapshot.checkouts.map { ($0.path, $0.groups.first?.displayTitle ?? "Something") }, uniquingKeysWith: { first, _ in first }
                )
                return (await engine.processTable(), running)
            }
            model.trashing.subtract(ids)
            activity.append(result.trashed.map { ActivityEntry(.trashed, $0, source: .panel) })
            reloadActivity()
            let toast = trashToast(result, asked: targets.count)
            // Missed if the panel closed while it was moving: shown when it opens again.
            lastTrash = panelVisible || toast.action == nil ? nil : (toast, Date())
            // Longer than most toasts, so there's time to Undo.
            show(toast, seconds: 12)
            withAnimation(Motion.layout) { publishDisk() }
        }
    }

    /// "Moved 6 worktrees to the Trash", with what emptying it frees, and Undo.
    private func trashToast(_ result: WorktreeTrash.Result, asked: Int) -> Toast {
        let trashed = result.trashed
        let kept = result.kept
        guard !trashed.isEmpty else {
            let name = kept.count == 1 ? kept[0].worktree.worktree.name : "\(kept.count) worktrees"
            return Toast(message: "Left \(name) where \(kept.count == 1 ? "it is" : "they are")", detail: kept.first?.reason)
        }
        let what = trashed.count == 1 ? trashed[0].name : kept.isEmpty ? "\(trashed.count) worktrees" : "\(trashed.count) of \(asked) worktrees"
        let freed = Format.bytes(trashed.reduce(0) { $0 + $1.freeable })
        let stays = trashed.count > 1 ? "branches stay" : trashed[0].branch == nil ? "its commits stay" : "its branch stays"
        let detail = kept.isEmpty
            ? "Empty the Trash to free \(freed) · \(stays)"
            : "Kept \(Format.names(kept.map(\.worktree.worktree.name), limit: 1)): \(kept[0].reason)"
        return Toast(message: "Moved \(what) to the Trash", detail: detail, action: .putBack(trashed.map(\.id)), actionTitle: "Undo")
    }

    /// Asks first, saying what goes, what it frees and what stays, then moves them.
    func confirmTrash(_ items: [IdleWorktree]) {
        guard !refuseIfReadOnly("Nothing was moved.") else { return }
        let targets = items.filter(\.canTrash)
        guard !targets.isEmpty else { return }
        let all = model.disk?.worktrees ?? []
        let ids = Set(targets.map(\.id))
        let held = all.filter { !ids.contains($0.id) && !$0.holds.isEmpty }.count
        let freed = Format.bytes(targets.reduce(0) { $0 + ($1.usage?.freeable ?? 0) })
        var lines = [
            "Frees \(freed) once you empty the Trash. Nothing in \(targets.count == 1 ? "it" : "them") is uncommitted, and no commit or branch is deleted. Files git ignores, like .env, go along, as they would from Finder.",
            "Corral checks each one again right before moving it. Undo, or Put Back in Finder, brings \(targets.count == 1 ? "it" : "them") back where \(targets.count == 1 ? "it was" : "they were").",
        ]
        if held > 0 { lines.append("\(held == 1 ? "1 other stays" : "\(held) others stay") where \(held == 1 ? "it is" : "they are"): \(held == 1 ? "it holds" : "they hold") work or \(held == 1 ? "is" : "are") in use.") }
        let title = targets.count == 1 ? "Move \(targets[0].worktree.name) to the Trash?" : "Move \(targets.count) idle worktrees to the Trash?"
        guard confirm(title, detail: lines.joined(separator: "\n\n"), button: "Move to Trash") else { return }
        trashWorktrees(targets)
    }

    /// Undo for a move to the Trash: puts the worktrees back where they were, as they were.
    func putBack(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if demo {
            model.disk = PreviewData.disk()
            show(Toast(message: "Put back"))
            return
        }
        lastTrash = nil
        Task {
            let result = await worktrees.putBack(Set(ids))
            let back = result.restored + result.offBranch.map(\.worktree) + result.unlinked
            activity.append(back.map { ActivityEntry(.restored, $0, source: .panel) })
            reloadActivity()
            let names = Format.names(back.map(\.name), limit: 1)
            if let failure = result.failed.first {
                show(Toast(message: "Couldn't put back \(Format.names(result.failed.map(\.worktree.name), limit: 1))", detail: failure.reason))
            } else if let unlinked = result.unlinked.first {
                show(Toast(message: "Put back \(names)", detail: "Git no longer lists \(unlinked.name) as a worktree. Its files are all there."))
            } else if let off = result.offBranch.first {
                show(Toast(message: "Put back \(names)", detail: Self.offBranch(off.worktree, off.reason)))
            } else if !back.isEmpty {
                show(Toast(message: back.count == 1 ? "Put back \(back[0].name)" : "Put back \(back.count) worktrees"))
            } else {
                show(Toast(message: "Nothing to put back", detail: "It's back already, or no longer in the Trash."))
            }
            withAnimation(Motion.layout) { publishDisk() }
        }
    }

    /// Why a worktree that's back is detached, and what to do about it.
    private static func offBranch(_ worktree: TrashedWorktree, _ reason: WorktreeTrash.OffBranch.Reason) -> String {
        let branch = worktree.branch ?? "its branch"
        return switch reason {
        case .moved: "\(branch) moved on while it was away, so it's detached: git switch \(branch) to catch up"
        case .taken: "\(branch) is checked out in another worktree now, so it's detached"
        case .unknown: "Git couldn't put it back on \(branch), so it's detached for now"
        }
    }

    /// A worktree put back from the Trash in Finder: worth a word only if it came back other
    /// than as it was.
    private func announce(_ returned: [WorktreeTrash.Returned]) {
        for item in returned {
            switch item.outcome {
            case .onBranch: continue
            case .unlinked:
                show(Toast(message: "\(item.worktree.name) is back from the Trash", detail: "Git no longer lists it as a worktree. Its files are all there."))
            case let .offBranch(reason):
                show(Toast(message: "\(item.worktree.name) is back from the Trash", detail: Self.offBranch(item.worktree, reason)))
            }
            return
        }
    }

    private func autoHibernate(_ snapshot: Snapshot) async {
        guard settings.autoHibernate, !settings.readOnly else { return }
        let limit = TimeInterval(settings.autoHibernateHours * 3600)
        // Never automatically stop an agent that's waiting on a question for you.
        let stale = snapshot.agents.filter {
            model.canHibernate($0) && $0.agent?.state == .idle && ($0.agent?.idleFor(now: Date()) ?? 0) >= limit
                && !autoFailed.contains($0.agent?.sessionID ?? "")
        }
        if !stale.isEmpty { hibernate(stale, source: .auto) }
    }

    /// Shows a toast in the panel, or posts it as a notification when the panel is closed (an
    /// action from the menu bar's menu or a notification).
    private func show(_ toast: Toast, notifyIfHidden: Bool = true, seconds: Double = 6) {
        guard panelVisible || demo else {
            if notifyIfHidden {
                Notifier.shared.post(id: "result", title: toast.message, body: toast.detail ?? "", offerHibernate: false)
            }
            return
        }
        model.toast = toast
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // Not while the pointer rests on it, and not the moment it leaves.
            var held = false
            while self?.model.holdsToast == true, !Task.isCancelled {
                held = true
                try? await Task.sleep(for: .milliseconds(250))
            }
            if held { try? await Task.sleep(for: .seconds(1.5)) }
            guard !Task.isCancelled else { return }
            if self?.model.toast?.id == toast.id { self?.model.toast = nil }
        }
    }

    /// Says what goes and asks first. Then removes Corral and quits.
    func uninstall() {
        guard !demo else { return }
        let sleeping = model.hibernated.count
        var detail = "Corral moves itself to the Trash and removes its settings, activity log, corral command and login item. Nothing else on your Mac changes."
        if sleeping > 0 {
            detail += sleeping == 1
                ? "\n\nThe hibernated session stays in its agent's history, so you can still resume it there."
                : "\n\nThe \(sleeping) hibernated sessions stay in their agents' history, so you can still resume them there."
        }
        guard confirm("Uninstall Corral?", detail: detail, button: "Uninstall") else { return }
        var leftovers = Uninstaller.removeData()
        do { try Uninstaller.trashApp() } catch { leftovers.append("Corral.app, so drag it to the Trash") }
        if !leftovers.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Corral couldn't remove everything"
            alert.informativeText = "Still there: " + leftovers.joined(separator: "; ") + "."
            alert.runModal()
        }
        Uninstaller.forgetSettingsAndQuit()
    }

    private func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Pressure and swap notifications, with cool-downs so they never nag.
@MainActor
final class Alerts {
    private var lastPressure: SystemMemory.Pressure = .normal
    private var lastPosted: [String: Date] = [:]

    func evaluate(snapshot: Snapshot, idle: [ProcessGroup], settings: CorralSettings) {
        let pressure = snapshot.system.pressure
        defer { lastPressure = pressure }
        let freeable = idle.reduce(0) { $0 + $1.memory }
        let offer = idle.isEmpty
            ? "Open Corral to see what's using it."
            : "\(idle.count) idle agent\(idle.count == 1 ? " is" : "s are") holding \(Format.bytes(freeable)). Hibernate them?"

        if settings.pressureAlerts, pressure > .normal, pressure > lastPressure, cooled("pressure", minutes: 20) {
            Notifier.shared.post(
                id: "pressure",
                title: pressure == .critical ? "Memory pressure is critical" : "Memory pressure is high",
                body: offer,
                offerHibernate: !idle.isEmpty
            )
        }
        let threshold = UInt64(settings.swapAlertGB) << 30
        if settings.swapAlert, snapshot.system.swapUsed > threshold, cooled("swap", minutes: 60) {
            Notifier.shared.post(
                id: "swap",
                title: "Swap is at \(Format.bytes(snapshot.system.swapUsed))",
                body: offer,
                offerHibernate: !idle.isEmpty
            )
        }
    }

    private func cooled(_ key: String, minutes: Double) -> Bool {
        let now = Date()
        if let last = lastPosted[key], now.timeIntervalSince(last) < minutes * 60 { return false }
        lastPosted[key] = now
        return true
    }
}
