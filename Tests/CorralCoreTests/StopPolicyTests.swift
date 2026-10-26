@testable import CorralCore
import Foundation
import Testing

struct StopPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func group(_ bucket: Bucket, _ title: String, agent: Agent? = nil, command: String = "node", mb: UInt64 = 100) -> ProcessGroup {
        let proc = Proc(pid: 400, ppid: 1, pgid: 400, name: "node", command: command, memory: mb << 20, startedAt: now)
        return ProcessGroup(id: "g:\(title)", bucket: bucket, title: title, memory: mb << 20, processes: [proc], rootPID: 400, agent: agent, startedAt: now)
    }

    func agent(_ host: AgentHost, resumable: Bool) -> Agent {
        Agent(
            harness: .claude, host: host, sessionID: "s", title: "Fix login", state: .idle, lastActive: now,
            resume: resumable ? .command(argv: ["claude", "--resume", "s"], cwd: "/w") : nil, canHibernate: resumable
        )
    }

    @Test func serversStopAndResumableAgentsHibernate() {
        #expect(StopPolicy.of(group(.leaked, "astro dev :4461")) == .stop)
        #expect(StopPolicy.of(group(.shared, "Postgres")) == .stop)
        let iterm = AgentHost(kind: .terminal, name: "iTerm")
        #expect(StopPolicy.of(group(.agents, "claude", agent: agent(iterm, resumable: true))) == .hibernate)
        #expect(StopPolicy.of(group(.agents, "aider", agent: agent(iterm, resumable: false))) == .stop)
    }

    @Test func appsKeepTheirOwnSessions() {
        let codex = AgentHost(kind: .app, name: "Codex Desktop", bundleID: "com.openai.codex")
        guard case let .managed(managed) = StopPolicy.of(group(.agents, "codex", agent: agent(codex, resumable: false))) else {
            Issue.record("Codex Desktop's server should be left to the app")
            return
        }
        #expect(managed.caption == "Codex Desktop")
    }

    @Test func containerVMsAndAgentProxiesAreLeftAlone() {
        guard case let .managed(vm) = StopPolicy.of(group(.shared, "Linux VM (Colima)")) else {
            Issue.record("the VM should never be signalled")
            return
        }
        #expect(vm.command == "colima stop")
        guard case let .managed(docker) = StopPolicy.of(group(.shared, "Linux VM (Docker Desktop)")) else {
            Issue.record("Docker's VM should never be signalled")
            return
        }
        #expect(docker.command == nil)
        #expect(docker.caption == "quit Docker Desktop to free it")
        if case .stop = StopPolicy.of(group(.shared, "QEMU")) { Issue.record("QEMU is a VM") }
    }

    @Test func runtimeProcessesFoldIntoTheirVM() {
        let merged = SnapshotBuilder.mergeShared([
            group(.shared, "Linux VM", mb: 6000),
            group(.shared, "Lima", command: "ssh -F /Users/me/.colima/_lima/colima/ssh.config lima-colima", mb: 12),
            group(.shared, "Lima", command: "limactl hostagent --pidfile /Users/me/.colima/_lima/colima/ha.pid colima", mb: 30),
            group(.shared, "Watchman", mb: 16),
        ])
        #expect(merged.map(\.title) == ["Linux VM (Colima)", "Watchman"])
        #expect(merged[0].memory == 6042 << 20)
        #expect(merged[0].processes.count == 3)
        #expect(merged[0].signalGroup == nil)
    }

    @Test func nameLists() {
        #expect(Format.names([]) == "")
        #expect(Format.names(["A"]) == "A")
        #expect(Format.names(["A", "B"]) == "A and B")
        #expect(Format.names(["A", "B", "C"]) == "A, B and C")
        #expect(Format.names(["A", "B", "C", "D"]) == "A, B and 2 more")
    }
}
