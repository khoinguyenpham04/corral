import Darwin
import Foundation

/// Finds out whether a newer Corral has been released, by asking GitHub for the repository's
/// tags with git. The repository is public, so it needs no account, and it quietly finds
/// nothing when there's no network or no git. It never prompts: no password dialogs, no
/// browser windows.
public enum UpdateCheck {
    public static let project = "https://github.com/khoinguyenpham04/corral"
    public static let remote = "\(project).git"
    public static let releases = "\(project)/releases"

    /// A new GitHub issue, with a short template and this Mac's versions filled in.
    public static var feedback: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var chip = utsname()
        uname(&chip)
        let machine = withUnsafeBytes(of: &chip.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let description = """
        **What happened?**


        **What did you expect instead?**


        ---
        Corral \(currentVersion) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(machine == "arm64" ? "Apple Silicon" : "Intel")
        """
        var components = URLComponents(string: "\(project)/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: description)]
        return components.url!
    }

    public struct Release: Sendable, Equatable {
        public let version: String

        public init(version: String) {
            self.version = version
        }

        public var page: URL { URL(string: "\(UpdateCheck.releases)/tag/v\(version)")! }
    }

    /// This build's version, for the app and for the CLI inside it (Corral.app/Contents/Helpers).
    public static var currentVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return version }
        guard let contents = bundleContents else { return "dev" }
        return NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The installer inside Corral.app, which downloads a release and puts it in Applications.
    public static var installer: URL? {
        guard let script = bundleContents?.appendingPathComponent("Resources/install.sh"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return script
    }

    /// Corral.app/Contents, from the app or from the CLI in Contents/Helpers (even through a symlink on PATH).
    private static var bundleContents: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        let contents = URL(fileURLWithPath: String(cString: resolved)).deletingLastPathComponent().deletingLastPathComponent()
        return contents.lastPathComponent == "Contents" ? contents : nil
    }

    /// The newest release, when it's newer than `current`. Nil when up to date or unknown.
    public static func newer(than current: String, timeout: TimeInterval = 20) async -> Release? {
        guard let latest = await latest(timeout: timeout), isNewer(latest, than: current) else { return nil }
        return Release(version: latest)
    }

    /// The newest released version, or nil when there's none or the check couldn't run.
    public static func latest(timeout: TimeInterval = 20) async -> String? {
        await released(timeout: timeout)?.max(by: { isNewer($1, than: $0) })
    }

    /// Every released version, or nil when the check couldn't run (no git, or offline).
    public static func released(timeout: TimeInterval = 20) async -> [String]? {
        guard let git = Subprocess.git else { return nil }
        let output = await Task.detached { Subprocess.run(git, ["ls-remote", "--tags", "--refs", remote], timeout: timeout) }.value
        return output.map(versions(inLsRemote:))
    }

    /// "4f3c…\trefs/tags/v0.2.0" lines → ["0.2.0"]. Tags that aren't versions are skipped.
    static func versions(inLsRemote output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/v") else { return nil }
            let version = String(ref.dropFirst("refs/tags/v".count))
            return numbers(version).isEmpty ? nil : version
        }
    }

    /// Compares "0.10.0" and "0.9.2" by number, not by text.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let a = numbers(version)
        let b = numbers(other)
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }
}
