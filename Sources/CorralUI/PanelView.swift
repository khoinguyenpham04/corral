import CorralCore
import SwiftUI

/// The menu bar panel: a header with two tabs and a bar split by kind and by worktree, a row
/// per worktree (or idle worktree, on Disk), and a footer with the ways to free memory.
public struct PanelView: View {
    let model: PanelModel

    public init(model: PanelModel) {
        self.model = model
    }

    public var body: some View {
        Themed { PanelBody(model: model) }
    }
}

struct PanelBody: View {
    @Environment(\.palette) private var palette
    let model: PanelModel
    @State private var contentHeight: CGFloat = 0
    /// The panel opening this height was measured in, so a fresh open doesn't animate it.
    @State private var measuredOpen = 0
    @State private var folds = FoldTracker()
    @State private var focus = Focus()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            DashRule(color: palette.rim).padding(.horizontal, Metrics.inset)
            list
            DashRule(color: palette.rim).padding(.horizontal, Metrics.inset)
            FooterView(model: model)
        }
        .environment(focus)
        .environment(\.opening, model.openCount)
        // A row that goes away under the pointer never hears it leave, so start each tab, and
        // each opening, with nothing lit.
        .onChange(of: model.tab) { focus.clear() }
        .onChange(of: model.openCount) {
            focus.clear()
            // The list may open at the height it closed at, and then says nothing: from the next
            // turn on, changes spring rather than snap.
            Task { @MainActor in measuredOpen = model.openCount }
        }
        .frame(width: Metrics.panelWidth)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(palette.rim, lineWidth: 1)
        }
    }

    @ViewBuilder private var list: some View {
        if model.scrolls {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    pages.environment(\.folds, folds).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        // Grow and shrink with the rows, on their spring, so the footer moves
                        // with them instead of jumping ahead. A row folding away shrinks frame
                        // by frame, so then the height just follows it.
                        if measuredOpen != model.openCount || contentHeight == 0 || folds.active > 0 {
                            measuredOpen = model.openCount
                            contentHeight = height
                        } else {
                            withAnimation(Motion.layout) { contentHeight = height }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: min(max(contentHeight, 40), model.maxListHeight))
                // A row opened near the bottom scrolls up into view.
                .onChange(of: model.expanded) { old, new in
                    guard let opened = new.subtracting(old).first else { return }
                    withAnimation(Motion.layout) { proxy.scrollTo(opened) }
                }
                .onChange(of: model.showsSmaller) {
                    if model.showsSmaller { withAnimation(Motion.layout) { proxy.scrollTo("smaller") } }
                }
                // Each tab starts at its top.
                .onChange(of: model.tab) { proxy.scrollTo("top", anchor: .top) }
            }
        } else {
            pages
        }
    }

    /// The tab on show. The one you pick comes in from its side while the other fades out,
    /// both in one place, so the list's height goes straight from one to the other.
    private var pages: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).id("top")
            ZStack(alignment: .top) {
                switch model.tab {
                case .memory: MemoryPage(model: model).transition(Motion.page(from: .leading))
                case .disk: DiskPage(model: model).transition(Motion.page(from: .trailing))
                }
            }
        }
    }
}

/// Worktrees, biggest first, then everything else on one line each.
struct MemoryPage: View {
    @Environment(\.palette) private var palette
    let model: PanelModel

    var body: some View {
        let layout = model.layout
        let snapshot = model.snapshot
        VStack(spacing: 0) {
            Banners(model: model)
            VStack(spacing: 0) {
                if snapshot.checkouts.isEmpty {
                    EmptyState(looking: snapshot.takenAt == .distantPast)
                }
                // One list, so a row keeps its place and state when it moves between the two,
                // as a smaller one does when it's opened.
                ForEach(model.showsSmaller ? layout.primary + layout.smaller : layout.primary) { checkout in
                    WorktreeRow(checkout: checkout, model: model).id(checkout.id)
                }
                if !layout.smaller.isEmpty {
                    MoreLink(
                        title: "\(layout.smaller.count) more worktrees · \(Format.bytes(layout.smaller.reduce(0) { $0 + $1.memory }))",
                        open: model.showsSmaller
                    ) {
                        model.showsSmaller.toggle()
                    }
                    .id("smaller")
                }
            }
            .padding(8)
            DashRule(color: palette.rim).padding(.horizontal, Metrics.inset)
            Ledger(model: model)
        }
    }
}

