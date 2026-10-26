@testable import CorralCore
import Darwin
import Foundation
import Testing

/// The blocks a file takes, the way `du` counts them.
private func blocks(_ path: String) -> UInt64 {
    var status = stat()
    return lstat(path, &status) == 0 ? UInt64(status.st_blocks) * 512 : 0
}

struct DiskScannerTests {
    /// Every file counts, however its folders are named. Folders with short names make short
    /// entries, which once cut the rest of a folder's listing off.
    @Test func countsEveryFile() throws {
        let sandbox = try Sandbox()
        var expected: UInt64 = 0
        var count = 0
        for folder in ["a", "b/c", "src/lib/x", "node_modules/.pnpm/react@19/node_modules/react", "z"] {
            for index in 0..<30 {
                let path = "w/\(folder)/f\(index).txt"
                try sandbox.file(path, String(repeating: "x", count: 5000 + index))
                expected += blocks(sandbox.root + "/" + path)
                count += 1
            }
        }
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit))
        #expect(usage.files == count)
        #expect(usage.allocated == expected)
        #expect(usage.freeable == expected)
        #expect(usage.nested.isEmpty)
    }

    /// A clone (how pnpm and bun install packages) or a hard link shares its blocks with
    /// another file, so removing it frees next to nothing.
    @Test func sharedBlocksDontCount() throws {
        let sandbox = try Sandbox()
        let contents = String(repeating: "corral", count: 200_000)
        try sandbox.file("store/package.js", contents)
        try sandbox.file("w/src/own.js", contents)
        _ = try sandbox.directory("w/node_modules")
        let store = sandbox.root + "/store/package.js"
        #expect(clonefile(store, sandbox.root + "/w/node_modules/cloned.js", 0) == 0)
        #expect(link(store, sandbox.root + "/w/node_modules/linked.js") == 0)

        let usage = try #require(DiskScanner.measure(sandbox.root + "/w"))
        let own = blocks(sandbox.root + "/w/src/own.js")
        #expect(usage.files == 3)
        #expect(usage.allocated == own * 3)
        #expect(usage.freeable >= own && usage.freeable < own + 64 * 1024)
        #expect(usage.shared >= own * 2 - 64 * 1024)
    }

    /// pnpm's packages, linked from its store, are nearly all of a worktree's files and free
    /// next to nothing, so after a sample the rest aren't walked. What's beside them, like a
    /// build cache in node_modules, still counts.
    @Test func sharedPackagesAreSampled() throws {
        let sandbox = try Sandbox()
        try sandbox.file("store/index.js", String(repeating: "x", count: 5000))
        try sandbox.file("w/src/own.js", String(repeating: "x", count: 5000))
        try sandbox.file("w/node_modules/.cache/build.bin", String(repeating: "x", count: 50_000))
        let packages = 60, perPackage = 50
        for package in 0..<packages {
            let folder = try sandbox.directory("w/node_modules/.pnpm/pkg\(package)@1.0.0/node_modules/pkg\(package)")
            for index in 0..<perPackage { #expect(link(sandbox.root + "/store/index.js", "\(folder)/f\(index).js") == 0) }
        }
        // Packages that build files of their own when installed count, wherever the sample falls.
        let built = "w/node_modules/.pnpm/electron@30.0.0/node_modules/electron"
        try sandbox.file(built + "/package.json", #"{"name": "electron", "scripts": {"postinstall": "node install.js"}}"#)
        try sandbox.file(built + "/dist/Electron.bin", String(repeating: "x", count: 50_000))
        let addon = "w/node_modules/.pnpm/@scope+addon@1.0.0/node_modules/@scope/addon"
        try sandbox.file(addon + "/binding.gyp", "{}")
        try sandbox.file(addon + "/build/Release/addon.node", String(repeating: "x", count: 50_000))
        try sandbox.file("w/node_modules/.pnpm/plain@1.0.0/node_modules/plain/package.json", #"{"name": "plain", "scripts": {"test": "x"}}"#)
        // Another checkout in a package, which the sample may well not reach.
        _ = try sandbox.directory("w/node_modules/.pnpm/pkg0@1.0.0/node_modules/pkg0/" + Sandbox.dotGit)

        let usage = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit))
        #expect(usage.sampled == true)
        #expect(usage.files >= DiskScanner.sampleFiles && usage.files < packages * perPackage)
        let own = ["w/src/own.js", "w/node_modules/.cache/build.bin", built + "/dist/Electron.bin", built + "/package.json", addon + "/binding.gyp", addon + "/build/Release/addon.node"]
        let freeable = own.reduce(0) { $0 + blocks(sandbox.root + "/" + $1) }
        // The plain package's package.json counts only if the sample reached it.
        #expect(usage.freeable == freeable || usage.freeable == freeable + blocks(sandbox.root + "/w/node_modules/.pnpm/plain@1.0.0/node_modules/plain/package.json"))

        let store = sandbox.root + "/w/node_modules/.pnpm/"
        #expect(DiskScanner.builds(store + "electron@30.0.0"))
        #expect(DiskScanner.builds(store + "@scope+addon@1.0.0"))
        #expect(!DiskScanner.builds(store + "plain@1.0.0"))
        #expect(!DiskScanner.builds(store + "pkg1@1.0.0"))

        // The check before a move still walks everything.
        let strict = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit, sizes: false))
        #expect(strict.sampled == nil)
        #expect(strict.nested.contains { $0.hasSuffix("/pkg0@1.0.0/node_modules/pkg0") })
    }

    /// Packages that were copied, like from a store on another disk, free what they take, so
    /// all of them are walked.
    @Test func copiedPackagesAreWalkedInFull() throws {
        let sandbox = try Sandbox()
        let packages = 60, perPackage = 50
        var expected: UInt64 = 0
        for package in 0..<packages {
            for index in 0..<perPackage {
                let path = "w/node_modules/.pnpm/pkg\(package)@1.0.0/node_modules/pkg\(package)/f\(index).js"
                try sandbox.file(path, String(repeating: "x", count: 5000))
                expected += blocks(sandbox.root + "/" + path)
            }
        }
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w"))
        #expect(usage.sampled == nil)
        #expect(usage.files == packages * perPackage)
        #expect(usage.freeable == expected)
    }

    /// When you last worked in it: generated folders and dot-files don't count.
    @Test func lastEditedSkipsGeneratedFiles() throws {
        let sandbox = try Sandbox()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        for (path, date) in [("w/src/index.ts", old), ("w/node_modules/x/index.js", new), ("w/.turbo/cache", new), ("w/dist/out.js", new), ("w/.env", new)] {
            try sandbox.file(path, "x")
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sandbox.root + "/" + path)
        }
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w"))
        #expect(usage.lastEdited == old)
        #expect(usage.files == 5)
    }

    /// Another repo inside a worktree would go to the Trash with it, so it's listed rather
    /// than counted. A submodule is part of the checkout.
    @Test func nestedCheckouts() throws {
        let sandbox = try Sandbox()
        try sandbox.file("w/\(Sandbox.dotGit)", "gitdir: /r/\(Sandbox.dotGit)/worktrees/w\n")
        try sandbox.file("w/src/a.ts", "a")
        try sandbox.file("w/scratch/other/\(Sandbox.dotGit)/HEAD", "ref: refs/heads/main\n")
        try sandbox.file("w/scratch/other/big.bin", String(repeating: "x", count: 100_000))
        try sandbox.file("w/vendor/lib/\(Sandbox.dotGit)", "gitdir: ../../\(Sandbox.dotGit)/modules/lib\n")
        try sandbox.file("w/vendor/lib/lib.c", "int x;")
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit))
        #expect(usage.nested == [sandbox.root + "/w/scratch/other"])
        #expect(usage.files == 4)
    }

    /// A submodule's git directory is in this worktree's own modules folder; a repo that just
    /// lives under a folder called modules is another checkout.
    @Test func submodulesAreToldApartByWhereTheyPoint() throws {
        let sandbox = try Sandbox()
        let gitDirs = [sandbox.root + "/r/\(Sandbox.dotGit)/worktrees/w", sandbox.root + "/r/\(Sandbox.dotGit)"]
        try sandbox.file("w/\(Sandbox.dotGit)", "gitdir: \(gitDirs[0])\n")
        try sandbox.file("w/inner/\(Sandbox.dotGit)", "gitdir: \(sandbox.root)/src/modules/other/\(Sandbox.dotGit)/worktrees/inner\n")
        try sandbox.file("w/vendor/lib/\(Sandbox.dotGit)", "gitdir: \(gitDirs[0])/modules/lib\n")
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit, gitDirs: gitDirs))
        #expect(usage.nested == [sandbox.root + "/w/inner"])
    }

    /// The look right before a move is strict: a folder it can't read means it can't be sure.
    /// A `.git` link and a bare repository count as other checkouts.
    @Test func theCheckBeforeAMoveIsStrict() throws {
        let sandbox = try Sandbox()
        try sandbox.file("w/src/a.ts", "a")
        try sandbox.file("w/vendor/lib-gitdir/HEAD", "ref: refs/heads/main\n")
        _ = try sandbox.directory("w/vendor/lib")
        try FileManager.default.createSymbolicLink(atPath: sandbox.root + "/w/vendor/lib/\(Sandbox.dotGit)", withDestinationPath: "../lib-gitdir")
        try sandbox.file("w/backup.git/HEAD", "ref: refs/heads/main\n")
        _ = try sandbox.directory("w/backup.git/objects")
        _ = try sandbox.directory("w/backup.git/refs")
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit, sizes: false))
        #expect(usage.nested == [sandbox.root + "/w/backup.git", sandbox.root + "/w/vendor/lib"])

        _ = try sandbox.directory("w/data/inner")
        chmod(sandbox.root + "/w/data", 0)
        defer { chmod(sandbox.root + "/w/data", 0o755) }
        #expect(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit, sizes: false) == nil)
        // Measuring only gives a floor, so it carries on without the folder.
        #expect(DiskScanner.measure(sandbox.root + "/w", dotGit: Sandbox.dotGit)?.files == 2)
    }

    /// More entries than one read returns.
    @Test func readsBigFoldersInFull() throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.directory("w/many")
        for index in 0..<5000 { try Data("x".utf8).write(to: URL(fileURLWithPath: "\(folder)/file-with-a-longish-name-\(index).txt")) }
        #expect(DiskScanner.measure(sandbox.root + "/w")?.files == 5000)
    }

    static var canCompress: Bool {
        guard let sandbox = try? Sandbox(), (try? sandbox.file("plain.txt", String(repeating: "corral ", count: 200_000))) != nil,
              (try? Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["--hfsCompression", sandbox.root + "/plain.txt", sandbox.root + "/packed.txt"]))
                  .map({ $0.waitUntilExit(); return $0.terminationStatus == 0 }) == true
        else { return false }
        var status = stat()
        return lstat(sandbox.root + "/packed.txt", &status) == 0 && status.st_flags & UInt32(UF_COMPRESSED) != 0
    }

    /// A compressed file's data isn't where APFS's private size looks, so it counts in full.
    @Test(.enabled(if: DiskScannerTests.canCompress)) func compressedFilesCount() throws {
        let sandbox = try Sandbox()
        try sandbox.file("plain.txt", String(repeating: "corral ", count: 200_000))
        _ = try sandbox.directory("w")
        let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["--hfsCompression", sandbox.root + "/plain.txt", sandbox.root + "/w/packed.txt"])
        ditto.waitUntilExit()
        let usage = try #require(DiskScanner.measure(sandbox.root + "/w"))
        #expect(usage.freeable > 0)
        #expect(usage.freeable == usage.allocated)
    }

    @Test func staysInsideTheFolder() throws {
        let sandbox = try Sandbox()
        try sandbox.file("outside/big.bin", String(repeating: "x", count: 200_000))
        try sandbox.file("w/a.txt", "a")
        try FileManager.default.createSymbolicLink(atPath: sandbox.root + "/w/link", withDestinationPath: sandbox.root + "/outside")
        #expect(DiskScanner.measure(sandbox.root + "/w")?.files == 1)
        #expect(DiskScanner.measure(sandbox.root + "/missing") == nil)
    }
}

