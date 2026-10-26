@testable import CorralCore
import Foundation
import Testing

struct RedactTests {
    @Test func masksSecretsInArguments() {
        let masked = Redact.arguments([
            "node", "--token=abc123", "--api-key", "hunter2", "GITHUB_TOKEN=ghp_x", "https://me:pass@example.com/repo.git",
            "ghp_aaaaaaaaaaaaaaaaaaaa", "dev", "--port", "4321",
        ])
        #expect(masked == [
            "node", "--token=•••", "--api-key", "•••", "GITHUB_TOKEN=•••", "https://me:•••@example.com/repo.git",
            "•••", "dev", "--port", "4321",
        ])
    }

    @Test func leavesOrdinaryCommandsAlone() {
        let line = "node ./node_modules/astro/bin/astro.mjs dev --port 4461"
        #expect(Redact.command(line) == line)
        #expect(Redact.arguments(["claude", "--resume", "b78d0274-5c1e-4d3a-9f0e-1a2b3c4d5e6f"]).last == "b78d0274-5c1e-4d3a-9f0e-1a2b3c4d5e6f")
    }
}

struct ActivityLogTests {
    func entry(_ title: String, _ action: ActivityEntry.Action = .stopped, at seconds: TimeInterval = 0) -> ActivityEntry {
        ActivityEntry(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), action: action, source: .panel, title: title, checkout: "meadow", memory: 1 << 30)
    }

    @Test func appendsAndReadsNewestFirst() throws {
        let sandbox = try Sandbox()
        let log = ActivityLog(url: URL(fileURLWithPath: sandbox.root + "/Corral/activity.jsonl"))
        log.append([entry("astro dev :4461")])
        log.append([entry("Fix login", .hibernated, at: 60), entry("Fix login", .woke, at: 120)])
        #expect(log.recent().map(\.action) == [.woke, .hibernated, .stopped])
        #expect(log.recent(limit: 1).first?.title == "Fix login")
    }

    @Test func survivesAHalfWrittenLine() throws {
        let sandbox = try Sandbox()
        let url = URL(fileURLWithPath: sandbox.root + "/Corral/activity.jsonl")
        let log = ActivityLog(url: url)
        log.append([entry("astro dev :4461")])
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("{\"action\":\"stop".utf8))
        try handle.close()
        log.append([entry("vite :5173", at: 30)])
        #expect(log.recent().map(\.title) == ["vite :5173", "astro dev :4461"])
    }

    @Test func keepsTheNewestWhenItGrows() throws {
        let sandbox = try Sandbox()
        let log = ActivityLog(url: URL(fileURLWithPath: sandbox.root + "/Corral/activity.jsonl"), limit: 10)
        for index in 0..<40 { log.append([entry("server \(index)", at: TimeInterval(index))]) }
        let kept = log.recent(limit: .max)
        #expect(kept.count <= 40)
        #expect(kept.first?.title == "server 39")
    }

    /// Long entries still leave room after a trim, so the file isn't rewritten on every append.
    @Test func trimsWithRoomToSpare() throws {
        let sandbox = try Sandbox()
        let url = URL(fileURLWithPath: sandbox.root + "/Corral/activity.jsonl")
        let log = ActivityLog(url: url, limit: 10)
        let long = String(repeating: "x", count: 900)
        var trims = 0
        var last = 0
        for index in 0..<30 {
            log.append([entry("\(long) \(index)", at: TimeInterval(index))])
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            if size < last { trims += 1 }
            last = size
        }
        #expect(trims <= 8)
        #expect(last <= 7_000)
        #expect(log.recent(limit: 1).first?.title == "\(long) 29")
    }
}

struct HibernateSafetyTests {
    @Test func freshRecordsSurviveReconcile() throws {
        let sandbox = try Sandbox()
        let store = HibernationStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/hibernated.json"))
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        store.add([HibernationRecord(
            harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "abc", title: "Fix flaky test",
            cwd: "/w", checkout: "meadow", resume: .command(argv: ["claude", "--resume", "abc"], cwd: "/w"),
            tty: nil, memory: 1 << 30, hibernatedAt: saved
        )])
        // Saved before the agent finished stopping, so it still shows as running for a moment.
        #expect(store.reconcile(runningSessions: ["abc"], now: saved.addingTimeInterval(3)).count == 1)
        #expect(store.reconcile(runningSessions: ["abc"], now: saved.addingTimeInterval(60)).isEmpty)
    }

