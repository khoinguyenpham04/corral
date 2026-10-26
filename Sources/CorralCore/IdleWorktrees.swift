import Darwin
import Foundation

/// A linked git worktree, found through its repository's list rather than by something
/// running in it.
public struct LinkedWorktree: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    /// The repository's entry for it (`.git/worktrees/<id>`), where git keeps its HEAD and index.
    public var adminDir: String
    /// The main checkout, or the bare repository, that `git worktree` commands run in.
    public var repoPath: String
    public var repoName: String
    public var name: String
    public var branch: String?
    /// HEAD isn't on a branch, so commits made here may be on no branch at all.
    public var detached: Bool
    /// Someone ran `git worktree lock` on it.
    public var locked: Bool
    /// Its submodules keep their history in the repository's entry for it, which goes when the
    /// worktree does.
    public var hasSubmodules: Bool
    /// A rebase, merge, cherry-pick, revert or bisect it's in the middle of.
    public var operation: String?
    /// The tool that made it ("Claude", "Codex", ...), when its folder says.
    public var manager: String?

    public var id: String { path }

    /// Its entry and the repository's git directory, where its submodules' git directories live.
    var gitDirs: [String] { [adminDir, Paths.parent(Paths.parent(adminDir))] }

    public init(
        path: String, adminDir: String, repoPath: String, repoName: String, name: String, branch: String?,
        detached: Bool, locked: Bool = false, hasSubmodules: Bool = false, operation: String? = nil, manager: String? = nil
    ) {
        self.path = path
        self.adminDir = adminDir
        self.repoPath = repoPath
        self.repoName = repoName
        self.name = name
        self.branch = branch
        self.detached = detached
        self.locked = locked
        self.hasSubmodules = hasSubmodules
        self.operation = operation
        self.manager = manager
    }
}

/// Finds linked worktrees: in the repositories Corral has seen something run in, and in the
/// repositories behind the folders where coding agents keep theirs.
public enum WorktreeCatalog {
    /// Where agents put worktrees, one or two folders down: ~/.codex/worktrees/<task>/<repo>,
    /// ~/.t3/worktrees/<repo>/<name>. Claude's .claude/worktrees live inside the repository.
    static let agentFolders = [".codex/worktrees", ".t3/worktrees", "conductor/workspaces", ".cursor/worktrees", ".opencode/worktrees"]

    /// The repository's git directory, from its main checkout (or the bare repository itself).
    public static func commonDir(forRepo repoPath: String, dotGit: String = ".git") -> String? {
        if isDirectory(repoPath + "/" + dotGit) { return repoPath + "/" + dotGit }
        if isDirectory(repoPath + "/worktrees"), access(repoPath + "/HEAD", F_OK) == 0 { return repoPath }
        return nil
    }

    /// The git directories of the repositories behind agents' worktree folders.
    public static func repositoriesInAgentFolders(home: String = NSHomeDirectory(), dotGit: String = ".git") -> Set<String> {
        let fm = FileManager.default
        var found = Set<String>()
        for folder in agentFolders {
            let base = home + "/" + folder
            guard let children = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for child in children where !child.hasPrefix(".") {
                let path = base + "/" + child
                var candidates = [path]
                if !isFile(path + "/" + dotGit), let grandchildren = try? fm.contentsOfDirectory(atPath: path) {
                    candidates = grandchildren.filter { !$0.hasPrefix(".") }.map { path + "/" + $0 }
                }
                for candidate in candidates {
                    if let common = commonDir(ofWorktree: candidate, dotGit: dotGit) { found.insert(common) }
                }
            }
        }
        return found
    }

