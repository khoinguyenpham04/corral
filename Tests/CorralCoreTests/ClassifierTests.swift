@testable import CorralCore
import Testing

/// Command lines taken from real machines (paths shortened).
struct ClassifierTests {
    func role(_ path: String, _ args: [String]) -> Role {
        Classifier.classify(ProcessRecord(pid: 10, ppid: 1, path: path, args: args))
    }

    let node = "/opt/homebrew/Cellar/node/26.3.1/bin/node"

    @Test func devServersUnwrapNode() {
        #expect(role(node, ["node", "./node_modules/.bin/../astro/bin/astro.mjs", "dev", "--port", "4461"]) == .stack("astro dev :4461"))
        #expect(role(node, ["node", "/w/node_modules/.pnpm/astro@7.3.2_x/node_modules/astro/bin/astro.mjs", "dev"]) == .stack("astro dev"))
        #expect(role(node, ["node", "/w/node_modules/vite/bin/vite.js", "--port", "5173"]) == .stack("vite :5173"))
        #expect(role(node, ["node", "/opt/homebrew/lib/node_modules/wrangler/bin/wrangler.js", "dev"]) == .stack("wrangler dev"))
        #expect(role(node, ["next-server (v15.1.0)"]) == .stack("next dev"))
        let workerd = "/w/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd"
        #expect(role(workerd, [workerd, "serve", "--binary", "--experimental"]) == .stack("workerd"))
    }

    @Test func buildsAndHelpers() {
        #expect(role(node, ["node", "/w/node_modules/typescript/bin/tsc", "--watch"]) == .build("tsc --watch"))
        #expect(role(node, ["node", "/w/node_modules/typescript/lib/tsserver.js"]) == .tool("tsserver"))
        let esbuild = "/w/node_modules/@esbuild/darwin-arm64/bin/esbuild"
        #expect(role(esbuild, [esbuild, "--service=0.28.1", "--ping"]) == .helper("esbuild"))
        #expect(role(node, ["node", "/w/node_modules/vitest/vitest.mjs"]) == .build("vitest watch"))
        #expect(role(node, ["node", "/w/node_modules/vitest/vitest.mjs", "run"]) == .build("vitest"))
    }

    @Test func wrappersCarryHints() {
        #expect(role(node, ["node", "/opt/homebrew/bin/pnpm", "--dir", "demos/simple", "exec", "astro", "dev", "--port", "4391"]) == .wrapper(hint: .stacks))
        #expect(role("/bin/zsh", ["/bin/zsh", "-c", "pnpm dev"]) == .wrapper(hint: .stacks))
        #expect(role("/Applications/Claude.app/Contents/Helpers/disclaimer", ["disclaimer", "--pgroup", "--", "claude"]) == .wrapper(hint: nil))
    }

    @Test func agents() {
        let desktop = "/Users/me/Library/Application Support/Claude-3p/claude-code/2.1.295/9d64/claude.app/Contents/MacOS/claude"
        #expect(role(desktop, [desktop, "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]) == .agent(.claude, .hosted))
        #expect(role("/Users/me/.local/share/claude/versions/2.1.300", ["claude"]) == .agent(.claude, .interactive))
        #expect(role("/Users/me/.local/share/claude/versions/2.1.300", ["claude", "-p", "hi"]) == .agent(.claude, .oneShot))
        #expect(role("/Users/me/.local/share/claude/versions/2.1.300", ["claude", "mcp", "serve"]) == .helper("claude mcp"))

        let desktopCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        #expect(role(desktopCodex, [desktopCodex, "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"]) == .agent(.codex, .server))
        let codex = "/opt/homebrew/Caskroom/codex/0.162.1/bin/codex"
        #expect(role(codex, ["codex"]) == .agent(.codex, .interactive))
        #expect(role(codex, ["codex", "resume", "01a13fe2-64f6-7211-8ff1-07e780baa4ce"]) == .agent(.codex, .interactive))
        #expect(role(codex, ["codex", "exec", "fix the tests"]) == .agent(.codex, .oneShot))

        let opencode = "/opt/homebrew/Cellar/opencode/1.18.29/bin/opencode"
        #expect(role(opencode, ["opencode"]) == .agent(.opencode, .interactive))
        #expect(role(opencode, ["opencode", "serve", "--port", "4096"]) == .agent(.opencode, .server))
        #expect(role(node, ["node", "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"]) == .agent(.pi, .interactive))
        #expect(role(node, ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"]) == .agent(.gemini, .interactive))
        #expect(role("/Users/me/.local/share/devin/cli/_versions/current/bin/devin", ["devin"]) == .agent(.devin, .interactive))
    }

    @Test func infrastructure() {
        let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(role(vm, [vm]) == .infra("Linux VM", global: true))
        #expect(role("/opt/homebrew/bin/limactl", ["limactl", "hostagent"]) == .infra("Lima", global: true))
        #expect(role("/opt/homebrew/bin/watchman", ["watchman", "--foreground"]) == .infra("Watchman", global: true))
        #expect(role("/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/x"]) == .infra("Postgres", global: false))
    }

    @Test func pythonFromCommandLineToolsIsNotAnApp() {
        let python = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        #expect(role(python, [python, "-m", "http.server", "4471"]) == .stack("http.server :4471"))
    }

    @Test func boundariesAndApps() {
        #expect(role("/bin/zsh", ["-zsh"]) == .shell)
        #expect(role("/bin/zsh", ["/bin/zsh", "-l"]) == .shell)
        #expect(role("/opt/homebrew/bin/tmux", ["tmux"]) == .multiplexer)
        #expect(role("/Applications/Claude.app/Contents/MacOS/Claude", ["Claude"]) == .app)
        #expect(role("/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)", ["T3 Code (Alpha)"]) == .app)
        #expect(role(node, ["node", "/tmp/claude-501/harness/mock.mjs", "18787"]) == .runtime("mock"))
    }

    @Test func scriptNames() {
        #expect(Invocation.toolName(fromScript: "./node_modules/.bin/../astro/bin/astro.mjs") == "astro")
        #expect(Invocation.toolName(fromScript: "/w/node_modules/.bin/vite") == "vite")
        #expect(Invocation.toolName(fromScript: "/w/node_modules/@scope/pkg/dist/cli.js") == "@scope/pkg")
        #expect(Invocation.toolName(fromScript: "/Users/me/.local/share/model-router/router.mjs") == "router")
        #expect(Invocation.toolName(fromScript: "/Users/me/tools/thing/dist/index.js") == "thing")
        #expect(Invocation.toolName(fromScript: "/opt/homebrew/lib/node_modules/npm/bin/npx-cli.js") == "npx")
    }
}
