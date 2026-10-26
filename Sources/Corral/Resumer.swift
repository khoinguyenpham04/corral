import AppKit
import CorralCore
import Foundation

/// Brings hibernated sessions back. Desktop-app sessions reopen through the app (Claude
/// Desktop has a deep link per session). Terminal sessions go back to the tab they ran in when
/// that tab is still sitting at a prompt (iTerm, Terminal), else to a new window of the
/// preferred terminal, else the command is copied.
@MainActor
struct Resumer {
    enum Outcome: Equatable {
        case opened, copied, failed
    }

    struct Terminal {
        let id: String
        let name: String
    }

    static let terminals: [Terminal] = [
        Terminal(id: "com.apple.Terminal", name: "Terminal"),
        Terminal(id: "com.googlecode.iterm2", name: "iTerm"),
        Terminal(id: "com.mitchellh.ghostty", name: "Ghostty"),
        Terminal(id: "com.github.wez.wezterm", name: "WezTerm"),
        Terminal(id: "net.kovidgoyal.kitty", name: "kitty"),
        Terminal(id: "dev.warp.Warp-Stable", name: "Warp"),
    ]

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func resume(_ record: HibernationRecord, preferred: String, ttyIsBusy: (String) -> Bool) -> Outcome {
        switch record.resume {
        case let .url(text):
            guard let url = URL(string: text) else { return .failed }
            return NSWorkspace.shared.open(url) ? .opened : .failed
        case let .app(bundleID):
            return openApp(bundleID) ? .opened : .failed
        case let .command(argv, cwd):
            let line = record.resume.shellLine ?? argv.joined(separator: " ")
            if preferred == "copy" { return copy(line) }
            let terminal = chooseTerminal(for: record, preferred: preferred)
            let sameTab = record.tty.flatMap { tty in ttyIsBusy(tty) ? nil : "/dev/" + tty }
            switch terminal {
            case "com.googlecode.iterm2":
                if runScript(Self.iTermScript(line: line, tty: sameTab)) { return .opened }
            case "com.apple.Terminal":
                if runScript(Self.terminalScript(line: line, tty: sameTab)) { return .opened }
            case "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm":
                if launch(terminal, cwd: cwd, line: line) { return .opened }
            case "dev.warp.Warp-Stable":
                // Warp opens a tab at a folder but can't type into it; the command goes on the clipboard.
                let path = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cwd
                if let url = URL(string: "warp://action/new_tab?path=\(path)"), NSWorkspace.shared.open(url) { return copy(line) }
            default:
                break
            }
            return copy(line)
        }
    }

    func openTerminal(at path: String, preferred: String) {
        let id = preferred == "auto" || preferred == "copy" ? defaultTerminal() : preferred
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Terminals

    private func chooseTerminal(for record: HibernationRecord, preferred: String) -> String {
        if preferred != "auto", Self.isInstalled(preferred) { return preferred }
        if let id = record.host.bundleID, Self.terminals.contains(where: { $0.id == id }) { return id }
        return defaultTerminal()
    }

    /// The terminal you last used, then one that's open, then the one every Mac has.
    private func defaultTerminal() -> String {
        if let last = TerminalTracker.shared.last, Self.isInstalled(last) { return last }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.terminals.first { running.contains($0.id) }?.id ?? "com.apple.Terminal"
    }

    private func openApp(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Terminals with a "run this" flag get a new window that drops back to a shell afterwards.
    private func launch(_ bundleID: String, cwd: String, line: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = "\(line); exec \(shell) -l"
        let configuration = NSWorkspace.OpenConfiguration()
        // macOS only passes arguments to an app as it launches, so if the terminal is already
        // running, start another copy of it to run the command.
        configuration.createsNewApplicationInstance = true
        switch bundleID {
        case "com.mitchellh.ghostty":
            configuration.arguments = ["--working-directory=\(cwd)", "-e", shell, "-lc", script]
        case "net.kovidgoyal.kitty":
            configuration.arguments = ["--directory", cwd, shell, "-lc", script]
        default:
            configuration.arguments = ["start", "--cwd", cwd, "--", shell, "-lc", script]
        }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        return true
    }

    private func copy(_ line: String) -> Outcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        return .copied
    }

    private func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Types the command into the iTerm session on `tty` if there is one, else a new window.
    static func iTermScript(line: String, tty: String?) -> String {
        let command = appleScriptString(line)
        let find = tty.map { tty in
            """
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is \(appleScriptString(tty)) then
                            set target to aSession
                            select aWindow
                            select aTab
                        end if
                    end repeat
                end repeat
            end repeat
            """
        } ?? ""
        return """
        tell application id "com.googlecode.iterm2"
            activate
            set target to missing value
            \(find)
            if target is missing value then
                set newWindow to (create window with default profile)
                set target to current session of newWindow
            end if
            tell target to write text \(command)
        end tell
        """
    }

    /// Runs the command in the Terminal tab on `tty` if there is one, else a new window.
    static func terminalScript(line: String, tty: String?) -> String {
        let command = appleScriptString(line)
        let find = tty.map { tty in
            """
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if tty of aTab is \(appleScriptString(tty)) then
                        do script \(command) in aTab
                        set selected of aTab to true
                        set index of aWindow to 1
                        set done to true
                    end if
                end repeat
            end repeat
            """
        } ?? ""
        return """
        tell application "Terminal"
            activate
            set done to false
            \(find)
            if not done then do script \(command)
        end tell
        """
    }
}

/// Remembers the terminal you last switched to, across launches, so Open in Terminal and Wake
/// go where you actually work rather than to whichever terminal happens to be installed.
@MainActor
final class TerminalTracker {
    static let shared = TerminalTracker()
    private static let key = "lastTerminal"
    private var observer: NSObjectProtocol?

    var last: String? { UserDefaults.standard.string(forKey: Self.key) }

    func start() {
        guard observer == nil else { return }
        note(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let id = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { TerminalTracker.shared.note(id) }
        }
    }

    private func note(_ id: String?) {
        guard let id, id != last, Resumer.terminals.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: Self.key)
    }
}