    /// Every linked worktree of these repositories whose folder is still there.
    public static func worktrees(in commonDirs: Set<String>, dotGit: String = ".git") -> [LinkedWorktree] {
        var found: [LinkedWorktree] = []
        var seen = Set<String>()
        for common in commonDirs.sorted() {
            let list = common + "/worktrees"
            guard let ids = try? FileManager.default.contentsOfDirectory(atPath: list) else { continue }
            let repoPath = Paths.name(common) == dotGit ? Paths.parent(common) : common
            for id in ids.sorted() {
                let admin = list + "/" + id
                guard let pointer = read(admin + "/gitdir"), !pointer.isEmpty else { continue }
                let gitFile = Paths.normalize(pointer.hasPrefix("/") ? pointer : admin + "/" + pointer)
                let root = Paths.parent(gitFile)
                // A folder that's gone, or that moved and now belongs to another entry, isn't this one.
                guard !seen.contains(root), adminDir(ofGitFile: gitFile).map({ same($0, admin) }) == true else { continue }
                seen.insert(root)
                let head = read(admin + "/HEAD") ?? ""
                // A reftable repository's HEAD file is a stub; its branch shows once git is asked.
                let named = head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst("ref: refs/heads/".count)) : nil
                let branch = named == ".invalid" ? nil : named
                let info = WorktreeInfo(root: root, gitDir: admin, repoRoot: repoPath, kind: .worktree, branch: branch)
                found.append(LinkedWorktree(
                    path: root, adminDir: admin, repoPath: repoPath, repoName: info.repoName, name: info.displayName, branch: branch,
                    detached: !head.hasPrefix("ref:"), locked: access(admin + "/locked", F_OK) == 0,
                    hasSubmodules: isDirectory(admin + "/modules"), operation: operation(inAdmin: admin), manager: info.manager
                ))
            }
        }
        return found
    }

    /// The repository's git directory, from a linked worktree's `.git` file. A submodule's
    /// points into `modules/` instead of `worktrees/`.
    static func commonDir(ofWorktree root: String, dotGit: String) -> String? {
        guard let admin = adminDir(ofGitFile: root + "/" + dotGit), Paths.name(Paths.parent(admin)) == "worktrees",
              let relative = read(admin + "/commondir"), !relative.isEmpty
        else { return nil }
        let common = Paths.normalize(relative.hasPrefix("/") ? relative : admin + "/" + relative)
        return isDirectory(common + "/worktrees") ? common : nil
    }

    /// What git is in the middle of there, from the markers it leaves in the worktree's entry.
    static func operation(inAdmin admin: String) -> String? {
        let markers = [
            ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
            ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("BISECT_LOG", "bisect"),
        ]
        return markers.first { access(admin + "/" + $0.0, F_OK) == 0 }?.1
    }

    /// Where a worktree's `.git` file points: its entry in the repository.
    static func adminDir(ofGitFile gitFile: String) -> String? {
        guard let text = read(gitFile), text.hasPrefix("gitdir:") else { return nil }
        let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return Paths.normalize(target.hasPrefix("/") ? target : Paths.parent(gitFile) + "/" + target)
    }

    /// The same folder, even when one path goes through a symlink (/tmp and /private/tmp).
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let left = realpath(a, nil), let right = realpath(b, nil) else { return false }
        defer {
            free(left)
            free(right)
        }
        return strcmp(left, right) == 0
    }

    static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    static func isFile(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
    }
}

/// What git says about a worktree's work.
public struct GitState: Codable, Sendable, Hashable {
    /// Files changed, staged, or new and not ignored, counting edits git status hides
    /// (assume-unchanged and skip-worktree files). Nil when git didn't answer.
    public var changes: Int?
    /// Commits on no branch, tag or remote that only this worktree knows: its detached HEAD's,
    /// and ones a detached HEAD left behind when it moved on. A branch keeps its commits when
    /// its worktree goes.
    public var unsavedCommits: Int?
    public var checkedAt: Date

    public init(changes: Int?, unsavedCommits: Int?, checkedAt: Date) {
        self.changes = changes
        self.unsavedCommits = unsavedCommits
        self.checkedAt = checkedAt
    }

    public var answered: Bool { changes != nil && unsavedCommits != nil }
}

