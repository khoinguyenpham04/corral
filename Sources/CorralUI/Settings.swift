import Foundation
import Observation

public enum MenuBarStyle: String, CaseIterable, Sendable {
    case icon, memory, idle

    public var label: String {
        switch self {
        case .icon: "Icon only"
        case .memory: "Icon and worktree memory"
        case .idle: "Icon and idle agents"
        }
    }
}

/// A global keyboard shortcut, stored as a Carbon key code and modifier mask.
public struct Shortcut: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// ⌃⌥⌘M: M for memory, and free in every app we checked.
    public static let standard = Shortcut(keyCode: 46, modifiers: 4096 | 2048 | 256, display: "⌃⌥⌘M")
}

/// Preferences, in the app's defaults domain (io.github.khoinguyenpham04.corral) so the CLI reads the same
/// idle threshold.
@MainActor @Observable
public final class CorralSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    public var hibernateDesktopSessions: Bool { didSet { defaults.set(hibernateDesktopSessions, forKey: "hibernateDesktopSessions") } }
    public var autoHibernate: Bool { didSet { defaults.set(autoHibernate, forKey: "autoHibernate") } }
    public var autoHibernateHours: Int { didSet { defaults.set(autoHibernateHours, forKey: "autoHibernateHours") } }
    public var pressureAlerts: Bool { didSet { defaults.set(pressureAlerts, forKey: "pressureAlerts") } }
    public var swapAlert: Bool { didSet { defaults.set(swapAlert, forKey: "swapAlert") } }
    public var swapAlertGB: Int { didSet { defaults.set(swapAlertGB, forKey: "swapAlertGB") } }
    public var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// "auto", "copy", or a terminal's bundle identifier.
    public var resumeTerminal: String { didSet { defaults.set(resumeTerminal, forKey: "resumeTerminal") } }
    /// Show memory, but never stop or hibernate anything. An organization can set this with a
    /// configuration profile, and then it can't be turned off here.
    public var readOnly: Bool { didSet { defaults.set(readOnly, forKey: "readOnly") } }
    public var readOnlyIsManaged: Bool { isManaged("readOnly") }

    /// True when a configuration profile sets this key, so Settings can't change it.
    public func isManaged(_ key: String) -> Bool { defaults.objectIsForced(forKey: key) }
    /// Ask GitHub once a day whether a newer Corral is out.
    public var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    /// The release the user said "Later" to; the panel stays quiet until a newer one.
    public var skippedUpdate: String? { didSet { defaults.set(skippedUpdate, forKey: "skippedUpdate") } }
    /// Leaked servers the user chose to keep running, by group id.
    public var keptServers: Set<String> { didSet { defaults.set(Array(keptServers), forKey: "keptServers") } }
    public var shortcut: Shortcut? {
        didSet {
            if let shortcut {
                defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers), "display": shortcut.display], forKey: "shortcut")
            } else {
                defaults.set([String: Any](), forKey: "shortcut")
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func integer(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        idleMinutes = integer("idleMinutes", 30)
        hibernateDesktopSessions = flag("hibernateDesktopSessions", true)
        autoHibernate = flag("autoHibernate", false)
        autoHibernateHours = integer("autoHibernateHours", 4)
        pressureAlerts = flag("pressureAlerts", true)
        swapAlert = flag("swapAlert", false)
        swapAlertGB = integer("swapAlertGB", 16)
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .icon
        resumeTerminal = defaults.string(forKey: "resumeTerminal") ?? "auto"
        keptServers = Set(defaults.stringArray(forKey: "keptServers") ?? [])
        readOnly = flag("readOnly", false)
        checkForUpdates = flag("checkForUpdates", true)
        skippedUpdate = defaults.string(forKey: "skippedUpdate")
        if let stored = defaults.dictionary(forKey: "shortcut") {
            if let code = stored["keyCode"] as? Int, let modifiers = stored["modifiers"] as? Int, let display = stored["display"] as? String {
                shortcut = Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers), display: display)
            } else {
                shortcut = nil
            }
        } else {
            shortcut = .standard
        }
    }
}
