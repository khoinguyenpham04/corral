import Darwin
import Foundation

/// Where a path lives: a git worktree (main or linked), or a plain project folder.
public struct WorktreeInfo: Sendable, Hashable {
    public var root: String
    public var gitDir: String?
    public var repoRoot: String
    public var kind: Checkout.Kind
    public var branch: String?

    public var repoName: String {
        let name = Paths.name(repoRoot)
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// The tool that made this worktree, recognised from where it lives on disk.
    public var manager: String? {
        let markers: [(String, String)] = [
            ("/.claude/worktrees/", "Claude"),
            ("/.codex/worktrees/", "Codex"),
            ("/.t3/worktrees/", "T3 Code"),
            ("/conductor/workspaces/", "Conductor"),
            ("/.conductor/", "Conductor"),
            ("/.cursor/worktrees/", "Cursor"),
            ("/.opencode/worktrees/", "OpenCode"),
            ("/.cmux/", "cmux"),
        ]
        return markers.first { root.contains($0.0) }?.1
    }

    /// A short name for the row: the repo name for a main checkout, otherwise the worktree's
    /// folder with generated suffixes trimmed ("table-color-ui-design-99dc44" → "table-color-ui-design").
    /// Generated folder names ("t3code-9503f4f7", "agitated-dijkstra-3e4138") give way to the
    /// branch, which agents usually rename to describe the work.
    public var displayName: String {
        if kind == .main { return repoName }
        var name = Paths.name(root)
        if name == repoName, kind == .worktree {
            // ~/.codex/worktrees/<slug>/<repo>: the slug is the meaningful part.
            name = Paths.name(Paths.parent(root))
        }
        if Self.hasGeneratedSuffix(name), let leaf = branch?.split(separator: "/").last, !leaf.isEmpty {
            return Self.trimGeneratedSuffix(String(leaf))
        }
        return Self.trimGeneratedSuffix(name)
    }

    static func hasGeneratedSuffix(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-"), dash > name.startIndex else { return false }
        let suffix = name[name.index(after: dash)...]
        return (6...8).contains(suffix.count) && suffix.allSatisfy(\.isHexDigit) && suffix.contains(where: \.isNumber)
    }

    static func trimGeneratedSuffix(_ name: String) -> String {
        guard hasGeneratedSuffix(name), let dash = name.lastIndex(of: "-") else { return name }
        return String(name[..<dash])
    }
}

/// Finds the git worktree that contains a path by reading `.git` entries directly (no `git`
/// subprocess). Results are cached per directory.
final class WorktreeResolver {
    private var rootForDirectory: [String: String] = [:]
    private var infoForRoot: [String: WorktreeInfo] = [:]
    private var projectForDirectory: [String: String] = [:]
    private var lastReset = Date()
    private let home: String
    /// The git directory's name: ".git" everywhere but tests, which can't write .git in some sandboxes.
    private let dotGit: String

    static let projectManifests = [
        "package.json", "wrangler.toml", "wrangler.json", "wrangler.jsonc", "Cargo.toml", "go.mod",
        "pyproject.toml", "Gemfile", "deno.json", "deno.jsonc", "Package.swift", "pom.xml",
        "build.gradle", "build.gradle.kts", "mix.exs", "composer.json",
    ]

    init(home: String = Paths.home, dotGit: String = ".git") {
        self.home = home
        self.dotGit = dotGit
    }

    /// Branches change and worktrees come and go; forget everything every couple of minutes.
    func expireIfNeeded(now: Date = Date()) {
        guard now.timeIntervalSince(lastReset) > 120 else { return }
        rootForDirectory.removeAll(keepingCapacity: true)
        infoForRoot.removeAll(keepingCapacity: true)
        projectForDirectory.removeAll(keepingCapacity: true)
        lastReset = now
    }