enum WorktreeGit {
    static func state(of worktree: LinkedWorktree, now: Date = Date()) -> GitState {
        guard let git = Subprocess.git else { return GitState(changes: nil, unsavedCommits: nil, checkedAt: now) }
        // With core.fsmonitor on, anything that reads the index starts a file-watching daemon
        // in the worktree, and Corral looks at a hundred of them.
        let run: (String, [String]) -> String? = { directory, arguments in
            Subprocess.run(git, ["-C", directory, "-c", "core.fsmonitor=false"] + arguments, timeout: 30)
        }
        let path = worktree.path
        let status = run(path, ["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none"])
        let files = run(path, ["ls-files", "-v", "-z"])
        var changes: Int?
        if let status, let files { changes = Self.changes(inPorcelain: status) + hiddenEdits(inLsFiles: files, root: path) }
        return GitState(changes: changes, unsavedCommits: unsavedCommits(at: ["-C", path], repoPath: worktree.repoPath, git: git), checkedAt: now)
    }

    /// Commits only a worktree's entry keeps: its HEAD, everything HEAD's log still has (a
    /// detached HEAD that was reset, amended or moved on), and refs of its own (refs/worktree,
    /// a bisect, a rebase's rewritten commits). A rebase's own steps don't count: they're the
    /// copies it makes on the way, and the result is on the branch. Counted against everything
    /// that outlasts the entry, branches, tags, remotes and their logs, as the main checkout
    /// sees them without this worktree's. `location` is `-C <worktree>` or `--git-dir=<entry>`.
    /// Asked whether HEAD is detached or not, since it may have moved since Corral looked. Nil
    /// when git didn't answer.
    static func unsavedCommits(at location: [String], repoPath: String, git: String) -> Int? {
        func run(_ place: [String], _ arguments: [String], input: String? = nil) -> String? {
            Subprocess.run(git, place + ["-c", "core.fsmonitor=false"] + arguments, input: input, timeout: 30)
        }
        guard let head = run(location, ["rev-parse", "--verify", "HEAD"]),
              let log = run(location, ["reflog", "show", "--format=%H %gs", "HEAD"]),
              let refs = run(location, ["for-each-ref", "--format=%(objectname)", "refs/worktree", "refs/bisect", "refs/rewritten"])
        else { return nil }
        let commits = Set(([head, refs].joined(separator: "\n").split(separator: "\n").map(String.init) + logged(inReflog: log)).filter(isCommitID))
        let count = run(
            ["-C", repoPath],
            ["rev-list", "--count", "--ignore-missing", "--stdin", "--not", "--branches", "--remotes", "--tags", "--single-worktree", "--reflog"],
            input: commits.sorted().joined(separator: "\n") + "\n"
        )
        return count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The commits HEAD's log (newest first, as `%H %gs`) holds on to: every entry's commit,
    /// and every commit a checkout moved away from, except a rebase's own steps before its
    /// last. Those are copies on the way to its result, superseded by it (the steps a squash
    /// folds away); the last entry of each rebase, its result, does count, so a rebase of a
    /// detached HEAD that was then left behind is caught.
    static func logged(inReflog output: String) -> [String] {
        var commits: [String] = []
        var inRebase = false
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let commit = String(line[..<space])
            let subject = line[line.index(after: space)...]
            if subject.hasPrefix("rebase") {
                // Newest first: the first step of a rebase seen is its last.
                if !inRebase { commits.append(commit) }
                // Its "(start)" step, seen last, closes it; anything older is another run.
                inRebase = !subject.prefix { $0 != ":" }.contains("(start)")
            } else {
                inRebase = false
                commits.append(commit)
            }
            if subject.hasPrefix("checkout: moving from "), let from = subject.dropFirst("checkout: moving from ".count).split(separator: " ").first {
                commits.append(String(from))
            }
        }
        return commits
    }

