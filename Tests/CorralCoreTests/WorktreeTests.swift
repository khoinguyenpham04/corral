@testable import CorralCore
import Foundation
import Testing

/// Builds throwaway repos on disk: a main checkout, a linked worktree, a submodule, a plain project.
/// Repos use "dot-git" instead of ".git" because some sandboxes refuse writes to any .git path.
final class Sandbox {
    static let dotGit = "dot-git"

    let root: String

    init() throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        root = Paths.normalize((base as NSString).appendingPathComponent("corral-tests-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func directory(_ path: String) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    func file(_ path: String, _ contents: String) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: Paths.parent(full), withIntermediateDirectories: true)
        try contents.write(toFile: full, atomically: false, encoding: .utf8)
    }

    /// A main checkout at `name` on `branch`, plus linked worktrees.
    @discardableResult
    func repo(_ name: String, branch: String = "main", worktrees: [(path: String, branch: String)] = []) throws -> String {
        let main = try directory(name)
        let git = Sandbox.dotGit
        try file("\(name)/\(git)/HEAD", "ref: refs/heads/\(branch)\n")
        for worktree in worktrees {
            let id = Paths.name(worktree.path)
            try file("\(name)/\(git)/worktrees/\(id)/HEAD", "ref: refs/heads/\(worktree.branch)\n")
            try file("\(name)/\(git)/worktrees/\(id)/commondir", "../..\n")
            try file("\(name)/\(git)/worktrees/\(id)/gitdir", "\(root)/\(worktree.path)/\(git)\n")
            try file("\(worktree.path)/\(git)", "gitdir: \(main)/\(git)/worktrees/\(id)\n")
        }
        return main
    }
}

struct WorktreeTests {
    @Test func mainAndLinkedWorktrees() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("meadow", worktrees: [("meadow/.claude/worktrees/table-color-ui-design-99dc44", "noah/table-color")])
        try sandbox.file("meadow/packages/core/src/index.ts", "")
        let resolver = WorktreeResolver(home: "/nonexistent-home", dotGit: Sandbox.dotGit)

        let inMain = try #require(resolver.worktree(containing: main + "/packages/core/src"))
        #expect(inMain.root == main)
        #expect(inMain.kind == .main)
        #expect(inMain.branch == "main")
        #expect(inMain.displayName == "meadow")

        let linked = try #require(resolver.worktree(containing: main + "/.claude/worktrees/table-color-ui-design-99dc44/src"))
        #expect(linked.kind == .worktree)
        #expect(linked.repoRoot == main)
        #expect(linked.repoName == "meadow")
        #expect(linked.branch == "noah/table-color")
        #expect(linked.manager == "Claude")
        #expect(linked.displayName == "table-color")
    }

    @Test func codexStyleWorktreeUsesTheSlug() throws {
        let sandbox = try Sandbox()
        try sandbox.repo("src/meadow", worktrees: [("codex/worktrees/editor-link-exit/meadow", "codex/editor-link-exit")])
        let info = try #require(WorktreeResolver(home: "/nonexistent-home", dotGit: Sandbox.dotGit).worktree(containing: sandbox.root + "/codex/worktrees/editor-link-exit/meadow"))
        #expect(info.displayName == "editor-link-exit")
    }

    @Test func submodulesBelongToTheSuperproject() throws {
        let sandbox = try Sandbox()
        let main = try sandbox.repo("app")
        try sandbox.file("app/vendor/lib/\(Sandbox.dotGit)", "gitdir: ../../\(Sandbox.dotGit)/modules/lib\n")
        let info = try #require(WorktreeResolver(home: "/nonexistent-home", dotGit: Sandbox.dotGit).worktree(containing: main + "/vendor/lib/src"))
        #expect(info.root == main)
    }

    @Test func projectsOutsideGit() throws {
        let sandbox = try Sandbox()
        try sandbox.file("scratch/meadow-1.2/package.json", "{}")
        try sandbox.file("scratch/meadow-1.2/node_modules/astro/package.json", "{}")
        let resolver = WorktreeResolver(home: "/nonexistent-home", dotGit: Sandbox.dotGit)
        #expect(resolver.worktree(containing: sandbox.root + "/scratch/meadow-1.2") == nil)
        let project = try #require(resolver.project(containing: sandbox.root + "/scratch/meadow-1.2/node_modules/astro/dist"))
        #expect(project.root == sandbox.root + "/scratch/meadow-1.2")
        #expect(project.kind == .project)
    }

    @Test func homeFolderRepoIsIgnored() throws {
        let sandbox = try Sandbox()
        try sandbox.repo("home")
        _ = try sandbox.directory("home/Documents/notes")
        let resolver = WorktreeResolver(home: sandbox.root + "/home", dotGit: Sandbox.dotGit)
        #expect(resolver.worktree(containing: sandbox.root + "/home/Documents/notes") == nil)
    }

    @Test func generatedNames() {
        #expect(WorktreeInfo.trimGeneratedSuffix("table-color-ui-design-99dc44") == "table-color-ui-design")
        #expect(WorktreeInfo.trimGeneratedSuffix("agent-ready") == "agent-ready")
        #expect(WorktreeInfo.trimGeneratedSuffix("feature-cafe") == "feature-cafe")
        let t3 = WorktreeInfo(root: "/Users/me/.t3/worktrees/meadow/t3code-9503f4f7", gitDir: nil, repoRoot: "/r/meadow", kind: .worktree, branch: "noah/calendar-notion-polish")
        #expect(t3.displayName == "calendar-notion-polish")
        #expect(t3.manager == "T3 Code")
    }
}