struct WorktreeCatalogTests {
    @Test func findsWorktreesThroughTheirRepository() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("meadow", worktrees: [
            ("meadow/.claude/worktrees/table-color-ui-design-99dc44", "noah/table-color"),
            ("home/.codex/worktrees/editor-link-exit/meadow", "codex/editor-link-exit"),
        ])
        let found = WorktreeCatalog.worktrees(in: [main + "/" + Sandbox.dotGit], dotGit: Sandbox.dotGit)
        #expect(found.map(\.name).sorted() == ["editor-link-exit", "table-color"])
        let claude = try #require(found.first { $0.manager == "Claude" })
        #expect(claude.repoPath == main)
        #expect(claude.repoName == "meadow")
        #expect(claude.branch == "noah/table-color")
        #expect(!claude.detached)
        #expect(!claude.locked)
        #expect(claude.adminDir == main + "/\(Sandbox.dotGit)/worktrees/table-color-ui-design-99dc44")
        #expect(found.first { $0.name == "editor-link-exit" }?.manager == "Codex")
    }

    @Test func findsRepositoriesBehindAgentFolders() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("src/meadow", worktrees: [
            ("home/.codex/worktrees/editor-link-exit/meadow", "codex/editor-link-exit"),
            ("home/.t3/worktrees/meadow/t3code-9503f4f7", "t3code/calendar"),
        ])
        _ = try sandbox.directory("home/.codex/worktrees/archived-task")
        // A repo that lives under a folder called modules is still a repo.
        let other = try sandbox.repo("src/modules/blog", worktrees: [("home/.codex/worktrees/fix-feed/blog", "codex/fix-feed")])
        #expect(WorktreeCatalog.repositoriesInAgentFolders(home: sandbox.root + "/home", dotGit: Sandbox.dotGit) == [main + "/" + Sandbox.dotGit, other + "/" + Sandbox.dotGit])
    }

    @Test func skipsWhatsGoneAndNotesDetachedAndLocked() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("meadow", worktrees: [("wt/gone", "a"), ("wt/moved", "b"), ("wt/detached", "c"), ("wt/locked", "d"), ("wt/merging", "e")])
        try FileManager.default.removeItem(atPath: sandbox.root + "/wt/gone")
        try sandbox.file("wt/moved/\(Sandbox.dotGit)", "gitdir: /somewhere/else\n")
        try sandbox.file("meadow/\(Sandbox.dotGit)/worktrees/detached/HEAD", "4f3c2b1a9e8d7c6b5a4f3c2b1a9e8d7c6b5a4f3c\n")
        try sandbox.file("meadow/\(Sandbox.dotGit)/worktrees/locked/locked", "")
        try sandbox.file("meadow/\(Sandbox.dotGit)/worktrees/merging/MERGE_HEAD", "4f3c2b1a9e8d7c6b5a4f3c2b1a9e8d7c6b5a4f3c\n")
        _ = try sandbox.directory("meadow/\(Sandbox.dotGit)/worktrees/detached/modules/lib")
        let found = WorktreeCatalog.worktrees(in: [main + "/" + Sandbox.dotGit], dotGit: Sandbox.dotGit)
        #expect(found.map(\.name).sorted() == ["detached", "locked", "merging"])
        #expect(found.first { $0.name == "merging" }?.operation == "merge")
        #expect(found.first { $0.name == "locked" }?.operation == nil)
        #expect(found.first { $0.name == "detached" }?.hasSubmodules == true)
        #expect(found.first { $0.name == "locked" }?.hasSubmodules == false)
        let detached = try #require(found.first { $0.name == "detached" })
        #expect(detached.detached)
        #expect(detached.branch == nil)
        #expect(found.first { $0.name == "locked" }?.locked == true)
    }
}

