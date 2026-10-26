# Developing Corral

## Build and run

The Xcode Command Line Tools are enough; Xcode itself isn't needed.

```bash
scripts/build.sh --release --app && cp -R build/release/Corral.app /Applications/
```

```bash
scripts/build.sh --test
```

```bash
scripts/build.sh --previews
```

```bash
build/debug/Corral.app/Contents/MacOS/Corral --demo
```

`--test` runs the test suite. `--previews` renders the panel, the README's hero image and the app icon to `build/previews` without launching the app. `--demo` runs the app with sample data, for screenshots.

`swift build` and `swift test` work too. The build script exists for machines without Xcode and for sandboxed shells.

- `Sources/CorralCore`: sampling, classification, grouping, sessions, hibernation, worktree disk use, the activity log, update checks. No UI.
- `Sources/CorralUI`: the Ink + ember design system and the panel (SwiftUI).
- `Sources/Corral`: the menu bar app (status item, panel window, notifications, hotkey, settings).
- `Sources/CorralCLI`: `corral`.

## How it works

Corral reads the process table with `sysctl` and `libproc`, the same calls Activity Monitor uses, and its **Memory** column matches Activity Monitor's (physical footprint). It needs no special permissions.

- **Grouping.** Each process tree under a shell, an app or launchd becomes one group, such as an agent session or `astro dev :4461`. Dev servers an agent starts get their own group.
- **Checkouts.** Groups belong to the git worktree of their working directory. Corral reads `.git` files directly and runs no `git` commands for this. It recognises worktrees made by Claude, Codex, T3 Code, Conductor and Cursor.
- **Leaked processes.** A dev server whose parent has exited, and which launchd isn't running on purpose, is marked leaked. Daemons started on purpose (`turbo daemon`, `--daemon`) and tools working from a hidden folder in your home (`~/.git-ai`) aren't.
- **Edit times.** "Edited 7 min ago" comes from FSEvents, ignoring `node_modules`, build output and dot-folders.
- **Hibernate.** Saves how to resume, then sends SIGTERM to an idle agent's process group, and SIGKILL after 3 seconds if it's still running. Every PID is re-checked against its start time first. Agents that are working are never stopped. Records live in `~/Library/Application Support/Corral/hibernated.json`, shared with the CLI.
- **Stop.** The same signals, for servers and builds. `StopPolicy` decides what may be stopped, and the app and the CLI both follow it. Each action is appended to `activity.jsonl` in the same folder, with command lines masked for secrets.
- **Updates.** Once a day, `git ls-remote --tags` against the repository, with prompts turned off so git never asks for anything. It never runs `/usr/bin/git`, which offers to install the developer tools on Macs without them.
- **Battery.** Samples every 2 s while the panel is open and every 10 s otherwise.

## Harnesses

| Harness | Detected | Title and idle time from | Hibernate and Wake |
| --- | --- | --- | --- |
| Claude Code (terminal) | `claude` | `~/.claude/sessions/<pid>.json` | `claude --resume <id>` in the original iTerm/Terminal tab, or a new window |
| Claude Desktop | its CLI sessions | same registry | stops the session's CLI; it resumes, with its history, on your next message |
| Codex | `codex` | open rollout file plus `state_*.sqlite` | `codex resume <id>` |
| Codex Desktop (ChatGPT.app) | `codex app-server` | same | shown, not stopped (one server for every thread) |
| OpenCode | `opencode` | `opencode.db` | `opencode --session <id>` |
| Pi / oh-my-pi | `pi`, `omp` | `~/.pi/agent/sessions` | `pi --session <id>` |
| Devin, Gemini, Cursor Agent, Amp, Copilot, Goose, Aider, Crush | by executable | CPU activity | Devin: `devin --continue`; others shown and stoppable |
| VS Code / Cursor / Devin Desktop / T3 Code | their agent processes | as above | the app restores its own sessions |

Teaching Corral a new harness takes an entry in `Classifier.agentRole`, plus a session reader in `Sources/CorralCore/Sessions` if the harness keeps titles on disk.

## Release

1. Bump `VERSION` and add a `## <version>` section to `CHANGELOG.md`. Commit and push.
2. Run `scripts/release.sh`. It needs `gh`, signed in. It runs the tests, builds a universal (Apple Silicon + Intel) `.dmg`, and publishes a GitHub release with it and its SHA-256 attached and the changelog as its notes. `scripts/install.sh` downloads both from there and refuses a download whose fingerprint doesn't match. `--dry-run` builds without publishing.

The README's Download link always points at the newest release, and running copies of Corral notice it within a day.

Builds are ad-hoc signed. To sign with a Developer ID instead, set `CORRAL_SIGN_IDENTITY="Developer ID Application: …"` before releasing.

## Managing Corral on many Macs

A configuration profile can set these keys in the `io.github.khoinguyenpham04.corral` domain. Anything a profile sets can't be changed in Settings.

- `readOnly` (Boolean): show memory, never stop or hibernate anything.
- `checkForUpdates` (Boolean): the daily update check.
- `autoHibernate` (Boolean) and `autoHibernateHours` (Integer).
