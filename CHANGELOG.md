# Changelog

## 0.4.0

A redrawn panel, with ports. And Corral is now free and open source.

- **Open source, on GitHub,** under the MIT license. Updates and the Terminal install come from GitHub releases and need no sign-in. Corral has a new app identifier, so its settings start over once; hibernated sessions and the activity log carry over.
- **Ports.** Every dev server shows the port it listens on, read from macOS the way `lsof` finds it rather than guessed from its command line. Click one to open it in your browser. Anything else in a worktree that listens on a port of its own counts as a server.
- **One bar, a piece per worktree.** The bar still splits memory by kind, and inside each colour every worktree has its own piece. Hover a row and its pieces light up; hover a piece to see whose it is. Each row has the same split as a rail beside its name, and one line saying what runs in it.
- **What's inside, fenced in.** Click a row and its servers, builds and agents open under it, along a dashed line like the ring around Corral's icon, with their buttons on hover.
- **Memory and Disk**, one switch apart at the top: Disk lists idle worktrees. ⌘1 and ⌘2 switch too. The switch takes the pressure pill's place; when macOS says memory is tight, the panel says so beside the figure.
- **The footer frees memory.** Stop the leaked servers, in two clicks, and hibernate idle agents, each saying how much it frees. What just happened shows in the footer, with Undo. Right-click Stop, or a leaked worktree, to keep a server running.
- **Moving idle worktrees to the Trash takes two clicks in the footer** instead of a dialog. Undo still puts them back.
- Shared services, hibernated sessions, other apps and Activity take a line each under the worktrees.
- **Smoother.** Rows, tabs, new samples and the panel's height move on one spring, numbers roll to their new values, and Reduce Motion turns it all into short fades.
- Opening a port, Finder or Terminal from the panel closes it.
- **Open in Terminal uses the terminal you last used**, as does Wake when it opens a new window, instead of iTerm whenever it's installed.

## 0.3.1

Quicker to measure.

- **Idle worktrees are measured with about a third of the work**, still at low priority. pnpm's and bun's packages are nearly all of a worktree's files and, cloned from their store, free almost nothing, so Corral walks a sample of them and leaves the rest out when they're shared. Packages that build files of their own when installed, like electron or native addons, and packages that were copied are still measured in full. Totals change by about 1%, on the low side.
- git's checks run at low priority too, instead of at normal priority, and take a third of the time: Corral hears the moment each one finishes instead of checking every 50 ms.

## 0.3.0

Disk space, by idle worktree.

- **Idle worktrees.** A new row lists every linked worktree with nothing running in it, biggest first, by the space removing it frees once the Trash is emptied. Packages that pnpm and bun share from their store barely count, so the numbers are often a quarter of what Finder shows, and if anything on the low side. Corral finds worktrees through their repositories and in Codex's, T3 Code's, Conductor's and Cursor's folders, and measures them in the background at low priority, never in Low Power Mode.
- **Move to Trash, without losing committed work.** A worktree can go only when git says everything in it is committed and nothing is running in it. Commits on no branch (even ones only HEAD's log remembers), a hibernated session, a lock, a rebase in progress or another checkout inside keep it where it is, and its row says why. Corral asks git again right before moving anything and never deletes a branch. Files git ignores, like `.env`, go with the folder. While it's in the Trash, git's record of the worktree is kept and locked, and its branch is free to check out elsewhere; Undo, or Put Back in Finder, brings it back where it was, on its branch when that's still free. Moving several at once asks first.
- **Disk almost full?** The panel says so when free space runs low and idle worktrees could help.
- `corral disk` lists idle worktrees and what each would free.
- Read-only mode covers worktrees too: nothing moves.

## 0.2.4

- **Install in the panel finishes the job.** In 0.2.3 and earlier, it put the new version in place but left the old one running, stuck on "Installing…". Updating from those versions, quit Corral once Install has run (right-click its icon → Quit Corral) and open it again. From 0.2.4 on, Corral restarts itself.

## 0.2.3

Smoother and sturdier.

- **Smoother panel.** Rows open and close on the same spring as the panel around them, and their details fade out before the rows below move up. Rows near the bottom scroll into view, toasts rise into place, and the panel fades when it closes.
- **Hibernate checks again right before stopping.** An agent that started working in the last few seconds is left running. Rows say "Hibernating…" or "Stopping…" until they're done, so a second click can't act twice.
- **Stop Everything Here** sums up in one toast and keeps its Undo. Servers stop side by side, so one that's slow to quit doesn't hold up the rest.
- **More Undo.** Removing a hibernated session from the list can be undone, ⌘Z undoes the last action, and a partial hibernate keeps Undo for the agents that stopped.
- **Wake keeps a session in the list if it couldn't resume it**, so you can try again. Waking into kitty or WezTerm works when they're already open.
- **Updates.** Check for Updates says it's checking straight away, and shows an update you put off with Later. If an update fails after Corral quits, the old version reopens.
- Fixes: auto-hibernate stops retrying an agent that won't stop; the activity log no longer rewrites itself on every entry once full.

## 0.2.2

Easier to trust.

- **Checked installs and updates.** Each release publishes its SHA-256 fingerprint. The Terminal install and Corral's own updates refuse a download that doesn't match, check the app's signature and version, and keep your current Corral until the new one is in place.
- **Uninstall** in Settings moves Corral to the Trash and removes its settings, data, `corral` command and login item.
- **Send Feedback…** in the ⋯ menu and the menu bar menu opens an issue with your versions filled in.
- When an update can't install, the panel says why.
- The installer window shows its background, with light labels and the first-open note in view.

## 0.2.1

An easier install.

- **Install from Terminal, with no warning.** One command installs Corral. macOS doesn't stop it on first open, because no browser downloaded it.
- **Updates install themselves.** When a new version is out, click **Install** in the panel (or run `corral update`): Corral downloads it, replaces itself and reopens.
- **A proper installer window.** The disk image opens to Corral, an arrow and Applications, with a note for macOS's first-open check.

## 0.2.0

Safer and clearer to use.

- **Stop takes two clicks.** The first turns ✕ into a coral Stop; the second stops. Hibernate stays one click, with Undo.
- **Leaked servers card.** Dev servers that outlived their terminal or agent are listed at the top, with Stop all and Keep. Click the card to see each one.
- **Corral leaves alone what other tools own:** container VMs and sessions an app manages, such as Codex Desktop. Their rows say how to stop them, for example `colima stop`.
- **Agents in the middle of a task are never hibernated**, from the panel or the CLI (`--force` overrides in the CLI).
- **Activity log.** Every stop, hibernate and wake, with the processes involved: **Activity** in the panel, or `corral log`.
- **Read-only mode** in Settings → Safety, which IT can also turn on with a configuration profile.
- **Hibernate saves the way back before it stops anything**, so a crash part way through never loses a session.
- **A proper download.** Releases are a `.dmg`: open it and drag Corral onto Applications.
- **Update notices.** Once a day Corral checks whether a newer version is out, and says so in the panel. **Check for Updates** is in the ⋯ menu.
- **Set up from the welcome card:** one click each for opening at login and adding the `corral` command.
- A welcome card on first open. Toasts name what changed, and results arrive as notifications when the panel is closed. The menu bar menu lists the agents Hibernate will stop.
- Fixes: background daemons such as git-ai's aren't flagged as leaked; renamed app helpers (Raycast's backend) count as their app; the Colima VM is one row.

## 0.1.0

First release: memory by worktree, agent titles and idle times, Hibernate and Wake, pressure alerts, auto-hibernate, the `corral` CLI and the ⌃⌥⌘M shortcut.
