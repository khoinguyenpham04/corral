import Foundation

/// A process tree folded into one group, before sessions and checkouts are attached.
struct GroupDraft {
    var rootPID: Int32
    var members: [Int32] = []
    var leadPID: Int32
    var leadWeight = -1
    var hasAgent = false
}

/// Folds the process table into groups. A group starts below a boundary (an app, a shell,
/// launchd) and takes in everything its root spawns, except that work an agent starts in the
/// background (a dev server, a watcher) gets its own group. Pure: no system calls.
struct Grouper {
    let records: [Int32: ProcessRecord]
    let roles: [Int32: Role]
    let ownUID: UInt32

    private(set) var drafts: [GroupDraft] = []
    /// Processes that belong to GUI apps or to macOS itself.
    private(set) var appMembers: [Int32] = []
    private var children: [Int32: [Int32]] = [:]
    private var serviceBelow: [Int32: Bool] = [:]
    private var visited = Set<Int32>()

    init(records: [ProcessRecord], roles: [Int32: Role], ownUID: UInt32) {
        var byPID: [Int32: ProcessRecord] = [:]
        for record in records { byPID[record.pid] = record }
        self.records = byPID
        self.roles = roles
        self.ownUID = ownUID
        for record in records where record.ppid != record.pid && byPID[record.ppid] != nil {
            children[record.ppid, default: []].append(record.pid)
        }
        for key in children.keys { children[key]?.sort() }
    }

    mutating func run() {
        let roots = records.values
            .filter { $0.ppid == $0.pid || records[$0.ppid] == nil }
            .map(\.pid)
            .sorted()
        for root in roots { visit(root, into: nil) }
        for pid in records.keys.sorted() where !visited.contains(pid) { visit(pid, into: nil) }
    }

    private mutating func visit(_ pid: Int32, into group: Int?) {
        guard let record = records[pid], visited.insert(pid).inserted else { return }
        let role = roles[pid] ?? .unknown(record.executable)
        let kids = children[pid] ?? []

        guard record.uid == ownUID else {
            for child in kids { visit(child, into: nil) }
            return
        }

        if group == nil {
            switch role {
            case .app, .system:
                appMembers.append(pid)
                for child in kids { visit(child, into: nil) }
                return
            case .shell, .multiplexer, .login:
                for child in kids { visit(child, into: nil) }
                return
            default:
                break
            }
        } else if role.isBoundary {
            for child in kids { visit(child, into: nil) }
            return
        }

        let target: Int
        if let group, !(drafts[group].hasAgent && !role.isAgent && (role.isService || hasServiceBelow(pid))) {
            target = group
        } else {
            drafts.append(GroupDraft(rootPID: pid, leadPID: pid))
            target = drafts.count - 1
        }
        add(pid, role: role, to: target)

        if case .processManager = role {
            for child in kids { visit(child, into: nil) }
        } else {
            for child in kids { visit(child, into: target) }
        }
    }

    private mutating func add(_ pid: Int32, role: Role, to index: Int) {
        drafts[index].members.append(pid)
        if role.isAgent { drafts[index].hasAgent = true }
        let weight = role.weight
        let current = drafts[index]
        let footprint = records[pid]?.footprint ?? 0
        let leadFootprint = records[current.leadPID]?.footprint ?? 0
        if weight > current.leadWeight || (weight == current.leadWeight && weight == 0 && footprint > leadFootprint) {
            drafts[index].leadPID = pid
            drafts[index].leadWeight = weight
        }
    }

    private mutating func hasServiceBelow(_ pid: Int32) -> Bool {
        if let cached = serviceBelow[pid] { return cached }
        var found = false
        for child in children[pid] ?? [] {
            if roles[child]?.isService == true || hasServiceBelow(child) {
                found = true
                break
            }
        }
        serviceBelow[pid] = found
        return found
    }

    /// The pgid that covers exactly these processes and nothing else, if there is one.
    func signalGroup(for members: [Int32]) -> Int32? {
        let memberSet = Set(members)
        let pgids = Set(members.compactMap { records[$0]?.pgid })
        guard pgids.count == 1, let pgid = pgids.first, pgid > 1 else { return nil }
        let inGroup = records.values.filter { $0.pgid == pgid }.map(\.pid)
        return Set(inGroup) == memberSet ? pgid : nil
    }

