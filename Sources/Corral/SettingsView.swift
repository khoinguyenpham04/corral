import AppKit
import CorralCore
import CorralUI
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: CorralSettings
    private let checkForUpdates: @MainActor () async -> String
    private let uninstall: @MainActor () -> Void

    init(settings: CorralSettings, checkForUpdates: @escaping @MainActor () async -> String, uninstall: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.checkForUpdates = checkForUpdates
        self.uninstall = uninstall
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(settings: settings, checkForUpdates: checkForUpdates, uninstall: uninstall))
            let window = NSWindow(contentViewController: controller)
            window.title = "Corral Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 500, height: 760))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var settings: CorralSettings
    let checkForUpdates: @MainActor () async -> String
    let uninstall: @MainActor () -> Void
    @State private var updateStatus = ""
    @State private var checking = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var installedAt = CommandLineTool.installedAt
    @State private var installError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandBand(subtitle: "Memory by worktree")
            Form {
                Section("General") {
                    Toggle("Open Corral at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { LoginItem.set(launchAtLogin) }
                    Picker("Menu bar shows", selection: $settings.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Open the panel with") {
                        ShortcutRecorder(shortcut: $settings.shortcut)
                    }
                }

                Section {
                    Toggle("Read-only: never stop or move anything", isOn: $settings.readOnly)
                        .disabled(settings.readOnlyIsManaged)
                } header: {
                    Text("Safety")
                } footer: {
                    Text(settings.readOnlyIsManaged
                        ? "Your organization turned on read-only mode."
                        : "Corral logs everything it stops, hibernates, wakes or moves to the Trash. See it under Activity in the panel, or run `corral log`.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Agents count as idle after", selection: $settings.idleMinutes) {
                        ForEach([15, 30, 60, 120, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")").tag(minutes)
                        }
                    }
                    Toggle("Include Claude Desktop sessions", isOn: $settings.hibernateDesktopSessions)
                    Toggle("Hibernate idle agents automatically", isOn: $settings.autoHibernate)
                        .disabled(settings.readOnly || settings.isManaged("autoHibernate"))
                    if settings.autoHibernate {
                        Picker("After", selection: $settings.autoHibernateHours) {
                            ForEach([1, 2, 4, 8, 24], id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s") idle").tag($0) }
                        }
                        .disabled(settings.isManaged("autoHibernateHours"))
                    }
                } header: {
                    Text("Hibernate")
                } footer: {
                    Text("Hibernating stops an agent's process and frees its memory. The session stays on disk, so Wake picks up where you left off. Agents that are working are never stopped.")
                        .foregroundStyle(.secondary)
                }

                Section("Alerts") {
                    Toggle("Notify when memory pressure rises", isOn: $settings.pressureAlerts)
                    Toggle("Notify when swap passes", isOn: $settings.swapAlert)
                    if settings.swapAlert {
                        Stepper("\(settings.swapAlertGB) GB", value: $settings.swapAlertGB, in: 2...128, step: 2)
                    }
                }

                Section {
                    Picker("Resume terminal sessions in", selection: $settings.resumeTerminal) {
                        Text("The terminal they ran in").tag("auto")
                        ForEach(Resumer.terminals.filter { Resumer.isInstalled($0.id) }, id: \.id) { Text($0.name).tag($0.id) }
                        Text("Copy the command").tag("copy")
                    }
                } header: {
                    Text("Wake")
                } footer: {
                    Text("Corral types the resume command into the original iTerm or Terminal tab when it's free, or opens a new window. Open in Terminal uses your choice here, or the terminal you last used.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("corral") {
                        if let installedAt {
                            Text(Format.path(installedAt.path)).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Button("Install") {
                                do {
                                    installedAt = try CommandLineTool.install()
                                    installError = nil
                                } catch {
                                    installError = error.localizedDescription
                                }
                            }
                        }
                    }
                    if let installError { Text(installError).foregroundStyle(.red).font(.caption) }
                } header: {
                    Text("Command line")
                } footer: {
                    Text("`corral ls`, `corral hibernate`, `corral wake` and `corral status`, for you, your scripts and your agents.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Version", value: version)
                    Toggle("Check for updates every day", isOn: $settings.checkForUpdates)
                        .disabled(settings.isManaged("checkForUpdates"))
                    LabeledContent {
                        Button(checking ? "Checking…" : "Check Now") {
                            checking = true
                            Task {
                                updateStatus = await checkForUpdates()
                                checking = false
                            }
                        }
                        .disabled(checking)
                    } label: {
                        Text(updateStatus.isEmpty ? "Updates" : updateStatus).foregroundStyle(updateStatus.isEmpty ? .primary : .secondary)
                    }
                    Link("Send Feedback…", destination: UpdateCheck.feedback)
                    Link("Source code on GitHub", destination: URL(string: UpdateCheck.project)!)
                } footer: {
                    Text("Corral asks GitHub for new releases. It needs no account and never asks for a password. Updates are checked against their published fingerprint before they're installed.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        Button("Uninstall…", role: .destructive) { uninstall() }
                    } label: {
                        Text("Uninstall Corral")
                    }
                } footer: {
                    Text("Moves Corral to the Trash and removes its settings, activity log, `corral` command and login item.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 760)
        .ignoresSafeArea(edges: .top)
    }
}

/// Click, then press the new shortcut. Escape cancels; Delete clears it.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press a shortcut…" : (shortcut?.display ?? "None")) {
                recording ? stop() : start()
            }
            .monospaced()
            if shortcut != nil, !recording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove the shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
            MainActor.assumeIsolated {
                if keyCode == 53 { stop(); return }
                if keyCode == 51 { shortcut = nil; stop(); return }
                guard !flags.intersection([.command, .option, .control]).isEmpty, !key.isEmpty else { return }
                var carbon: UInt32 = 0
                var symbols = ""
                if flags.contains(.control) { carbon |= 4096; symbols += "⌃" }
                if flags.contains(.option) { carbon |= 2048; symbols += "⌥" }
                if flags.contains(.shift) { carbon |= 512; symbols += "⇧" }
                if flags.contains(.command) { carbon |= 256; symbols += "⌘" }
                shortcut = Shortcut(keyCode: UInt32(keyCode), modifiers: carbon, display: symbols + key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