struct IdleReportTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func worktree(_ name: String) -> LinkedWorktree {
        LinkedWorktree(
            path: "/w/\(name)", adminDir: "/r/.git/worktrees/\(name)", repoPath: "/r", repoName: "meadow", name: name,
            branch: name == "detached" ? nil : "noah/\(name)", detached: name == "detached", locked: name == "locked",
            hasSubmodules: name == "submodules", operation: name == "rebasing" ? "rebase" : nil
        )
    }

    func measured(_ megabytes: UInt64, changes: Int? = 0, commits: Int? = 0, edited: TimeInterval = -3 * 86_400, nested: [String] = []) -> WorktreeStore.Measured {
        WorktreeStore.Measured(
            usage: DiskUsage(allocated: megabytes << 22, freeable: megabytes << 20, files: 10, lastEdited: Self.now.addingTimeInterval(edited), nested: nested),
            git: GitState(changes: changes, unsavedCommits: commits, checkedAt: Self.now), measuredAt: Self.now, signature: ""
        )
    }

    /// Anything with work in it stays: uncommitted changes, commits on no branch, a shell in
    /// it, a hibernated session, a lock, another checkout inside, or git not answering.
    @Test func keepsAnythingWithWorkInIt() {
        let names = ["clean", "changed", "detached", "busy", "sleeping", "locked", "submodules", "rebasing", "nested", "running", "fresh", "unanswered", "unmeasured"]
        let measured: [String: WorktreeStore.Measured] = [
            "/w/clean": measured(900),
            "/w/changed": measured(800, changes: 3),
            "/w/detached": measured(700, commits: 2),
            "/w/busy": measured(600),
            "/w/sleeping": measured(500),
            "/w/locked": measured(400),
            "/w/submodules": measured(350),
            "/w/rebasing": measured(320),
            "/w/nested": measured(300, nested: ["/w/nested/scratch/other"]),
            "/w/running": measured(200),
            "/w/fresh": measured(100, edited: -3600),
            "/w/unanswered": measured(50, changes: nil),
        ]
        let shell = ProcessRecord(pid: 10, ppid: 1, path: "/bin/zsh", cwd: "/w/busy/src")
        let watcher = ProcessRecord(pid: 11, ppid: 1, path: "/usr/bin/git", args: ["git", "fsmonitor--daemon", "run"], cwd: "/w/clean")
        let record = HibernationRecord(
            harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "s", title: "Fix login", cwd: "/w/sleeping",
            checkout: "sleeping", resume: .command(argv: ["claude", "--resume", "s"], cwd: "/w/sleeping"), tty: nil, memory: 0, hibernatedAt: Self.now
        )
        let report = IdleWorktrees.report(names.map(worktree), measured: measured, running: ["/w/running"], processes: [shell, watcher], hibernated: [record])

        #expect(report.worktrees.map(\.worktree.name) == ["clean", "changed", "detached", "busy", "sleeping", "locked", "submodules", "rebasing", "nested", "fresh", "unanswered", "unmeasured"])
        let holds = Dictionary(uniqueKeysWithValues: report.worktrees.map { ($0.worktree.name, $0.holds) })
        #expect(holds["clean"] == [])
        #expect(holds["changed"] == [.changes(3)])
        #expect(holds["detached"] == [.unsavedCommits(2)])
        #expect(holds["busy"] == [.inUse("zsh")])
        #expect(holds["sleeping"] == [.hibernated])
        #expect(holds["locked"] == [.locked])
        #expect(holds["submodules"] == [.submodules])
        #expect(holds["rebasing"] == [.busy("rebase")])
        #expect(holds["nested"] == [.nested("/w/nested/scratch/other")])
        #expect(holds["unanswered"] == [.unchecked])
        #expect(holds["unmeasured"] == [])
        #expect(report.safe.map(\.worktree.name) == ["clean", "fresh"])
        // Everything idle and measured counts toward the total, held or not.
        #expect(report.freeable == 5020 << 20)
    }

    /// Corral's own git commands, and what they start, work inside the worktrees they check.
    @Test func corralsOwnCommandsDontCount() {
        let git = ProcessRecord(pid: 900_001, ppid: getpid(), path: "/usr/bin/git", cwd: "/w/clean")
        let helper = ProcessRecord(pid: 900_002, ppid: 900_001, path: "/usr/libexec/git-core/git", cwd: "/w/clean/src")
        let report = IdleWorktrees.report([worktree("clean")], measured: ["/w/clean": measured(900)], running: [], processes: [git, helper], hibernated: [])
        #expect(report.worktrees.first?.holds == [])
    }
}

