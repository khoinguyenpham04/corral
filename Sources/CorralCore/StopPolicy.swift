import Foundation

/// What Corral may do to a group of processes. The panel and the CLI both ask this, so neither
/// offers to stop something that stopping from outside would break.
public enum StopPolicy: Equatable, Sendable {
    /// Stop it: SIGTERM, then SIGKILL. It doesn't come back on its own.
    case stop
    /// Stop it and keep its session, so it can be woken later.
    case hibernate
    /// Leave it running: something else owns it.
    case managed(Managed)

    public struct Managed: Equatable, Sendable {
        /// A few words for beside the title, when there's no command to show instead.
        public var caption: String
        /// Why Corral leaves it alone, as a sentence.
        public var reason: String
        /// The proper way to stop it, when a command does that.
        public var command: String?

        public init(caption: String, reason: String, command: String? = nil) {
            self.caption = caption
            self.reason = reason
            self.command = command
        }
    }

    public static func of(_ group: ProcessGroup) -> StopPolicy {
        if let agent = group.agent {
            if agent.canHibernate, agent.resume != nil { return .hibernate }
            guard agent.host.kind == .app || agent.host.kind == .editor else { return .stop }
            let host = agent.host.name
            return .managed(Managed(
                caption: host,
                reason: "\(host) runs this session and keeps it. Quit \(host) to free its memory."
            ))
        }
        guard group.bucket == .shared else { return .stop }
        if let runtime = ContainerRuntime(title: group.title) { return .managed(runtime.managed) }
        if group.title.hasPrefix("Linux VM") || group.title == "QEMU" {
            return .managed(Managed(
                caption: "stop it from its app",
                reason: "Stopping a VM from outside can corrupt what runs in it. Stop it from the app that started it."
            ))
        }
        return .stop
    }
}

/// Tools that run containers in a Linux VM. Corral never signals them; each has its own way to
/// stop that shuts the containers down cleanly.
public enum ContainerRuntime: String, CaseIterable, Sendable {
    case colima = "Colima"
    case lima = "Lima"
    case docker = "Docker Desktop"
    case orbstack = "OrbStack"
    case podman = "Podman"
    case rancher = "Rancher Desktop"

    /// The runtime behind a shared group: its own processes ("Colima") or its VM ("Linux VM (Colima)").
    public init?(title: String) {
        let name = title.hasPrefix("Linux VM (") && title.hasSuffix(")") ? String(title.dropFirst(10).dropLast()) : title
        guard let runtime = Self(rawValue: name) else { return nil }
        self = runtime
    }

    public var stopCommand: String? {
        switch self {
        case .colima: "colima stop"
        case .lima: "limactl stop"
        case .orbstack: "orb stop"
        case .podman: "podman machine stop"
        case .docker, .rancher: nil
        }
    }

    var managed: StopPolicy.Managed {
        if let command = stopCommand {
            return .init(
                caption: "run \(command)",
                reason: "Containers run in this VM, and stopping it from outside can corrupt them. `\(command)` stops it cleanly.",
                command: command
            )
        }
        return .init(
            caption: "quit \(rawValue) to free it",
            reason: "Containers run in this VM, and stopping it from outside can corrupt them. Quit \(rawValue) to stop it cleanly."
        )
    }
}
