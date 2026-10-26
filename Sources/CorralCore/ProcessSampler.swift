import Darwin
import Foundation

/// One process as read from the kernel. Only the current user's processes carry a path,
/// arguments, working directory and memory; other users' processes are kept as names so the
/// process tree stays connected (`login` sits between a terminal and its shell, for example).
public struct ProcessRecord: Codable, Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var startedAt: Date
    public var tty: String?
    public var path: String
    public var args: [String]
    public var cwd: String?
    /// Physical footprint, the number Activity Monitor shows as "Memory".
    public var footprint: UInt64
    /// User + system CPU time in nanoseconds.
    public var cpuTime: UInt64

    public init(
        pid: Int32, ppid: Int32, pgid: Int32? = nil, uid: UInt32 = getuid(), startedAt: Date = Date(timeIntervalSince1970: 0),
        tty: String? = nil, path: String, args: [String] = [], cwd: String? = nil, footprint: UInt64 = 0, cpuTime: UInt64 = 0
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid ?? pid
        self.uid = uid
        self.startedAt = startedAt
        self.tty = tty
        self.path = path
        self.args = args
        self.cwd = cwd
        self.footprint = footprint
        self.cpuTime = cpuTime
    }

    /// Executable file name: "node", "claude", "workerd".
    public var executable: String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        return (args.first.map { ($0 as NSString).lastPathComponent }) ?? ""
    }

    /// Identifies this process across samples, even if the pid is later reused.
    public var key: String { "\(pid)@\(Int64(startedAt.timeIntervalSince1970 * 1000))" }

    /// A short command line for display: executable plus the first few arguments.
    public var commandLine: String {
        let rest = args.dropFirst().prefix(6).map { arg -> String in
            let shortened = arg.hasPrefix("/") ? Paths.abbreviate(arg) : arg
            return shortened.count > 60 ? String(shortened.prefix(57)) + "…" : shortened
        }
        return ([executable] + rest).joined(separator: " ")
    }
}

/// Reads the process table with sysctl and libproc. Needs no special privileges; it sees full
/// details only for processes owned by the current user.
final class ProcessSampler {
    private struct Key: Hashable {
        let pid: Int32
        let start: Int64
    }

    private var executables: [Key: (path: String, args: [String])] = [:]
    private var ttyNames: [Int32: String] = [:]
    private let uid = getuid()
    private let argMax: Int
    private let argBuffer: UnsafeMutableRawPointer
    private let ticksToNanos: Double

    init() {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mib, 2, &argMax, &size, nil, 0) != 0 || argMax <= 0 { argMax = 1 << 20 }
        self.argMax = Int(argMax)
        argBuffer = .allocate(byteCount: Int(argMax), alignment: 8)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = Double(timebase.numer) / Double(max(timebase.denom, 1))
    }

    deinit { argBuffer.deallocate() }

    func sample() -> [ProcessRecord] {
        let kinfos = Self.processTable()
        var seen = Set<Key>()
        var records: [ProcessRecord] = []
        records.reserveCapacity(kinfos.count)

        for kinfo in kinfos {
            let pid = kinfo.kp_proc.p_pid
            guard pid > 0, kinfo.kp_proc.p_stat != CChar(SZOMB) else { continue }
            let start = kinfo.kp_proc.p_un.__p_starttime
            let key = Key(pid: pid, start: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
            seen.insert(key)
            let owner = kinfo.kp_eproc.e_ucred.cr_uid
            var record = ProcessRecord(
                pid: pid,
                ppid: kinfo.kp_eproc.e_ppid,
                pgid: kinfo.kp_eproc.e_pgid,
                uid: owner,
                startedAt: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000),
                tty: ttyName(kinfo.kp_eproc.e_tdev),
                path: ""
            )
            if owner == uid {
                let exe = executable(pid: pid, key: key, fallback: Self.commandName(kinfo))
                record.path = exe.path
                record.args = exe.args
                record.cwd = Self.workingDirectory(pid)
                if let usage = usage(pid) {
                    record.footprint = usage.footprint
                    record.cpuTime = usage.cpu
                }
            } else {
                record.path = Self.commandName(kinfo)
            }
            records.append(record)
        }

        if executables.count > seen.count + 64 {
            executables = executables.filter { seen.contains($0.key) }
        }
        return records
    }

    // MARK: Kernel calls

    private static func processTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += size / 8
            let stride = MemoryLayout<kinfo_proc>.stride
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let result = table.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if result == 0 { return Array(table.prefix(size / stride)) }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    private static func commandName(_ kinfo: kinfo_proc) -> String {
        withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func executable(pid: Int32, key: Key, fallback: String) -> (path: String, args: [String]) {
        if let cached = executables[key] { return cached }
        let arguments = arguments(pid)
        var path = Self.executablePath(pid)
        if path.isEmpty { path = arguments.execPath ?? fallback }
        let value = (path, arguments.argv)
        executables[key] = value
        return value
    }

    private static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Parses KERN_PROCARGS2: argc, the exec path, padding, then argv. The environment that
    /// follows is never read.
    private func arguments(_ pid: Int32) -> (execPath: String?, argv: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        guard sysctl(&mib, 3, argBuffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return (nil, []) }
        let bytes = UnsafeRawBufferPointer(start: argBuffer, count: size)
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<min(index, start + 4096)], as: UTF8.self)
            index += 1
            return value
        }

        let execPath = nextString()
        while index < size, bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < min(argc, 128), let arg = nextString() { argv.append(arg) }
        return (execPath, argv)
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private func usage(_ pid: Int32) -> (footprint: UInt64, cpu: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return (info.ri_phys_footprint, UInt64(ticks * ticksToNanos))
    }

    private func ttyName(_ device: Int32) -> String? {
        guard device != -1 else { return nil }
        if let cached = ttyNames[device] { return cached }
        guard let name = devname(dev_t(device), S_IFCHR) else { return nil }
        let value = String(cString: name)
        ttyNames[device] = value
        return value
    }
}

/// Reads one process's identity again right before signalling it, so a pid that was reused
/// since the last sample is never touched.
enum ProcessIdentity {
    /// When a live process started; nil once it has exited (zombies count as exited).
    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    static func matches(pid: Int32, startedAt: Date) -> Bool {
        guard let start = startTime(of: pid) else { return false }
        return abs(start.timeIntervalSince(startedAt)) < 0.01
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Open files of one process, for agents that keep their transcript open (Codex).
    static func openFiles(of pid: Int32) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bufferSize) }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// TCP ports one process listens on, the way lsof finds them: its socket descriptors, read
    /// with libproc. Needs no privileges for the user's own processes, and takes a few
    /// microseconds a process.
    static func listeningPorts(of pid: Int32) -> [Int] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bufferSize) }
        guard used > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  Int(info.psi.soi_kind) == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            // In network byte order, in the low 16 bits.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports.sorted()
    }
}

enum Paths {
    static let home = NSHomeDirectory()

    /// "/Users/me/x" → "~/x".
    static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Lexically resolves "." and ".." in an absolute path without touching the file system.
    static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return normalizeLexically(path)
    }

    /// Like `normalize`, but also tidies relative paths ("./node_modules/.bin/../astro" → "node_modules/astro").
    static func normalizeLexically(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." {
                parts.removeLast()
                continue
            }
            if part == "..", absolute { continue }
            parts.append(part)
        }
        return (absolute ? "/" : "") + parts.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// True if `path` is `root` or inside it.
    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
