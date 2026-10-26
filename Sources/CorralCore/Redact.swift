import Foundation

/// Keeps secrets out of anything Corral writes down or prints: the activity log and
/// `corral snapshot --raw`. Masks values after token-ish flags, `KEY=value` pairs with
/// token-ish keys, passwords in URLs and well-known token formats, and cuts long arguments.
public enum Redact {
    static let mask = "•••"
    static let sensitive = ["token", "secret", "password", "passwd", "apikey", "api-key", "api_key", "auth", "credential", "private-key", "private_key"]
    static let tokenPrefixes = ["ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "sk-", "xoxb-", "xoxp-", "AKIA", "eyJ"]

    public static func arguments(_ args: [String]) -> [String] {
        var masked: [String] = []
        var maskNext = false
        for arg in args {
            if maskNext {
                masked.append(mask)
                maskNext = false
                continue
            }
            let lower = arg.lowercased()
            let flagged = sensitive.contains { lower.contains($0) }
            if arg.hasPrefix("-"), flagged {
                if let equals = arg.firstIndex(of: "=") { masked.append(String(arg[...equals]) + mask) } else { masked.append(arg); maskNext = true }
                continue
            }
            if !arg.hasPrefix("-"), let equals = arg.firstIndex(of: "="), isSensitive(String(arg[..<equals])) {
                masked.append(String(arg[...equals]) + mask)
                continue
            }
            if tokenPrefixes.contains(where: { arg.hasPrefix($0) && arg.count >= 20 }) {
                masked.append(mask)
                continue
            }
            let clean = maskingURLPassword(arg)
            masked.append(clean.count > 200 ? String(clean.prefix(200)) + "…" : clean)
        }
        return masked
    }

    /// A display command line, masked word by word.
    public static func command(_ line: String) -> String {
        arguments(line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)).joined(separator: " ")
    }

    public static func record(_ record: ProcessRecord) -> ProcessRecord {
        var copy = record
        copy.args = arguments(record.args)
        return copy
    }

    private static func isSensitive(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitive.contains { lower.contains($0) }
    }

    /// "https://me:hunter2@host/x" → "https://me:•••@host/x".
    private static func maskingURLPassword(_ arg: String) -> String {
        guard let scheme = arg.range(of: "://"), let at = arg[scheme.upperBound...].firstIndex(of: "@") else { return arg }
        let userInfo = arg[scheme.upperBound..<at]
        guard !userInfo.contains("/"), let colon = userInfo.firstIndex(of: ":") else { return arg }
        return String(arg[..<arg.index(after: colon)]) + mask + String(arg[at...])
    }
}
