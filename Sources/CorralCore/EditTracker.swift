import CoreServices
import Foundation

/// When each checkout was last edited. A bounded scan seeds the time when a checkout first
/// appears; FSEvents keeps it current after that. Generated and tooling folders (node_modules,
/// dist, dot-folders) don't count as edits.
final class EditTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.khoinguyenpham04.corral.edits", qos: .utility)
    private let lock = NSLock()
    private var roots: [String] = []
    private var edits: [String: Date] = [:]
    private var scanned = Set<String>()
    private var stream: FSEventStreamRef?

    static let ignoredNames: Set<String> = [
        "node_modules", "dist", "build", "out", "target", "coverage", "vendor", "Pods", "DerivedData",
        "__pycache__", "venv", "tmp", "logs",
    ]

    func lastEdited(_ root: String) -> Date? {
        lock.withLock { edits[root] }
    }

    /// Watches exactly these checkouts. Cheap to call every sample; only acts on changes.
    func watch(_ newRoots: [String]) {
        let wanted = Array(Set(newRoots)).sorted { $0.count > $1.count }
        let (changed, unscanned): (Bool, [String]) = lock.withLock {
            guard Set(wanted) != Set(roots) else { return (false, []) }
            roots = wanted
            return (true, wanted.filter { !scanned.contains($0) })
        }
        guard changed else { return }
        queue.async { [self] in
            restartStream(wanted)
            for root in unscanned { scan(root) }
        }
    }

    private func restartStream(_ paths: [String]) {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, Self.callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let tracker = Unmanaged<EditTracker>.fromOpaque(info).takeUnretainedValue()
        let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
        let contentChange = UInt32(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
        )
        var changed: [String] = []
        for index in 0..<min(count, list.count) where flags[index] & contentChange != 0 {
            changed.append(list[index])
        }
        tracker.record(changed)
    }

    private func record(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let now = Date()
        lock.withLock {
            for path in paths {
                guard let root = roots.first(where: { Paths.contains($0, path) }) else { continue }
                let relative = path.dropFirst(root.count).split(separator: "/")
                if relative.contains(where: { $0.hasPrefix(".") || Self.ignoredNames.contains(String($0)) }) { continue }
                edits[root] = now
            }
        }
    }

    /// Finds the newest file in a checkout, looking at up to 20,000 entries.
    private func scan(_ root: String) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return }
        var newest = Date.distantPast
        var visited = 0
        while let url = enumerator.nextObject() as? URL, visited < 20_000 {
            visited += 1
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if name.hasPrefix(".") || Self.ignoredNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if let date = values?.contentModificationDate, date > newest { newest = date }
        }
        lock.withLock {
            scanned.insert(root)
            if newest > .distantPast { edits[root] = max(edits[root] ?? .distantPast, newest) }
        }
    }
}
