import CorralCore
import Foundation
import Observation
import SwiftUI

/// What the panel's buttons do. The app wires these to the engine; previews leave them empty.
public struct PanelActions {
    public var hibernate: @MainActor ([ProcessGroup]) -> Void = { _ in }
    /// Stops groups the user already confirmed in place, with a two-click Stop button.
    public var stop: @MainActor ([ProcessGroup]) -> Void = { _ in }
    /// Asks in a dialog first; `scope` names what's stopping ("everything in meadow").
    public var confirmStop: @MainActor (_ scope: String, _ groups: [ProcessGroup]) -> Void = { _, _ in }
    public var open: @MainActor (String) -> Void = { _ in }
    public var setOpenAtLogin: @MainActor (Bool) -> Void = { _ in }
    public var installCommandLineTool: @MainActor () -> Void = {}
    public var checkForUpdates: @MainActor () -> Void = {}
    public var sendFeedback: @MainActor () -> Void = {}
    /// A toast's Undo, from its button or ⌘Z.
    public var undo: @MainActor (Toast.Action) -> Void = { _ in }
    public var installUpdate: @MainActor (UpdateCheck.Release) -> Void = { _ in }
    public var wake: @MainActor ([HibernationRecord]) -> Void = { _ in }
    public var forget: @MainActor ([HibernationRecord]) -> Void = { _ in }
    /// Moves idle worktrees to the Trash, confirmed in place with a two-click button.
    public var trash: @MainActor ([IdleWorktree]) -> Void = { _ in }
    /// Asks in a dialog first, for moving several at once.
    public var confirmTrash: @MainActor ([IdleWorktree]) -> Void = { _ in }
    public var reveal: @MainActor (String) -> Void = { _ in }
    public var openTerminal: @MainActor (String) -> Void = { _ in }
    public var copy: @MainActor (String) -> Void = { _ in }
    public var openSettings: @MainActor () -> Void = {}
    public var refresh: @MainActor () -> Void = {}
    public var quit: @MainActor () -> Void = {}

    public init() {}
}

public struct Toast: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Undo a hibernate: wake these records.
        case wake([UUID])
        /// Undo a forget: put these records back.
        case restore([HibernationRecord])
        /// Undo a move to the Trash: put these worktrees back where they were.
        case putBack([UUID])
    }

    public let id = UUID()
    public var message: String
    /// A second, quieter line, such as which sessions an action touched.
    public var detail: String?
    public var action: Action?
    public var actionTitle: String?

    public init(message: String, detail: String? = nil, action: Action? = nil, actionTitle: String? = nil) {
        self.message = message
        self.detail = detail
        self.action = action
        self.actionTitle = actionTitle
    }
}

/// The panel's two views: what's using memory, by worktree, and what idle worktrees take on disk.
public enum PanelTab: String, Sendable {
    case memory, disk
}

@MainActor @Observable
public final class PanelModel {
    public var snapshot: Snapshot
    public var tab: PanelTab = .memory
    public var hibernated: [HibernationRecord]
    public var expanded: Set<String> = []
    public var showsSmaller = false
    public var toast: Toast?
    /// The pointer is on the footer, so the toast there stays until it leaves.
    public var holdsToast = false
    /// A one-line heads-up above the list, e.g. that the menu bar icon is hidden.
    public var notice: String?
    /// Tallest the list may grow before it scrolls; the app sets it from the screen.
    public var maxListHeight: CGFloat = 560
    /// Previews render without a ScrollView, which ImageRenderer can't draw.
    public var scrolls = true
    /// Bumped each time the panel opens, to replay the header's entrance.
    public var openCount = 0
    /// The Stop button waiting for its second click. Only one is armed at a time.
    public private(set) var armed: String?
    @ObservationIgnored private var disarming: Task<Void, Never>?
    /// The card that explains the panel, shown until it's dismissed.
    public var showsWelcome = false
    /// Groups being stopped or hibernated right now. Their rows say so and offer nothing to click.
    public var stopping: Set<String> = []
    /// What Corral stopped, hibernated and woke, newest first.
    public var activity: [ActivityEntry] = []
    /// Linked worktrees with nothing running in them, and what moving each to the Trash
    /// frees. Nil until Corral has looked for them.
    public var disk: DiskReport?
    /// Worktrees going to the Trash right now. Their rows say so and offer nothing to click.
    public var trashing: Set<String> = []
    public var showsAllWorktrees = false
    /// Free space on the home disk, for the heads-up when it's nearly full.
    public var volume: VolumeSpace?
    /// "Later" on that heads-up hides it until then.
    public var diskNudgeHiddenUntil: Date?
    /// A newer release, once the daily check finds one.
    public var update: UpdateCheck.Release?
    /// The installer is running; Corral is about to quit and reopen.
    public var installing = false
    /// For the welcome card's setup buttons.
    public var opensAtLogin = false
    public var commandLineToolPath: String?
    public var now: Date
    public let settings: CorralSettings
    @ObservationIgnored public var actions = PanelActions()

    public init(snapshot: Snapshot = .empty, hibernated: [HibernationRecord] = [], settings: CorralSettings, now: Date = Date()) {
        self.snapshot = snapshot
        self.hibernated = hibernated
        self.settings = settings
        self.now = now
    }

