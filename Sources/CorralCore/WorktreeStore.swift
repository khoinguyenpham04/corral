import Darwin
import Foundation

/// What Corral knows about worktrees between launches, in
/// ~/Library/Application Support/Corral/worktrees.json: the repositories it has seen, each
/// worktree's size and git state, and the worktrees it moved to the Trash. The app and the CLI
/// share it, with the same locking as the hibernated list.
public final class WorktreeStore: @unchecked Sendable {
    public static let shared = WorktreeStore()

    public struct Measured: Codable, Sendable, Hashable {
        public var usage: DiskUsage
        public var git: GitState
        public var measuredAt: Date
        /// Changes when git checks something out or commits, or when files come and go at the
        /// top of the worktree, so its size gets measured again.
        public var signature: String

        public init(usage: DiskUsage, git: GitState, measuredAt: Date, signature: String) {
            self.usage = usage
            self.git = git
            self.measuredAt = measuredAt
            self.signature = signature
        }
    }

    struct State: Codable, Equatable {
        /// Bumped when what Corral checks changes, so every worktree is measured and asked about again.
        static let schema = 3
        var schema: Int? = State.schema
        var repositories: [String] = []
        var measured: [String: Measured] = [:]
        var trashed: [TrashedWorktree] = []
        /// Some part didn't decode (a newer or older Corral wrote it), so the file is backed up
        /// before it's written over.
        var lossy = false

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decodeIfPresent(Int.self, forKey: .schema)
            repositories = (try? container.decodeIfPresent([String].self, forKey: .repositories)) ?? []
            let measured = (try? container.decodeIfPresent([String: Lenient<Measured>].self, forKey: .measured)) ?? [:]
            self.measured = measured.compactMapValues(\.value)
            let trashed = (try? container.decodeIfPresent([Lenient<TrashedWorktree>].self, forKey: .trashed)) ?? []
            self.trashed = trashed.compactMap(\.value)
            lossy = self.measured.count != measured.count || self.trashed.count != trashed.count
        }

        enum CodingKeys: String, CodingKey { case schema, repositories, measured, trashed }

