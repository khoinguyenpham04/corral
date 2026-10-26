import Foundation

/// Tracks CPU use per group between samples, to tell a working agent from one waiting for you
/// when the agent's own files don't say.
final class ActivityTracker {
    private var samples: [String: (cpu: UInt64, at: Date)] = [:]
    private var lastBusy: [String: Date] = [:]
    private var seen = Set<String>()

    /// Records a group's total CPU time and returns when it last used more than `threshold`
    /// of one core.
    func update(key: String, cpuTime: UInt64, now: Date, threshold: Double = 0.05) -> Date? {
        seen.insert(key)
        if let previous = samples[key], cpuTime >= previous.cpu {
            let elapsed = now.timeIntervalSince(previous.at)
            if elapsed > 0.5, Double(cpuTime - previous.cpu) / (elapsed * 1_000_000_000) > threshold {
                lastBusy[key] = now
            }
        }
        samples[key] = (cpuTime, now)
        return lastBusy[key]
    }

    /// Forgets groups that weren't part of the sample that just finished.
    func endSample() {
        samples = samples.filter { seen.contains($0.key) }
        lastBusy = lastBusy.filter { seen.contains($0.key) }
        seen.removeAll(keepingCapacity: true)
    }
}

/// Programs that launchd starts on purpose (from LaunchAgents plists), so a daemon whose parent
/// is launchd isn't mistaken for a leaked dev server.
final class LaunchAgentIndex {
    private var programs = Set<String>()
    private var loadedAt = Date.distantPast
    private let directories: [String]

    static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "perl", "sh", "bash", "zsh", "env", "osascript",
    ]

    init(directories: [String] = [Paths.home + "/Library/LaunchAgents", "/Library/LaunchAgents"]) {
        self.directories = directories
    }

    func refreshIfNeeded(now: Date) {
        guard now.timeIntervalSince(loadedAt) > 300 else { return }
        loadedAt = now
        var found = Set<String>()
        for directory in directories {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".plist") {
                guard let plist = NSDictionary(contentsOfFile: directory + "/" + name) else { continue }
                var paths: [String] = []
                if let program = plist["Program"] as? String { paths.append(program) }
                if let arguments = plist["ProgramArguments"] as? [String] {
                    paths += arguments.prefix(4).filter { $0.hasPrefix("/") }
                }
                for path in paths where !Self.interpreters.contains(Paths.name(path)) && !Invocation.isPython(Paths.name(path)) {
                    found.insert(path)
                    found.insert((path as NSString).resolvingSymlinksInPath)
                }
            }
        }
        programs = found
    }

    func matches(_ record: ProcessRecord) -> Bool {
        programs.contains(record.path) || record.args.dropFirst().prefix(3).contains(where: programs.contains)
    }
}