    private static func isCommitID(_ text: String) -> Bool {
        [40, 64].contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    /// One line per changed path in `git status --porcelain`.
    static func changes(inPorcelain output: String) -> Int {
        output.split(separator: "\n").count
    }

    /// Files git status keeps quiet about, from `git ls-files -v -z`: assume-unchanged ones
    /// (a lowercase tag) and skip-worktree ones ("S") that are on disk, where they can hold
    /// local edits. Outside a sparse checkout's cone they aren't.
    static func hiddenEdits(inLsFiles output: String, root: String) -> Int {
        output.split(separator: "\0").filter { entry in
            guard entry.count > 2, let tag = entry.first else { return false }
            if tag.isLowercase { return true }
            return tag == "S" && access(root + "/" + entry.dropFirst(2), F_OK) == 0
        }.count
    }
}

/// Why Corral won't move a worktree to the Trash.
public enum Hold: Codable, Sendable, Hashable {
    case changes(Int)
    case unsavedCommits(Int)
    /// A process is working in it: a shell, an editor's terminal, a server.
    case inUse(String)
    case hibernated
    case locked
    case submodules
    /// In the middle of a rebase, merge, cherry-pick, revert or bisect.
    case busy(String)
    /// Another checkout lives inside it and would go with it.
    case nested(String)
    case unchecked
    /// Some folders inside it can't be read, so what else would go with it is unknown.
    case unreadable
    /// It's on a disk that doesn't keep file IDs, so Corral couldn't find it again in the Trash.
    case untrackable

    /// A word or two for the panel's one-line rows: "4 changes", "Rebasing".
    public var label: String {
        switch self {
        case let .changes(count): count == 1 ? "1 change" : "\(count) changes"
        case let .unsavedCommits(count): count == 1 ? "1 commit off-branch" : "\(count) commits off-branch"
        case .inUse: "In use"
        case .hibernated: "Hibernated"
        case .locked: "Locked"
        case .submodules: "Submodules"
        case let .busy(operation):
            ["rebase": "Rebasing", "merge": "Merging", "cherry-pick": "Cherry-picking", "revert": "Reverting", "bisect": "Bisecting"][operation] ?? "Busy"
        case .nested: "Nested repo"
        case .unchecked: "Unchecked"
        case .unreadable: "Can't read all"
        case .untrackable: "Other disk"
        }
    }

    /// "4 uncommitted changes", for `corral disk` and tooltips.
    public var caption: String {
        switch self {
        case let .changes(count): count == 1 ? "1 uncommitted change" : "\(count) uncommitted changes"
        case let .unsavedCommits(count): count == 1 ? "1 commit on no branch" : "\(count) commits on no branch"
        case let .inUse(name): "In use by \(name)"
        case .hibernated: "Has a hibernated session"
        case .locked: "Locked in git"
        case .submodules: "Has submodules"
        case let .busy(operation): operation.prefix(1).uppercased() + operation.dropFirst() + " in progress"
        case .nested: "Holds another checkout"
        case .unchecked: "Git didn't answer"
        case .unreadable: "Some folders can't be read"
        case .untrackable: "On a disk Corral can't track"
        }
    }

    /// Why that keeps it where it is, for tooltips and toasts.
    public var reason: String {
        switch self {
        case .changes: "It has changes that aren't committed."
        case .unsavedCommits: "Its commits aren't on any branch, so they'd be lost. Make a branch for them first."
        case let .inUse(name): "\(name) is working in it."
        case .hibernated: "A hibernated session belongs to it. Wake it, or remove it from Hibernated, first."
        case .locked: "It's locked with git worktree lock."
        case .submodules: "Its submodules' history lives in git's entry for it, which would go with it. git worktree remove refuses these too."
        case let .busy(operation): "It's in the middle of a \(operation). Finish or abort it first."
        case let .nested(path): "It holds another checkout, \(Format.path(path)), which would go with it."
        case .unchecked: "Git didn't answer, so Corral can't tell whether it holds unsaved work."
        case .unreadable: "Corral can't read every folder inside it, so it can't tell what else would go with it."
        case .untrackable: "Its disk doesn't keep file IDs, so Corral couldn't find it in the Trash to put it back."
        }
    }
}

/// A linked worktree with nothing running in it, what moving it to the Trash would free, and
/// whether Corral will.
public struct IdleWorktree: Codable, Sendable, Hashable, Identifiable {
    public var worktree: LinkedWorktree
    /// Nil until it's been measured.
    public var usage: DiskUsage?
    public var git: GitState?
    /// Why it stays where it is. Empty when moving it to the Trash loses nothing.
    public var holds: [Hold]

    public var id: String { worktree.path }

    public init(worktree: LinkedWorktree, usage: DiskUsage?, git: GitState?, holds: [Hold] = []) {
        self.worktree = worktree
        self.usage = usage
        self.git = git
        self.holds = holds
    }

