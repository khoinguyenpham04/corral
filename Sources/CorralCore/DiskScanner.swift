import Darwin
import Foundation

/// How much space a folder takes, and how much moving it to the Trash would give back.
public struct DiskUsage: Codable, Sendable, Hashable {
    /// What Finder and `du` count: every file's blocks.
    public var allocated: UInt64
    /// What removing it frees: the blocks no other file shares. pnpm and bun install
    /// node_modules as APFS clones of their store, and those share nearly all their blocks, so
    /// a node_modules folder usually counts for little.
    public var freeable: UInt64
    public var files: Int
    /// The newest file that isn't generated or tooling (node_modules, dist, dot-folders).
    public var lastEdited: Date?
    /// Other checkouts inside it, which moving it would take along. Their size isn't counted.
    public var nested: [String]
    /// The disk it's on, so the space counts toward the right one.
    public var device: Int32?
    /// Some folders inside couldn't be read, so the size is short and nested checkouts may be missed.
    public var incomplete: Bool?
    /// Its disk keeps file IDs when files move (APFS and HFS+ do; exFAT doesn't), which Corral
    /// needs to find a worktree again in the Trash.
    public var keepsIDs: Bool?
    /// pnpm's or bun's packages turned out to be shared with their store, so only a sample of
    /// them was walked: `allocated` and `files` leave the rest out, and `freeable` misses next
    /// to nothing.
    public var sampled: Bool?

    public init(allocated: UInt64 = 0, freeable: UInt64 = 0, files: Int = 0, lastEdited: Date? = nil, nested: [String] = [], device: Int32? = nil) {
        self.allocated = allocated
        self.freeable = freeable
        self.files = files
        self.lastEdited = lastEdited
        self.nested = nested
        self.device = device
    }

    static func keepsIDs(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsPersistentIDsKey]))?.volumeSupportsPersistentIDs == true
    }

    /// The part other files share, which stays on disk when this goes.
    public var shared: UInt64 { allocated > freeable ? allocated - freeable : 0 }
}

/// Free space on the disk that holds your home folder, counted the way Finder does (space
/// macOS can purge, like caches, counts as free).
public struct VolumeSpace: Codable, Sendable, Hashable {
    public var available: UInt64
    public var total: UInt64
    public var device: Int32?

    public init(available: UInt64, total: UInt64, device: Int32? = nil) {
        self.available = available
        self.total = total
        self.device = device
    }

    public static func home() -> VolumeSpace? {
        let home = NSHomeDirectory()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        var status = stat()
        guard let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, total > 0,
              stat(home, &status) == 0
        else { return nil }
        // The figure Finder shows, counting space macOS can purge; it can come back as 0 when
        // macOS can't work it out, and then the plain figure is the better guess.
        let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? UInt64($0) : nil }
        let plain = values.volumeAvailableCapacity.flatMap { $0 > 0 ? UInt64($0) : nil }
        guard let available = important ?? plain else { return nil }
        return VolumeSpace(available: available, total: UInt64(total), device: status.st_dev)
    }

    /// Under a tenth free, counting at least 15 GB and at most 50 GB as low: early enough to
    /// help, late enough not to nag on a big disk.
    public var isLow: Bool {
        let gb: UInt64 = 1 << 30
        return available < min(50 * gb, max(15 * gb, total / 10))
    }
}

/// Measures folders with getattrlistbulk, which reads a directory's entries and their sizes a
/// few hundred at a time, and APFS's private size: the part of a file that no clone shares.
public enum DiskScanner {
    private static let bufferSize = 256 * 1024
    /// How many files of pnpm's or bun's packages to walk before deciding they're shared.
    static let sampleFiles = 2_000

    /// Walks `root` without following symlinks or leaving its volume. A folder with its own
    /// git checkout inside (another repo, a worktree, a bare repository) goes in `nested` and
    /// isn't counted; submodules, whose git directories are in `modules` under one of
    /// `gitDirs`, are part of the checkout and are. Sizes are a floor: a folder that can't be
    /// read is left out, and so are pnpm's and bun's packages once a sample shows they're
    /// shared with their store (see `Walk.sample`).
    ///
    /// Without `sizes` it only looks for nested checkouts, for the check right before a move,
    /// and is strict: it walks everything, and any folder it can't read, or another disk
    /// mounted inside, and it returns nil, since it can't say what's in there. Also nil when
    /// `root` can't be read or `isCancelled` says to stop.
    public static func measure(
        _ root: String, dotGit: String = ".git", gitDirs: [String] = [], sizes: Bool = true, isCancelled: () -> Bool = { false }
    ) -> DiskUsage? {
        var rootStatus = stat()
        guard lstat(root, &rootStatus) == 0, rootStatus.st_mode & S_IFMT == S_IFDIR else { return nil }
        var walk = Walk(root: root, device: rootStatus.st_dev, dotGit: dotGit, gitDirs: gitDirs, sizes: sizes)
        defer { walk.buffer.deallocate() }
        walk.usage.keepsIDs = DiskUsage.keepsIDs(root)
        var pending = [Folder(path: root, counts: true)]

        while let folder = pending.popLast() {
            if isCancelled() { return nil }
            guard let children = walk.visit(folder) else { return nil }
            for child in children {
                if child.isStore { pending += walk.sample(child) } else { pending.append(child) }
            }
        }
        var usage = walk.usage
        usage.lastEdited = walk.newest > 0 ? Date(timeIntervalSince1970: TimeInterval(walk.newest)) : nil
        usage.nested.sort()
        return usage
    }