struct ReflogTests {
    /// HEAD's log, newest first: each rebase counts by its last entry, its result, and not by
    /// the steps before; other entries and what checkouts moved from all count.
    @Test func aRebaseCountsByItsResult() {
        func id(_ c: Character) -> String { String(repeating: c, count: 40) }
        let log = """
        \(id("a")) rebase (finish): returning to refs/heads/x
        \(id("b")) rebase (pick): two
        \(id("c")) rebase (start): checkout main
        \(id("d")) rebase (finish): returning to \(id("d"))
        \(id("9")) rebase (pick): fix the (start) button
        \(id("e")) rebase (squash): # This is a combination of 2 commits.
        \(id("f")) rebase (start): checkout HEAD~3
        \(id("1")) commit: three
        \(id("2")) checkout: moving from \(id("3")) to main
        """
        #expect(Set(WorktreeGit.logged(inReflog: log)) == [id("a"), id("d"), id("1"), id("2"), id("3")])
    }
}

struct VolumeSpaceTests {
    /// A tenth free counts as low, but never less than 15 GB nor more than 50 GB.
    @Test func lowMeansUnderATenthWithinLimits() {
        let gb: UInt64 = 1 << 30
        #expect(VolumeSpace(available: 20 * gb, total: 256 * gb).isLow)
        #expect(!VolumeSpace(available: 30 * gb, total: 256 * gb).isLow)
        #expect(VolumeSpace(available: 14 * gb, total: 100 * gb).isLow)
        #expect(!VolumeSpace(available: 60 * gb, total: 2048 * gb).isLow)
        #expect(VolumeSpace(available: 45 * gb, total: 2048 * gb).isLow)
    }
}

