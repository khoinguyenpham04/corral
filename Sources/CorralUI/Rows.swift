import AppKit
import CorralCore
import SwiftUI

// MARK: Worktrees

/// A checkout on one line: a rail that's its slice of the bar, its name, one line that says
/// what runs in it with the ports it serves, its idle agents and its memory. Click it to see
/// what's inside, fenced in under it.
struct WorktreeRow: View {
    @Environment(\.palette) private var palette
    @Environment(Focus.self) private var focus
    @Environment(\.opening) private var opening
    let checkout: Checkout
    let model: PanelModel
    @State private var hovering = false

    /// Arming covers exactly these servers. If one exits or another leaks, it asks again.
    private static func stopID(_ checkout: Checkout, _ leaked: [ProcessGroup]) -> String {
        "wt:\(checkout.id):" + leaked.map(\.id).sorted().joined(separator: ",")
    }

    var body: some View {
        let open = model.expanded.contains(checkout.id)
        VStack(alignment: .leading, spacing: 0) {
            face(open: open)
            Fold(open: open) {
                WorktreeInside(checkout: checkout, model: model)
            }
        }
        .contextMenu { menu }
    }

    private func face(open: Bool) -> some View {
        let leaked = model.leakedOnly(checkout)
        let idle = model.idleAgents(in: checkout)
        let busy = checkout.groups.contains { model.stopping.contains($0.id) }
        let stopID = Self.stopID(checkout, leaked)
        let status = Self.status(checkout, model: model)
        let toggle = { withAnimation(Motion.layout) { model.toggle(checkout.id) } }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(checkout.name)
                    .font(Typeface.title)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                StatusLine(parts: status, model: model)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { Rail(pieces: Bars.rail(checkout, palette: palette)).frame(width: 3) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityAction { toggle() }
            .accessibilityActions {
                ForEach(status.compactMap(\.port), id: \.self) { port in
                    Button("Open localhost:" + String(port)) { model.actions.open("http://localhost:\(port)") }
                }
            }
            HStack(spacing: 9) {
                if model.canAct, !leaked.isEmpty, !busy, hovering || model.armed == stopID {
                    TwoClickCapsule(
                        id: stopID, model: model, title: "Stop", armedTitle: "Stop?", small: true,
                        help: "Stop \(Format.names(leaked.map(\.displayTitle), limit: 1)). Whatever started \(leaked.count == 1 ? "it" : "them") has closed.",
                        armedHelp: "Click again to stop. \(leaked.count == 1 ? "It" : "They") won't restart on \(leaked.count == 1 ? "its" : "their") own."
                    ) {
                        model.actions.stop(leaked)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                }
                if !idle.isEmpty {
                    MoonButton(count: idle.count, enabled: model.canAct, help: "Hibernate \(Format.names(idle.map { "“\($0.displayTitle)”" }, limit: 2))") {
                        model.actions.hibernate(idle)
                    }
                }
                Text(Format.bytes(checkout.memory))
                    .font(Typeface.number)
                    .foregroundStyle(leaked.isEmpty ? palette.text : palette.text2)
                    .contentTransition(.numericText(value: Double(checkout.memory)))
                    .frame(minWidth: 50, alignment: .trailing)
            }
            .animation(Motion.swap, value: model.armed)
            .animation(Motion.swap, value: busy)
        }
        .padding(.top, 9)
        .padding(.bottom, open ? 5 : 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering && !open ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.hover) {
                hovering = inside
                if !inside, model.armed == stopID { model.disarm() }
            }
            focus.hover(checkout.id, inside)
        }
        .onChange(of: opening) { hovering = false }
        .onTapGesture { toggle() }
    }

    @ViewBuilder private var menu: some View {
        if !checkout.isMissing {
            Button("Reveal in Finder") { model.actions.reveal(checkout.path) }
            Button("Open in Terminal") { model.actions.openTerminal(checkout.path) }
        }
        Button("Copy Path") { model.actions.copy(checkout.path) }
        if model.canAct {
            let leaked = checkout.groups.filter { $0.bucket == .leaked && model.policy(for: $0) == .stop }
            if !leaked.isEmpty, !leaked.allSatisfy({ model.settings.keptServers.contains($0.id) }) {
                Button("Keep Running") { withAnimation(Motion.layout) { model.keep(leaked) } }
            }
            Divider()
            Button("Stop Everything Here…") { model.actions.confirmStop("everything in \(checkout.name)", checkout.groups) }
        }
    }

