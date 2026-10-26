import CorralCore
import SwiftUI

/// The Disk tab: linked worktrees with nothing running in them, biggest first by what moving
/// each to the Trash frees. Ones holding work that isn't committed stay put, and say why.
struct DiskPage: View {
    let model: PanelModel

    /// How many show before "N more".
    static let preview = 7

    var body: some View {
        VStack(spacing: 0) {
            Banners(model: model)
            if let report = model.disk, !report.worktrees.isEmpty {
                let all = report.worktrees
                let rest = all.dropFirst(Self.preview)
                VStack(spacing: 0) {
                    ForEach(model.showsAllWorktrees ? all : Array(all.prefix(Self.preview))) { item in
                        DiskRow(item: item, model: model, measuring: report.progress != nil).id(item.id)
                    }
                    if !rest.isEmpty {
                        MoreLink(title: "\(rest.count) more · \(Format.bytes(DiskReport.freeable(Array(rest))))", open: model.showsAllWorktrees) {
                            model.showsAllWorktrees.toggle()
                        }
                    }
                }
                .padding(8)
            } else {
                DiskEmpty(looking: model.disk == nil)
            }
        }
    }
}

/// One idle worktree: a rail in ink if it's safe to remove or mango hatch if it holds work,
/// its name, what holds it or when it was edited, and what it frees.
struct DiskRow: View {
    @Environment(\.palette) private var palette
    @Environment(Focus.self) private var focus
    @Environment(\.opening) private var opening
    let item: IdleWorktree
    let model: PanelModel
    /// Measuring is under way, so one without a size yet is next; otherwise it's waiting (Low Power Mode).
    var measuring = true
    @State private var hovering = false

    private var armID: String { "trash:" + item.id }

    var body: some View {
        let moving = model.trashing.contains(item.id)
        let canTrash = model.canAct && item.canTrash && !moving
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.worktree.name)
                    .font(Typeface.title)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(moving: moving).font(Typeface.status).lineLimit(1)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { rail.frame(width: 3) }
            HStack(spacing: 9) {
                if canTrash, hovering || model.armed == armID {
                    TwoClickCapsule(
                        id: armID, model: model, title: "Trash", armedTitle: "Trash?", small: true,
                        help: "Move it to the Trash. Its branch stays.",
                        armedHelp: "Click again to move it to the Trash. Its branch stays; files git ignores, like .env, go with it."
                    ) {
                        model.actions.trash([item])
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                }
                Text(item.usage.map { Format.bytes($0.freeable) } ?? "—")
                    .font(Typeface.number)
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(value: Double(item.usage?.freeable ?? 0)))
                    .frame(minWidth: 50, alignment: .trailing)
            }
            .animation(Motion.swap, value: model.armed == armID)
            .animation(Motion.swap, value: moving)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.hover) {
                hovering = inside
                if !inside, model.armed == armID { model.disarm() }
            }
            focus.hover("disk:" + item.id, inside)
        }
        .onChange(of: opening) { hovering = false }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if canTrash { Button("Move to Trash…") { model.actions.confirmTrash([item]) } }
        }
        .contextMenu {
            Button("Reveal in Finder") { model.actions.reveal(item.worktree.path) }
            Button("Open in Terminal") { model.actions.openTerminal(item.worktree.path) }
            Button("Copy Path") { model.actions.copy(item.worktree.path) }
            if canTrash {
                Divider()
                Button("Move to Trash…") { model.actions.confirmTrash([item]) }
            }
        }
    }

    @ViewBuilder private var rail: some View {
        if !item.holds.isEmpty {
            Hatch(color: palette.mango).clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(item.canTrash ? palette.text3 : palette.quiet)
        }
    }

    @ViewBuilder private func status(moving: Bool) -> some View {
        if moving {
            Text("Moving…").foregroundStyle(palette.ember)
        } else if let hold = item.holds.first {
            Text(hold.caption).foregroundStyle(palette.mangoText)
        } else if let usage = item.usage {
            let about = [item.worktree.repoName, item.worktree.manager, usage.lastEdited.map { "edited " + Format.ago(model.now.timeIntervalSince($0)) }]
            Text(about.compactMap { $0 }.joined(separator: " · ")).foregroundStyle(palette.text2)
        } else {
            Text(measuring ? "Measuring…" : "Not measured yet").foregroundStyle(palette.text3)
        }
    }

    /// Everything the row leaves out: where it is, its branch and the tool that made it, what
    /// it takes on disk, and why it stays if it does.
    private var tooltip: String {
        let worktree = item.worktree
        var lines = [Format.path(worktree.path)]
        var about = [worktree.repoName, worktree.branch.map { "branch \($0)" } ?? "detached HEAD"]
        if let manager = worktree.manager { about.append("made by \(manager)") }
        lines.append(about.joined(separator: " · "))
        if let usage = item.usage {
            var line = "Moving it to the Trash frees \(Format.bytes(usage.freeable)) once you empty the Trash."
            if usage.sampled == true {
                line += " Its packages are shared with pnpm's or bun's store, so they stay."
            } else if usage.shared >= 100 << 20 {
                line += " The rest of its \(Format.bytes(usage.allocated)) on disk is shared with other copies, like pnpm's store, so it stays."
            }
            lines.append(line)
            if let edited = usage.lastEdited { lines.append("Last edited \(Format.ago(model.now.timeIntervalSince(edited))).") }
        }
        if let hold = item.holds.first { lines.append(hold.caption + ": " + hold.reason) }
        return lines.joined(separator: "\n")
    }
}

struct DiskEmpty: View {
    @Environment(\.palette) private var palette
    let looking: Bool

    var body: some View {
        VStack(spacing: 9) {
            Sparkle().stroke(palette.ember, lineWidth: 1).frame(width: 20, height: 20)
            Text(looking ? "Looking for idle worktrees…" : "No idle worktrees").font(Typeface.title).foregroundStyle(palette.text)
            if !looking {
                Text("Linked worktrees with nothing running in them show up here, with what moving each to the Trash frees.")
                    .font(Typeface.caption)
                    .foregroundStyle(palette.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}