struct SubprocessTests {
    @Test func givesUpAfterItsTimeout() {
        let start = Date()
        #expect(Subprocess.run("/bin/sleep", ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

struct WorktreeTrashTests {
    static let commit = "4f3c2b1a9e8d7c6b5a4f3c2b1a9e8d7c6b5a4f3c"

    /// What git would do to an entry, done to the files, for repos made in the sandbox.
    static func entries(unsaved: Int? = 0, staged: Bool? = false, knowsBranch: Bool = true) -> WorktreeTrash.Entries {
        WorktreeTrash.Entries(
            head: { _ in commit },
            state: { admin in
                guard knowsBranch else { return .unknown }
                let head = WorktreeCatalog.read(admin + "/HEAD") ?? ""
                return head.hasPrefix("ref: refs/heads/") ? .branch(String(head.dropFirst("ref: refs/heads/".count))) : .detached
            },
            detach: { admin, commit in (try? (commit + "\n").write(toFile: admin + "/HEAD", atomically: false, encoding: .utf8)) != nil },
            attach: { admin, branch in (try? "ref: refs/heads/\(branch)\n".write(toFile: admin + "/HEAD", atomically: false, encoding: .utf8)) != nil },
            tip: { _, _ in commit },
            checkedOut: { _, _ in false },
            unsaved: { _, _ in unsaved },
            staged: { _ in staged }
        )
    }

    /// A repo with a worktree that holds nothing uncommitted, as the panel would list it.
    func setUp(_ sandbox: Sandbox, store name: String = "Corral") throws -> (IdleWorktree, WorktreeStore) {
        let main = try sandbox.repo("meadow", worktrees: [("meadow/.claude/worktrees/iframe-block", "noah/iframe-block"), ("wt/other", "noah/other")])
        try sandbox.file("meadow/.claude/worktrees/iframe-block/src/index.ts", "export {}")
        let worktree = try #require(WorktreeCatalog.worktrees(in: [main + "/" + Sandbox.dotGit], dotGit: Sandbox.dotGit).first { $0.name == "iframe-block" })
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/\(name)/worktrees.json"))
        let git = GitState(changes: 0, unsavedCommits: 0, checkedAt: Date())
        return (IdleWorktree(worktree: worktree, usage: DiskUsage(allocated: 8192, freeable: 4096, files: 2), git: git), store)
    }

    /// Both halves of a move, into a Trash folder in the sandbox.
    func trash(
        _ items: [IdleWorktree], _ store: WorktreeStore, _ sandbox: Sandbox, changes: Int = 0,
        processes: [ProcessRecord] = [], running: [String: String] = [:], bin: String = "Trash/.Trash",
        entries: WorktreeTrash.Entries = WorktreeTrashTests.entries()
    ) -> WorktreeTrash.Result {
        let answer = GitState(changes: changes, unsavedCommits: 0, checkedAt: Date())
        let checked = WorktreeTrash.check(items, dotGit: Sandbox.dotGit) { _ in answer }
        let folder = sandbox.root + "/" + bin
        return WorktreeTrash.move(
            checked, processes: processes, running: running, hibernated: [], store: store, dotGit: Sandbox.dotGit, entries: entries
        ) { url in
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let destination = URL(fileURLWithPath: folder + "/" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    func head(_ admin: String) -> String? { WorktreeCatalog.read(admin + "/HEAD") }
    func gitFile(_ item: IdleWorktree) -> String? { try? String(contentsOfFile: item.worktree.path + "/" + Sandbox.dotGit, encoding: .utf8) }
    func lock(_ admin: String) -> String? { WorktreeCatalog.read(admin + "/locked") }

    /// In the Trash, its entry is locked, renamed to a name git never reuses with the folder
    /// pointing at it, and off its branch so the branch can be checked out elsewhere.
    @Test func parksItsEntryWhileItsInTheTrash() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        #expect(!FileManager.default.fileExists(atPath: item.worktree.path))
        #expect(!WorktreeCatalog.isDirectory(item.worktree.adminDir))
        #expect(trashed.adminDir.hasPrefix(item.worktree.adminDir + ".corral-"))
        #expect(WorktreeCatalog.adminDir(ofGitFile: trashed.trashedPath + "/" + Sandbox.dotGit) == trashed.adminDir)
        #expect(head(trashed.adminDir) == Self.commit)
        #expect(lock(trashed.adminDir) == WorktreeTrash.lockReason)
        #expect(store.trashed.first?.parked == true)
        #expect(store.trashed.first?.branch == "noah/iframe-block")
    }

    /// Back where it was, on its branch, its entry under its old name and its .git file as it was.
    @Test func undoPutsItBackWhereItWas() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let before = gitFile(item)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        let back = WorktreeTrash.putBack([trashed.id], store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(back.restored.map(\.id) == [trashed.id])
        #expect(FileManager.default.fileExists(atPath: item.worktree.path + "/src/index.ts"))
        #expect(!WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(head(item.worktree.adminDir) == "ref: refs/heads/noah/iframe-block")
        #expect(lock(item.worktree.adminDir) == nil)
        #expect(gitFile(item) == before)
        #expect(store.trashed.isEmpty)
    }

    /// Finder's Put Back works too, and so does putting back a Finder duplicate of it: the
    /// next look gives the worktree its entry back.
    @Test func putBackInFinderIsNoticed() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.copyItem(atPath: trashed.trashedPath, toPath: item.worktree.path)
        #expect(WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit).map(\.worktree.id) == [trashed.id])
        #expect(head(item.worktree.adminDir) == "ref: refs/heads/noah/iframe-block")
        #expect(lock(item.worktree.adminDir) == nil)
        #expect(store.trashed.isEmpty)
    }

    /// Emptying the Trash takes the entry with it, and only that one.
    @Test func emptyingTheTrashRemovesItsEntry() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(!WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(WorktreeCatalog.isDirectory(Paths.parent(item.worktree.adminDir) + "/other"))
        #expect(store.trashed.isEmpty)
    }

    /// Gone, but a copy committed through its entry: the entry stays, saying why.
    @Test func anEntryWithUnsavedCommitsStays() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store, entries: Self.entries(unsaved: 1), dotGit: Sandbox.dotGit)
        #expect(WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(lock(trashed.adminDir) == WorktreeTrash.keptReason)
        #expect(store.trashed.isEmpty)
    }

    /// Dragged out of the Trash somewhere else: it's a worktree there now.
    @Test func aWorktreeDraggedOutOfTheTrashIsAdopted() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        let desktop = sandbox.root + "/Desktop/iframe-block"
        _ = try sandbox.directory("Desktop")
        try FileManager.default.moveItem(atPath: trashed.trashedPath, toPath: desktop)
        // Found by its file ID, so by its real path (/private/tmp rather than /tmp).
        let adopted = WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit).map(\.worktree.path)
        #expect(adopted.count == 1 && WorktreeCatalog.same(adopted[0], desktop))
        let pointer = try #require(WorktreeCatalog.read(item.worktree.adminDir + "/gitdir"))
        #expect(WorktreeCatalog.same(Paths.parent(pointer), desktop) && pointer.hasSuffix("/" + Sandbox.dotGit))
        #expect(lock(item.worktree.adminDir) == nil)
        #expect(store.trashed.isEmpty)
    }

    /// Renamed inside the Trash, Undo still finds it.
    @Test func undoFindsItRenamedInTheTrash() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.moveItem(atPath: trashed.trashedPath, toPath: trashed.trashedPath + " copy")
        #expect(WorktreeTrash.putBack([trashed.id], store: store, entries: Self.entries(), dotGit: Sandbox.dotGit).restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path + "/src/index.ts"))
    }

    /// When Corral can't tell where it is (the file system won't say, or its disk was
    /// reattached as another), nothing is removed.
    @Test func notKnowingIsNotGone() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox, bin: "locked/Trash/.Trash").trashed.first)
        chmod(sandbox.root + "/locked", 0)
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        chmod(sandbox.root + "/locked", 0o755)
        #expect(WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(store.trashed.count == 1)

        var other = try #require(store.trashed.first)
        other.identity?.volume = "00000000-0000-0000-0000-000000000000"
        store.updateTrashed([other])
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(store.trashed.count == 1)
    }

    /// Undo never moves anything onto a folder that took its place.
    @Test func leavesSomethingElseAtThePathAlone() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try sandbox.file("meadow/.claude/worktrees/iframe-block/new.txt", "someone else's")
        let back = WorktreeTrash.putBack([trashed.id], store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(back.restored.isEmpty)
        #expect(back.failed.first?.reason.hasPrefix("Something else is at") == true)
        #expect(FileManager.default.fileExists(atPath: trashed.trashedPath + "/src/index.ts"))
        #expect(store.trashed.count == 1)
    }

    /// What git, the process list and the snapshot say right before moving decides.
    @Test func checksAgainRightBeforeMoving() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        #expect(trash([item], store, sandbox, changes: 2).kept.first?.reason == Hold.changes(2).reason)
        let shell = ProcessRecord(pid: 10, ppid: 1, path: "/bin/zsh", cwd: item.worktree.path)
        #expect(trash([item], store, sandbox, processes: [shell]).kept.first?.reason == Hold.inUse("zsh").reason)
        let started = trash([item], store, sandbox, running: [item.worktree.path: "astro dev :4461"])
        #expect(started.kept.first?.reason == Hold.inUse("astro dev :4461").reason)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path))
        #expect(WorktreeCatalog.isDirectory(item.worktree.adminDir))
        #expect(store.trashed.isEmpty)
    }

    /// Measured before another checkout appeared inside it: the look right before moving finds it.
    @Test func findsACheckoutThatAppearedInside() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        try sandbox.file("meadow/.claude/worktrees/iframe-block/node_modules/inner/\(Sandbox.dotGit)/HEAD", "ref: refs/heads/main\n")
        let result = trash([item], store, sandbox)
        #expect(result.trashed.isEmpty)
        #expect(result.kept.first?.reason == Hold.nested(item.worktree.path + "/node_modules/inner").reason)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path))
    }

    @Test func leavesAWorktreeThatMovedAlone() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        try sandbox.file("meadow/.claude/worktrees/iframe-block/\(Sandbox.dotGit)", "gitdir: /elsewhere/.git/worktrees/x\n")
        let result = trash([item], store, sandbox)
        #expect(result.trashed.isEmpty)
        #expect(result.kept.count == 1)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path))
    }

    /// Without a record of where it went, Undo couldn't find it, so it doesn't go, and its
    /// entry is left exactly as it was.
    /// Another worktree at the old path by the time the Trash is emptied doesn't keep this
    /// worktree's entry around.
    @Test func anotherWorktreeAtThePathDoesntKeepTheEntry() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try sandbox.file("meadow/.claude/worktrees/iframe-block/\(Sandbox.dotGit)", "gitdir: \(item.worktree.adminDir)\n")
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(!WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(store.trashed.isEmpty)
    }

    /// Gone, but a copy staged changes through its entry: the entry stays, saying why.
    @Test func stagedChangesKeepTheEntry() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store, entries: Self.entries(staged: true), dotGit: Sandbox.dotGit)
        #expect(lock(trashed.adminDir) == WorktreeTrash.keptReason)
        #expect(store.trashed.isEmpty)
    }

    /// Recovering a cut-short move only touches an entry Corral locked: one git made afresh at
    /// the same name (git worktree add -f -f) is someone else's.
    @Test func recoveryLeavesSomeoneElsesEntryAlone() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let file = item.worktree.path + "/" + Sandbox.dotGit
        let parked = item.worktree.adminDir + ".corral-0dead"
        let record = TrashedWorktree(
            name: item.worktree.name, repoName: "meadow", path: item.worktree.path, trashedPath: "", adminDir: parked,
            originalAdmin: item.worktree.adminDir, gitFile: try String(contentsOfFile: file, encoding: .utf8), repoPath: item.worktree.repoPath,
            branch: "noah/iframe-block", commit: Self.commit, identity: FolderIdentity(item.worktree.path), freeable: 0, trashedAt: Date()
        )
        #expect(store.addTrashed(record))
        #expect(WorktreeTrash.point(file, at: parked))
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(WorktreeCatalog.adminDir(ofGitFile: file) == parked)
    }

    /// When git can't say whether an entry holds unsaved work, it's asked again next time,
    /// rather than labelled as holding some.
    @Test func gitNotAnsweringMeansAskAgain() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        let now = Date()
        WorktreeTrash.settle(store: store, entries: Self.entries(unsaved: nil), dotGit: Sandbox.dotGit, now: now)
        #expect(lock(trashed.adminDir) == WorktreeTrash.lockReason)
        #expect(store.trashed.count == 1)
        // Not asked again for a quarter hour; then the answer counts.
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit, now: now.addingTimeInterval(60))
        #expect(WorktreeCatalog.isDirectory(trashed.adminDir))
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit, now: now.addingTimeInterval(16 * 60))
        #expect(!WorktreeCatalog.isDirectory(trashed.adminDir))
        #expect(store.trashed.isEmpty)
    }

    /// If git can't say which branch it's on, it stays where it is.
    @Test func anUnknownBranchStays() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let result = trash([item], store, sandbox, entries: Self.entries(knowsBranch: false))
        #expect(result.kept.first?.reason.hasPrefix("Git couldn't say which branch") == true)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path))
        #expect(store.trashed.isEmpty)
    }

    /// A move cut short after the .git file pointed at the entry's new name, but before the
    /// entry took it: the next look puts both back.
    @Test func aMoveCutShortIsPutRight() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let file = item.worktree.path + "/" + Sandbox.dotGit
        let before = try String(contentsOfFile: file, encoding: .utf8)
        let parked = item.worktree.adminDir + ".corral-0dead"
        let record = TrashedWorktree(
            name: item.worktree.name, repoName: "meadow", path: item.worktree.path, trashedPath: "", adminDir: parked,
            originalAdmin: item.worktree.adminDir, gitFile: before, repoPath: item.worktree.repoPath, branch: "noah/iframe-block",
            commit: Self.commit, identity: FolderIdentity(item.worktree.path), freeable: 0, trashedAt: Date()
        )
        #expect(store.addTrashed(record))
        #expect(WorktreeTrash.lock(item.worktree.adminDir, WorktreeTrash.lockReason))
        #expect(WorktreeTrash.point(file, at: parked))
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(gitFile(item) == before)
        #expect(lock(item.worktree.adminDir) == nil)
        #expect(store.trashed.isEmpty)
    }

    /// `git worktree repair` run on the copy in the Trash points the entry there; put back,
    /// it's this folder's entry again, and unlocked.
    @Test func aRepairedEntryIsLetGoWhenItComesBack() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox)
        let trashed = try #require(trash([item], store, sandbox).trashed.first)
        try sandbox.file(String(trashed.adminDir.dropFirst(sandbox.root.count + 1)) + "/gitdir", trashed.trashedPath + "/\(Sandbox.dotGit)\n")
        try FileManager.default.moveItem(atPath: trashed.trashedPath, toPath: item.worktree.path)
        WorktreeTrash.settle(store: store, entries: Self.entries(), dotGit: Sandbox.dotGit)
        #expect(lock(item.worktree.adminDir) == nil)
        #expect(WorktreeTrash.pointsAt(item.worktree.adminDir, item.worktree.path))
        #expect(store.trashed.isEmpty)
    }

    @Test func whatCantBeWrittenDownStays() throws {
        let sandbox = try Sandbox()
        let (item, store) = try setUp(sandbox, store: "Locked")
        _ = store.measured
        chmod(sandbox.root + "/Locked", 0o555)
        defer { chmod(sandbox.root + "/Locked", 0o755) }
        let result = trash([item], store, sandbox)
        #expect(result.trashed.isEmpty)
        #expect(result.kept.first?.reason.hasPrefix("Corral couldn't write down") == true)
        #expect(FileManager.default.fileExists(atPath: item.worktree.path + "/src/index.ts"))
        #expect(WorktreeCatalog.adminDir(ofGitFile: item.worktree.path + "/" + Sandbox.dotGit) == item.worktree.adminDir)
        #expect(lock(item.worktree.adminDir) == nil)
    }
}