    /// Hibernating the same session twice leaves one record, the newer.
    @Test func oneRecordPerSession() throws {
        let sandbox = try Sandbox()
        let store = HibernationStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/hibernated.json"))
        func record(at seconds: TimeInterval) -> HibernationRecord {
            HibernationRecord(
                harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "abc", title: "Fix flaky test",
                cwd: "/w", checkout: "meadow", resume: .command(argv: ["claude", "--resume", "abc"], cwd: "/w"),
                tty: nil, memory: 1 << 30, hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds)
            )
        }
        let first = record(at: 0)
        let second = record(at: 2)
        store.add([first])
        store.add([second])
        #expect(store.all().map(\.id) == [second.id])
    }

    /// Hibernates a real process: it stops, its record is kept, and the activity log says so.
    @Test func hibernatesARealProcess() async throws {
        let sandbox = try Sandbox()
        let store = HibernationStore(url: URL(fileURLWithPath: sandbox.root + "/Corral/hibernated.json"))
        let log = ActivityLog(url: URL(fileURLWithPath: sandbox.root + "/Corral/activity.jsonl"))
        let sleeper = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = sleeper.processIdentifier
        let started = try #require(ProcessIdentity.startTime(of: pid))

        let agent = Agent(
            harness: .claude, host: AgentHost(kind: .terminal, name: "iTerm"), sessionID: "s-\(pid)", title: "Fix login",
            state: .idle, lastActive: started, resume: .command(argv: ["claude", "--resume", "s-\(pid)"], cwd: sandbox.root), canHibernate: true
        )
        let group = ProcessGroup(
            id: "g:\(pid)", bucket: .agents, title: "claude", memory: 1 << 20,
            processes: [Proc(pid: pid, ppid: getpid(), pgid: pid, name: "sleep", command: "sleep 60", memory: 1 << 20, startedAt: started)],
            rootPID: pid, cwd: sandbox.root, agent: agent, startedAt: started
        )
        let records = await Hibernator.hibernate([group], in: .empty, source: .cli, store: store, log: log)

        #expect(records.count == 1)
        #expect(store.all().map(\.sessionID) == ["s-\(pid)"])
        #expect(!ProcessIdentity.matches(pid: pid, startedAt: started))
        #expect(log.recent().map(\.action) == [.hibernated])
        #expect(log.recent().first?.source == .cli)
    }
}

struct UpdateCheckTests {
    @Test func feedbackOpensAFilledInIssue() throws {
        let url = UpdateCheck.feedback
        #expect(url.absoluteString.hasPrefix(UpdateCheck.project + "/issues/new?"))
        let description = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(description.contains("Corral \(UpdateCheck.currentVersion) · macOS "))
    }

    @Test func readsVersionTags() {
        let output = """
        4f3c2b1a\trefs/tags/v0.1.0
        9e8d7c6b\trefs/tags/v0.10.0
        1a2b3c4d\trefs/tags/v0.9.2
        5e6f7a8b\trefs/tags/nightly
        """
        let versions = UpdateCheck.versions(inLsRemote: output)
        #expect(versions == ["0.1.0", "0.10.0", "0.9.2"])
        #expect(versions.max(by: { UpdateCheck.isNewer($1, than: $0) }) == "0.10.0")
    }

    @Test func comparesByNumber() {
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.2"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.99.99"))
        #expect(!UpdateCheck.isNewer("0.2.0", than: "0.2.0"))
        #expect(!UpdateCheck.isNewer("0.2", than: "0.2.0"))
        #expect(!UpdateCheck.isNewer("dev", than: "0.2.0"))
        #expect(UpdateCheck.isNewer("0.2.0", than: "dev"))
    }
}