    /// Trouble first, then where it is, the ports it serves, what's running and when it was
    /// last touched: "Leaked · :4323 · running 11 d", "main · :4461 · 4 agents · ✦ 1 working".
    static func status(_ checkout: Checkout, model: PanelModel) -> [StatusPart] {
        let groups = checkout.groups
        let busy = groups.filter { model.stopping.contains($0.id) }
        let busyPart = busy.isEmpty ? nil : StatusPart(
            id: "busy", look: .busy, text: busy.contains { $0.agent != nil && model.policy(for: $0) == .hibernate } ? "Hibernating…" : "Stopping…", keep: 95
        )

        var seen: [Int] = []
        for group in groups where [.stacks, .leaked, .other].contains(group.bucket) {
            if let port = group.ports.first, !seen.contains(port) { seen.append(port) }
        }
        var ports = seen.prefix(2).enumerated().map { index, port in
            StatusPart(id: "port\(port)", look: .port(port), text: ":\(port)", keep: index == 0 ? 90 : 80)
        }
        if seen.count > 2 { ports.append(StatusPart(id: "more", look: .more, text: "+\(seen.count - 2)", keep: 70)) }

        if !model.leakedOnly(checkout).isEmpty {
            let since = groups.map(\.startedAt).min() ?? model.now
            let gone = checkout.kind == .worktree ? "worktree deleted" : "folder deleted"
            let age = StatusPart(id: "since", look: .plain, text: checkout.isMissing ? gone : "running " + Format.duration(model.now.timeIntervalSince(since)), keep: 85)
            return [StatusPart(id: "leaked", look: .leaked, text: "Leaked", keep: 100)] + ports + [busyPart ?? age]
        }

        // Its name says which checkout it is; this says what the name doesn't.
        let place: String? = switch checkout.kind {
        case .main: checkout.branch
        case .worktree: checkout.repoName
        case .project: "folder"
        }
        var parts = place.map { [StatusPart(id: "place", look: .plain, text: $0, keep: 100)] } ?? []
        parts += ports
        var builds: [String] = []
        for group in groups where group.bucket == .build {
            let name = group.titleWithoutPort.split(separator: " ").first.map(String.init) ?? group.title
            if !builds.contains(name) { builds.append(name) }
        }
        if !builds.isEmpty { parts.append(StatusPart(id: "builds", look: .plain, text: builds.joined(separator: ", "), keep: 60)) }
        if let busyPart { return parts + [busyPart] }

        let agents = checkout.agents
        let working = agents.filter { $0.agent?.state == .working }.count
        if agents.count > 1 { parts.append(StatusPart(id: "agents", look: .plain, text: "\(agents.count) agents", keep: 50)) }
        if working > 0 {
            parts.append(StatusPart(id: "state", look: .working, text: agents.count == 1 ? "Working" : "\(working) working", keep: 88))
        } else if agents.contains(where: { $0.agent?.state == .waiting }) {
            parts.append(StatusPart(id: "state", look: .attention, text: "needs you", keep: 87))
        } else if agents.count == 1, ports.isEmpty, builds.isEmpty, let agent = agents[0].agent {
            parts.append(StatusPart(id: "when", look: .plain, text: Format.idle(agent.idleFor(now: model.now)).lowercased(), keep: 40))
        } else if let edited = checkout.lastEdited {
            parts.append(StatusPart(id: "when", look: .plain, text: "edited " + Format.ago(model.now.timeIntervalSince(edited)), keep: 40))
        }
        return parts
    }
}

/// One piece of a row's line. When space runs out, the pieces with the lowest `keep` go
/// first, whole, with their separators; the first piece always stays.
struct StatusPart: Hashable, Identifiable {
    enum Look: Hashable {
        case plain, port(Int), more, working, attention, busy, leaked
    }

    let id: String
    let look: Look
    let text: String
    let keep: Int

    var port: Int? {
        if case let .port(port) = look { port } else { nil }
    }
}

/// A row's one line. Ports are links. When it doesn't fit, the least important pieces drop
/// out whole rather than everything shrinking into ellipses.
struct StatusLine: View {
    @Environment(\.palette) private var palette
    let parts: [StatusPart]
    let model: PanelModel