struct WorktreeMonitorTests {
    @Test func measuresAgainWhenSomethingChanged() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("meadow", worktrees: [("meadow/.claude/worktrees/iframe-block", "noah/iframe-block")])
        try sandbox.file("meadow/.claude/worktrees/iframe-block/src/index.ts", "export {}")
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/worktrees.json"))
        let monitor = WorktreeMonitor(store: store, home: sandbox.root + "/home", dotGit: Sandbox.dotGit)
        let checkout = Checkout(path: main, name: "meadow", repoName: "meadow", repoPath: main, kind: .main)
        let worktree = try #require(monitor.discover([checkout]).first)

        let now = Date()
        let entry = try #require(monitor.measure(worktree, now: now))
        #expect(entry.usage.files == 2)
        // Saved for next time. (Dates go through JSON, so compare what they measured.)
        #expect(store.measured[worktree.path]?.usage == entry.usage)
        #expect(store.measured[worktree.path]?.signature == entry.signature)
        #expect(!monitor.isStale(worktree, entry: entry, now: now.addingTimeInterval(60)))
        #expect(monitor.isStale(worktree, entry: entry, lastRunning: now.addingTimeInterval(30), now: now.addingTimeInterval(60)))
        #expect(monitor.isStale(worktree, entry: entry, now: now.addingTimeInterval(86_401)))
        try sandbox.file("meadow/.claude/worktrees/iframe-block/README.md", "new at the top")
        #expect(monitor.isStale(worktree, entry: entry, now: now.addingTimeInterval(60)))
        // Remembered: found again with nothing running in the repo.
        #expect(monitor.discover([]).map(\.path) == [worktree.path])
    }
}

