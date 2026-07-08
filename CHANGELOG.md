# Changelog

## Unreleased

- Cmd+W (close tab) and Shift+Cmd+W (close pane) now ask for confirmation before killing sessions, calling out any agents still working there. On by default; disable in Preferences > General or with `confirm_close = false` under `[behavior]`.

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