    var body: some View {
        if let first = parts.first {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(Self.fallbacks(parts).enumerated()), id: \.offset) { _, shown in
                    line(shown, fits: true)
                }
                // Only the first piece, and even that gives way to an ellipsis if it must.
                line([first], fits: false)
            }
        }
    }

    /// The line with fewer and fewer pieces: each time, the least important one goes.
    static func fallbacks(_ parts: [StatusPart]) -> [[StatusPart]] {
        var shown = parts
        var result = [shown]
        while shown.count > 1,
              let drop = shown.indices.dropFirst().min(by: { (shown[$0].keep, -$0) < (shown[$1].keep, -$1) }) {
            shown.remove(at: drop)
            result.append(shown)
        }
        return result
    }

    private func line(_ shown: [StatusPart], fits: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, part in
                HStack(spacing: 0) {
                    if index > 0 { Text(verbatim: " · ") }
                    view(part)
                }
                .fixedSize(horizontal: fits, vertical: false)
            }
        }
        .font(Typeface.status)
        .foregroundStyle(palette.text2)
        .lineLimit(1)
    }

    @ViewBuilder private func view(_ part: StatusPart) -> some View {
        switch part.look {
        case .plain:
            Text(part.text)
        case let .port(port):
            PortToken(port: port) { model.actions.open("http://localhost:\(port)") }
        case .more:
            Text(part.text).font(Typeface.port).foregroundStyle(palette.text3)
        case .working:
            HStack(spacing: 3) {
                Sparkle().fill(palette.ember).frame(width: 8, height: 8)
                Text(part.text)
            }
            .foregroundStyle(palette.ember)
        case .attention:
            Text(part.text).foregroundStyle(palette.mangoText)
        case .busy:
            Text(part.text).foregroundStyle(palette.ember)
        case .leaked:
            HStack(spacing: 5) {
                Hatch(color: palette.coral).frame(width: 8, height: 8).clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                Text(part.text)
            }
        }
    }
}

/// What runs in a checkout, servers first: each with its port, what it is, and buttons on hover.
struct WorktreeInside: View {
    let checkout: Checkout
    let model: PanelModel

    static let order: [Bucket] = [.leaked, .stacks, .build, .agents, .shared, .other]

    var body: some View {
        // Servers first, then builds, then agents with the busy ones on top, then the rest.
        let rank = { (group: ProcessGroup) -> (Int, Int) in
            let state = switch group.agent?.state {
            case .working: 0
            case .waiting: 1
            default: 2
            }
            return (Self.order.firstIndex(of: group.bucket) ?? Self.order.count, state)
        }
        let visible = checkout.groups
            .filter { $0.memory >= 4 << 20 || $0.agent != nil || !$0.ports.isEmpty }
            .sorted { (rank($0).0, rank($0).1, $1.memory) < (rank($1).0, rank($1).1, $0.memory) }
        Fenced {
            ForEach(visible) { group in
                GroupKid(group: group, model: model)
            }
            PathLine(checkout: checkout, model: model)
        }
    }
}

/// What's inside a row, fenced in by a dashed line that carries on down from the row's rail.
struct Fenced<Content: View>: View {
    @Environment(\.palette) private var palette
    /// Where the fence stands, from the row's edge: under the rail.
    var at: CGFloat = 11
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.leading, 21)
            .padding(.vertical, 2)
            .background(alignment: .leading) { Fence(color: palette.text3.opacity(0.7)) }
            .padding(.leading, at)
            .padding(.trailing, 10)
            .padding(.bottom, 8)
    }
}

/// One thing inside a row: a lead (its port, or what kind of thing it is), its name with a
/// quiet caption, buttons while the pointer is over it, and its memory.
struct KidRow<Lead: View, Acts: View, Trailing: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.opening) private var opening
    let title: Text
    var caption: Text?
    var memory: UInt64?
    /// Keeps the buttons showing, while one of them is armed.
    var pinned = false
    var onExit: () -> Void = {}
    @ViewBuilder let lead: () -> Lead
    @ViewBuilder let acts: () -> Acts
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Wide enough for a five-digit port, which ephemeral and proxy ports have.
            lead().frame(width: 48, alignment: .leading)
            (caption.map { title + Text(verbatim: "  ") + $0.font(Typeface.caption).foregroundStyle(palette.text3) } ?? title)
                .font(Typeface.body)
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if hovering || pinned { acts().transition(.opacity) }
                trailing()
                if let memory {
                    Text(Format.bytes(memory))
                        .font(Typeface.smallNumber)
                        .foregroundStyle(palette.text2)
                        .contentTransition(.numericText(value: Double(memory)))
                        .frame(minWidth: 50, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.hover) { hovering = inside }
            if !inside { onExit() }
        }
        .onChange(of: opening) { hovering = false }
    }
}

