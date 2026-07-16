# Changelog

## Unreleased

- **Claude/Codex permission parity**: the shared approval selector now maps the same four intents onto both agents. Codex Ask now deliberately starts stricter than before—read-only, so writes and other boundary crossings require approval instead of inheriting a potentially permissive global Codex default. Auto uses workspace-write, safety-reviewed Auto uses Codex's `auto_review` reviewer, and Full Access uses danger-full-access with no prompts. Preference changes apply to the next agent launched in an already-open pane, while the UI now identifies path-specific diff-desk rules as Claude/Pi-only.

## 0.3.0 (2026-07-13)

### New features

- **Close confirmation**: Cmd+W (close tab) and Shift+Cmd+W (close pane) now ask before killing sessions, calling out any agents still working there. On by default; disable in Preferences > General or with `confirm_close = false` under `[behavior]`. The built-in editor joins in: an unsaved buffer prompts Save / Cancel / Discard on every close path (pane or tab close, window close, quit) instead of being silently discarded.
- **Upgrades complete themselves**: whichever way you install, the agent integration keeps itself current. An installed app refreshes the `~/.local/bin` helper binaries on launch when they differ from the bundled copies (atomic swap, never creating absent ones), re-syncs the bundled `sidekick-panes` skill the same way, and brings existing hook entries up to the current contract when the hook vocabulary grows (Claude Code, Codex, and Pi). From source, `./install.sh` finishes by re-running `scripts/install-agent-status-hooks` (new `--refresh-only` and `--binaries-from DIR` flags) against the app it just installed, so there is no second build and no follow-up command. Nothing ever bootstraps an integration you didn't opt into, and hook dedup now keys on helper name plus arguments so the two install paths recognize each other's entries.
- **Versioned status handshake**: the `agent_status` report now carries a wire-protocol version. A pane whose hook speaks an older protocol than the app flags it once, in the pane and in the log, instead of failing silently; reports are always honored whatever version they declare.
- **Readable pane transcripts**: recent pane reads return a normalized transcript (escape chatter stripped, each spinner's carriage-return overwrite run collapsed to its final frame) instead of the raw redraw stream; a 20-line read of a spinning TUI dropped from 19.5KB to 1.2KB. Full reads are served from the interpreted screen, and the normalization work runs off the main thread.
- **Ghost text marked in pane reads**: autosuggest completions (Claude Code, fish/zsh) rendered at the cursor are wrapped in an explicit "suggested, not typed" marker in visible reads, so monitoring agents stop attributing suggestions to the user.
- **Live tab drag-reorder**: dragging a tab now works while agents are busy (the tab bar's refresh storm no longer snaps the dragged tab back), and the other tabs slide out of the way live to preview where everything lands on release.

### Fixes

- **Editor data-loss guards**: saves check the file's modification date so you can't silently overwrite an agent's concurrent edit, write through symlinks instead of replacing them with regular files, and keep the file's original encoding, asking before any fallback to UTF-8.
- **Agent status reaches the app from tty-less hooks**: Claude Code spawns hook processes detached from the terminal, so every status report died on `/dev/tty` and panes drifted on text heuristics that misread Claude's spinner as idle. The hook now falls back to the control socket with the same authority, fixing `wait agent-status` monitoring.
- **Symlinked directories expand in the file tree**: linked folders (pnpm `node_modules`, linked packages) rendered as unexpandable files; they now classify and enumerate through the resolved target. The expanded-folder icon also draws again ("folder.open" is not a real SF Symbol).
- **Search results say what actually happened**: outcomes are explicit (complete, capped at 1000, stopped at the 8s timeout, failed), a killed or failed search no longer renders partial or stale rows under a confident count.
- **Structural edits recolor the whole file**: the tree-sitter highlighter keeps the document's tree, reparses incrementally, and recolors whatever the edit restructured, so deleting a brace or opening a quote no longer leaves the rest of the file wearing the old parse's colors.
- Five small data-loss and staleness bugs: a corrupt `session.json` is preserved as `session.json.bak` instead of being overwritten by the next autosave; the shell-integration installer no longer treats an unreadable `~/.zshrc` as empty (and would have replaced it); stale terminal titles and a mispinned branch watcher from out-of-order cwd lookups; Search and Quick Open no longer deadlock a child process on an undrained stderr pipe; a ConfigWatcher fd close race.
- The log is bounded: one held handle, rotation to `Sidekick.log.1` at 5MB, and debug records gated behind `SIDEKICK_LOG_LEVEL`.
- Untrusted text is no longer taken at face value: a git filename containing " -> " no longer truncates in the git panel, and an SSH config alias must look like a host token before it is ever typed into a shell.
- CommandRecorder stops capturing alternate-screen output, so a full-screen TUI's redraw noise no longer fills the 256KB command record.

### Performance

- Tab-bar rebuilds no longer eat clicks: under an active agent, per-second title refreshes rebuilt every tab button and a rebuild landing mid-click silently swallowed the selection; buttons now update in place.
- The git panel stops refreshing on every prompt: cwd reports resolve through a memoized repo lookup instead of forking `git rev-parse` on the main thread and restarting the FSEvents watcher each time, and Stage/Unstage flips the row the moment git returns.
- File-tree rebuilds are off the main thread's back: scans that come back structurally identical to what's on screen are dropped (the common agent workload now costs nothing), re-expansion is batched, and first-time expansion of a large folder inserts only the new rows instead of rebuilding every descendant.

## 0.2.0 (2026-07-03)

### New features

- **Worktrees as workstreams**: a Worktrees sidebar panel with review-vs-main, git panel retargeting, and a one-click merge action. `pane split --worktree <branch>` creates or reuses a worktree for the pane, worktree lifecycle is scriptable over MCP (`sidekick_worktree_list` / `remove` / `prune`), and worktree tabs get a muted glyph in their titles.
- **Agent edit review queue**: agent file edits queue in a sidebar panel for review instead of interrupting with a blocking sheet, with worktree-scoped auto-approve so a trusted worker's edits inside its own worktree flow through.
- **Native notifications (opt-in)**: attention events can mirror to macOS notifications: agent needs input, agent finished, command failed out of view, long-running command finished. Everything is off by default; enable per event in Preferences or the `[notifications]` config section. Sidekick never notifies while frontmost, never steals focus, withdraws stale alerts, and names the failing command in the notification body.
- **Failed commands join the attention cycle**: a command exiting non-zero in a pane you aren't viewing lights a "Command failed" row in the Agents panel and joins the Shift-Cmd-J cycle; it clears when you visit the pane or its next command succeeds.
- **Command timeline**: a Commands panel built from shell-integration (OSC 133) records; every command's exit code, duration, and output per pane, also available as structured JSON via `pane read --json`.
- **Cost telemetry**: per-tab cost roll-up in the Agents dashboard with per-pane, per-model attribution, plus a JSONL session cost history on disk.
- **Fleet status in one call**: the `sidekick_agent_list` MCP verb and `sidekick-ctl agent-list` return every active agent pane's state, elapsed time, cost, and worktree at once.
- **Event waiting for orchestrators**: `sidekick_wait_event` over MCP and `sidekick-ctl wait event` block until the next agent-state, command, or diff event.
- **Codex parity**: scoped approvals and lifecycle hooks now work for Codex workers, not just Claude.
- **Delta pane reads**: `pane_read` supports cursor-based reads that return only output since the last read.

### Fixes

- `pane_split` and `new_tab` no longer hang (IPC file descriptors leaked into forked pane shells).
- Cost telemetry was inflated roughly 2.2x; now attributed accurately per pane and model.
- `pane run` no longer has its Enter swallowed by TUI apps; it is sent as a separate keystroke.
- Preferences window no longer clips tall content; every tab scrolls and the window is resizable.
- Dead panes: the close button works, and waits no longer outlive their pane.
- IPC hardening: pool exhaustion, fd reuse, SIGPIPE, and latched-state bugs.
- Agent-edit approval hardening and config-integrity protection.
- Keyboard chords match exactly instead of loosely.

### Internal

- Two full multi-agent code-review sweeps resolved: critical bugs, perf work off the scroll/render hot paths, dead-code removal, dependency pinning.
- Major refactors: agent-state machine extracted from the terminal controller, git plumbing consolidated behind GitService with a single FSEvents watcher, palette registry and preferences form builder extracted, eventing consolidated.
- Tests added for previously zero-coverage risky modules.

## 0.1.0 (2026-07-01)

Initial release.