/// Notes above the list: the welcome card, a hidden menu bar icon, an update, a nearly full disk.
struct Banners: View {
    let model: PanelModel

    var body: some View {
        let memory = model.tab == .memory
        let welcome = memory && model.showsWelcome
        let notice = welcome ? nil : model.notice
        let update = model.visibleUpdate
        let nudge = memory ? model.diskNudge : nil
        VStack(spacing: 0) {
            if welcome {
                WelcomeCard(model: model) {
                    UserDefaults.standard.set(true, forKey: "welcomeDismissed")
                    withAnimation(Motion.layout) { model.showsWelcome = false }
                }
            } else if let notice {
                NoticeView(text: notice) {
                    UserDefaults.standard.set(true, forKey: "hiddenIconNoticeDismissed")
                    withAnimation(Motion.layout) { model.notice = nil }
                }
            }
            if let update {
                UpdateBanner(release: update, model: model)
            }
            if let nudge {
                DiskNudge(volume: nudge.volume, freeable: nudge.freeable, model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(.top, welcome || notice != nil || update != nil || nudge != nil ? 8 : 0)
    }
}

// MARK: Header

struct HeaderView: View {
    @Environment(\.palette) private var palette
    let model: PanelModel
    @State private var drift: Double = 1
    /// How much of the bar shows, swept in from the left when the panel opens.
    @State private var sweep: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 7) {
                    Sparkle().fill(palette.ember).frame(width: 13, height: 13)
                    Text("Corral").font(Typeface.wordmark()).foregroundStyle(palette.text)
                }
                Spacer()
                TabStrip(model: model)
            }
            figure.padding(.top, 14)
            bar.padding(.top, 13).zIndex(1)
            legend.padding(.top, 11)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .background(alignment: .top) {
            // The dashes ride between the wordmark and the switch, clear of both.
            WaveField(
                line: palette.ember, accents: [palette.mango, palette.pink, palette.lavender],
                drift: drift, strength: palette.isDark ? 1 : 0.75, dashesAt: 0.30
            )
            .frame(height: 168)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
            .mask(LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8), .black], startPoint: .leading, endPoint: .trailing))
            .allowsHitTesting(false)
        }
        .onChange(of: model.openCount) {
            guard !Motion.reduced else { return }
            drift = 0
            sweep = 0
            withAnimation(.easeOut(duration: 1.8)) { drift = 1 }
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45).delay(0.06)) { sweep = 1 }
        }
    }

    /// The big number: worktree memory, or what idle worktrees free. It rolls from one to the other.
    private var figure: some View {
        let memory = model.tab == .memory
        let bytes = memory ? model.snapshot.trackedMemory : model.disk?.freeable
        let parts = bytes.map(Format.bytesParts) ?? (value: "—", unit: "")
        return HStack(alignment: .lastTextBaseline, spacing: 5) {
            Text(parts.value)
                .font(Typeface.figure)
                .tracking(-0.9)
                .foregroundStyle(palette.text)
                .contentTransition(.numericText(value: Double(bytes ?? 0)))
            Text(parts.unit).font(.system(size: 11, design: .monospaced)).tracking(0.5).foregroundStyle(palette.text3)
            Spacer()
            ZStack(alignment: .trailing) {
                if memory {
                    memorySide.transition(.opacity)
                } else {
                    diskSide.transition(.opacity)
                }
            }
            .padding(.bottom, 5)
        }
    }

    private var memorySide: some View {
        let system = model.snapshot.system
        return VStack(alignment: .trailing, spacing: 5) {
            // Quiet while all is well; when macOS says memory is tight, it says so here.
            if system.pressure != .normal {
                let color = palette.color(for: system.pressure)
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(system.pressure == .critical ? "pressure critical" : "pressure high").smallCaps(color)
                }
                .help("Memory pressure, as macOS reports it")
                .transition(.opacity)
            }
            Text("of \(Format.capacity(system.physical)) RAM").smallCaps(palette.text3)
            if system.swapUsed > 1 << 28 {
                Text("swap \(Format.bytes(system.swapUsed))").smallCaps(system.swapUsed > system.physical / 4 ? palette.ember : palette.text3)
            }
        }
    }

    @ViewBuilder private var diskSide: some View {
        if let volume = model.volume {
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(Format.disk(volume.available)) free").smallCaps(volume.isLow ? palette.ember : palette.text3)
                Text("of \(Format.disk(volume.total))").smallCaps(palette.text3)
            }
        }
    }

    @ViewBuilder private var bar: some View {
        let snapshot = model.snapshot
        ZStack {
            if model.tab == .memory {
                SplitBar(
                    groups: Bars.memory(snapshot, palette: palette),
                    scale: max(snapshot.system.physical, snapshot.trackedMemory), reveal: sweep
                )
                .transition(.opacity)
            } else {
                SplitBar(groups: model.disk.map { Bars.disk($0, palette: palette) } ?? [], scale: 0, reveal: sweep)
                    .transition(.opacity)
            }
        }
    }

    private var legend: some View {
        ZStack(alignment: .leading) {
            if model.tab == .memory {
                let breakdown = model.snapshot.breakdown
                BarLegend(items: Bars.kinds.filter { $0 != .other && breakdown[$0] > 0 }.map {
                    BarLegend.Item(label: $0.label, fill: Bars.fill($0, palette))
                })
                .transition(.opacity)
            } else {
                let worktrees = model.disk?.worktrees ?? []
                BarLegend(items: [
                    worktrees.contains(where: \.canTrash) ? BarLegend.Item(label: "Safe to remove", fill: .solid(palette.text.opacity(0.85))) : nil,
                    worktrees.contains { !$0.holds.isEmpty } ? BarLegend.Item(label: "Has work in it", fill: .hatch(palette.mango)) : nil,
                ].compactMap { $0 })
                .transition(.opacity)
            }
        }
        // As tall with no labels as with, so switching tabs never moves the list.
        .frame(maxWidth: .infinity, minHeight: 12, alignment: .leading)
    }
}

