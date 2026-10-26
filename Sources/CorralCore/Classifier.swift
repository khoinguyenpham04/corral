import Foundation

public enum AgentMode: String, Codable, Sendable, Hashable {
    /// A TUI in a terminal.
    case interactive
    /// Driven by an app over stdio: Claude Desktop, an editor extension, the Agent SDK.
    case hosted
    /// A long-lived server several sessions talk to: `codex app-server`, `opencode serve`.
    case server
    /// A single headless run: `claude -p`, `codex exec`.
    case oneShot
}

/// What one process is, judged from its executable and arguments.
public enum Role: Sendable, Hashable {
    case agent(Harness, AgentMode)
    case stack(String)
    case build(String)
    /// Databases, VMs, gateways. `global` ones (VMs, daemons) never belong to one checkout.
    case infra(String, global: Bool)
    /// An interactive shell. Everything started from it is its own group.
    case shell
    case multiplexer
    case login
    /// devenv, process-compose, concurrently: each child becomes its own group.
    case processManager(String)
    /// npm, pnpm, `sh -c`: takes the role of whatever it runs. The hint comes from the script
    /// name (`pnpm dev` hints at a stack) and applies only if nothing more specific is found.
    case wrapper(hint: Bucket?)
    /// Belongs to whatever started it: `esbuild --service`, MCP servers.
    case helper(String)
    /// Editors and language servers.
    case tool(String)
    /// node, python, bun running something Corral doesn't recognise.
    case runtime(String)
    case app
    case system
    case unknown(String)

    var bucket: Bucket {
        switch self {
        case .agent: .agents
        case .stack: .stacks
        case .build: .build
        case .infra: .shared
        case let .wrapper(hint): hint ?? .other
        default: .other
        }
    }

    /// How strongly this process defines its group. The heaviest member names the group.
    var weight: Int {
        switch self {
        case .agent: 6
        case .stack: 5
        case .build: 4
        case .infra: 3
        case .wrapper(.some): 1
        default: 0
        }
    }

    var label: String? {
        switch self {
        case let .agent(harness, _): harness.displayName
        case let .stack(label), let .build(label), let .infra(label, _), let .helper(label),
             let .tool(label), let .runtime(label), let .unknown(label), let .processManager(label):
            label
        default: nil
        }
    }

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// Long-running work an agent might start that deserves its own row.
    var isService: Bool {
        switch self {
        case .stack, .build, .infra, .processManager: true
        default: false
        }
    }

    var isBoundary: Bool {
        switch self {
        case .shell, .multiplexer, .login: true
        default: false
        }
    }
}

/// A process's command line, with interpreters unwrapped: for `node …/astro/bin/astro.mjs dev`
/// the tool is "astro" and `rest` is `["dev"]`.
struct Invocation {
    let path: String
    let exe: String
    /// The name the process was started as. Differs from `exe` for versioned binaries
    /// (`~/.local/share/claude/versions/2.1.300` runs as "claude").
    let arg0: String
    let args: [String]
    let tool: String
    let toolPath: String
    let rest: [String]

    init(_ record: ProcessRecord) {
        self.init(path: record.path, args: record.args)
    }

    init(path: String, args: [String]) {
        self.path = path
        self.args = args
        let exe = Paths.name(path.isEmpty ? (args.first ?? "") : path)
        self.exe = exe
        arg0 = Paths.name(args.first ?? exe)
        let tail = Array(args.dropFirst())

        if Invocation.nodeLike.contains(exe) {
            let (script, after) = Invocation.splitScript(tail, valueFlags: Invocation.nodeValueFlags)
            if let script {
                tool = Invocation.toolName(fromScript: script)
                toolPath = script
                rest = after
            } else if let title = Invocation.processTitle(args, exe: exe) {
                tool = title[0]
                toolPath = path
                rest = Array(title.dropFirst())
            } else {
                tool = exe
                toolPath = path
                rest = tail
            }
        } else if Invocation.isPython(exe) {
            if let index = tail.firstIndex(of: "-m"), index + 1 < tail.count {
                tool = tail[index + 1]
                toolPath = tail[index + 1]
                rest = Array(tail[(index + 2)...])
            } else {
                let (script, after) = Invocation.splitScript(tail, valueFlags: ["-W", "-X", "-c"])
                tool = script.map(Invocation.toolName(fromScript:)) ?? exe
                toolPath = script ?? path
                rest = after
            }
        } else if exe == "ruby" || exe == "perl" || exe == "php" {
            let (script, after) = Invocation.splitScript(tail, valueFlags: ["-I", "-r", "-e"])
            tool = script.map(Invocation.toolName(fromScript:)) ?? exe
            toolPath = script ?? path
            rest = after
        } else {
            tool = exe
            toolPath = path
            rest = tail
        }
    }