extension KidRow where Trailing == EmptyView {
    init(
        title: Text, caption: Text? = nil, memory: UInt64? = nil, pinned: Bool = false, onExit: @escaping () -> Void = {},
        @ViewBuilder lead: @escaping () -> Lead, @ViewBuilder acts: @escaping () -> Acts
    ) {
        self.init(title: title, caption: caption, memory: memory, pinned: pinned, onExit: onExit, lead: lead, acts: acts, trailing: { EmptyView() })
    }
}

/// A server, build, agent or service inside a row, with what can be done to it.
struct GroupKid: View {
    @Environment(\.palette) private var palette
    let group: ProcessGroup
    let model: PanelModel

    var body: some View {
        let policy = model.policy(for: group)
        let busy = model.stopping.contains(group.id)
        KidRow(
            title: Text(group.agent == nil ? group.titleWithoutPort : group.displayTitle),
            caption: caption(policy, busy: busy),
            memory: group.memory,
            pinned: model.armed == group.id,
            onExit: { if model.armed == group.id { withAnimation(Motion.swap) { model.disarm() } } }
        ) {
            lead(policy)
        } acts: {
            if !busy { acts(policy) }
        }
        .help(tooltip(policy))
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if group.agent == nil, let port = group.ports.first {
                Button("Open localhost:" + String(port)) { model.actions.open("http://localhost:\(port)") }
            }
            if model.canAct, model.canHibernate(group) {
                Button("Hibernate") { model.actions.hibernate([group]) }
            }
            if model.canAct, policy == .stop {
                Button("Stop…") { model.actions.confirmStop(group.displayTitle, [group]) }
            }
        }
    }

    /// How you reach it, or what kind of thing it is: its port, a hammer for a build, the
    /// sparkle for an agent (filled while it works), the moon once it's idle enough to hibernate.
    @ViewBuilder private func lead(_ policy: StopPolicy) -> some View {
        if let agent = group.agent {
            switch agent.state {
            case .working:
                Sparkle().fill(palette.ember).frame(width: 10, height: 10)
            case .waiting:
                Sparkle().stroke(palette.mango, lineWidth: 1.1).frame(width: 10, height: 10)
            case .idle:
                if model.canHibernate(group), model.isIdle(group) {
                    Image(systemName: "moon.fill").font(.system(size: 9.5)).foregroundStyle(palette.mangoText)
                } else {
                    Sparkle().stroke(palette.text3, lineWidth: 1.1).frame(width: 10, height: 10)
                }
            }
        } else if let port = group.ports.first {
            PortToken(port: port, size: 11.5) { model.actions.open("http://localhost:\(port)") }.padding(.leading, -2)
        } else if group.bucket == .build {
            Image(systemName: "hammer").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.lavender)
        } else if case .managed = policy {
            Image(systemName: "lock").font(.system(size: 9.5, weight: .medium)).foregroundStyle(palette.text3)
        } else {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(palette.color(for: group.bucket)).frame(width: 6, height: 6)
        }
    }

    private func caption(_ policy: StopPolicy, busy: Bool) -> Text {
        if busy { return Text(policy == .hibernate ? "Hibernating…" : "Stopping…").foregroundStyle(palette.ember) }
        if let agent = group.agent {
            switch agent.state {
            case .working: return Text("working").foregroundStyle(palette.ember)
            case .waiting: return Text("needs you").foregroundStyle(palette.mangoText)
            case .idle: return Text(Format.idle(agent.idleFor(now: model.now)).lowercased())
            }
        }
        if case let .managed(managed) = policy { return Text(managed.caption) }
        var parts: [String] = []
        if group.bucket == .leaked { parts.append("leaked") }
        let age = model.now.timeIntervalSince(group.startedAt)
        parts.append(age < 60 ? "just started" : "up " + Format.duration(age))
        if group.ports.count > 1 { parts.append("also " + group.ports.dropFirst().map { ":\($0)" }.joined(separator: " ")) }
        return Text(parts.joined(separator: " · "))
    }

    private func acts(_ policy: StopPolicy) -> some View {
        HStack(spacing: 2) {
            if group.agent == nil, let port = group.ports.first, model.armed != group.id {
                IconButton(symbol: "arrow.up.right", help: "Open localhost:" + String(port)) { model.actions.open("http://localhost:\(port)") }
            }
            switch policy {
            case .hibernate:
                if model.canAct, model.canHibernate(group) {
                    IconButton(symbol: "moon.fill", help: "Hibernate: stop it and keep the session to wake later", tint: palette.mango) {
                        model.actions.hibernate([group])
                    }
                }
            case .stop:
                if model.canAct {
                    TwoClickIcon(id: group.id, model: model, help: stopHelp) { model.actions.stop([group]) }
                }
            case let .managed(managed):
                if let command = managed.command {
                    IconButton(symbol: "doc.on.doc", help: "Copy “\(command)”") { model.actions.copy(command) }
                }
            }
        }
        .animation(Motion.swap, value: model.armed == group.id)
    }

    private var stopHelp: String {
        guard let agent = group.agent else { return "Stop \(group.displayTitle)" }
        return "Stop \(group.displayTitle). \(agent.harness.displayName) sessions here can't be resumed."
    }

    private func tooltip(_ policy: StopPolicy) -> String {
        var lines = [group.displayTitle]
        if let agent = group.agent {
            lines.append("\(agent.harness.displayName) in \(agent.host.name)")
            if let id = agent.sessionID { lines.append("Session \(id)") }
            if agent.state == .working, policy == .hibernate { lines.append("Working, so Hibernate leaves it alone until it's idle.") }
        }
        if !group.ports.isEmpty { lines.append("Listening on " + group.ports.map { "localhost:\($0)" }.joined(separator: ", ")) }
        if group.isOrphaned { lines.append("Leaked: whatever started it has closed, so it runs until you stop it.") }
        if case let .managed(managed) = policy { lines.append(managed.reason) }
        for proc in group.processes.prefix(6) {
            lines.append("\(proc.pid)  \(Format.bytes(proc.memory))  \(proc.command)")
        }
        if group.processes.count > 6 { lines.append("+\(group.processes.count - 6) more") }
        return lines.joined(separator: "\n")
    }
}