extension WaveField: Animatable {
    nonisolated var animatableData: Double {
        get { drift }
        set { drift = newValue }
    }
}

/// Memory or Disk: a segmented switch in a capsule. The side you're on is lit, with its icon
/// in ember, and the light slides across when you switch.
struct TabStrip: View {
    @Environment(\.palette) private var palette
    let model: PanelModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            TabSegment(title: "Memory", symbol: "memorychip", selected: model.tab == .memory, help: "What's using memory, by worktree · ⌘1") {
                model.select(.memory)
            }
            .matchedGeometryEffect(id: PanelTab.memory, in: selection)
            TabSegment(title: "Disk", symbol: "internaldrive", selected: model.tab == .disk, help: "Idle worktrees and the disk they take · ⌘2") {
                model.select(.disk)
            }
            .matchedGeometryEffect(id: PanelTab.disk, in: selection)
        }
        .padding(2)
        // Opaque, so the wave art behind the header never shows through the labels.
        .background {
            Capsule()
                .fill(palette.isDark ? Color(hex: 0x333333) : .white)
                .overlay(Capsule().strokeBorder(palette.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05), lineWidth: 0.5))
                .shadow(color: .black.opacity(palette.isDark ? 0.25 : 0.1), radius: 1.5, y: 0.5)
                .matchedGeometryEffect(id: model.tab, in: selection, isSource: false)
        }
        .background(Capsule().fill(palette.isDark ? Color(hex: 0x1F1F1F) : Color(hex: 0xEFEFEF)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }
}

struct TabSegment: View {
    @Environment(\.palette) private var palette
    let title: String
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? palette.ember : (hovering ? palette.text2 : palette.text3))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(selected || hovering ? palette.text : palette.text2)
            }
            .padding(.horizontal, 11)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .help(help)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Footer