    static let nodeLike: Set<String> = ["node", "nodejs", "bun", "deno"]
    static let nodeValueFlags: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions",
        "--env-file", "--title", "--inspect-port", "--stack-size", "--max-old-space-size",
        "--input-type", "--experimental-config-file",
    ]

    static func isPython(_ exe: String) -> Bool {
        exe == "Python" || exe == "python" || exe.hasPrefix("python3")
    }

    var isInterpreter: Bool {
        Invocation.nodeLike.contains(exe) || Invocation.isPython(exe) || ["ruby", "perl", "php", "java", "beam.smp", "dotnet"].contains(exe)
    }

    /// A process that renames itself (`process.title = "Raycast Backend"`) overwrites its
    /// arguments, leaving the new name as argv[0] and blanks after it. Returns its words.
    static func processTitle(_ args: [String], exe: String) -> [String]? {
        guard let first = args.first, !first.contains("/"), Paths.name(first) != exe, !nodeLike.contains(first) else { return nil }
        let words = first.split(separator: " ").map(String.init)
        return words.isEmpty ? nil : words
    }

    /// The first argument that isn't a flag (skipping the values of `valueFlags`), and what follows it.
    static func splitScript(_ args: [String], valueFlags: Set<String>) -> (String?, [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.isEmpty {
                index += 1
                continue
            }
            if arg == "-e" || arg == "--eval" || arg == "-p" || arg == "--print" || arg == "-c" {
                return (nil, Array(args[index...]))
            }
            if arg.hasPrefix("-") {
                index += valueFlags.contains(arg) ? 2 : 1
                continue
            }
            return (arg, Array(args[(index + 1)...]))
        }
        return (nil, [])
    }

    /// "…/node_modules/.pnpm/astro@7/node_modules/astro/bin/astro.mjs" → "astro";
    /// "…/node_modules/.bin/vite" → "vite"; "/x/harness/mock.mjs" → "mock".
    static func toolName(fromScript script: String) -> String {
        let path = Paths.normalizeLexically(script)
        if let range = path.range(of: "node_modules/", options: .backwards) {
            let parts = path[range.upperBound...].split(separator: "/").map(String.init)
            if parts.first == ".bin", parts.count > 1 { return parts[1] }
            if let first = parts.first {
                let package = first.hasPrefix("@") && parts.count > 1 ? first + "/" + parts[1] : first
                let file = Invocation.stem(parts.last ?? "")
                switch package {
                case "typescript": return file
                case "npm": return file.hasPrefix("npx") ? "npx" : "npm"
                default: return package
                }
            }
        }
        var name = stem(Paths.name(path))
        let generic: Set<String> = ["index", "cli", "main", "bin", "run", "start", "server", "entry", "app"]
        if generic.contains(name) {
            var parent = Paths.parent(path)
            while ["bin", "dist", "lib", "src", "build", "out"].contains(Paths.name(parent)), parent.count > 1 {
                parent = Paths.parent(parent)
            }
            let folder = Paths.name(parent)
            if !folder.isEmpty, folder != "/" { name = folder }
        }
        return name
    }

    static func stem(_ file: String) -> String {
        for ext in [".mjs", ".cjs", ".js", ".ts", ".mts", ".cts", ".tsx", ".py", ".rb", ".pl", ".php", ".jar"] where file.hasSuffix(ext) {
            return String(file.dropLast(ext.count))
        }
        return file
    }

    /// True if the executable or argv[0] is `name`.
    func named(_ names: String...) -> Bool {
        names.contains(exe) || names.contains(arg0)
    }

    func has(_ flags: String...) -> Bool {
        rest.contains { arg in flags.contains(arg) || flags.contains { arg.hasPrefix($0 + "=") } }
    }

    func contains(_ word: String) -> Bool { rest.contains(word) }

    /// The first positional argument, skipping the values of `valueFlags`.
    func positional(skipping valueFlags: Set<String> = []) -> String? {
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg.hasPrefix("-") {
                index += (valueFlags.contains(arg) && !arg.contains("=")) ? 2 : 1
                continue
            }
            return arg
        }
        return nil
    }

    var subcommand: String? { positional() }

    /// The port a dev server listens on, from `--port 4461`, `--port=4461` or `-p 4461`.
    var port: String? {
        for (index, arg) in rest.enumerated() {
            if arg.hasPrefix("--port=") { return String(arg.dropFirst("--port=".count)) }
            if (arg == "--port" || arg == "-p" || arg == "--listen"), index + 1 < rest.count,
               let value = Int(rest[index + 1].split(separator: ":").last ?? ""), value > 0 {
                return String(value)
            }
        }
        return nil
    }

    func label(_ base: String) -> String {
        if let port { return "\(base) :\(port)" }
        return base
    }

    /// Guesses what a wrapper runs from its words: `pnpm dev` → stacks, `turbo watch` → build.
    var hint: Bucket? {
        let words = rest.flatMap { $0.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init) }
        let stackWords: Set<String> = ["dev", "start", "serve", "server", "preview", "develop", "storybook", "up"]
        let buildWords: Set<String> = ["build", "watch", "compile", "typecheck", "test", "bundle"]
        if words.contains(where: stackWords.contains) { return .stacks }
        if words.contains(where: buildWords.contains) { return .build }
        return nil
    }
}