    /// A folder still to read.
    private struct Folder {
        var path: String
        /// Whether a change in it counts as an edit.
        var counts: Bool
        /// pnpm's or bun's packages: `.pnpm` or `.bun` in a node_modules folder.
        var isStore = false
    }

    private struct Walk {
        let root: String
        let device: dev_t
        let dotGit: String
        let gitDirs: [String]
        let sizes: Bool
        let git: [UInt8]
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: DiskScanner.bufferSize, alignment: 16)
        var usage: DiskUsage
        var newest = 0

        init(root: String, device: dev_t, dotGit: String, gitDirs: [String], sizes: Bool) {
            self.root = root
            self.device = device
            self.dotGit = dotGit
            self.gitDirs = gitDirs
            self.sizes = sizes
            git = Array(dotGit.utf8)
            usage = DiskUsage(device: device)
        }

        /// Reads one folder and counts its files. Returns its folders to read next, or nil when
        /// the walk can't go on.
        mutating func visit(_ folder: Folder) -> [Folder]? {
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if folder.path == root || !sizes { return nil }
                usage.incomplete = true
                return []
            }
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_dev == device else { return sizes ? [] : nil }

            var listing = Listing()
            DiskScanner.read(fd, buffer: buffer, git: git, counts: folder.counts, sizes: sizes, into: &listing)
            if listing.failed {
                if !sizes { return nil }
                usage.incomplete = true
            }
            let isCheckout = listing.dotGit.map { $0 != .file || !DiskScanner.isSubmodule(folder.path + "/" + dotGit, gitDirs: gitDirs, dotGit: dotGit) } ?? false
            if folder.path != root, isCheckout || listing.bare.count == 3 {
                usage.nested.append(folder.path)
                return []
            }
            usage.allocated += listing.allocated
            usage.freeable += listing.freeable
            usage.files += listing.files
            newest = max(newest, listing.newest)
            let inModules = sizes && folder.path.hasSuffix("/node_modules")
            return listing.folders.map { name in
                Folder(
                    path: folder.path + "/" + name, counts: folder.counts && !name.hasPrefix(".") && !EditTracker.ignoredNames.contains(name),
                    isStore: inModules && (name == ".pnpm" || name == ".bun")
                )
            }
        }

        /// pnpm and bun keep a worktree's packages in one folder, cloned or hard-linked from
        /// their store: nearly all of its files, and next to none of what removing it frees. So
        /// a few packages are walked, and when they free next to nothing (under a twentieth of
        /// what they take), the rest are taken to be the same and left out, except packages that
        /// build or download files of their own when installed. Packages that were copied, like
        /// from a store on another disk, are all walked. Returns what's left to read.
        mutating func sample(_ store: Folder) -> [Folder] {
            var packages = visit(store) ?? []
            let start = usage
            while usage.files - start.files < DiskScanner.sampleFiles, let package = packages.popLast() {
                var queue = [package]
                while let folder = queue.popLast() { queue += visit(folder) ?? [] }
            }
            let allocated = usage.allocated - start.allocated
            let freeable = usage.freeable - start.freeable
            guard !packages.isEmpty, usage.files - start.files >= DiskScanner.sampleFiles / 10, freeable <= allocated / 20 else { return packages }
            usage.sampled = true
            return packages.filter { DiskScanner.builds($0.path) }
        }
    }

    /// Whether a package in pnpm's or bun's folder (`name@version`, holding
    /// `node_modules/name`) builds or downloads files into itself when installed, like
    /// electron or a native addon: install scripts or a `binding.gyp`. Those files are its own,
    /// not the store's. Unsure counts as yes, which only costs a walk.
    static func builds(_ package: String) -> Bool {
        let modules = package + "/node_modules"
        guard let names = subfolders(of: modules) else { return true }
        var folders: [String] = []
        for name in names {
            let path = modules + "/" + name
            // A scoped package, @scope/name, is a folder further down.
            if !name.hasPrefix("@") {
                folders.append(path)
            } else if let scoped = subfolders(of: path) {
                folders += scoped.map { path + "/" + $0 }
            } else {
                return true
            }
        }
        return folders.contains { folder in
            if access(folder + "/binding.gyp", F_OK) == 0 { return true }
            guard let data = FileManager.default.contents(atPath: folder + "/package.json") else { return false }
            // Most packages have no install scripts: no need to read the JSON to tell.
            let names = ["preinstall", "install", "postinstall"]
            guard names.contains(where: { data.range(of: Data("\"\($0)\"".utf8)) != nil }) else { return false }
            guard let scripts = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["scripts"] as? [String: Any] else { return true }
            return names.contains { scripts[$0] != nil }
        }
    }

    /// The folders in a folder, not following symlinks: a package's own folder, not the
    /// packages it links to. Nil when it can't be read.
    private static func subfolders(of path: String) -> [String]? {
        guard let folder = opendir(path) else { return nil }
        defer { closedir(folder) }
        var names: [String] = []
        while let entry = readdir(folder) {
            let type = Int32(entry.pointee.d_type)
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            // Some network disks don't say what an entry is.
            if type == DT_UNKNOWN {
                var status = stat()
                guard lstat(path + "/" + name, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            }
            names.append(name)
        }
        return names
    }

    private enum Kind { case file, folder, link }

    /// One folder's direct contents.
    private struct Listing {
        var allocated: UInt64 = 0
        var freeable: UInt64 = 0
        var files = 0
        var newest = 0
        var folders: [String] = []
        var dotGit: Kind?
        /// Which of a bare repository's HEAD, objects and refs it has.
        var bare = Set<String>()
        /// Reading it stopped part way.
        var failed = false
    }

    /// Reads a folder's entries in batches. Each entry holds the attributes it returned, in
    /// order: length, the returned set, the name's reference, type, modification time and
    /// flags, then for files the link count, allocated size and APFS private size. Folders
    /// have no file attributes, so they're shorter.
    private static func read(_ fd: Int32, buffer: UnsafeMutableRawPointer, git: [UInt8], counts: Bool, sizes: Bool, into listing: inout Listing) {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
        if sizes {
            list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        }
        let options = UInt64(FSOPT_ATTR_CMN_EXTENDED)

        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, options)
            guard count > 0 else {
                if count < 0 { listing.failed = true }
                return
            }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                guard length >= 36 else {
                    listing.failed = true
                    return
                }
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                let nameOffset = Int(entry.loadUnaligned(fromByteOffset: 24, as: Int32.self))
                let nameLength = Int(entry.loadUnaligned(fromByteOffset: 28, as: UInt32.self))
                let name = UnsafeRawBufferPointer(start: entry + 24 + nameOffset, count: max(0, nameLength - 1))
                let type = entry.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
                let isGit = name.elementsEqual(git)

                if type == VREG.rawValue {
                    var offset = 36
                    func next<T>(_ type: T.Type, if bit: attrgroup_t, in group: attrgroup_t) -> T? {
                        guard group & bit != 0, offset + MemoryLayout<T>.size <= length else { return nil }
                        defer { offset += MemoryLayout<T>.size }
                        return entry.loadUnaligned(fromByteOffset: offset, as: T.self)
                    }
                    let modified = next(timespec.self, if: attrgroup_t(ATTR_CMN_MODTIME), in: returned.commonattr)?.tv_sec ?? 0
                    let flags = next(UInt32.self, if: attrgroup_t(ATTR_CMN_FLAGS), in: returned.commonattr) ?? 0
                    let links = next(UInt32.self, if: attrgroup_t(ATTR_FILE_LINKCOUNT), in: returned.fileattr) ?? 1
                    let allocated = UInt64(max(0, next(Int64.self, if: attrgroup_t(ATTR_FILE_ALLOCSIZE), in: returned.fileattr) ?? 0))
                    var unshared = next(Int64.self, if: attrgroup_t(ATTR_CMNEXT_PRIVATESIZE), in: returned.forkattr).map { UInt64(max(0, $0)) }
                    // A compressed file keeps its data where the private size doesn't look.
                    if flags & UInt32(UF_COMPRESSED) != 0 { unshared = nil }
                    listing.files += 1
                    listing.allocated += allocated
                    // A hard-linked file's blocks stay while another link does. Without APFS
                    // (an HFS+ or exFAT drive) there are no clones, so the whole file counts.
                    if links <= 1 { listing.freeable += unshared ?? allocated }
                    if counts, name.first != UInt8(ascii: ".") { listing.newest = max(listing.newest, modified) }
                    if isGit { listing.dotGit = .file }
                    if name.elementsEqual("HEAD".utf8) { listing.bare.insert("HEAD") }
                } else if type == VDIR.rawValue {
                    if isGit {
                        listing.dotGit = .folder
                    } else {
                        let folder = String(decoding: name, as: UTF8.self)
                        if folder == "objects" || folder == "refs" { listing.bare.insert(folder) }
                        listing.folders.append(folder)
                    }
                } else if type == VLNK.rawValue, isGit {
                    listing.dotGit = .link
                }
                entry += length
            }
        }
    }

    /// A submodule's `.git` is a file pointing into the `modules` folder of its superproject's
    /// git directory: one of `gitDirs` when they're known, else any `.git/modules`.
    static func isSubmodule(_ gitFile: String, gitDirs: [String], dotGit: String) -> Bool {
        guard let target = WorktreeCatalog.adminDir(ofGitFile: gitFile) else { return false }
        if gitDirs.isEmpty { return target.contains("/\(dotGit)/modules/") }
        return gitDirs.contains { Paths.contains($0 + "/modules", target) }
    }
}