    /// Measured, checked with git, and nothing holds it.
    public var canTrash: Bool { holds.isEmpty && usage != nil && git?.answered == true }
}

/// The idle worktrees the panel lists, biggest first.
public struct DiskReport: Codable, Sendable, Hashable {
    /// How far the first measurement has got, until every worktree has a size.
    public struct Progress: Codable, Sendable, Hashable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public var worktrees: [IdleWorktree]
    public var progress: Progress?

    public init(worktrees: [IdleWorktree], progress: Progress? = nil) {
        self.worktrees = worktrees
        self.progress = progress
    }

    /// What they'd all free, held or not: what idle worktrees take.
    public var freeable: UInt64 { Self.freeable(worktrees) }

    public static func freeable(_ items: [IdleWorktree]) -> UInt64 { items.reduce(0) { $0 + ($1.usage?.freeable ?? 0) } }

    /// The ones Corral will move to the Trash, which "Move to Trash…" takes.
    public var safe: [IdleWorktree] { worktrees.filter(\.canTrash) }
}

public enum IdleWorktrees {
    /// Processes other than Corral and what it runs: its own git commands work inside the
    /// worktrees they look at.
    public static func foreign(_ processes: [ProcessRecord]) -> [ProcessRecord] {
        var own: Set<Int32> = [getpid()]
        var grew = true
        while grew {
            grew = false
            for process in processes where !own.contains(process.pid) && own.contains(process.ppid) {
                own.insert(process.pid)
                grew = true
            }
        }
        return processes.filter { !own.contains($0.pid) }
    }

    /// The worktrees nothing in the snapshot runs in, with what holds each one.
    public static func report(
        _ worktrees: [LinkedWorktree], measured: [String: WorktreeStore.Measured], running: Set<String>,
        processes: [ProcessRecord], hibernated: [HibernationRecord], progress: DiskReport.Progress? = nil
    ) -> DiskReport {
        let processes = foreign(processes)
        let items = worktrees.filter { !running.contains($0.path) }.map { worktree in
            let entry = measured[worktree.path]
            return IdleWorktree(
                worktree: worktree, usage: entry?.usage, git: entry?.git,
                holds: holds(worktree, usage: entry?.usage, git: entry?.git, processes: processes, hibernated: hibernated)
            )
        }
        let sorted = items.sorted { a, b in
            switch (a.usage, b.usage) {
            case let (left?, right?): left.freeable != right.freeable ? left.freeable > right.freeable : a.worktree.name < b.worktree.name
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.worktree.name < b.worktree.name
            }
        }
        return DiskReport(worktrees: sorted, progress: progress)
    }

    /// Everything that keeps a worktree where it is. Git's answer counts only once it has one.
    public static func holds(
        _ worktree: LinkedWorktree, usage: DiskUsage?, git: GitState?, processes: [ProcessRecord], hibernated: [HibernationRecord],
        running: [String: String] = [:]
    ) -> [Hold] {
        var holds: [Hold] = []
        if let what = running[worktree.path] { holds.append(.inUse(what)) }
        if let git {
            if !git.answered { holds.append(.unchecked) }
            if let changes = git.changes, changes > 0 { holds.append(.changes(changes)) }
            if let commits = git.unsavedCommits, commits > 0 { holds.append(.unsavedCommits(commits)) }
        }
        // Git's file-watching daemon quits by itself when its worktree goes.
        if let process = processes.first(where: { ($0.cwd.map { Paths.contains(worktree.path, $0) } ?? false) && !$0.args.contains("fsmonitor--daemon") }) {
            holds.append(.inUse(process.executable))
        }
        if hibernated.contains(where: { Paths.contains(worktree.path, $0.cwd) }) { holds.append(.hibernated) }
        if worktree.locked { holds.append(.locked) }
        if worktree.hasSubmodules { holds.append(.submodules) }
        if let operation = worktree.operation { holds.append(.busy(operation)) }
        if let nested = usage?.nested.first { holds.append(.nested(nested)) }
        if usage?.incomplete == true { holds.append(.unreadable) }
        if usage?.keepsIDs == false { holds.append(.untrackable) }
        return holds
    }
}
