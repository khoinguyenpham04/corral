import CorralCore
import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Corral: couldn't change the login item: \(error.localizedDescription)")
        }
    }
}

/// Links the `corral` binary inside the app bundle onto PATH: Homebrew's bin if it's writable
/// (no sudo), else ~/.local/bin.
enum CommandLineTool {
    struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/corral")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var directories: [URL] {
        ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"].map { URL(fileURLWithPath: $0) }
    }

    /// Where `corral` points at this app, if it's installed.
    static var installedAt: URL? {
        guard let bundled else { return nil }
        return directories.map { $0.appendingPathComponent("corral") }.first { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == bundled.path
        }
    }

    @discardableResult
    static func install() throws -> URL {
        guard let bundled else { throw InstallError(errorDescription: "This build of Corral doesn't include the command-line tool.") }
        let fm = FileManager.default
        let directory = directories.first { fm.isWritableFile(atPath: $0.path) } ?? directories[2]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("corral")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw InstallError(errorDescription: "\(link.path) already exists and isn't Corral's.")
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
        return link
    }
}

/// Takes Corral off this Mac: the login item, the `corral` command, its settings and data
/// (the activity log, the list of hibernated sessions, update logs), and the app itself, which
/// goes to the Trash so it can be put back. Hibernated sessions stay in each agent's history.
enum Uninstaller {
    /// Removes everything but the settings and the app, and returns what it couldn't remove.
    static func removeData() -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        if LoginItem.isEnabled { LoginItem.set(false) }
        if LoginItem.isEnabled { failed.append("the login item") }
        if let link = CommandLineTool.installedAt {
            do { try fm.removeItem(at: link) } catch { failed.append(Format.path(link.path)) }
        }
        // Worktrees in the Trash keep their git entries, unlocked for git's own cleanup.
        WorktreeTrash.release(store: .shared)
        let home = fm.homeDirectoryForCurrentUser
        let folders = [HibernationStore.defaultURL.deletingLastPathComponent()] + [
            "Library/Logs/Corral", "Library/Caches/io.github.khoinguyenpham04.corral", "Library/HTTPStorages/io.github.khoinguyenpham04.corral",
        ].map { home.appendingPathComponent($0) }
        for folder in folders where fm.fileExists(atPath: folder.path) {
            do { try fm.removeItem(at: folder) } catch { failed.append(Format.path(folder.path)) }
        }
        return failed
    }

    /// Moves Corral.app to the Trash. It keeps running until it quits.
    static func trashApp() throws {
        try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }

    /// Forgets Corral's settings and quits at once, so nothing writes them back on the way out.
    static func forgetSettingsAndQuit() -> Never {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "io.github.khoinguyenpham04.corral")
        UserDefaults.standard.synchronize()
        exit(0)
    }
}
