import AppKit
import CorralCore
import CorralUI
import Foundation

/// Asks GitHub for a newer Corral shortly after launch and then once a day, while the setting
/// is on. A newer release shows up as a note in the panel and an item in the menu.
@MainActor
final class Updates {
    private let settings: CorralSettings
    private let model: PanelModel
    private var loop: Task<Void, Never>?

    init(settings: CorralSettings, model: PanelModel) {
        self.settings = settings
        self.model = model
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if self?.settings.checkForUpdates == true { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// Checks now and says what it found, for the menu's "Check for Updates" and Settings. A
    /// check someone asked for brings back an update they put off with Later.
    @discardableResult
    func check(manual: Bool = true) async -> String {
        let current = UpdateCheck.currentVersion
        guard let released = await UpdateCheck.released() else {
            return "Couldn't check. It needs the network and git."
        }
        guard let latest = released.max(by: { UpdateCheck.isNewer($1, than: $0) }) else { return "No releases yet." }
        guard UpdateCheck.isNewer(latest, than: current) else {
            model.update = nil
            return "You're up to date: \(current) is the newest."
        }
        if manual { settings.skippedUpdate = nil }
        model.update = UpdateCheck.Release(version: latest)
        return "Corral \(latest) is available."
    }

    /// Installs a release with the installer inside Corral.app, which quits this copy and opens
    /// the new one. It runs on its own, logging to ~/Library/Logs/Corral/update.log, so it
    /// carries on after Corral quits. Calls `failed` if it stops before that.
    func install(_ release: UpdateCheck.Release, failed: @escaping @MainActor (String) -> Void) {
        guard let installer = UpdateCheck.installer else {
            failed("This copy of Corral has no installer.")
            return
        }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Corral")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CORRAL_VERSION"] = release.version
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        let bundle = Bundle.main.bundleURL
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard status != 0 else {
                    // The installer quits this copy before it finishes. If this copy is somehow
                    // still running, the new one is in place: open it and quit.
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
                        Task { @MainActor in NSApp.terminate(nil) }
                    }
                    return
                }
                // The installer's last word is why it stopped, as "install.sh: <reason>".
                let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
                let reason = lines.last { $0.hasPrefix("install.sh: ") }.map { String($0.dropFirst(12)).sentence }
                failed(reason ?? "The installer stopped. Its log is in ~/Library/Logs/Corral/update.log.")
            }
        }
        do { try process.run() } catch { failed(error.localizedDescription) }
    }
}

private extension String {
    var sentence: String { prefix(1).uppercased() + dropFirst() + (hasSuffix(".") ? "" : ".") }
}
