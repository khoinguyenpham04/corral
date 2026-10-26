import CorralCore
import SwiftUI

/// Everything that isn't a worktree, a line each, labelled like the posters: what every
/// checkout shares, hibernated sessions, other apps, and what Corral has done.
struct Ledger: View {
    let model: PanelModel

    var body: some View {
        let snapshot = model.snapshot
        let hibernated = model.hibernated
        VStack(spacing: 0) {
            if !snapshot.shared.isEmpty {
                LedgerRow(
                    id: "shared", label: "Shared", detail: snapshot.shared.prefix(2).map(\.title).joined(separator: ", "),
                    value: Format.bytes(snapshot.sharedMemory), owner: "shared", model: model
                ) {
                    ForEach(snapshot.shared) { GroupKid(group: $0, model: model) }
                    KidNote(text: Self.sharedNote(snapshot.shared, model: model))
                }
            }
            if !hibernated.isEmpty {
                LedgerRow(
                    id: "hibernated", label: "Hibernated", detail: "\(hibernated.count == 1 ? "1 session" : "\(hibernated.count) sessions") · wake any time",
                    value: Format.bytes(hibernated.reduce(0) { $0 + $1.memory }), quiet: true, model: model
                ) {
                    ForEach(hibernated.prefix(8)) { HibernatedKid(record: $0, model: model) }
                    if hibernated.count > 1 {
                        KidFooter(note: hibernated.count > 8 ? "and \(hibernated.count - 8) more" : nil, action: "Wake all") {
                            model.actions.wake(hibernated)
                        }
                    }
                }
            }
            if !snapshot.elsewhere.isEmpty {
                LedgerRow(
                    id: "elsewhere", label: "Other apps", detail: snapshot.elsewhere.prefix(3).map(\.name).joined(separator: ", "),
                    value: Format.bytes(snapshot.elsewhereMemory), quiet: true, model: model
                ) {
                    ForEach(snapshot.elsewhere.prefix(10)) { app in
                        KidRow(title: Text(app.name), caption: app.processCount > 1 ? Text("\(app.processCount) processes") : nil, memory: app.memory) {
                            EmptyView()
                        } acts: {
                            EmptyView()
                        }
                    }
                    if snapshot.elsewhere.count > 10 { KidNote(text: "and \(snapshot.elsewhere.count - 10) more") }
                }
            }
            if !model.activity.isEmpty {
                LedgerRow(id: "activity", label: "Activity", detail: Self.summary(model.activity, now: model.now), value: nil, model: model) {
                    ForEach(model.activity.prefix(12)) { ActivityKid(entry: $0) }
                    KidFooter(
                        note: model.activity.count > 12 ? "\(model.activity.count - 12) more in the log" : "Everything Corral stopped, woke or moved",
                        action: "Show log"
                    ) {
                        model.actions.reveal(ActivityLog.shared.url.path)
                    }
                    .help("Reveal activity.jsonl in Finder. `corral log` prints it.")
                }
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    static func sharedNote(_ groups: [ProcessGroup], model: PanelModel) -> String {
        let managed = groups.filter { if case .managed = model.policy(for: $0) { true } else { false } }
        if managed.isEmpty { return "Services that no single checkout owns." }
        let vm = managed.contains { ContainerRuntime(title: $0.title) != nil || $0.title.hasPrefix("Linux VM") }
        return vm
            ? "Every checkout uses these. Corral leaves the container VM running, since your containers need it."
            : "Every checkout uses these. Corral leaves them to the apps that run them."
    }

    /// "Today: 2 stopped · 3 hibernated · 3.8 GB freed", or the last thing done before today.
    static func summary(_ entries: [ActivityEntry], now: Date) -> String {
        let today = entries.filter { Calendar.current.isDateInToday($0.date) }
        guard !today.isEmpty else {
            guard let last = entries.first else { return "" }
            return "Last: \(ActivityKid.verb(last.action).lowercased()) \(last.title), \(Format.ago(now.timeIntervalSince(last.date)))"
        }
        let freed = today.filter { $0.action == .stopped || $0.action == .hibernated }.reduce(0) { $0 + $1.memory }
        let counts: [(ActivityEntry.Action, String)] = [
            (.stopped, "stopped"), (.hibernated, "hibernated"), (.woke, "woken"), (.trashed, "trashed"), (.failed, "didn't stop"),
        ]
        let parts = counts.compactMap { action, word -> String? in
            let count = today.filter { $0.action == action }.count
            return count > 0 ? "\(count) \(word)" : nil
        }
        return "Today: " + (parts.isEmpty ? "\(today.count) changes" : parts.joined(separator: " · ")) + (freed > 0 ? " · \(Format.bytes(freed)) freed" : "")
    }
}

/// A small caps label, a line of detail, a value and a chevron; it opens in place, fenced in.
struct LedgerRow<Inside: View>: View {
    @Environment(\.palette) private var palette
    @Environment(Focus.self) private var focus
    @Environment(\.opening) private var opening
    let id: String
    let label: String
    let detail: String
    let value: String?
    var quiet = false
    /// The bar's piece for this row, lit while the pointer is over it.
    var owner: String?
    let model: PanelModel
    @ViewBuilder let inside: () -> Inside
    @State private var hovering = false

    var body: some View {
        let open = model.expanded.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label).smallCaps(palette.text3).frame(width: 96, alignment: .leading)
                Text(detail)
                    .font(Typeface.status)
                    .foregroundStyle(palette.text2)
                    .lineLimit(1)
                    .padding(.trailing, 10)
                Spacer(minLength: 0)
                if let value {
                    Text(value)
                        .font(Typeface.number)
                        .foregroundStyle(quiet ? palette.text2 : palette.text)
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(palette.text3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 16, alignment: .trailing)
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(Motion.hover) { hovering = inside }
                if let owner { focus.hover(owner, inside) }
            }
            .onChange(of: opening) { hovering = false }
            .onTapGesture { withAnimation(Motion.layout) { model.toggle(id) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(Motion.layout) { model.toggle(id) } }
            Fold(open: open) {
                Fenced(at: 13) { inside() }.padding(.top, 2)
            }
        }
        .id(id)
    }
}

struct HibernatedKid: View {
    @Environment(\.palette) private var palette
    let record: HibernationRecord
    let model: PanelModel

    var body: some View {
        KidRow(title: Text(record.title), caption: Text(record.checkout ?? record.host.name), memory: record.memory) {
            Image(systemName: "moon.fill").font(.system(size: 9.5)).foregroundStyle(palette.mangoText)
        } acts: {
            IconButton(symbol: "minus.circle", help: "Remove from this list. The session stays in its agent's history.") {
                model.actions.forget([record])
            }
        } trailing: {
            PillButton(title: "Wake", tint: palette.ember) { model.actions.wake([record]) }
                .help(record.resume.shellLine ?? "Reopen in \(record.host.name)")
        }
        .help("\(record.host.name) · hibernated \(Format.ago(model.now.timeIntervalSince(record.hibernatedAt)))")
    }
}

struct ActivityKid: View {
    @Environment(\.palette) private var palette
    let entry: ActivityEntry

    var body: some View {
        let showsMemory = ![.woke, .forgot, .restored].contains(entry.action) && entry.memory > 0
        KidRow(
            title: Text(Self.verb(entry.action)).foregroundStyle(color) + Text(verbatim: " ") + Text(entry.title),
            caption: entry.checkout.map { Text($0) },
            memory: showsMemory ? entry.memory : nil
        ) {
            Text(Self.time(entry.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.text3)
        } acts: {
            EmptyView()
        }
        .help(([entry.source.label] + entry.processes.map { "\($0.pid)  \($0.command)" }).joined(separator: "\n"))
    }

    private var color: Color {
        switch entry.action {
        case .stopped, .failed, .trashed: palette.coral
        case .hibernated: palette.mangoText
        case .woke, .restored: palette.ember
        case .forgot: palette.text3
        }
    }

    static func verb(_ action: ActivityEntry.Action) -> String {
        switch action {
        case .stopped: "Stopped"
        case .hibernated: "Hibernated"
        case .woke: "Woke"
        case .forgot: "Forgot"
        case .failed: "Couldn't stop"
        case .trashed: "Trashed"
        case .restored: "Put back"
        }
    }

    /// "3:02 PM" today, "Oct 14" before.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A quiet sentence under what's inside a row.
struct KidNote: View {
    @Environment(\.palette) private var palette
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(palette.text3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

/// The last line inside a row: a note, and one quiet button for all of it.
struct KidFooter: View {
    @Environment(\.palette) private var palette
    var note: String?
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let note {
                Text(note).font(.system(size: 10.5)).foregroundStyle(palette.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action, action: perform)
                .buttonStyle(Pressable())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.ember)
        }
        .padding(.top, 5)
        .padding(.bottom, 1)
    }
}
