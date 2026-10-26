import Foundation

/// Human-readable sizes and durations, matching how Activity Monitor rounds (1 GB = 1024³ bytes).
public enum Format {
    static let gib = 1024.0 * 1024 * 1024
    static let mib = 1024.0 * 1024

    /// "21.1 GB", "0.7 GB", "84 MB".
    public static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 0.095 * gib { return String(format: "%.1f GB", value / gib) }
        return "\(Int((value / mib).rounded())) MB"
    }

    /// Installed RAM: "48 GB", "16 GB".
    public static func capacity(_ bytes: UInt64) -> String {
        let value = Double(bytes) / gib
        return value.rounded() == value ? "\(Int(value)) GB" : String(format: "%.1f GB", value)
    }

    /// A disk's size or free space as Finder shows it, in thousands: "994 GB", "1.8 TB".
    public static func disk(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1e9
        return value >= 1000 ? String(format: "%.1f TB", value / 1000) : "\(Int(value)) GB"
    }

    /// The number and unit separately, for layouts that set them in different type.
    public static func bytesParts(_ bytes: UInt64) -> (value: String, unit: String) {
        let text = Self.bytes(bytes)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? text, parts.count > 1 ? parts[1] : "")
    }

    /// "now", "4 min", "7 h", "3 d".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 * 2 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// "Idle 33 h", "Idle 4 min", "Idle".
    public static func idle(_ interval: TimeInterval) -> String {
        interval < 60 ? "Idle" : "Idle \(duration(interval))"
    }

    /// "/Users/me/Developer/x" → "~/Developer/x".
    public static func path(_ path: String) -> String { Paths.abbreviate(path) }

    /// "A", "A and B", "A, B and 3 more".
    public static func names(_ names: [String], limit: Int = 2) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count <= limit + 1 && names.count <= 3 {
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }

    /// "just now", "2 min ago", "7 h ago".
    public static func ago(_ interval: TimeInterval) -> String {
        interval < 60 ? "just now" : "\(duration(interval)) ago"
    }
}