struct WorktreeStoreTests {
    /// A record this Corral can't read (an older or newer one wrote it) costs only that record,
    /// and the file as it was is kept beside the new one.
    @Test func oneUnreadableRecordCostsOnlyItself() throws {
        let sandbox = try Sandbox()
        let good = TrashedWorktree(
            name: "iframe-block", repoName: "meadow", path: "/w/a", trashedPath: "/t/a", adminDir: "/r/.git/worktrees/a",
            repoPath: "/r", branch: "noah/a", freeable: 1, trashedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let record = String(decoding: try encoder.encode(good), as: UTF8.self)
        try sandbox.file("Corral/worktrees.json", #"{"schema":3,"repositories":[],"measured":{},"trashed":[{"id":"not one"},"# + record + "]}")
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/worktrees.json"))
        #expect(store.trashed.map(\.name) == ["iframe-block"])
        #expect(store.trashed.count == 1)
        func backups() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: sandbox.root + "/Corral").filter { $0.hasPrefix("worktrees.unreadable-") }.count }
        #expect(try backups() == 0)
        store.save("/w/b", WorktreeStore.Measured(usage: DiskUsage(), git: GitState(changes: 0, unsavedCommits: 0, checkedAt: Date()), measuredAt: Date(), signature: ""))
        #expect(try backups() == 1)
        #expect(store.trashed.map(\.name) == ["iframe-block"])
        store.save("/w/c", WorktreeStore.Measured(usage: DiskUsage(), git: GitState(changes: 0, unsavedCommits: 0, checkedAt: Date()), measuredAt: Date(), signature: ""))
        #expect(try backups() == 1)
    }

    /// Measurements from before Corral's checks changed are dropped, so everything is asked
    /// about again; the repositories it knows stay.
    @Test func newChecksMeasureEverythingAgain() throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.directory("r/\(Sandbox.dotGit)")
        let old = """
        {"measured":{"/w/a":{"git":{"changes":0,"checkedAt":1800000000,"unsavedCommits":0},"measuredAt":1800000000,"signature":"x",\
        "usage":{"allocated":8192,"files":2,"freeable":4096,"nested":[]}}},"repositories":["\(repo)"],"schema":1,"trashed":[]}
        """
        try sandbox.file("Corral/worktrees.json", old)
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/worktrees.json"))
        #expect(store.measured.isEmpty)
        #expect(store.remember([]) == [repo])
    }
}

/// The same steps with real git, where the sandbox lets tests create .git folders.
struct RealGitTests {
    static var canUseGit: Bool {
        guard let git = Subprocess.git, let sandbox = try? Sandbox() else { return false }
        return Subprocess.run(git, ["init", "-q", sandbox.root + "/probe"], timeout: 20) != nil
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let path = try #require(Subprocess.git)
        return try #require(Subprocess.run(path, ["-c", "user.name=Corral", "-c", "user.email=corral@example.com"] + arguments, timeout: 30))
    }

    /// A repo with a worktree on a branch, and the main checkout's own commit to start from.
    func repo(_ sandbox: Sandbox) throws -> String {
        let main = sandbox.root + "/repo"
        try git(["init", "-q", "-b", "main", main])
        try git(["-C", main, "commit", "-q", "--allow-empty", "-m", "init"])
        try git(["-C", main, "branch", "other"])
        try git(["-C", main, "worktree", "add", "-q", sandbox.root + "/feature", "-b", "feature"])
        return main
    }

    func worktree(_ main: String, _ test: (LinkedWorktree) -> Bool) throws -> LinkedWorktree {
        let found = WorktreeCatalog.worktrees(in: [main + "/.git"]).first(where: test)
        return try #require(found)
    }

    @Test(.enabled(if: RealGitTests.canUseGit)) func findsWorkThatWouldBeLost() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        let feature = try worktree(main) { $0.branch == "feature" }
        let clean = WorktreeGit.state(of: feature)
        #expect(clean.changes == 0 && clean.unsavedCommits == 0)

        // A detached commit; one left behind by moving on to a branch; one dropped by a reset,
        // so only HEAD's log has it; and a ref of the worktree's own.
        try git(["-C", main, "worktree", "add", "-q", "--detach", sandbox.root + "/agent"])
        try git(["-C", sandbox.root + "/agent", "commit", "-q", "--allow-empty", "-m", "agent work"])
        try git(["-C", main, "worktree", "add", "-q", "--detach", sandbox.root + "/lefty"])
        try git(["-C", sandbox.root + "/lefty", "commit", "-q", "--allow-empty", "-m", "left behind"])
        try git(["-C", sandbox.root + "/lefty", "checkout", "-q", "other"])
        try git(["-C", main, "worktree", "add", "-q", "--detach", sandbox.root + "/reset"])
        try git(["-C", sandbox.root + "/reset", "commit", "-q", "--allow-empty", "-m", "dropped"])
        try git(["-C", sandbox.root + "/reset", "reset", "-q", "--hard", "HEAD~1"])
        try git(["-C", main, "worktree", "add", "-q", "--detach", sandbox.root + "/keeper"])
        let tree = try git(["-C", sandbox.root + "/keeper", "rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = try git(["-C", sandbox.root + "/keeper", "commit-tree", "-m", "kept", tree]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["-C", sandbox.root + "/keeper", "update-ref", "refs/worktree/keep", kept])
        for name in ["agent", "lefty", "reset", "keeper"] {
            let found = try worktree(main) { $0.path.hasSuffix("/" + name) }
            #expect(WorktreeGit.state(of: found).unsavedCommits == 1, "\(name)")
        }

        // A rebase on a branch leaves its old commits in the branch's log, which stays: fine.
        try git(["-C", sandbox.root + "/feature", "commit", "-q", "--allow-empty", "-m", "one"])
        try git(["-C", sandbox.root + "/feature", "rebase", "-q", "--onto", "other", "HEAD~1"])
        #expect(WorktreeGit.state(of: feature).unsavedCommits == 0)

        // Detached since Corral looked: still checked.
        try git(["-C", sandbox.root + "/feature", "checkout", "-q", "--detach"])
        try git(["-C", sandbox.root + "/feature", "commit", "-q", "--allow-empty", "-m", "since"])
        #expect(WorktreeGit.state(of: feature).unsavedCommits == 1)

        // An edit git status hides.
        let agent = try worktree(main) { $0.path.hasSuffix("/agent") }
        try sandbox.file("agent/config.js", "a")
        try git(["-C", sandbox.root + "/agent", "add", "config.js"])
        try git(["-C", sandbox.root + "/agent", "commit", "-q", "-m", "config"])
        try git(["-C", sandbox.root + "/agent", "update-index", "--assume-unchanged", "config.js"])
        try sandbox.file("agent/config.js", "local edit")
        #expect(WorktreeGit.state(of: agent).changes == 1)

        // A log git can't read is no answer, not a clean one.
        try git(["-C", main, "config", "log.date", "no-such-format"])
        #expect(WorktreeGit.state(of: agent).unsavedCommits == nil)
    }

    /// With core.fsmonitor on, looking doesn't leave a file-watching daemon in the worktree.
    @Test(.enabled(if: RealGitTests.canUseGit)) func startsNoFileWatchers() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        try git(["-C", main, "config", "core.fsmonitor", "true"])
        let feature = try worktree(main) { $0.branch == "feature" }
        let path = try #require(Subprocess.git)
        defer { _ = Subprocess.run(path, ["-C", feature.path, "fsmonitor--daemon", "stop"], timeout: 10) }
        _ = WorktreeGit.state(of: feature)
        // `status` fails when no daemon watches the worktree.
        #expect(Subprocess.run(path, ["-C", feature.path, "fsmonitor--daemon", "status"], timeout: 10) == nil)
    }