        static func == (a: State, b: State) -> Bool {
            a.schema == b.schema && a.repositories == b.repositories && a.measured == b.measured && a.trashed == b.trashed
        }
    }

    /// Decodes what it can, and nil instead of failing the whole file.
    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public let url: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        HibernationStore.defaultURL.deletingLastPathComponent().appendingPathComponent("worktrees.json")
    }

    public init(url: URL = WorktreeStore.defaultURL) {
        self.url = url
    }

    /// Adds repositories (their git directories) to the ones Corral looks in, drops any that
    /// are gone, and returns them all.
    @discardableResult
    public func remember(_ repositories: Set<String>) -> Set<String> {
        withState { state in
            let all = Set(state.repositories).union(repositories).filter { WorktreeCatalog.isDirectory($0) }
            state.repositories = all.sorted()
            return all
        }.value
    }

    public var measured: [String: Measured] { withState { $0.measured }.value }

    public func save(_ path: String, _ entry: Measured) {
        withState { $0.measured[path] = entry }
    }

    /// Forgets the sizes of worktrees that are gone.
    public func keepMeasurements(for paths: Set<String>) {
        withState { state in state.measured = state.measured.filter { paths.contains($0.key) } }
    }

    public var trashed: [TrashedWorktree] { withState { $0.trashed }.value }

    /// Writes down a worktree that just went to the Trash. False if it couldn't be saved (a
    /// full disk), when the caller puts the worktree straight back. Its size stays until the
    /// next look finds the folder gone, so one put back with Undo shows it straight away.
    func addTrashed(_ item: TrashedWorktree) -> Bool {
        withState { $0.trashed.append(item) }.saved
    }

    func updateTrashed(_ items: [TrashedWorktree]) {
        guard !items.isEmpty else { return }
        withState { state in
            for item in items {
                if let index = state.trashed.firstIndex(where: { $0.id == item.id }) { state.trashed[index] = item }
            }
        }
    }

    func removeTrashed(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withState { $0.trashed.removeAll { ids.contains($0.id) } }
    }

    /// A locked read-modify-write. `saved` is false when a change couldn't be written.
    @discardableResult
    private func withState<T>(_ change: (inout State) -> T) -> (value: T, saved: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockFile = open(directory.appendingPathComponent(".worktrees.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFile >= 0 { flock(lockFile, LOCK_EX) }
        defer {
            if lockFile >= 0 {
                flock(lockFile, LOCK_UN)
                close(lockFile)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try? Data(contentsOf: url)
        let decoded = data.flatMap { try? decoder.decode(State.self, from: $0) }
        let original = decoded ?? State()
        let lossy = data != nil && (decoded == nil || decoded?.lossy == true)
        var state = original
        if state.schema != State.schema {
            state.schema = State.schema
            state.measured = [:]
        }
        let result = change(&state)
        guard state != original else { return (result, true) }
        // What it couldn't read is kept beside it before it's written over, once: after the
        // write it reads in full.
        if lossy, let data {
            let name = "unreadable-\(Int(Date().timeIntervalSince1970))-\(UInt16.random(in: .min ... .max)).json"
            guard (try? data.write(to: url.deletingPathExtension().appendingPathExtension(name))) != nil else { return (result, false) }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        // Write beside the file and rename over it, so a crash never leaves half a file.
        let temporary = url.appendingPathExtension("tmp")
        guard let data = try? encoder.encode(state), (try? data.write(to: temporary)) != nil else { return (result, false) }
        return (result, rename(temporary.path, url.path) == 0)
    }
}

/// A folder as the file system knows it, to recognise it wherever it's moved on its disk:
/// the disk's UUID (its BSD number changes when it's reattached), the folder's file ID, and
/// when it was made, which tells it from a later folder given the same ID.
public struct FolderIdentity: Codable, Sendable, Hashable {
    var volume: String
    var inode: UInt64
    var bornSeconds: Int
    var bornNanoseconds: Int

    init?(_ path: String) {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, let volume = Self.volume(of: path) else { return nil }
        self.volume = volume
        inode = status.st_ino
        bornSeconds = status.st_birthtimespec.tv_sec
        bornNanoseconds = status.st_birthtimespec.tv_nsec
    }

    /// The UUID of the disk `path` is on.
    static func volume(of path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }
}

/// A worktree Corral moved to the Trash.
public struct TrashedWorktree: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var repoName: String
    /// Where it was, and where Undo puts it back.
    public var path: String
    /// Where it is in the Trash; empty while the move is under way.
    public var trashedPath: String
    /// Its git entry, renamed so git never gives the name to another worktree.
    public var adminDir: String
    /// The entry's name before, and the worktree's `.git` file as it was, both put back with it.
    public var originalAdmin: String?
    public var gitFile: String?
    public var repoPath: String
    /// The branch it was on, read from git when it moved.
    public var branch: String?
    /// The commit HEAD was on, where its entry waits while it's in the Trash.
    public var commit: String?
    public var identity: FolderIdentity?
    public var freeable: UInt64
    public var trashedAt: Date
    /// Its entry's HEAD is off the branch, so the branch can be checked out elsewhere.
    public var parked: Bool?
    /// Gone, but git couldn't say whether its entry holds unsaved work: asked again from then.
    public var retryAt: Date?

    public init(
        id: UUID = UUID(), name: String, repoName: String, path: String, trashedPath: String, adminDir: String,
        originalAdmin: String? = nil, gitFile: String? = nil, repoPath: String, branch: String?, commit: String? = nil,
        identity: FolderIdentity? = nil, freeable: UInt64, trashedAt: Date, parked: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.repoName = repoName
        self.path = path
        self.trashedPath = trashedPath
        self.adminDir = adminDir
        self.originalAdmin = originalAdmin
        self.gitFile = gitFile
        self.repoPath = repoPath
        self.branch = branch
        self.commit = commit
        self.identity = identity
        self.freeable = freeable
        self.trashedAt = trashedAt
        self.parked = parked
    }
}

/// Moves worktrees to the Trash, and back.
///
/// Git keeps an entry for each worktree (.git/worktrees/<id>) with its HEAD, its log, its
/// index and any refs of its own, and the worktree's `.git` file names it. Right before a
/// worktree moves, Corral locks its entry, so neither `git worktree prune` nor `git gc`
/// removes it, and renames it to a name git never gives a worktree, pointing the folder's
/// `.git` at the new name. The old name is free for git to reuse, and no copy of the folder,
/// wherever it ends up, can ever attach to another worktree's entry. Once the folder is in the
/// Trash, the entry's HEAD moves off the branch so the branch can be checked out elsewhere.
///
/// Put back, by Undo or Finder, the entry is unlocked and back on its branch if it can be.
/// Dragged out of the Trash somewhere else, it's a worktree there. Only when the folder is gone
/// for good, the Trash emptied, does the entry go too, and not even then if it has commits no
/// branch has.
public enum WorktreeTrash {
    /// Moves, put-backs and settles one at a time; recursive, since a move ends with a settle.
    private static let serial = NSRecursiveLock()

    static let lockReason = "In the Trash, moved there by Corral. Put it back and Corral unlocks it; empty the Trash and Corral removes this entry."
    static let keptReason = "Kept by Corral: it holds work found nowhere else, commits no branch has or changes staged in it. Save that work, then remove this entry with git worktree remove --force --force."

    static func releasedReason(_ branch: String?) -> String {
        let back = branch.map { "git worktree unlock on it and git switch \($0) in it" } ?? "git worktree unlock on it"
        return "In the Trash, moved there by Corral, which has since been uninstalled. Put it back and run \(back); or remove it with git worktree remove --force --force."
    }

    public struct Result: Sendable {
        public var trashed: [TrashedWorktree] = []
        /// Worktrees that stayed where they were, and why.
        public var kept: [Kept] = []

        public init(trashed: [TrashedWorktree] = [], kept: [Kept] = []) {
            self.trashed = trashed
            self.kept = kept
        }
    }

    public struct Kept: Sendable {
        public var worktree: IdleWorktree
        public var reason: String
    }

    /// What looking again found, between the two halves of a move.
    public struct Checked: Sendable {
        public var item: IdleWorktree
        var git: GitState?
        var nested: [String]?
        var problem: String?
    }

    /// The first half of a move, and the slow one: asks git about each worktree again and
    /// walks it for other checkouts, several at once.
    public static func check(_ items: [IdleWorktree]) -> [Checked] {
        check(items, dotGit: ".git") { WorktreeGit.state(of: $0) }
    }

    static func check(_ items: [IdleWorktree], dotGit: String, git: @Sendable (LinkedWorktree) -> GitState) -> [Checked] {
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<Checked?>.allocate(capacity: items.count)
        results.initialize(repeating: nil)
        defer {
            results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let item = items[index]
            let worktree = item.worktree
            // Still the worktree it was: its .git file points at the same entry.
            guard WorktreeCatalog.adminDir(ofGitFile: worktree.path + "/" + dotGit).map({ WorktreeCatalog.same($0, worktree.adminDir) }) == true else {
                results[index] = Checked(item: item, problem: "It's no longer a worktree of \(worktree.repoName) there.")
                return
            }
            guard let nested = DiskScanner.measure(worktree.path, dotGit: dotGit, gitDirs: worktree.gitDirs, sizes: false)?.nested else {
                results[index] = Checked(item: item, problem: "Corral couldn't look in every folder inside it, so it can't tell what else would go with it.")
                return
            }
            results[index] = Checked(item: item, git: git(worktree), nested: nested)
        }
        return results.compactMap { $0 }
    }

    /// The second half, right after a fresh look at what's running: moves the worktrees
    /// nothing holds, one at a time, writing each down as it goes. `running` maps a worktree
    /// something runs in, by the snapshot's reckoning, to what it is.
    public static func move(
        _ checked: [Checked], processes: [ProcessRecord], running: [String: String], hibernated: [HibernationRecord], store: WorktreeStore
    ) -> Result {
        move(checked, processes: processes, running: running, hibernated: hibernated, store: store, dotGit: ".git", entries: .git, trash: finderTrash)
    }

    static func move(
        _ checked: [Checked], processes: [ProcessRecord], running: [String: String], hibernated: [HibernationRecord],
        store: WorktreeStore, dotGit: String, entries: Entries, trash: (URL) throws -> URL
    ) -> Result {
        serial.lock()
        defer { serial.unlock() }
        let processes = IdleWorktrees.foreign(processes)
        var result = Result()
        for check in checked {
            let item = check.item
            func keep(_ reason: String) { result.kept.append(Kept(worktree: item, reason: reason)) }
            guard check.problem == nil, let git = check.git, let nested = check.nested else {
                keep(check.problem ?? "Corral couldn't check it.")
                continue
            }
            var worktree = item.worktree
            worktree.locked = access(worktree.adminDir + "/locked", F_OK) == 0
            worktree.hasSubmodules = WorktreeCatalog.isDirectory(worktree.adminDir + "/modules")
            worktree.operation = WorktreeCatalog.operation(inAdmin: worktree.adminDir)
            var usage = item.usage ?? DiskUsage()
            usage.nested = nested
            usage.keepsIDs = DiskUsage.keepsIDs(worktree.path)
            let holds = IdleWorktrees.holds(worktree, usage: usage, git: git, processes: processes, hibernated: hibernated, running: running)
            if let hold = holds.first {
                keep(hold.reason)
                continue
            }
            let admin = worktree.adminDir
            let gitFile = worktree.path + "/" + dotGit
            guard let identity = FolderIdentity(worktree.path), let commit = entries.head(admin),
                  let contents = try? String(contentsOfFile: gitFile, encoding: .utf8)
            else {
                keep("Corral couldn't tell which folder and commit it is, so it can't promise to find it again.")
                continue
            }
            let branch: String?
            switch entries.state(admin) {
            case let .branch(name): branch = name
            case .detached: branch = nil
            case .unknown:
                keep("Git couldn't say which branch it's on, so it stayed.")
                continue
            }
            let parkedAdmin = admin + ".corral-" + String(UInt32.random(in: .min ... .max), radix: 16)
            let original = URL(fileURLWithPath: worktree.path)
            var record = TrashedWorktree(
                name: worktree.name, repoName: worktree.repoName, path: worktree.path, trashedPath: "", adminDir: parkedAdmin,
                originalAdmin: admin, gitFile: contents, repoPath: worktree.repoPath, branch: branch, commit: commit,
                identity: identity, freeable: item.usage?.freeable ?? 0, trashedAt: Date()
            )
            // Written down before anything changes, so a crash part way leaves something to finish from.
            guard store.addTrashed(record) else {
                keep("Corral couldn't write down the move, so it didn't start it.")
                continue
            }
            // Back as it was. If the old name was taken meanwhile, it keeps the new one rather than
            // pointing at someone else's entry.
            func undo() {
                if !FileManager.default.fileExists(atPath: parkedAdmin) || exclusiveRename(parkedAdmin, admin) {
                    _ = try? Data(contents.utf8).write(to: URL(fileURLWithPath: gitFile))
                    unlock(admin)
                } else {
                    unlock(parkedAdmin)
                }
                store.removeTrashed([record.id])
            }
            // Locked, then the .git file points at the new name, then the entry takes it: a crash
            // between leaves a pointer to a name nobody has, never to another worktree's entry.
            guard lock(admin, lockReason), point(gitFile, at: parkedAdmin), exclusiveRename(admin, parkedAdmin) else {
                undo()
                keep("Corral couldn't set aside its git entry, so it stayed.")
                continue
            }
            let destination: URL
            do { destination = try trash(original) } catch {
                undo()
                keep("macOS couldn't move it: \(error.localizedDescription)")
                continue
            }
            // If this can't be saved, the folder is still found by its identity.
            record.trashedPath = destination.path
            store.updateTrashed([record])
            result.trashed.append(record)
        }
        settle(store: store, entries: entries, dotGit: dotGit)
        return result
    }

    public struct PutBack: Sendable {
        public var restored: [TrashedWorktree] = []
        /// Back, but off its branch, with why.
        public var offBranch: [OffBranch] = []
        /// Back, but git no longer has an entry for it, so it's just a folder of files.
        public var unlinked: [TrashedWorktree] = []
        public var failed: [Failure] = []
    }

    public struct OffBranch: Sendable {
        public enum Reason: Equatable, Sendable { case moved, taken, unknown }
        public var worktree: TrashedWorktree
        public var reason: Reason
    }

    public struct Failure: Sendable {
        public var worktree: TrashedWorktree
        public var reason: String
    }

    /// Puts worktrees back where they were, and back on their branches when that's possible.
    public static func putBack(_ ids: Set<UUID>, store: WorktreeStore) -> PutBack {
        putBack(ids, store: store, entries: .git)
    }

    static func putBack(_ ids: Set<UUID>, store: WorktreeStore, entries: Entries, dotGit: String = ".git") -> PutBack {
        serial.lock()
        defer { serial.unlock() }
        var result = PutBack()
        var done = Set<UUID>()
        let fm = FileManager.default
        for item in store.trashed where ids.contains(item.id) {
            func fail(_ reason: String) { result.failed.append(Failure(worktree: item, reason: reason)) }
            switch place(of: item, dotGit: dotGit) {
            case .back:
                break
            case let .trash(path):
                guard !fm.fileExists(atPath: item.path) else {
                    fail("Something else is at \(Format.path(item.path)) now, so it's still in the Trash.")
                    continue
                }
                guard (try? fm.moveItem(atPath: path, toPath: item.path)) != nil else {
                    fail("macOS couldn't move it back. It's still in the Trash.")
                    continue
                }
            case .restored:
                fail("It's been moved out of the Trash already.")
                continue
            case .unknown:
                fail("Corral can't find it right now. If it's on another disk, connect that disk.")
                continue
            case .gone:
                fail("It's no longer in the Trash.")
                continue
            }
            done.insert(item.id)
            switch unpark(item, entries, dotGit: dotGit) {
            case .onBranch: result.restored.append(item)
            case let .offBranch(reason): result.offBranch.append(OffBranch(worktree: item, reason: reason))
            case .unlinked: result.unlinked.append(item)
            }
        }
        store.removeTrashed(done)
        return result
    }

    /// Brings each trashed worktree's entry in line with where its folder is now: parked
    /// while it's in the Trash, unparked once it's back (or adopted wherever it was dragged
    /// to), and removed once it's gone for good. Cheap when nothing changed, so it's run often.
    /// Returns the worktrees that came back.
    @discardableResult
    public static func settle(store: WorktreeStore) -> [Returned] {
        settle(store: store, entries: .git)
    }

    /// A worktree that came back, and how.
    public struct Returned: Sendable {
        public var worktree: TrashedWorktree
        public var outcome: Unparked
    }

    @discardableResult
    static func settle(store: WorktreeStore, entries: Entries, dotGit: String = ".git", now: Date = Date()) -> [Returned] {
        var back: [Returned] = []
        var gone: [TrashedWorktree] = []
        locked {
            var done = Set<UUID>()
            var changed: [TrashedWorktree] = []
            for item in store.trashed {
                switch place(of: item, dotGit: dotGit) {
                case .back:
                    back.append(Returned(worktree: item, outcome: unpark(item, entries, dotGit: dotGit)))
                    done.insert(item.id)
                case let .trash(path):
                    var copy = item
                    copy.trashedPath = path
                    if item.parked != true, park(item, entries) { copy.parked = true }
                    if copy != item { changed.append(copy) }
                case let .restored(path):
                    back.append(adopt(item, at: path, entries, dotGit: dotGit))
                    done.insert(item.id)
                case .unknown:
                    continue
                case .gone:
                    if item.retryAt.map({ $0 <= now }) ?? true { gone.append(item) }
                }
            }
            store.updateTrashed(changed)
            store.removeTrashed(done)
        }
        guard !gone.isEmpty else { return back }
        // Asking git about unsaved work can take a while on a big repository, so it's done
        // without holding up Undo or a move, and the answer is acted on only if it's still gone.
        // Changes a copy of the folder staged through the entry count as work too. Each answer
        // stands only if the entry's index and log didn't change while git was asked.
        let answers = gone.map { item in
            let before = touched(item.adminDir)
            return (item, entries.unsaved(item.adminDir, item.repoPath), entries.staged(item.adminDir), before)
        }
        locked {
            var done = Set<UUID>()
            var changed: [TrashedWorktree] = []
            for (item, unsaved, staged, before) in answers where place(of: item, dotGit: dotGit) == .gone && touched(item.adminDir) == before {
                if removeEntry(of: item, unsaved: unsaved, staged: staged, dotGit: dotGit) == .later {
                    var copy = item
                    copy.retryAt = now.addingTimeInterval(15 * 60)
                    changed.append(copy)
                } else {
                    done.insert(item.id)
                }
            }
            store.updateTrashed(changed)
            store.removeTrashed(done)
        }
        return back
    }

    /// When the entry's index and HEAD log last changed.
    private static func touched(_ admin: String) -> String {
        [admin + "/index", admin + "/logs/HEAD"].map { path in
            var status = stat()
            return stat(path, &status) == 0 ? "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)" : "-"
        }.joined(separator: ":")
    }

    private static func locked<T>(_ body: () -> T) -> T {
        serial.lock()
        defer { serial.unlock() }
        return body()
    }

    /// Lets go of every trashed worktree, for Uninstall: back ones are unparked, dragged-out
    /// ones adopted, and the entries of ones still in the Trash stay locked, saying Corral is gone.
    public static func release(store: WorktreeStore) {
        serial.lock()
        defer { serial.unlock() }
        for item in store.trashed {
            switch place(of: item) {
            case .back: _ = unpark(item, .git, dotGit: ".git")
            case let .restored(path): _ = adopt(item, at: path, .git, dotGit: ".git")
            default:
                // Kept by git, so whatever comes back still has its entry, and saying who to ask now.
                if WorktreeCatalog.read(item.adminDir + "/locked") == lockReason { _ = lock(item.adminDir, releasedReason(item.branch), replacing: true) }
            }
        }
        store.removeTrashed(Set(store.trashed.map(\.id)))
    }

    /// Dragged out of the Trash somewhere else on its disk: a worktree there now. (Dragged to
    /// another disk, it's a copy with a new file ID, and the original counts as gone.)
    static func adopt(_ item: TrashedWorktree, at path: String, _ entries: Entries, dotGit: String) -> Returned {
        var moved = item
        moved.path = path
        // Under its new name, or its old one again if a put-back was cut short after the rename.
        let entry = WorktreeCatalog.isDirectory(item.adminDir) ? item.adminDir
            : item.originalAdmin.flatMap { WorktreeCatalog.read($0 + "/locked") == lockReason && pointsAt($0, item.path) ? $0 : nil }
        guard let entry, (try? Data((path + "/" + dotGit + "\n").utf8).write(to: URL(fileURLWithPath: entry + "/gitdir"))) != nil else {
            return Returned(worktree: moved, outcome: .unlinked)
        }
        return Returned(worktree: moved, outcome: unpark(moved, entries, dotGit: dotGit))
    }

    enum Place: Equatable {
        /// Where it was: put back with Undo or Finder.
        case back
        /// In a Trash, at this path.
        case trash(String)
        /// Out of the Trash, at this path.
        case restored(String)
        /// Corral can't tell: its disk isn't connected, or the file system won't say.
        case unknown
        /// Deleted: the Trash was emptied.
        case gone
    }

    /// Where a trashed worktree's folder is now, found by its identity wherever it moved.
    static func place(of item: TrashedWorktree, dotGit: String = ".git") -> Place {
        guard let identity = item.identity else { return .unknown }
        // The folder, or a copy of it that points at this entry, back where it was.
        if FolderIdentity(item.path) == identity || WorktreeCatalog.adminDir(ofGitFile: item.path + "/" + dotGit) == item.adminDir { return .back }
        if !item.trashedPath.isEmpty, FolderIdentity(item.trashedPath) == identity { return .trash(item.trashedPath) }
        // Elsewhere on its disk, found by its file ID, if that disk is the one connected.
        // Its disk, from the nearest folder still there (the one it was in may have been tidied away).
        var near = Paths.parent(item.trashedPath.isEmpty ? item.path : item.trashedPath)
        while !WorktreeCatalog.isDirectory(near), near != "/" { near = Paths.parent(near) }
        var volume = statfs()
        guard FolderIdentity.volume(of: near) == identity.volume, statfs(near, &volume) == 0 else { return .unknown }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        errno = 0
        if fsgetpath(&buffer, buffer.count, &volume.f_fsid, identity.inode) > 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if FolderIdentity(path) == identity { return isInTrash(path) ? .trash(path) : .restored(path) }
        } else if errno != ENOENT {
            return .unknown
        }
        // Not found by its ID, and nothing where it was left: the Trash was emptied.
        var status = stat()
        errno = 0
        return lstat(item.trashedPath, &status) != 0 && errno == ENOENT ? .gone : .unknown
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// Moves the entry's HEAD off the branch, so the branch can be checked out elsewhere, and
    /// makes sure it's still locked. False if that didn't work; it's tried again next time.
    static func park(_ item: TrashedWorktree, _ entries: Entries) -> Bool {
        let admin = item.adminDir
        guard WorktreeCatalog.isDirectory(admin), pointsAt(admin, item.path) else { return true }
        guard lock(admin, lockReason) else { return false }
        switch entries.state(admin) {
        case .detached: return true
        case .unknown: return false
        case .branch:
            guard let commit = item.commit else { return false }
            return entries.detach(admin, commit)
        }
    }

    public enum Unparked: Equatable, Sendable { case onBranch, offBranch(OffBranch.Reason), unlinked }

    /// Unlocks the entry of a worktree that's back, puts it back on its branch if the branch is
    /// where it was and isn't checked out anywhere else, and gives the entry its old name back
    /// when that's free, with the `.git` file as it was.
    static func unpark(_ item: TrashedWorktree, _ entries: Entries, dotGit: String) -> Unparked {
        let admin = item.adminDir
        let gitFile = item.path + "/" + dotGit
        if !WorktreeCatalog.isDirectory(admin), let original = item.originalAdmin, WorktreeCatalog.isDirectory(original), pointsAt(original, item.path) {
            if WorktreeCatalog.read(original + "/locked") == lockReason {
                // A move or a put-back cut short with the entry under its old name, which always
                // leaves Corral's lock on it: put the .git file and the lock back.
                let restored = item.gitFile.map { contents in
                    leads(contents, from: gitFile, to: original) && (try? Data(contents.utf8).write(to: URL(fileURLWithPath: gitFile))) != nil
                } ?? false
                guard restored || point(gitFile, at: original) else { return .unlinked }
                unlock(original)
                return .onBranch
            }
            // A move that never got as far as the lock: nothing changed.
            if WorktreeCatalog.adminDir(ofGitFile: gitFile).map({ WorktreeCatalog.same($0, original) }) == true { return .onBranch }
        }
        guard WorktreeCatalog.isDirectory(admin) else { return .unlinked }
        if !pointsAt(admin, item.path) {
            // Pointed elsewhere (git worktree repair on the copy in the Trash, say) while this
            // folder names it: it's this folder's entry again.
            guard WorktreeCatalog.adminDir(ofGitFile: gitFile) == admin,
                  (try? Data((gitFile + "\n").utf8).write(to: URL(fileURLWithPath: admin + "/gitdir"))) != nil
            else { return .unlinked }
        }
        let outcome = reattach(item, entries)
        // Renamed back and pointed at before the lock comes off, so a crash part way is still
        // recognisably Corral's to finish.
        var current = admin
        if let original = item.originalAdmin, original != admin, exclusiveRename(admin, original) {
            // The old .git, if it still leads to the entry from here (a relative one may not), else a plain pointer.
            let restored = item.gitFile.map { contents in
                leads(contents, from: gitFile, to: original) && (try? Data(contents.utf8).write(to: URL(fileURLWithPath: gitFile))) != nil
            } ?? false
            if restored || point(gitFile, at: original) { current = original } else { _ = exclusiveRename(original, admin) }
        }
        unlock(current)
        return outcome
    }

    private static func reattach(_ item: TrashedWorktree, _ entries: Entries) -> Unparked {
        let admin = item.adminDir
        guard let branch = item.branch else { return .onBranch }
        switch entries.state(admin) {
        case .branch: return .onBranch
        case .unknown: return .offBranch(.unknown)
        case .detached: break
        }
        guard let commit = item.commit, let head = entries.head(admin) else { return .offBranch(.unknown) }
        guard head == commit, entries.tip(admin, branch) == commit else { return .offBranch(.moved) }
        switch entries.checkedOut(item.repoPath, branch) {
        case false?: return entries.attach(admin, branch) ? .onBranch : .offBranch(.unknown)
        case true?: return .offBranch(.taken)
        case nil: return .offBranch(.unknown)
        }
    }

    enum Removal: Equatable { case removed, kept, later, notOurs }

    /// Removes the entry of a worktree whose folder is gone for good: only one Corral locked,
    /// only while it still points at that folder's path, and never one with commits no branch
    /// has (made in a copy of the folder, say), which stays, saying why. Another worktree at
    /// the same path since doesn't stop it. `later` when git couldn't say: tried again next time.
    static func removeEntry(of item: TrashedWorktree, unsaved: Int?, staged: Bool? = false, dotGit: String) -> Removal {
        let admin = item.adminDir
        guard WorktreeCatalog.isDirectory(admin), pointsAt(admin, item.path) || (!item.trashedPath.isEmpty && pointsAt(admin, item.trashedPath)),
              WorktreeCatalog.read(admin + "/locked") == lockReason
        else { return .notOurs }
        // A folder at the path pointing at this entry is this worktree after all.
        if WorktreeCatalog.adminDir(ofGitFile: item.path + "/" + dotGit) == admin { return .later }
        switch (unsaved, staged) {
        case (0?, false?): return (try? FileManager.default.removeItem(atPath: admin)) != nil ? .removed : .later
        case (nil, _), (_, nil): return .later
        default: return lock(admin, keptReason, replacing: true) ? .kept : .later
        }
    }

    /// The entry exists and its `gitdir` points at the worktree's folder.
    static func pointsAt(_ admin: String, _ path: String) -> Bool {
        guard let pointer = WorktreeCatalog.read(admin + "/gitdir"), !pointer.isEmpty else { return false }
        return Paths.parent(Paths.normalize(pointer.hasPrefix("/") ? pointer : admin + "/" + pointer)) == path
    }

    // Written in place, as git writes them: a staged copy would go through a temporary folder
    // the file may not be allowed in.

    static func lock(_ admin: String, _ reason: String, replacing: Bool = false) -> Bool {
        if !replacing, access(admin + "/locked", F_OK) == 0 { return true }
        return (try? Data(reason.utf8).write(to: URL(fileURLWithPath: admin + "/locked"))) != nil
    }

    static func unlock(_ admin: String) {
        guard WorktreeCatalog.read(admin + "/locked") == lockReason else { return }
        try? FileManager.default.removeItem(atPath: admin + "/locked")
    }

    /// A rename that fails rather than replace something already there, even an empty folder
    /// git has just made for a new worktree.
    static func exclusiveRename(_ from: String, _ to: String) -> Bool {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
    }

    /// Whether `.git` file contents, read from `gitFile`'s folder, name `admin`.
    static func leads(_ contents: String, from gitFile: String, to admin: String) -> Bool {
        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("gitdir:") else { return false }
        let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return WorktreeCatalog.same(Paths.normalize(target.hasPrefix("/") ? target : Paths.parent(gitFile) + "/" + target), admin)
    }

    /// Points a worktree's `.git` file at its entry.
    static func point(_ gitFile: String, at admin: String) -> Bool {
        (try? Data("gitdir: \(admin)\n".utf8).write(to: URL(fileURLWithPath: gitFile))) != nil
    }

    enum HeadState: Equatable, Sendable {
        case branch(String)
        case detached
        case unknown
    }

    /// What Corral asks of git about a worktree's entry. Tests swap in their own.
    struct Entries: Sendable {
        /// The commit HEAD is on.
        var head: @Sendable (_ admin: String) -> String?
        /// Whether HEAD is on a branch, detached, or git couldn't say.
        var state: @Sendable (_ admin: String) -> HeadState
        /// Points HEAD at a commit, off any branch.
        var detach: @Sendable (_ admin: String, _ commit: String) -> Bool
        var attach: @Sendable (_ admin: String, _ branch: String) -> Bool
        /// The commit a branch is on.
        var tip: @Sendable (_ admin: String, _ branch: String) -> String?
        /// Whether some worktree has the branch checked out; nil when git can't say.
        var checkedOut: @Sendable (_ repoPath: String, _ branch: String) -> Bool?
        /// Commits only this entry keeps; nil when git can't say.
        var unsaved: @Sendable (_ admin: String, _ repoPath: String) -> Int?
        /// Whether the entry's index holds changes staged on top of its HEAD; nil when git can't say.
        var staged: @Sendable (_ admin: String) -> Bool? = { _ in false }

        static let git = Entries(
            head: { admin in run(["--git-dir=" + admin, "rev-parse", "--verify", "HEAD"]) },
            state: { admin in
                guard let git = Subprocess.git, let (status, output) = Subprocess.runStatus(
                    git, quiet + ["--git-dir=" + admin, "symbolic-ref", "-q", "--short", "HEAD"], timeout: 30
                ) else { return .unknown }
                switch status {
                case 0: return .branch(output.trimmingCharacters(in: .whitespacesAndNewlines))
                case 1: return .detached
                default: return .unknown
                }
            },
            detach: { admin, commit in
                run(["--git-dir=" + admin, "update-ref", "--no-deref", "-m", "corral: moved to the Trash", "HEAD", commit]) != nil
            },
            attach: { admin, branch in
                run(["--git-dir=" + admin, "symbolic-ref", "-m", "corral: put back", "HEAD", "refs/heads/" + branch]) != nil
            },
            tip: { admin, branch in run(["--git-dir=" + admin, "rev-parse", "--verify", "refs/heads/" + branch]) },
            checkedOut: { repoPath, branch in
                run(["-C", repoPath, "worktree", "list", "--porcelain"]).map { $0.split(separator: "\n").contains { $0 == "branch refs/heads/\(branch)" } }
            },
            unsaved: { admin, repoPath in
                guard let git = Subprocess.git else { return nil }
                return WorktreeGit.unsavedCommits(at: ["--git-dir=" + admin], repoPath: repoPath, git: git)
            },
            staged: { admin in
                guard let git = Subprocess.git,
                      let (status, _) = Subprocess.runStatus(git, quiet + ["--git-dir=" + admin, "diff-index", "--cached", "--quiet", "HEAD"], timeout: 30)
                else { return nil }
                return status == 0 ? false : status == 1 ? true : nil
            }
        )

        /// With core.fsmonitor on, anything that reads an index starts a file-watching daemon,
        /// and with --git-dir and no worktree it would watch Corral's own folder.
        private static let quiet = ["-c", "core.fsmonitor=false"]

        private static func run(_ arguments: [String]) -> String? {
            guard let git = Subprocess.git else { return nil }
            return Subprocess.run(git, quiet + arguments, timeout: 30)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The Finder's Move to Trash, which Put Back in Finder understands.
    public static func finderTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }
}

/// Keeps worktree sizes current: finds linked worktrees, and measures and checks with git the
/// ones whose numbers are out of date. The app runs it in the background; `corral disk` runs
/// it once.
public final class WorktreeMonitor: @unchecked Sendable {
    public let store: WorktreeStore
    private let home: String
    private let dotGit: String

    public init(store: WorktreeStore = .shared, home: String = NSHomeDirectory(), dotGit: String = ".git") {
        self.store = store
        self.home = home
        self.dotGit = dotGit
    }

    /// Every linked worktree Corral can find: in the repositories of these checkouts, in ones
    /// it has seen before, and behind agents' worktree folders.
    public func discover(_ checkouts: [Checkout]) -> [LinkedWorktree] {
        let seen = Set(checkouts.filter { $0.kind != .project }.compactMap { WorktreeCatalog.commonDir(forRepo: $0.repoPath, dotGit: dotGit) })
        let repositories = store.remember(seen.union(WorktreeCatalog.repositoriesInAgentFolders(home: home, dotGit: dotGit)))
        let worktrees = WorktreeCatalog.worktrees(in: repositories, dotGit: dotGit)
        store.keepMeasurements(for: Set(worktrees.map(\.path)))
        return worktrees
    }

    /// Whether a worktree needs measuring again: it never was, git or its top folder changed
    /// since, something ran in it since, git didn't answer an hour ago, or it's been a day.
    public func isStale(_ worktree: LinkedWorktree, entry: WorktreeStore.Measured?, lastRunning: Date? = nil, now: Date = Date()) -> Bool {
        guard let entry else { return true }
        if entry.signature != Self.signature(of: worktree) { return true }
        if let lastRunning, lastRunning > entry.measuredAt { return true }
        // Without git there's nothing to ask, so don't walk the folder again for it.
        if !entry.git.answered, Subprocess.git != nil, now.timeIntervalSince(entry.measuredAt) > 3600 { return true }
        return now.timeIntervalSince(entry.measuredAt) > 86_400
    }

    /// Measures a worktree, asks git about it, and saves both.
    public func measure(_ worktree: LinkedWorktree, now: Date = Date(), isCancelled: () -> Bool = { false }) -> WorktreeStore.Measured? {
        let signature = Self.signature(of: worktree)
        guard let usage = DiskScanner.measure(worktree.path, dotGit: dotGit, gitDirs: worktree.gitDirs, isCancelled: isCancelled) else { return nil }
        let entry = WorktreeStore.Measured(usage: usage, git: WorktreeGit.state(of: worktree, now: now), measuredAt: now, signature: signature)
        store.save(worktree.path, entry)
        return entry
    }

    /// When the worktree's folder and git's HEAD and index for it last changed.
    static func signature(of worktree: LinkedWorktree) -> String {
        [worktree.path, worktree.adminDir + "/HEAD", worktree.adminDir + "/index"].map { path in
            var status = stat()
            guard stat(path, &status) == 0 else { return "-" }
            return "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
        }.joined(separator: ":")
    }
}