    /// Ancestors of `pid`, nearest first, stopping before launchd.
    func ancestors(of pid: Int32) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        var current = records[pid]?.ppid
        var seen = Set<Int32>()
        while let next = current, next > 1, let record = records[next], seen.insert(next).inserted {
            result.append(record)
            current = record.ppid
        }
        return result
    }
}

/// App bundle names and identifiers, read from Info.plist once per bundle.
final class BundleCatalog {
    struct Info: Hashable {
        let path: String
        let identifier: String?
        let name: String
    }

    private var cache: [String: Info] = [:]

    /// `known` pre-seeds bundles by path, for tests.
    init(known: [Info] = []) {
        for info in known { cache[info.path] = info }
    }

    /// The outermost app bundle that contains `executable`, so Chrome's helper apps count as
    /// Chrome. Chrome relaunches from a staged "Google Chrome.app.bundle" after updates.
    static func bundlePath(containing executable: String) -> String? {
        let ends = [".app/", ".app.bundle/"].compactMap { executable.range(of: $0) }
        guard let first = ends.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return String(executable[..<executable.index(before: first.upperBound)])
    }

    func info(forExecutable executable: String) -> Info? {
        guard let path = Self.bundlePath(containing: executable) else { return nil }
        if let cached = cache[path] { return cached }
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        let fallback = Paths.name(path).replacingOccurrences(of: ".bundle", with: "").replacingOccurrences(of: ".app", with: "")
        let name = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleName"] as? String) ?? fallback
        let info = Info(path: path, identifier: plist?["CFBundleIdentifier"] as? String, name: name.isEmpty ? fallback : name)
        cache[path] = info
        return info
    }

    /// How an app hosts agents: terminals and editors run TUIs; others drive sessions themselves.
    static func host(for info: Info) -> AgentHost {
        let id = info.identifier ?? ""
        let known: [String: (AgentHost.Kind, String)] = [
            "com.anthropic.claudefordesktop": (.app, "Claude Desktop"),
            "com.openai.codex": (.app, "Codex Desktop"),
            "com.openai.chat": (.app, "ChatGPT"),
            "com.t3tools.t3code": (.app, "T3 Code"),
            "ai.opencode.desktop": (.app, "OpenCode Desktop"),
            "com.exafunction.windsurf": (.editor, info.name),
            "com.todesktop.230313mzl4w4u92": (.editor, "Cursor"),
            "com.microsoft.VSCode": (.editor, "VS Code"),
            "com.microsoft.VSCodeInsiders": (.editor, "VS Code Insiders"),
            "com.vscodium": (.editor, "VSCodium"),
            "dev.zed.Zed": (.editor, "Zed"),
            "dev.zed.Zed-Preview": (.editor, "Zed"),
            "com.googlecode.iterm2": (.terminal, "iTerm"),
            "com.apple.Terminal": (.terminal, "Terminal"),
            "com.mitchellh.ghostty": (.terminal, "Ghostty"),
            "com.github.wez.wezterm": (.terminal, "WezTerm"),
            "net.kovidgoyal.kitty": (.terminal, "kitty"),
            "org.alacritty": (.terminal, "Alacritty"),
            "io.alacritty": (.terminal, "Alacritty"),
            "dev.warp.Warp-Stable": (.terminal, "Warp"),
            "dev.warp.Warp": (.terminal, "Warp"),
            "co.zeit.hyper": (.terminal, "Hyper"),
            "org.tabby": (.terminal, "Tabby"),
            "com.raphaelamorim.rio": (.terminal, "Rio"),
        ]
        if let (kind, name) = known[id] { return AgentHost(kind: kind, name: name, bundleID: id) }
        if id.hasPrefix("com.jetbrains.") { return AgentHost(kind: .editor, name: info.name, bundleID: id) }
        if info.name.localizedCaseInsensitiveContains("cmux") { return AgentHost(kind: .terminal, name: "cmux", bundleID: id) }
        return AgentHost(kind: .app, name: info.name, bundleID: info.identifier)
    }
}