    /// Parked in the Trash its branch is free; put back it's on its branch again; with the
    /// Trash emptied its entry goes, unless a copy committed through it. Branches stay.
    @Test(.enabled(if: RealGitTests.canUseGit)) func aTrashedWorktreeFreesItsBranchAndComesBack() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        let feature = try worktree(main) { $0.branch == "feature" }
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/worktrees.json"))
        func move() throws -> TrashedWorktree {
            let item = IdleWorktree(worktree: try worktree(main) { $0.path == feature.path }, usage: DiskUsage(), git: nil)
            let checked = WorktreeTrash.check([item], dotGit: ".git") { WorktreeGit.state(of: $0) }
            let result = WorktreeTrash.move(checked, processes: [], running: [:], hibernated: [], store: store, dotGit: ".git", entries: .git) { url in
                let destination = URL(fileURLWithPath: sandbox.root + "/.Trash/feature")
                try FileManager.default.createDirectory(atPath: sandbox.root + "/.Trash", withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
            return try #require(result.trashed.first)
        }

        let trashed = try move()
        #expect(try git(["-C", main, "worktree", "list", "--porcelain"]).contains("locked " + WorktreeTrash.lockReason))
        try git(["-C", main, "worktree", "prune"])
        #expect(WorktreeCatalog.isDirectory(trashed.adminDir))
        // The branch is free, and the old entry name is free for git to reuse.
        try git(["-C", main, "switch", "-q", "feature"])
        try git(["-C", main, "switch", "-q", "main"])

        try FileManager.default.moveItem(atPath: trashed.trashedPath, toPath: feature.path)
        #expect(WorktreeTrash.settle(store: store).count == 1)
        #expect(try git(["-C", feature.path, "status", "-sb"]).hasPrefix("## feature"))
        #expect(!(try git(["-C", main, "worktree", "list", "--porcelain"])).contains("locked"))

        // A copy of the trashed folder commits through the entry; then the Trash is emptied.
        let again = try move()
        try FileManager.default.copyItem(atPath: again.trashedPath, toPath: sandbox.root + "/copy")
        try git(["-C", sandbox.root + "/copy", "commit", "-q", "--allow-empty", "-m", "made in the copy"])
        try FileManager.default.removeItem(atPath: again.trashedPath)
        WorktreeTrash.settle(store: store)
        #expect(try git(["-C", main, "worktree", "list", "--porcelain"]).contains("locked " + WorktreeTrash.keptReason))
        try git(["-C", sandbox.root + "/copy", "branch", "saved"])
        try FileManager.default.removeItem(atPath: sandbox.root + "/copy")
        #expect(try git(["-C", main, "branch", "--list", "feature"]).contains("feature"))
    }

    /// A copy of the trashed folder staged a change through its entry, then the Trash was
    /// emptied: the staged change lives only in the entry's index, so the entry stays.
    @Test(.enabled(if: RealGitTests.canUseGit)) func changesStagedInACopyKeepTheEntry() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        let feature = try worktree(main) { $0.branch == "feature" }
        let store = WorktreeStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/worktrees.json"))
        let checked = WorktreeTrash.check([IdleWorktree(worktree: feature, usage: DiskUsage(), git: nil)], dotGit: ".git") { WorktreeGit.state(of: $0) }
        let result = WorktreeTrash.move(checked, processes: [], running: [:], hibernated: [], store: store, dotGit: ".git", entries: .git) { url in
            try FileManager.default.createDirectory(atPath: sandbox.root + "/.Trash", withIntermediateDirectories: true)
            let destination = URL(fileURLWithPath: sandbox.root + "/.Trash/feature")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let trashed = try #require(result.trashed.first)
        try FileManager.default.copyItem(atPath: trashed.trashedPath, toPath: sandbox.root + "/copy")
        try sandbox.file("copy/new.txt", "staged only")
        try git(["-C", sandbox.root + "/copy", "add", "new.txt"])
        try FileManager.default.removeItem(atPath: sandbox.root + "/copy/new.txt")
        try FileManager.default.removeItem(atPath: trashed.trashedPath)
        WorktreeTrash.settle(store: store)
        #expect(try git(["-C", main, "worktree", "list", "--porcelain"]).contains("locked " + WorktreeTrash.keptReason))
    }

    /// A detached HEAD that was rebased, then left for another commit: the rebased commit is
    /// only in HEAD's log, under the rebase's own entries, and is work that would be lost.
    @Test(.enabled(if: RealGitTests.canUseGit)) func aDetachedRebaseLeftBehindIsCaught() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        try sandbox.file("feature/notes.md", "work")
        try git(["-C", sandbox.root + "/feature", "add", "notes.md"])
        try git(["-C", sandbox.root + "/feature", "commit", "-q", "-m", "on feature"])
        try git(["-C", main, "worktree", "add", "-q", "--detach", sandbox.root + "/rebased", "feature"])
        try git(["-C", main, "commit", "-q", "--allow-empty", "-m", "main moves on"])
        try git(["-C", sandbox.root + "/rebased", "rebase", "-q", "main"])
        try git(["-C", sandbox.root + "/rebased", "checkout", "-q", "--detach", "main"])
        let rebased = try worktree(main) { $0.path.hasSuffix("/rebased") }
        #expect(WorktreeGit.state(of: rebased).unsavedCommits == 1)
    }

    /// A squash rebase leaves its own steps in HEAD's log; they aren't lost work.
    @Test(.enabled(if: RealGitTests.canUseGit)) func aSquashRebaseIsntUnsavedWork() throws {
        let sandbox = try Sandbox()
        let main = try repo(sandbox)
        let feature = try worktree(main) { $0.branch == "feature" }
        for message in ["one", "two", "three"] { try git(["-C", feature.path, "commit", "-q", "--allow-empty", "-m", message]) }
        let path = try #require(Subprocess.git)
        let squash = Process()
        squash.executableURL = URL(fileURLWithPath: path)
        squash.arguments = ["-c", "user.name=Corral", "-c", "user.email=corral@example.com", "-C", feature.path, "rebase", "-q", "-i", "HEAD~3"]
        squash.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_SEQUENCE_EDITOR": "sed -i '' -e '2,3s/^pick/squash/'", "GIT_EDITOR": "true"], uniquingKeysWith: { $1 }
        )
        try squash.run()
        squash.waitUntilExit()
        #expect(squash.terminationStatus == 0)
        #expect(WorktreeGit.state(of: feature).unsavedCommits == 0)
    }
}