/// The ways to free space, in Corral's capsules. A toast takes the footer's place for a few
/// seconds; clicking it puts the buttons back.
struct FooterView: View {
    let model: PanelModel
    /// Just after a toast goes, so a click meant for its Undo doesn't land on the button
    /// fading in where it was.
    @State private var settling = false

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ToastBar(toast: toast, model: model)
                    .id(toast.id)
                    .transition(Motion.rise)
            } else {
                Group {
                    switch model.tab {
                    case .memory: MemoryControls(model: model)
                    case .disk: DiskControls(model: model)
                    }
                }
                .allowsHitTesting(!settling)
                .transition(.opacity)
            }
        }
        .frame(height: 52)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        // A toast stays while the pointer rests on it: someone's reading it, or reaching for Undo.
        .onHover { model.holdsToast = $0 }
        .onChange(of: model.toast?.id) { old, new in
            guard old != nil, new == nil else { return }
            settling = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                settling = false
            }
        }
        .animation(Motion.swap, value: model.toast?.id)
    }
}

/// Stop the leaked servers (two clicks), hibernate the idle agents (one, with Undo).
struct MemoryControls: View {
    @Environment(\.palette) private var palette
    let model: PanelModel

    var body: some View {
        let leaked = model.leakedServers.filter { !model.stopping.contains($0.id) }
        let idle = model.idleAgents
        let stopping = model.snapshot.allGroups.filter { model.stopping.contains($0.id) }
        let hibernating = stopping.contains { $0.agent != nil && model.policy(for: $0) == .hibernate }
        HStack(spacing: 8) {
            if model.canAct {
                if !leaked.isEmpty {
                    // Arming covers exactly these servers. If one exits or another leaks, it asks again.
                    TwoClickCapsule(
                        id: "leaked:" + leaked.map(\.id).sorted().joined(separator: ","), model: model,
                        title: "Stop \(leaked.count) leaked", armedTitle: "Stop \(leaked.count) now", amount: leaked.reduce(0) { $0 + $1.memory },
                        help: "\(Format.names(leaked.map(\.displayTitle), limit: 2)): still running after whatever started \(leaked.count == 1 ? "it" : "them") closed. Right-click to keep \(leaked.count == 1 ? "it" : "them").",
                        armedHelp: "Click again to stop \(leaked.count == 1 ? "it" : "them"). \(leaked.count == 1 ? "It won't restart on its" : "They won't restart on their") own."
                    ) {
                        model.actions.stop(leaked)
                    }
                    .contextMenu {
                        Button(leaked.count == 1 ? "Keep It Running" : "Keep Them Running") { withAnimation(Motion.layout) { model.keep(leaked) } }
                    }
                    .transition(.opacity)
                } else if stopping.contains(where: { $0.agent == nil }) {
                    Quiet(text: "Stopping…").transition(.opacity)
                }
                Spacer(minLength: 0)
                if !idle.isEmpty {
                    Button {
                        model.actions.hibernate(idle)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "moon.fill").font(.system(size: 10))
                            Text("Hibernate \(idle.count)")
                            Text(Format.bytes(idle.reduce(0) { $0 + $1.memory })).font(.system(size: 10.5, weight: .medium, design: .monospaced)).opacity(0.75)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(CapsuleStyle(kind: .ember))
                    .help("Stops \(Format.names(idle.map(\.displayTitle), limit: 3)). Their sessions stay, so you can wake them from Corral or with `corral wake`.")
                    .transition(.opacity)
                } else {
                    Quiet(symbol: "moon.fill", text: hibernating ? "Hibernating…" : "No idle agents")
                        .help(hibernating ? "" : "Nothing to hibernate: no agent has been idle for \(model.settings.idleMinutes) min.")
                        .transition(.opacity)
                }
            } else {
                Spacer(minLength: 0)
                ReadOnlyLabel()
            }
            MoreMenu(model: model)
        }
        .animation(Motion.swap, value: leaked.map(\.id))
        .animation(Motion.swap, value: idle.map(\.id))
    }
}