/// Where a checkout is, and its branch, with buttons to open it.
struct PathLine: View {
    @Environment(\.palette) private var palette
    let checkout: Checkout
    let model: PanelModel

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Text(Format.path(checkout.path)).truncationMode(.middle)
                if checkout.kind == .worktree {
                    // The branch says more than the middle of a long path, so it gives way last.
                    Text(" · " + (checkout.branch ?? "detached")).layoutPriority(1)
                }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(palette.text3)
            .lineLimit(1)
            .help(Format.path(checkout.path))
            Spacer(minLength: 4)
            if !checkout.isMissing {
                IconButton(symbol: "folder", help: "Reveal in Finder") { model.actions.reveal(checkout.path) }
                IconButton(symbol: "terminal", help: "Open in Terminal") { model.actions.openTerminal(checkout.path) }
            }
        }
        .padding(.top, 6)
    }
}

/// "2 more worktrees · 242 MB", which shows the rest in place; "Fewer" folds them away.
struct MoreLink: View {
    @Environment(\.palette) private var palette
    let title: String
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.layout) { action() }
        } label: {
            HStack(spacing: 6) {
                Text(open ? "Fewer" : title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typeface.status)
            .foregroundStyle(hovering ? palette.text2 : palette.text3)
            .padding(.vertical, 5)
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }
}

// MARK: Controls

/// A port as a link: mango mono, like the servers' colour in the bar. Click to open it.
struct PortToken: View {
    @Environment(\.palette) private var palette
    @Environment(\.opening) private var opening
    let port: Int
    var size: CGFloat = 11
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            Text(verbatim: ":\(port)")
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(palette.mangoText)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(palette.mango.opacity(hovering ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .onChange(of: opening) { hovering = false }
        .linkCursor()
        .help("Open localhost:" + String(port))
        .accessibilityLabel("Open localhost port " + String(port))
    }
}

/// How many agents in a row are idle enough to hibernate. Click to hibernate them.
struct MoonButton: View {
    @Environment(\.palette) private var palette
    @Environment(\.opening) private var opening
    let count: Int
    var enabled = true
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if enabled {
            Button(action: action) { label }
                .buttonStyle(Pressable())
                .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
                .onChange(of: opening) { hovering = false }
                .help(help)
        } else {
            label.help("\(count) idle agent\(count == 1 ? "" : "s")")
        }
    }

    private var label: some View {
        MoonCount(count: count)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.mango.opacity(hovering ? 0.14 : 0)))
            .contentShape(Rectangle())
    }
}

struct MoonCount: View {
    @Environment(\.palette) private var palette
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(verbatim: "\(count)").font(Typeface.smallNumber)
        }
        .foregroundStyle(palette.mangoText)
    }
}

