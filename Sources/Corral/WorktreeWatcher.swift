import CorralCore
import Foundation

/// Finds linked worktrees and keeps their sizes current in the background: two at a time
/// while some have never been measured, one at a time after that, at low priority, and not at
/// all in Low Power Mode. Sizes are kept between launches, so after the first time only
/// worktrees that changed get measured again. It also keeps the git entries of worktrees in
/// the Trash in line with where their folders are.
@MainActor
final class WorktreeWatcher {
    private let monitor = WorktreeMonitor()
    private var worktrees: [LinkedWorktree] = []
    private var measured: [String: WorktreeStore.Measured] = [:]
    private var progress: DiskReport.Progress?
    /// When each worktree last had something running in it, to measure it again once it's idle.
    private var lastRunning: [String: Date] = [:]
    private var knownRepos = Set<String>()
    private var checkouts: [Checkout] = []
    /// Worktrees just moved to the Trash, so a look that began before the move can't list them again.
    private var justTrashed: [String: Date] = [:]
    /// Worktrees are in the Trash: watch for one coming back with Finder's Put Back.
    private var hasTrashed = false
    private var settledAt = Date.distantPast
    private var loop: Task<Void, Never>?
    private var power: NSObjectProtocol?
    private var ready = false
    private var discoveredAt: Date?
    private var cycling = false
    private var again = false
    /// Called when the list or a size changes.
    var onChange: () -> Void = {}
    /// Called with worktrees that came back from the Trash some other way than Undo.
    var onReturn: ([WorktreeTrash.Returned]) -> Void = { _ in }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            // Let launch settle first.
            try? await Task.sleep(for: .seconds(8))
            self?.ready = true
            while !Task.isCancelled {
                await self?.cycle()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        // Measuring waits out Low Power Mode, and picks up again once it's off.
        power = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if !ProcessInfo.processInfo.isLowPowerModeEnabled { self?.refresh() }
            }
        }
    }

    /// Notes what runs where. A repository Corral hasn't seen yet gets its worktrees looked up.
    func observe(_ snapshot: Snapshot) {
        let now = Date()
        checkouts = snapshot.checkouts
        for checkout in snapshot.checkouts where checkout.kind == .worktree { lastRunning[checkout.path] = now }
        // A worktree put back from the Trash gets its git entry back within seconds.
        if hasTrashed, now.timeIntervalSince(settledAt) > 10 { settleTrash() }
        let repos = Set(snapshot.checkouts.filter { $0.kind != .project }.map(\.repoPath))
        guard !repos.isSubset(of: knownRepos) else { return }
        knownRepos.formUnion(repos)
        if ready { Task { await cycle() } }
    }

    /// Looks again now, for Refresh.
    func refresh() {
        guard ready else { return }
        Task { await cycle() }
    }

    /// Looks again when the panel opens, if the last look was more than a few minutes ago, so
    /// a worktree made or removed since shows up.
    func panelOpened() {
        guard ready, discoveredAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        Task { await cycle() }
    }

    func report(snapshot: Snapshot, processes: [ProcessRecord], hibernated: [HibernationRecord]) -> DiskReport? {
        guard !worktrees.isEmpty else { return nil }
        return IdleWorktrees.report(
            worktrees, measured: measured, running: Set(snapshot.checkouts.map(\.path)), processes: processes,
            hibernated: hibernated, progress: progress
        )
    }

    /// Moves worktrees to the Trash. Each is looked at again first, which takes a moment; then
    /// `look` takes a fresh look at what's running, right before anything moves.
    func trash(
        _ items: [IdleWorktree], hibernated: [HibernationRecord],
        look: () async -> (processes: [ProcessRecord], running: [String: String])
    ) async -> WorktreeTrash.Result {
        let checked = await Self.background(.userInitiated) { WorktreeTrash.check(items) }
        let (processes, running) = await look()
        let store = monitor.store
        let result = await Self.background(.userInitiated) {
            WorktreeTrash.move(checked, processes: processes, running: running, hibernated: hibernated, store: store)
        }
        let now = Date()
        for item in result.trashed { justTrashed[item.path] = now }
        worktrees.removeAll { justTrashed[$0.path] != nil }
        if !result.trashed.isEmpty { hasTrashed = true }
        return result
    }

    /// Puts worktrees back where they were, back on their branches, and back on the list.
    func putBack(_ ids: Set<UUID>) async -> WorktreeTrash.PutBack {
        let store = monitor.store
        let result = await Self.background(.userInitiated) { WorktreeTrash.putBack(ids, store: store) }
        for item in result.restored + result.offBranch.map(\.worktree) + result.unlinked { justTrashed[item.path] = nil }
        await discover()
        // Its size may have gone while it was away.
        refresh()
        return result
    }

    private func settleTrash() {
        settledAt = Date()
        let store = monitor.store
        Task {
            let (back, remaining) = await Self.background(.utility) { (WorktreeTrash.settle(store: store), store.trashed.count) }
            hasTrashed = remaining > 0
            guard !back.isEmpty else { return }
            // Put back in Finder: on the list again, and measured.
            for item in back { justTrashed[item.worktree.path] = nil }
            onReturn(back)
            await cycle()
        }
    }

    /// Looks for worktrees, then measures the ones that need it. One pass at a time; a request
    /// during a pass runs another after it.
    private func cycle() async {
        guard !cycling else {
            again = true
            return
        }
        cycling = true
        defer { cycling = false }
        repeat {
            again = false
            await discover()
            if !ProcessInfo.processInfo.isLowPowerModeEnabled { await measureStale() }
        } while again
    }

    private func discover() async {
        let monitor = self.monitor
        let checkouts = self.checkouts
        let (back, found, sizes, trashed) = await Self.background(.utility) {
            let back = WorktreeTrash.settle(store: monitor.store)
            return (back, monitor.discover(checkouts), monitor.store.measured, monitor.store.trashed.map(\.path))
        }
        for item in back { justTrashed[item.worktree.path] = nil }
        if !back.isEmpty { onReturn(back) }
        let now = Date()
        justTrashed = justTrashed.filter { now.timeIntervalSince($0.value) < 120 }
        // In the Trash, or moved there while this look was under way.
        let hidden = Set(trashed).union(justTrashed.keys)
        worktrees = found.filter { !hidden.contains($0.path) }
        measured = sizes
        hasTrashed = !trashed.isEmpty
        discoveredAt = now
        knownRepos.formUnion(found.map(\.repoPath))
        onChange()
    }

    /// Worktrees never measured go first, two at a time at utility priority so the list fills
    /// in; then ones that changed, one at a time in the background. Low Power Mode stops it
    /// between worktrees.
    private func measureStale() async {
        let monitor = self.monitor
        let now = Date()
        let running = Set(checkouts.map(\.path))
        let stale = worktrees.filter {
            !running.contains($0.path) && monitor.isStale($0, entry: measured[$0.path], lastRunning: lastRunning[$0.path], now: now)
        }
        guard !stale.isEmpty else { return }
        let unmeasured = Set(stale.filter { measured[$0.path] == nil }.map(\.path))
        var queue = ArraySlice(stale.sorted { unmeasured.contains($0.path) && !unmeasured.contains($1.path) })
        if !unmeasured.isEmpty { progress = DiskReport.Progress(done: 0, total: unmeasured.count) }

        await withTaskGroup(of: (LinkedWorktree, WorktreeStore.Measured?).self) { group in
            var inFlight = 0
            func fill() {
                while let worktree = queue.first, !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    let first = unmeasured.contains(worktree.path)
                    guard inFlight < (first ? 2 : 1) else { return }
                    queue.removeFirst()
                    inFlight += 1
                    group.addTask { (worktree, await Self.background(first ? .utility : .background) { monitor.measure(worktree) }) }
                }
            }
            fill()
            for await (worktree, entry) in group {
                inFlight -= 1
                if let entry { measured[worktree.path] = entry }
                if unmeasured.contains(worktree.path), let current = progress {
                    progress = DiskReport.Progress(done: current.done + 1, total: current.total)
                }
                onChange()
                fill()
            }
        }
        progress = nil
        onChange()
    }

    private nonisolated static func background<T: Sendable>(_ priority: DispatchQoS.QoSClass, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: priority).async { continuation.resume(returning: work()) }
        }
    }
}