    /// Checkouts live in the home folder, on external volumes or in temp dirs. Everything else
    /// (/opt/homebrew is itself a git repo, ~/Library holds app data) is never a checkout.
    func isUserSpace(_ path: String) -> Bool {
        if path.hasPrefix(home + "/") { return !path.hasPrefix(home + "/Library/") }
        return ["/Volumes/", "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/Users/Shared/"].contains { path.hasPrefix($0) }
    }

    /// A hidden folder in home (~/.git-ai/internal/daemon) holds a tool's own state, not a
    /// project. Agents' worktree folders (~/.codex/worktrees/…) are the exception.
    func isToolState(_ path: String) -> Bool {
        path.hasPrefix(home + "/.") && !path.contains("/worktrees/")
    }

    func worktree(containing path: String) -> WorktreeInfo? {
        guard isUserSpace(path) else { return nil }
        var directory = Paths.normalize(path)
        var visited: [String] = []
        var found: String?
        while true {
            if let cached = rootForDirectory[directory] {
                found = cached.isEmpty ? nil : cached
                break
            }
            visited.append(directory)
            if let info = gitInfo(at: directory) {
                infoForRoot[directory] = info
                found = directory
                break
            }
            if directory == "/" { break }
            directory = Paths.parent(directory)
        }
        for entry in visited { rootForDirectory[entry] = found ?? "" }
        return found.flatMap { infoForRoot[$0] }
    }

    /// The nearest folder with a project manifest, for code that isn't in git (a scratch copy
    /// in /tmp, say). Never climbs to the home folder or above, and ignores node_modules.
    func project(containing path: String) -> WorktreeInfo? {
        var directory = Paths.normalize(path)
        if let range = directory.range(of: "/node_modules") { directory = String(directory[..<range.lowerBound]) }
        guard isUserSpace(directory) else { return nil }

        var visited: [String] = []
        var found: String?
        while directory != home, directory != "/", directory.count > 1 {
            if let cached = projectForDirectory[directory] {
                found = cached.isEmpty ? nil : cached
                break
            }
            visited.append(directory)
            if Self.projectManifests.contains(where: { access(directory + "/" + $0, F_OK) == 0 }) {
                found = directory
                break
            }
            directory = Paths.parent(directory)
        }
        for entry in visited { projectForDirectory[entry] = found ?? "" }
        return found.map { WorktreeInfo(root: $0, gitDir: nil, repoRoot: $0, kind: .project, branch: nil) }
    }

    private func gitInfo(at directory: String) -> WorktreeInfo? {
        // A dotfiles repo at ~ (or /) would otherwise claim every process on the machine.
        guard directory != home, directory != "/" else { return nil }
        let entry = directory + "/" + dotGit
        var status = stat()
        guard lstat(entry, &status) == 0 else { return nil }

        if status.st_mode & S_IFMT == S_IFDIR {
            return WorktreeInfo(root: directory, gitDir: entry, repoRoot: directory, kind: .main, branch: Self.branch(gitDir: entry))
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              let text = try? String(contentsOfFile: entry, encoding: .utf8),
              text.hasPrefix("gitdir:")
        else { return nil }

        var gitDir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDir.hasPrefix("/") { gitDir = Paths.normalize(directory + "/" + gitDir) }
        // Submodules point into .git/modules; keep walking up to the superproject.
        if gitDir.contains("/\(dotGit)/modules/") { return nil }

        var common = gitDir
        if let relative = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty {
            common = relative.hasPrefix("/") ? relative : Paths.normalize(gitDir + "/" + relative)
        }
        let repoRoot = Paths.name(common) == dotGit ? Paths.parent(common) : common
        return WorktreeInfo(root: directory, gitDir: gitDir, repoRoot: repoRoot, kind: .worktree, branch: Self.branch(gitDir: gitDir))
    }

    static func branch(gitDir: String) -> String? {
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        guard head.hasPrefix("ref: refs/heads/") else { return nil }
        return String(head.dropFirst("ref: refs/heads/".count))
    }
}