/// Move the idle worktrees that are safe to remove to the Trash, in two clicks.
struct DiskControls: View {
    let model: PanelModel

    var body: some View {
        let safe = model.trashable
        HStack(spacing: 8) {
            if let progress = model.disk?.progress {
                Quiet(text: "Measuring \(progress.done) of \(progress.total)…")
            } else if !safe.isEmpty {
                Quiet(text: "Branches always stay")
            }
            Spacer(minLength: 0)
            if !model.canAct {
                ReadOnlyLabel()
            } else if !safe.isEmpty {
                TwoClickCapsule(
                    id: "trash-all:" + safe.map(\.id).sorted().joined(separator: ","), model: model,
                    title: "Move \(safe.count) to Trash", armedTitle: "Move \(safe.count) now", amount: DiskReport.freeable(safe),
                    help: "Nothing uncommitted, no commits off a branch, nothing running. Corral checks each again right before moving it, and Undo puts them back.",
                    armedHelp: "Click again to move \(safe.count == 1 ? "it" : "them") to the Trash. Branches stay; files git ignores, like .env, go along."
                ) {
                    model.actions.trash(safe)
                }
                .transition(.opacity)
            }
            MoreMenu(model: model)
        }
        .animation(Motion.swap, value: safe.map(\.id))
    }
}

/// A quiet line in the footer, where a button would be.
struct Quiet: View {
    @Environment(\.palette) private var palette
    var symbol: String?
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.text3)
    }
}

struct ReadOnlyLabel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Label("Read-only", systemImage: "lock")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.text3)
            .help("Read-only mode is on: Corral shows memory and disk use, and never stops or moves anything. Change it in Settings.")
    }
}

struct MoreMenu: View {
    @Environment(\.palette) private var palette
    let model: PanelModel

    var body: some View {
        if model.scrolls {
            Menu {
                Button("Settings…") { model.actions.openSettings() }
                Button("Check for Updates") { model.actions.checkForUpdates() }
                Button("Send Feedback…") { model.actions.sendFeedback() }
                Button("Refresh") { model.actions.refresh() }
                Divider()
                Button("Quit Corral") { model.actions.quit() }
            } label: {
                dots
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            dots
        }
    }

    private var dots: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.text2)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
}

/// What just happened, in the footer's place: a line, a quieter one under it, and Undo.
struct ToastBar: View {
    @Environment(\.palette) private var palette
    let toast: Toast
    let model: PanelModel

    var body: some View {
        HStack(spacing: 10) {
            Sparkle().fill(palette.ember).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                if let detail = toast.detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(palette.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let title = toast.actionTitle, let action = toast.action {
                ToastAction(title: title) {
                    model.toast = nil
                    model.actions.undo(action)
                }
            }
            IconButton(symbol: "xmark", help: "Dismiss") { model.toast = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help([toast.message, toast.detail].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
    }
}

private struct ToastAction: View {
    @Environment(\.palette) private var palette
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ember)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(hovering ? palette.hover : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }
}

struct NoticeView: View {
    @Environment(\.palette) private var palette
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "menubar.rectangle").font(.system(size: 12)).foregroundStyle(palette.mango).padding(.top, 1)
            Text(text).font(Typeface.caption).foregroundStyle(palette.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Don't show again", action: dismiss)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.mango.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.mango.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct EmptyState: View {
    @Environment(\.palette) private var palette
    /// Corral hasn't looked yet: it just started.
    var looking = false

    var body: some View {
        VStack(spacing: 10) {
            Sparkle().stroke(palette.ember, lineWidth: 1).frame(width: 24, height: 24)
            Text(looking ? "Looking at what's running…" : "Nothing running in a checkout").font(Typeface.title).foregroundStyle(palette.text)
            if !looking {
                Text("Corral watches git worktrees, dev servers and coding agents. Start one and it shows up here.")
                    .font(Typeface.caption)
                    .foregroundStyle(palette.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }
}
