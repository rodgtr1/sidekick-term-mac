# Changelog

## Unreleased

- Cmd+W (close tab) and Shift+Cmd+W (close pane) now ask for confirmation before killing sessions, calling out any agents still working there. On by default; disable in Preferences > General or with `confirm_close = false` under `[behavior]`.
- Agent-status and MCP helpers installed in `~/.local/bin` are refreshed on launch when they differ from the copies the app ships, so an upgrade no longer leaves your Claude/Codex hooks running weeks-old binaries. Absent helpers are never created, and the swap is atomic. Running from source, `swift run` builds skip this; re-run `scripts/install-agent-status-hooks`.
- The `agent_status` socket report now carries a wire-protocol version. A pane whose hook reports over an older protocol than the app speaks flags it once, in the pane and in the log, instead of failing silently. Reports are always honored, whatever version they declare.
- Upgrading is now complete in one step, whichever way you install. From source, `./install.sh` refreshes the agent integration it finds (the `~/.local/bin` helpers, the `sidekick-panes` skill, and the hook entries) by re-running `scripts/install-agent-status-hooks` against the app bundle it just installed, so there is no second release build and no follow-up command to remember. Never opted in? It changes nothing and says how to. `scripts/install-agent-status-hooks` gained `--refresh-only` and `--binaries-from DIR` for this, and now dedups hook entries by helper name plus argument, so refreshing an app-installed integration adds no duplicates.
- Installing the .app is the other complete path: the app now bundles the `sidekick-panes` skill and re-syncs the installed copy on launch, the same way it already refreshes the helper binaries, so agents stop reading instructions from the version you installed months ago.
- Hook *entries* self-heal too. When the hook contract gains an event, an installed integration that predates it is brought up to date on launch (Claude Code, Codex, and Pi). It never bootstraps an integration: with no Sidekick hooks in a config, the file is not opened, and a current one is never rewritten. Preferences → Agents now also installs the `sidekick-panes` skill, so an app-only user gets the same integration the from-source script writes.

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
