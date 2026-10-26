import AppKit
import CorralCore
import CorralUI
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private let hotkeys = Hotkeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows most of the time; don't let macOS quit it for that.
        ProcessInfo.processInfo.disableAutomaticTermination("Corral watches memory from the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        store = AppStore(demo: CommandLine.arguments.contains("--demo"))
        panel = PanelController(model: store.model)
        settingsWindow = SettingsWindowController(
            settings: store.settings,
            checkForUpdates: { [weak self] in await self?.store.updates.check() ?? "" },
            uninstall: { [weak self] in self?.store.uninstall() }
        )
        statusItem = StatusItemController(onClick: { [weak self] in self?.togglePanel() }, menu: { [weak self] in self?.menu() ?? NSMenu() })

        store.model.actions.openSettings = { [weak self] in
            self?.panel.hide()
            self?.settingsWindow.show()
        }
        // What takes you to another app closes the panel, the way choosing from a menu does.
        let actions = store.model.actions
        store.model.actions.open = { [weak self] link in
            actions.open(link)
            self?.panel.hide()
        }
        store.model.actions.reveal = { [weak self] path in
            actions.reveal(path)
            self?.panel.hide()
        }
        store.model.actions.openTerminal = { [weak self] path in
            actions.openTerminal(path)
            self?.panel.hide()
        }
        store.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            statusItem.update(snapshot: snapshot, idleAgents: store.model.idleAgents(in: snapshot).count, style: store.settings.menuBarStyle)
        }
        panel.onVisibilityChange = { [weak self] visible in self?.store.panelVisible = visible }
        panel.onShortcut = { [weak self] key in
            guard let self else { return }
            switch key {
            case ",": store.model.actions.openSettings()
            case "r": store.model.actions.refresh()
            case "h": store.hibernateIdle(source: .panel)
            case "z": store.undoLast()
            case "1": store.model.select(.memory)
            case "2": store.model.select(.disk)
            case "q": NSApp.terminate(nil)
            default: break
            }
        }

        TerminalTracker.shared.start()
        Notifier.shared.setUp()
        Notifier.shared.onHibernate = { [weak self] in self?.store.hibernateIdle(source: .notification) }
        Notifier.shared.onOpen = { [weak self] in self?.showPanel() }

        watchSettings()
        store.start()
        if CommandLine.arguments.contains("--open") || store.demo {
            // Give the menu bar a moment to place the icon before deciding where the panel goes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.showPanel()
            }
        }
    }

    private func togglePanel() {
        panel.isVisible ? panel.hide() : showPanel()
    }

    private func showPanel() {
        guard !panel.isVisible else { return }
        let visible = statusItem.isOnScreen
        store.model.notice = visible || UserDefaults.standard.bool(forKey: "hiddenIconNoticeDismissed") ? nil
            : "Your menu bar is full, so Corral's icon is hidden. Press \(store.settings.shortcut?.display ?? "the shortcut") to open Corral, or ⌘-drag other icons out of the menu bar to make room."
        panel.show(below: visible ? statusItem.button : nil)
    }

    /// Re-registers the shortcut and redraws the menu bar item when their settings change.
    private func watchSettings() {
        withObservationTracking {
            _ = store.settings.shortcut
            _ = store.settings.menuBarStyle
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchSettings() }
        }
        hotkeys.register(store.settings.shortcut) { [weak self] in self?.togglePanel() }
        statusItem.update(snapshot: store.latest, idleAgents: store.model.idleAgents(in: store.latest).count, style: store.settings.menuBarStyle)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        if let update = store.model.visibleUpdate {
            let item = NSMenuItem(title: "Install Corral \(update.version)", action: #selector(downloadUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let idle = store.settings.readOnly ? [] : store.model.idleAgents(in: store.latest)
        let hibernate = NSMenuItem(
            title: store.settings.readOnly ? "Read-Only Mode Is On" : idle.isEmpty ? "No Idle Agents" : "Hibernate \(idle.count) Idle Agent\(idle.count == 1 ? "" : "s") (\(Format.bytes(idle.reduce(0) { $0 + $1.memory })))",
            action: idle.isEmpty ? nil : #selector(hibernateIdle), keyEquivalent: ""
        )
        hibernate.target = self
        menu.addItem(hibernate)
        // Say which agents it will stop before it does.
        for group in idle.prefix(6) {
            let idleFor = Format.idle(group.agent?.idleFor(now: Date()) ?? 0).lowercased()
            let entry = NSMenuItem(title: "\(group.displayTitle) · \(idleFor)", action: nil, keyEquivalent: "")
            entry.indentationLevel = 1
            entry.isEnabled = false
            menu.addItem(entry)
        }
        if idle.count > 6 {
            let more = NSMenuItem(title: "and \(idle.count - 6) more", action: nil, keyEquivalent: "")
            more.indentationLevel = 1
            more.isEnabled = false
            menu.addItem(more)
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Send Feedback…", #selector(sendFeedback), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Corral", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func hibernateIdle() { store.hibernateIdle(source: .menu) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func sendFeedback() { store.model.actions.sendFeedback() }
    @objc private func downloadUpdate() {
        if let update = store.model.visibleUpdate { store.installUpdate(update) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
