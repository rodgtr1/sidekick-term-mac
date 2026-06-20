---
name: sidekick-panes
description: Control Sidekick terminal panes and orchestrate visible worker agents. Use when running inside Sidekick and asked to split work into panes, launch separate Claude/Codex processes, run servers or tests beside the current agent, inspect pane output, or wait for another pane or agent to finish.
---

# Sidekick Panes

Use `sidekick-ctl` to control the running Sidekick instance. Each terminal pane is a real PTY process; workers launched here are separate CLI processes, not internal subagents.

## Preconditions

Check both conditions before controlling panes:

```sh
test "$SIDEKICK_ENV" = 1
command -v sidekick-ctl
```

If either fails, report that the current process is not running in an automation-enabled Sidekick pane. Do not use GUI keyboard automation.

Discover the caller and current layout:

```sh
sidekick-ctl pane current
sidekick-ctl pane list
```

Use `SIDEKICK_PANE_ID` as the initial target. Treat pane IDs as opaque runtime values and use IDs returned by `pane split` for subsequent operations.

## Launch a worker

Split without stealing the user's focus and launch with an argv array:

```sh
sidekick-ctl pane split "$SIDEKICK_PANE_ID" \
  --direction right \
  --cwd "$PWD" \
  --no-focus \
  --exec claude
```

Read `result.pane.pane_id` from the JSON response. Do not guess a pane ID.

Send an interactive prompt:

```sh
sidekick-ctl pane run "$WORKER_PANE" "Review the API error handling and report concrete defects"
```

For a noninteractive worker, launch its complete argv atomically:

```sh
sidekick-ctl pane split "$SIDEKICK_PANE_ID" \
  --direction down --cwd "$PWD" --no-focus \
  --exec claude -p "Run the focused test suite and diagnose failures"
```

Use separate git worktrees when multiple workers may modify overlapping files. Shared panes do not isolate filesystem changes.

## Coordinate panes

Inspect output already produced:

```sh
sidekick-ctl pane read "$WORKER_PANE" --source visible --lines 60
sidekick-ctl pane read "$WORKER_PANE" --source recent --lines 200
```

Wait for future output or an agent state:

```sh
sidekick-ctl wait output "$WORKER_PANE" "ready" --timeout 30000
sidekick-ctl wait agent-status "$WORKER_PANE" done --timeout 600000
```

Wait commands return exit status 1 on timeout. After waiting, always read the pane rather than assuming success.

Send input without or with Enter:

```sh
sidekick-ctl pane send-text "$WORKER_PANE" "additional context"
sidekick-ctl pane send-key "$WORKER_PANE" enter
sidekick-ctl pane run "$WORKER_PANE" "additional context"
```

Supported named keys include `enter`, `tab`, `esc`, `backspace`, `ctrl-c`, `ctrl-d`, and arrow directions.

## Manage layout

```sh
sidekick-ctl pane focus "$WORKER_PANE"
sidekick-ctl pane close "$WORKER_PANE"
```

Sidekick currently permits four panes per tab. If a split reports the pane limit, reuse an existing terminal pane or ask the user before closing one.

Do not close panes you did not create unless the user explicitly requests it. Do not send input to a pane until its ID and purpose have been verified with `pane list` or the split response.