struct IconButton: View {
    @Environment(\.palette) private var palette
    @Environment(\.opening) private var opening
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hovering ? (tint ?? palette.ember) : palette.text2)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? palette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
        .onChange(of: opening) { hovering = false }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small outlined capsule, or a filled one for the action a card is asking for.
struct PillButton: View {
    @Environment(\.palette) private var palette
    let title: String
    var tint: Color?
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = tint ?? palette.text2
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filled ? palette.onEmber : color)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(filled ? color : color.opacity(hovering ? 0.12 : 0)))
                .overlay { if !filled { Capsule().strokeBorder(color.opacity(tint == nil ? 0.3 : 0.55), lineWidth: 1) } }
                .brightness(filled && hovering ? 0.05 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }
}

/// Corral's capsules: ember for what a view is for, a coral outline for what can't be undone,
/// and coral filled once that's armed and asking again.
struct CapsuleStyle: ButtonStyle {
    enum Kind {
        case ember, line, fill
    }

    var kind: Kind
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, kind: kind, small: small)
    }
}

private struct CapsuleBody: View {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let kind: CapsuleStyle.Kind
    let small: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: small ? 11 : 12, weight: .semibold))
            .foregroundStyle(kind == .line ? palette.coral : palette.onEmber)
            .padding(.horizontal, small ? 10 : 13)
            .frame(height: small ? 22 : 28)
            .background {
                Capsule()
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.06 : (hovering && kind != .line ? 0.05 : 0))
            }
            .overlay {
                if kind == .line {
                    Capsule().strokeBorder(palette.coral.opacity(0.55), lineWidth: 1)
                } else if kind == .ember {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { inside in withAnimation(Motion.hover) { hovering = inside } }
    }

    private var fill: Color {
        switch kind {
        case .ember: palette.ember
        case .line: palette.coral.opacity(hovering ? 0.12 : 0)
        case .fill: palette.coralFill
        }
    }
}

/// Stopping and moving to the Trash take two clicks: the first arms the capsule, which fills
/// coral and asks again; the second acts. Only one is armed at a time, and it disarms after a
/// few seconds, when the pointer leaves its row, or when the panel closes.
struct TwoClickCapsule: View {
    let id: String
    let model: PanelModel
    let title: String
    let armedTitle: String
    var amount: UInt64?
    var small = false
    let help: String
    let armedHelp: String
    let action: () -> Void

    var body: some View {
        let armed = model.armed == id
        Button {
            if armed {
                model.disarm()
                action()
            } else {
                model.arm(id)
            }
        } label: {
            HStack(spacing: 6) {
                Text(armed ? armedTitle : title)
                if let amount {
                    Text(Format.bytes(amount)).font(.system(size: 10.5, weight: .medium, design: .monospaced)).opacity(0.75)
                }
            }
            .fixedSize()
        }
        .buttonStyle(CapsuleStyle(kind: armed ? .fill : .line, small: small))
        .help(armed ? armedHelp : help)
        .accessibilityLabel(armed ? armedTitle : title)
        .animation(Motion.swap, value: armed)
    }
}

/// The two clicks, for an icon in a row: ✕, then a coral "Stop".
struct TwoClickIcon: View {
    @Environment(\.palette) private var palette
    let id: String
    let model: PanelModel
    var symbol = "xmark"
    var armedTitle = "Stop"
    let help: String
    var armedHelp = "Click again to stop. It won't restart on its own."
    let action: () -> Void

    var body: some View {
        let armed = model.armed == id
        ZStack(alignment: .trailing) {
            if armed {
                Button(armedTitle) {
                    model.disarm()
                    action()
                }
                .buttonStyle(CapsuleStyle(kind: .fill, small: true))
                .help(armedHelp)
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            } else {
                IconButton(symbol: symbol, help: help, tint: palette.coral) { model.arm(id) }
                    .transition(.opacity)
            }
        }
        .animation(Motion.swap, value: armed)
    }
}

/// A press dims what's pressed, the same for every quiet button in the panel.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    /// The pointing hand, over a port or anything else that opens a link.
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

private struct LinkCursor: ViewModifier {
    @Environment(\.opening) private var opening
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onChange(of: opening) {
                    if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onHover { inside in
                    if inside, !pushed {
                        NSCursor.pointingHand.push()
                        pushed = true
                    } else if !inside, pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onDisappear {
                    if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
        }
    }
}