    public var idleThreshold: TimeInterval { TimeInterval(settings.idleMinutes * 60) }

    /// The update to mention, unless the user put this one off.
    public var visibleUpdate: UpdateCheck.Release? {
        guard let update, update.version != settings.skippedUpdate else { return nil }
        return update
    }

    /// False in read-only mode, when the panel offers no stop or hibernate buttons.
    public var canAct: Bool { !settings.readOnly }

    /// What the panel offers for a group: the shared policy, plus the user's settings.
    public func policy(for group: ProcessGroup) -> StopPolicy {
        let policy = StopPolicy.of(group)
        if policy == .hibernate, let agent = group.agent, agent.host.bundleID == "com.anthropic.claudefordesktop",
           !settings.hibernateDesktopSessions {
            return .managed(.init(caption: agent.host.name, reason: "Hibernating Claude Desktop sessions is off in Corral's settings."))
        }
        return policy
    }

    /// Whether Hibernate may stop this agent now. Agents in the middle of a task are left alone.
    public func canHibernate(_ group: ProcessGroup) -> Bool {
        policy(for: group) == .hibernate && group.agent?.state != .working && !stopping.contains(group.id)
    }

    public func isIdle(_ group: ProcessGroup) -> Bool {
        (group.agent?.idleFor(now: now) ?? 0) >= idleThreshold
    }

    /// Agents the footer's Hibernate button will stop.
    public var idleAgents: [ProcessGroup] { idleAgents(in: snapshot) }

    public func idleAgents(in snapshot: Snapshot, now: Date = Date()) -> [ProcessGroup] {
        snapshot.agents.filter { canHibernate($0) && ($0.agent?.idleFor(now: now) ?? 0) >= idleThreshold }
    }

    public func idleAgents(in checkout: Checkout) -> [ProcessGroup] {
        checkout.agents.filter { canHibernate($0) && isIdle($0) }
    }

    /// A checkout's servers, when leaked ones are all that run in it: stopping them all is safe.
    public func leakedOnly(_ checkout: Checkout) -> [ProcessGroup] {
        let leaked = checkout.groups.filter { $0.bucket == .leaked }
        return !leaked.isEmpty && leaked.count == checkout.groups.count ? leaked : []
    }

    /// Idle worktrees the Disk tab can move to the Trash right now.
    public var trashable: [IdleWorktree] {
        guard canAct, let disk else { return [] }
        return disk.safe.filter { !trashing.contains($0.id) }
    }

    /// Switches tabs on the panel's spring, from the tabs or ⌘1 and ⌘2.
    public func select(_ tab: PanelTab) {
        guard tab != self.tab else { return }
        disarm()
        withAnimation(Motion.layout) { self.tab = tab }
    }

    /// Leaked servers, biggest first, minus any the user chose to keep.
    public var leakedServers: [ProcessGroup] {
        snapshot.checkouts.flatMap(\.groups)
            .filter { $0.bucket == .leaked && policy(for: $0) == .stop && !settings.keptServers.contains($0.id) }
            .sorted { $0.memory > $1.memory }
    }

    /// Stops suggesting these. Ids name one run of a process, so a restarted server shows up again.
    public func keep(_ groups: [ProcessGroup]) {
        let live = Set(snapshot.checkouts.flatMap(\.groups).map(\.id))
        settings.keptServers = settings.keptServers.filter(live.contains).union(groups.map(\.id))
    }

    /// Arms a Stop button for its second click, until it's used or a few seconds pass.
    public func arm(_ id: String) {
        armed = id
        disarming?.cancel()
        disarming = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.armed == id else { return }
            self?.armed = nil
        }
    }

    public func disarm() {
        disarming?.cancel()
        armed = nil
    }

    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// What the heads-up above the list says: the disk is nearly full, and idle worktrees on it
    /// that are safe to move could free at least a gigabyte. Quiet on the Disk tab or after Later.
    public var diskNudge: (volume: VolumeSpace, freeable: UInt64)? {
        guard let volume, volume.isLow, let disk, tab != .disk else { return nil }
        if let until = diskNudgeHiddenUntil, until > now { return nil }
        let freeable = DiskReport.freeable(disk.worktrees.filter { $0.canTrash && $0.usage?.device == volume.device })
        return freeable >= 1 << 30 ? (volume, freeable) : nil
    }

    /// The checkouts that get their own row; the rest fold into "N smaller checkouts".
    public var layout: (primary: [Checkout], smaller: [Checkout]) {
        let all = snapshot.checkouts
        let floor = max(UInt64(300) << 20, snapshot.checkoutMemory / 50)
        var primary: [Checkout] = []
        var smaller: [Checkout] = []
        for checkout in all {
            let working = checkout.agents.contains { $0.agent?.state == .working }
            // An open row stays in view when the smaller ones fold away. While they show, rows
            // keep their places, so opening one doesn't move it.
            if primary.count < 8, checkout.memory >= floor || working || (expanded.contains(checkout.id) && !showsSmaller) {
                primary.append(checkout)
            } else {
                smaller.append(checkout)
            }
        }
        if smaller.count == 1 { return (primary + smaller, []) }
        return (primary, smaller)
    }
}
