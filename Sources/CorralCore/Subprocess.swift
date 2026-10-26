import Foundation

/// Runs the few commands Corral needs (git, xcode-select) without letting them ask anything,
/// and gives up on them after a timeout.
enum Subprocess {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: String?
    nonisolated(unsafe) private static var lookedAt: Date?

    /// A real git, never /usr/bin/git: on a Mac without developer tools that one asks to
    /// install them. While there's none, it's looked for again at most once a minute, so
    /// installing the developer tools while Corral runs works.
    static var git: String? {
        lock.withLock {
            if let found { return found }
            if let lookedAt, Date().timeIntervalSince(lookedAt) < 60 { return nil }
            lookedAt = Date()
            let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git"] + (developerDirectory.map { [$0 + "/usr/bin/git"] } ?? [])
            found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            return found
        }
    }

    /// What a git hook or a direnv shell can set to point git at another repository than the
    /// one asked about. Everything else in the environment, like GIT_SSH_COMMAND, stays.
    static let repositoryVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_QUARANTINE_PATH",
    ]

    private static var developerDirectory: String? {
        let output = run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    /// Runs a command without letting git or a credential manager ask anything, and gives up
    /// after `timeout`. Returns standard output when it exits cleanly.
    static func run(_ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval) -> String? {
        guard let (status, output) = runStatus(path, arguments, input: input, timeout: timeout), status == 0 else { return nil }
        return output
    }

    /// Like `run`, with the exit status, for commands whose status is the answer
    /// (`git symbolic-ref -q` exits 1 for a detached HEAD). Nil when it couldn't run or timed out.
    static func runStatus(_ path: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment.filter { !repositoryVariables.contains($0.key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GCM_INTERACTIVE"] = "never"
        // Looking at a repo shouldn't change it: git status otherwise rewrites the index.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        // As low a priority as the caller's, so git asked about a worktree measured in the
        // background doesn't run ahead of it; but no lower than utility, where it would often
        // run out of time on a busy Mac and leave the worktree unchecked.
        let caller = Thread.current.qualityOfService
        process.qualityOfService = caller == .background ? .utility : caller
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        // Told the moment it exits, rather than looking every so often.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if let stdin, let input {
            // Written while it runs, without SIGPIPE if it exits before reading it all.
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }
        }
        // Read while it runs, so a full pipe can never stall it.
        nonisolated(unsafe) var data = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        reading.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
