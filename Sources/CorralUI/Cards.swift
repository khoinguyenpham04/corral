import CorralCore
import SwiftUI

/// Shown the first time the panel opens: what the bar, the moon and the ports mean.
struct WelcomeCard: View {
    @Environment(\.palette) private var palette
    let model: PanelModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Sparkle().fill(palette.ember).frame(width: 10, height: 10)
                (Text("Welcome to ") + Text("Corral").font(Typeface.wordmark(15)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.text)
            }
            item("The bar splits memory by kind, a piece per worktree: hover a row to find its share. Hatched coral is a leaked server, still running after whatever started it closed.") {
                HStack(spacing: 1.5) {
                    Rectangle().fill(palette.ember).frame(width: 9)
                    Rectangle().fill(palette.mango).frame(width: 7)
                    Hatch(color: palette.coral).frame(width: 7)
                    Rectangle().fill(palette.graphite).frame(width: 5)
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
            item("Agents idle \(model.settings.idleMinutes) min or more. Hibernate frees their memory, and Wake picks up where they left off.") {
                MoonCount(count: 2)
            }
            item(model.canAct
                ? "Click a port to open it. Hover a row for its buttons; Stop takes two clicks, since it can't be undone."
                : "Click a port to open it. Read-only mode is on: Corral shows memory and disk use, and never stops or moves anything.") {
                Text(verbatim: ":4321").font(Typeface.port).foregroundStyle(palette.mangoText)
            }
            HStack(spacing: 6) {
                SetupPill(title: model.opensAtLogin ? "Opens at login" : "Open at login", done: model.opensAtLogin) {
                    model.actions.setOpenAtLogin(!model.opensAtLogin)
                }
                .help("Start Corral when you log in, so it's always in the menu bar")
                SetupPill(title: "corral command", done: model.commandLineToolPath != nil) {
                    model.actions.installCommandLineTool()
                }
                .help(model.commandLineToolPath.map { "Installed at \($0)" } ?? "Add `corral` to your terminal: corral ls, corral hibernate, corral wake")
                Spacer(minLength: 4)
                PillButton(title: "Got it", tint: palette.ember, filled: true, action: dismiss)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.rim, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func item<Glyph: View>(_ text: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(alignment: .top, spacing: 10) {
            glyph().frame(width: 34, height: 15, alignment: .leading)
            Text(text)
                .font(Typeface.caption)
                .foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A heads-up when the disk is nearly full and idle worktrees hold space you could free.
/// Review opens the list; either button quiets it for a day.
struct DiskNudge: View {
    @Environment(\.palette) private var palette
    let volume: VolumeSpace
    let freeable: UInt64
    let model: PanelModel

    private func hideForADay() {
        let until = model.now.addingTimeInterval(86_400)
        UserDefaults.standard.set(until, forKey: "diskNudgeHiddenUntil")
        model.diskNudgeHiddenUntil = until
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13))
                .foregroundStyle(palette.mango)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disk almost full").font(Typeface.title).foregroundStyle(palette.text)
                Text(model.canAct
                    ? "\(Format.bytes(volume.available)) left · \(Format.bytes(freeable)) in idle worktrees is safe to remove"
                    : "\(Format.bytes(volume.available)) left · idle worktrees hold \(Format.bytes(freeable))")
                    .font(Typeface.caption)
                    .foregroundStyle(palette.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                PillButton(title: "Later") {
                    withAnimation(.easeOut(duration: 0.2)) { hideForADay() }
                }
                .help("Hide this for a day")
                PillButton(title: "Review", tint: palette.ember, filled: true) {
                    hideForADay()
                    model.select(.disk)
                }
                .help("Show the idle worktrees, biggest first")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.mango.opacity(palette.isDark ? 0.08 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.mango.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

/// A quiet note when a newer Corral is out: Download opens its release page, Later waits for
/// the one after.
struct UpdateBanner: View {
    @Environment(\.palette) private var palette
    let release: UpdateCheck.Release
    let model: PanelModel

    var body: some View {
        HStack(spacing: 11) {
            Sparkle().fill(palette.ember).frame(width: 11, height: 11).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Corral \(release.version) is out").font(Typeface.title).foregroundStyle(palette.text)
                HStack(spacing: 4) {
                    Text("You have \(UpdateCheck.currentVersion) ·").foregroundStyle(palette.text2)
                    Button("What's new") { model.actions.open(release.page.absoluteString) }
                        .buttonStyle(Pressable())
                        .foregroundStyle(palette.ember)
                }
                .font(Typeface.caption)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                PillButton(title: "Later") {
                    withAnimation(.easeOut(duration: 0.2)) { model.settings.skippedUpdate = release.version }
                }
                .help("Hide this until the next release")
                if model.installing {
                    Text("Installing…").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.text2).frame(height: 22)
                } else {
                    PillButton(title: "Install", tint: palette.ember, filled: true) { model.actions.installUpdate(release) }
                        .help("Download it, replace this copy and reopen Corral")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.ember.opacity(palette.isDark ? 0.08 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.ember.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

/// A one-click setup step on the welcome card, with a check once it's done.
struct SetupPill: View {
    @Environment(\.palette) private var palette
    let title: String
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(done ? palette.mint : palette.text3)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(done ? palette.text : palette.text2)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(hovering ? palette.hover : .clear))
            .overlay(Capsule().strokeBorder(palette.rim, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
    }
}