public enum Classifier {
    public static func classify(_ record: ProcessRecord) -> Role {
        classify(Invocation(record))
    }

    static func classify(_ inv: Invocation) -> Role {
        if let role = agentRole(inv) { return role }
        if let role = infraRole(inv) { return role }
        if inv.exe == "disclaimer" { return .wrapper(hint: nil) }
        // CLT's python runs from inside Python.app; interpreters are never GUI apps.
        if BundleCatalog.bundlePath(containing: inv.path) != nil, !inv.isInterpreter { return .app }

        switch inv.exe {
        case "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "-zsh", "-bash":
            if let index = inv.rest.firstIndex(of: "-c") {
                return .wrapper(hint: Invocation(path: inv.path, args: [inv.exe] + inv.rest.suffix(from: index + 1)).hint)
            }
            return .shell
        case "tmux", "zellij", "screen", "abduco", "dtach":
            return .multiplexer
        case "login", "sshd", "sshd-session", "mosh-server":
            return .login
        default:
            break
        }

        if let role = toolRole(inv) { return role }
        if inv.isInterpreter { return .runtime(inv.tool == inv.exe ? inv.exe : inv.tool) }
        if isSystem(inv.path) { return .system }
        return .unknown(inv.exe)
    }

    static func isSystem(_ path: String) -> Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/usr/lib/"].contains { path.hasPrefix($0) }
    }

    // MARK: Agents

    static func agentRole(_ inv: Invocation) -> Role? {
        let tool = inv.tool
        let oneShot = inv.has("-p", "--print")

        if inv.named("claude") || inv.path.contains("/claude/versions/") || tool == "@anthropic-ai/claude-code"
            || (tool == "@anthropic-ai/claude-agent-sdk" && inv.toolPath.hasSuffix("cli.js")) {
            if let sub = inv.subcommand, ["mcp", "doctor", "update", "install", "config", "setup-token", "migrate-installer"].contains(sub) {
                return .helper("claude \(sub)")
            }
            if oneShot { return .agent(.claude, .oneShot) }
            if inv.has("--input-format", "--output-format", "--sdk-url") { return .agent(.claude, .hosted) }
            return .agent(.claude, .interactive)
        }

        if inv.named("codex") || inv.exe.hasPrefix("codex-aarch64") || inv.exe.hasPrefix("codex-x86_64") {
            if inv.contains("app-server") || inv.contains("proto") { return .agent(.codex, .server) }
            if inv.contains("exec") || inv.subcommand == "e" { return .agent(.codex, .oneShot) }
            if inv.contains("mcp-server") || inv.subcommand == "mcp" { return .helper("codex mcp") }
            let utilities: Set<String> = ["login", "logout", "apply", "sandbox", "completion", "debug", "features", "cloud-tasks"]
            if let sub = inv.positional(skipping: ["-c", "--config", "-m", "--model", "-p", "--profile"]), utilities.contains(sub) {
                return .helper("codex \(sub)")
            }
            return .agent(.codex, .interactive)
        }
        if tool == "@openai/codex" || tool == "opencode-ai" { return .wrapper(hint: nil) }

        if inv.named("opencode", "opencode-cli") {
            let sub = inv.positional(skipping: ["-m", "--model", "--port", "--hostname", "-s", "--session", "--agent", "--prompt", "--log-level"])
            switch sub {
            case "serve", "web", "acp": return .agent(.opencode, .server)
            case "run": return .agent(.opencode, .oneShot)
            case "mcp", "auth", "models", "stats", "export", "import", "upgrade", "session", "github", "agent", "debug":
                return .helper("opencode \(sub!)")
            default: return .agent(.opencode, .interactive)
            }
        }

        if tool.hasSuffix("/pi-coding-agent") || inv.named("pi") {
            if inv.has("--mode") || inv.has("--rpc") { return .agent(.pi, .hosted) }
            return .agent(.pi, oneShot ? .oneShot : .interactive)
        }
        if inv.named("omp") || tool.hasPrefix("@oh-my-pi/") || inv.toolPath.contains("/oh-my-pi/") {
            return .agent(.ohMyPi, oneShot ? .oneShot : .interactive)
        }
        if tool == "@google/gemini-cli" || inv.named("gemini") {
            return .agent(.gemini, inv.has("-p", "--prompt") ? .oneShot : .interactive)
        }
        if inv.named("cursor-agent") || inv.toolPath.contains("/cursor-agent/") {
            return .agent(.cursor, oneShot ? .oneShot : .interactive)
        }
        if inv.named("devin") {
            if let sub = inv.subcommand, ["list", "ls", "cloud", "auth", "login", "logout", "update", "mcp", "config", "version"].contains(sub) {
                return .helper("devin \(sub)")
            }
            return .agent(.devin, oneShot ? .oneShot : .interactive)
        }
        if tool == "@sourcegraph/amp" || inv.named("amp") {
            return .agent(.amp, inv.has("-x", "--execute") ? .oneShot : .interactive)
        }
        if tool == "@github/copilot" || inv.named("copilot") {
            return .agent(.copilot, inv.has("-p", "--prompt") ? .oneShot : .interactive)
        }
        if inv.named("goose") {
            if inv.subcommand == "mcp" { return .helper("goose mcp") }
            return .agent(.goose, inv.subcommand == "run" ? .oneShot : .interactive)
        }
        if tool == "aider" || inv.named("aider") { return .agent(.aider, .interactive) }
        if inv.named("crush") { return .agent(.crush, inv.subcommand == "run" ? .oneShot : .interactive) }
        if inv.named("kiro-cli") { return .agent(.kiro, .interactive) }
        if tool == "@qwen-code/qwen-code" || inv.named("qwen") { return .agent(.qwen, oneShot ? .oneShot : .interactive) }
        return nil
    }

    // MARK: Infrastructure

    static func infraRole(_ inv: Invocation) -> Role? {
        let path = inv.path
        if path.contains("/Docker.app/") { return .infra("Docker Desktop", global: true) }
        if path.contains("/OrbStack.app/") { return .infra("OrbStack", global: true) }
        if path.contains("/Rancher Desktop.app/") { return .infra("Rancher Desktop", global: true) }
        if inv.exe == "com.apple.Virtualization.VirtualMachine" { return .infra("Linux VM", global: true) }

        switch inv.exe {
        case "colima": return .infra("Colima", global: true)
        case "limactl", "lima": return .infra(inv.args.contains { $0.contains("/.colima/") } ? "Colima" : "Lima", global: true)
        case "vfkit", "gvproxy", "krunkit", "podman", "podman-mac-helper": return .infra("Podman", global: true)
        case "ollama": return .infra("Ollama", global: true)
        case "watchman": return .infra("Watchman", global: true)
        case "postgres", "postmaster": return .infra("Postgres", global: false)
        case "mysqld", "mariadbd": return .infra("MySQL", global: false)
        case "mongod": return .infra("MongoDB", global: false)
        case "redis-server", "valkey-server": return .infra("Redis", global: false)
        case "memcached": return .infra("Memcached", global: false)
        case "clickhouse", "clickhouse-server": return .infra("ClickHouse", global: false)
        case "etcd": return .infra("etcd", global: false)
        case "nats-server": return .infra("NATS", global: false)
        case "minio": return .infra("MinIO", global: false)
        case "meilisearch": return .infra("Meilisearch", global: false)
        case "typesense-server": return .infra("Typesense", global: false)
        case "temporal", "temporalite": return inv.contains("server") || inv.exe == "temporalite" ? .infra("Temporal", global: false) : nil
        case "grafana", "grafana-server": return .infra("Grafana", global: false)
        case "prometheus": return .infra("Prometheus", global: false)
        case "loki": return .infra("Loki", global: false)
        case "jaeger", "jaeger-all-in-one": return .infra("Jaeger", global: false)
        case "otelcol", "otelcol-contrib": return .infra("OTel collector", global: false)
        case "cloudflared": return .infra("cloudflared", global: false)
        case "caddy", "nginx", "httpd", "traefik", "envoy": return .infra(inv.exe, global: false)
        case "mailpit", "mailhog", "MailHog": return .infra("Mailpit", global: false)
        case "docker-compose": return .infra("docker compose", global: false)
        case "docker": return inv.contains("compose") || inv.subcommand == "run" ? .infra("docker \(inv.subcommand ?? "")", global: false) : nil
        default: break
        }
        if inv.exe.hasPrefix("qemu-system") { return .infra("QEMU", global: true) }
        if inv.exe == "ssh" {
            let joined = inv.args.joined(separator: " ")
            if joined.contains("/.colima/") { return .infra("Colima", global: true) }
            if joined.contains("/.lima/") { return .infra("Lima", global: true) }
        }
        if inv.exe == "java" {
            let joined = inv.args.joined(separator: " ")
            if joined.contains("kafka.Kafka") { return .infra("Kafka", global: false) }
            if joined.contains("org.apache.zookeeper") { return .infra("ZooKeeper", global: false) }
            if joined.contains("org.elasticsearch") { return .infra("Elasticsearch", global: false) }
            if joined.contains("org.opensearch") { return .infra("OpenSearch", global: false) }
        }
        return nil
    }

    // MARK: Dev servers, builds and wrappers

    static func toolRole(_ inv: Invocation) -> Role? {
        let sub = inv.subcommand
        let watching = inv.has("--watch", "-w", "--watchAll")

        if inv.args.first?.hasPrefix("next-server") == true { return .stack("next dev") }
        if inv.args.first?.hasPrefix("PM2 ") == true { return .processManager("PM2") }
        if inv.toolPath.contains("nx/src/daemon") { return .build("Nx daemon") }

        switch inv.tool {
        // Package managers and runners: whatever they run decides.
        case "npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "corepack", "bunx", "uv", "uvx", "pipx", "poetry", "pdm", "rye",
             "hatch", "mise", "asdf", "direnv", "env", "nohup", "caffeinate", "time", "nice", "timeout", "gtimeout", "script",
             "dotenv", "dotenvx", "cross-env", "nodemon", "op", "doppler", "infisical", "aws-vault", "make", "gmake", "just",
             "task", "watchexec", "reflex", "entr", "with-contenv", "sudo", "xargs", "nx":
            return .wrapper(hint: inv.hint)
        case "concurrently", "npm-run-all", "run-p", "run-s", "process-compose", "overmind", "hivemind", "foreman", "honcho",
             "supervisord", "mprocs", "devenv", "tilt", "pm2", "wireit":
            return .processManager(inv.tool)
        case "turbo":
            if sub == "daemon" { return .build("turbo daemon") }
            return .processManager("turbo")
        case "bun":
            if inv.has("--hot", "--watch") { return .stack(inv.label("bun --hot")) }
            if sub == "build" { return .build(watching ? "bun build --watch" : "bun build") }
            if sub == "test" { return .build(watching ? "bun test --watch" : "bun test") }
            return .wrapper(hint: inv.hint)
        case "deno":
            if sub == "serve" { return .stack(inv.label("deno serve")) }
            if sub == "lsp" { return .tool("deno lsp") }
            if sub == "test" { return .build("deno test") }
            if sub == "run", watching { return .stack(inv.label("deno run --watch")) }
            return .wrapper(hint: inv.hint)

        // Dev servers.
        case "vite":
            switch sub {
            case "build": return .build(watching ? "vite build --watch" : "vite build")
            case "optimize": return .build("vite optimize")
            case "preview": return .stack(inv.label("vite preview"))
            default: return .stack(inv.label("vite"))
            }
        case "astro":
            switch sub {
            case "dev", "preview", nil: return .stack(inv.label("astro \(sub ?? "dev")"))
            default: return .build("astro \(sub!)")
            }
        case "next":
            switch sub {
            case "build", "lint", "export": return .build("next \(sub!)")
            default: return .stack(inv.label("next \(sub ?? "dev")"))
            }
        case "nuxt", "nuxi":
            return sub == "build" || sub == "generate" ? .build("nuxt \(sub!)") : .stack(inv.label("nuxt dev"))
        case "wrangler":
            switch sub {
            case "dev", "pages": return .stack(inv.label("wrangler dev"))
            case "tail": return .helper("wrangler tail")
            default: return .build("wrangler \(sub ?? "")".trimmingCharacters(in: .whitespaces))
            }
        case "workerd": return .stack(inv.label("workerd"))
        case "miniflare": return .stack(inv.label("miniflare"))
        case "@remix-run/dev", "remix": return sub == "build" ? .build("remix build") : .stack(inv.label("remix dev"))
        case "@react-router/dev", "react-router": return sub == "build" ? .build("react-router build") : .stack(inv.label("react-router dev"))
        case "storybook", "start-storybook", "@storybook/cli":
            return sub == "build" ? .build("storybook build") : .stack(inv.label("storybook"))
        case "expo", "@expo/cli": return .stack(inv.label("expo"))
        case "react-native", "metro": return sub == "start" || inv.tool == "metro" ? .stack(inv.label("metro")) : .build("react-native \(sub ?? "")")
        case "ng", "@angular/cli": return sub == "serve" || sub == "s" ? .stack(inv.label("ng serve")) : .build("ng \(sub ?? "build")")
        case "vue-cli-service": return sub == "serve" ? .stack(inv.label("vue serve")) : .build("vue build")
        case "gatsby": return sub == "develop" ? .stack(inv.label("gatsby develop")) : .build("gatsby \(sub ?? "build")")
        case "@11ty/eleventy", "eleventy": return inv.has("--serve") ? .stack(inv.label("eleventy")) : .build("eleventy")
        case "hugo": return sub == "server" || sub == "serve" ? .stack(inv.label("hugo server")) : .build("hugo")
        case "jekyll": return sub == "serve" || sub == "s" ? .stack(inv.label("jekyll serve")) : .build("jekyll build")
        case "docusaurus", "@docusaurus/core": return sub == "start" ? .stack(inv.label("docusaurus")) : .build("docusaurus build")
        case "@rspack/cli", "rspack", "@rsbuild/core", "rsbuild":
            return sub == "build" ? .build("\(Paths.name(inv.tool)) build") : .stack(inv.label(Paths.name(inv.tool)))
        case "parcel": return sub == "build" ? .build("parcel build") : (sub == "watch" ? .build("parcel watch") : .stack(inv.label("parcel")))
        case "webpack", "webpack-cli":
            if sub == "serve" { return .stack(inv.label("webpack serve")) }
            return .build(watching ? "webpack --watch" : "webpack")
        case "webpack-dev-server": return .stack(inv.label("webpack-dev-server"))
        case "http-server", "serve", "live-server", "json-server", "browser-sync", "lite-server", "sirv-cli", "local-web-server":
            return .stack(inv.label(inv.tool))
        case "tsx": return sub == "watch" ? .stack(inv.label("tsx watch")) : .runtime("tsx")
        case "ts-node-dev", "ts-node": return .runtime(inv.tool)
        case "air": return .stack(inv.label("air"))
        case "trunk": return sub == "serve" ? .stack(inv.label("trunk serve")) : .build("trunk build")

        // Builds and watchers.
        case "tsc": return .build(watching ? "tsc --watch" : "tsc")
        case "tsserver", "typingsInstaller": return .tool("tsserver")
        case "esbuild":
            if inv.has("--service") { return .helper("esbuild") }
            return .build(watching ? "esbuild --watch" : "esbuild")
        case "tsup", "tsdown", "unbuild", "rollup", "rolldown", "babel", "@babel/cli", "swc", "@swc/cli", "sass", "tailwindcss",
             "@tailwindcss/cli", "postcss", "postcss-cli", "microbundle", "pkgroll":
            let name = Paths.name(inv.tool)
            return .build(watching ? "\(name) --watch" : name)
        case "vitest":
            return .build(sub == "run" || inv.has("--run") ? "vitest" : "vitest watch")
        case "jest", "jest-cli":
            return .build(watching ? "jest --watch" : "jest")
        case "playwright", "@playwright/test":
            return sub == "test" ? .build("playwright test") : .helper("playwright")
        case "cargo":
            switch sub {
            case "watch": return .build("cargo watch")
            case "run": return .wrapper(hint: .stacks)
            default: return .build("cargo \(sub ?? "build")")
            }
        case "go":
            if sub == "run" { return .wrapper(hint: .stacks) }
            return .build("go \(sub ?? "build")")
        case "bazel", "bazelisk": return .build("bazel \(sub ?? "")".trimmingCharacters(in: .whitespaces))
        case "ninja", "cmake", "xcodebuild", "swift-build", "gradle", "gradlew", "mvn", "sbt", "zig", "buck2", "pants":
            return .build(inv.tool)
        case "rustc", "clang", "clang++", "swift-frontend", "swiftc", "cc1", "ld", "ld64":
            return .build("compile")

        // Python, Ruby, PHP and Java servers.
        case "http.server": return .stack(inv.label("http.server" + (inv.rest.first(where: { Int($0) != nil }).map { " :\($0)" } ?? "")))
        case "uvicorn", "gunicorn", "hypercorn", "daphne", "granian", "waitress-serve": return .stack(inv.label(inv.tool))
        case "flask": return sub == "run" ? .stack(inv.label("flask run")) : .runtime("flask")
        case "fastapi": return .stack(inv.label("fastapi \(sub ?? "dev")"))
        case "manage": return sub == "runserver" ? .stack(inv.label("django runserver")) : .runtime("manage.py")
        case "streamlit": return .stack(inv.label("streamlit"))
        case "jupyter", "jupyter-lab", "jupyter-notebook", "jupyterlab": return .stack("Jupyter")
        case "mkdocs": return sub == "serve" ? .stack(inv.label("mkdocs serve")) : .build("mkdocs build")
        case "pytest", "py.test": return .build("pytest")
        case "mypy", "dmypy": return .build(inv.tool)
        case "rails": return sub == "server" || sub == "s" ? .stack(inv.label("rails server")) : .runtime("rails")
        case "puma", "unicorn", "thin", "falcon": return .stack(inv.label(inv.tool))
        case "sidekiq": return .infra("Sidekiq", global: false)
        case "artisan": return sub == "serve" ? .stack(inv.label("artisan serve")) : .runtime("artisan")
        default: break
        }

        if inv.exe == "php", inv.args.contains("-S") { return .stack("php -S") }
        if inv.exe == "beam.smp", inv.args.contains(where: { $0.contains("phx.server") }) { return .stack("phoenix") }
        if inv.exe == "java" {
            let joined = inv.args.joined(separator: " ")
            if joined.contains("GradleDaemon") { return .build("Gradle daemon") }
            if joined.contains("KotlinCompileDaemon") { return .build("Kotlin daemon") }
            if joined.contains("A-server.jar") || joined.contains("bazel") { return .build("Bazel server") }
        }

        if let editor = editorName(inv.exe) { return .tool(editor) }
        if isLanguageServer(inv.tool) { return .tool(Paths.name(inv.tool)) }
        if inv.tool.hasPrefix("@modelcontextprotocol/") || inv.tool.lowercased().contains("mcp") {
            let short = Paths.name(inv.tool).replacingOccurrences(of: "server-", with: "")
            return .helper("MCP \(short)")
        }
        return nil
    }

    static func editorName(_ exe: String) -> String? {
        switch exe {
        case "nvim": "Neovim"
        case "vim", "vi": "Vim"
        case "hx", "helix": "Helix"
        case "emacs", "emacs-nox": "Emacs"
        case "kak": "Kakoune"
        case "micro": "micro"
        case "nano": "nano"
        default: nil
        }
    }

    static func isLanguageServer(_ tool: String) -> Bool {
        let name = Paths.name(tool)
        let known: Set<String> = [
            "gopls", "rust-analyzer", "clangd", "sourcekit-lsp", "vtsls", "pyright", "pyright-langserver", "basedpyright",
            "pylsp", "zls", "marksman", "taplo", "terraform-ls", "solargraph", "ruby-lsp", "jdtls", "elixir-ls", "lexical",
            "nextls", "eslint_d", "prettierd", "@vtsls/language-server", "copilot-language-server",
        ]
        return known.contains(name) || known.contains(tool) || name.contains("language-server") || name.contains("langserver")
            || name.hasSuffix("-lsp") || name.hasSuffix("-ls")
    }
}
