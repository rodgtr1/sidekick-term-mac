# Sidekick

![Sidekick's Agents panel showing live agent status and per-agent context-usage bars](screenshot-agents-panel.png)

A native macOS terminal built for running AI coding agents — Claude Code,
Codex, and friends — alongside a real dev environment, not just a shell
prompt. It's fast (Swift/AppKit, not Electron), it looks like a normal
terminal, and it adds exactly the things that make agent-driven development
easier: live per-tab agent status, a context-usage bar so you can see a
session approaching its token limit, one-click git worktrees so parallel
agents don't collide, and an inline diff review before an agent's edits land.

Everything else you'd want from a terminal — tabs, splits, a file tree, a git
panel, a built-in editor — is there too, and every opinionated bit (built-in
editor vs. your own `$EDITOR`/nvim, sidebar visibility, theme) is a config
toggle, not a requirement.

## Why Sidekick

- **Built for agent workflows, not bolted onto a generic terminal.** An
  Agents dashboard shows every running agent's state (working / waiting /
  done) with a live context-usage bar per agent, dock bounces and
  notifications when one needs you, and a diff approval panel to review an
  agent's proposed edits before they land — with configurable auto-approve
  rules for the edits you trust.
- **Git worktree per agent.** Spin up an isolated worktree — and optionally
  launch an agent straight into it — with one action, so parallel agents
  never fight over the same working tree.
- **A real sidebar without leaving the terminal.** Files, Search, Git,
  Worktrees, Agents, and SSH Hosts panels, VS Code-style, in a native window.
- **Scriptable down to the socket.** A Unix-socket IPC layer, a `sidekick-ctl`
  CLI, and a full [MCP](https://modelcontextprotocol.io) server mean any
  agent or script — not just the ones running inside Sidekick — can list
  panes, split them, run commands, and read output.
- **Native and fast.** Swift + AppKit, not a bundled browser.
- **Configurable, not opinionated.** Theme, fonts, editor mode, approval
  policy — all in one live-reloading `config.toml` or the Preferences window.

## Features

**Terminal** — SwiftTerm-powered emulation, auto-detected shell, cwd + git
branch in the tab title, Catppuccin Mocha/Latte themes (or drop in your own
JSON palette), tabs, up to 4 splits per tab, and full session restore
(tabs/panes/cwd) across restarts.

**Sidebar** — Files (with git status and a hidden-file toggle), Search,
Git (stage/unstage/commit/push/pull), Worktrees (create/open/remove with a
guard against discarding uncommitted work), and Hosts (jump straight into an
`ssh` session for anything in `~/.ssh/config`).

**Agent orchestration** — an Agents dashboard with live state per tab and a
per-agent context-usage bar (green → yellow → red as a session's context
window fills up); macOS notifications and dock bounces when an agent needs
input or finishes; an inline diff approval panel with accept/reject/"remember
for this session"; and a configurable approval policy (ask every edit,
auto-approve edits, or fully autonomous) with always-allow/always-ask glob
overrides for things like `.env` and secrets.

**Editor** — a built-in editor with tree-sitter syntax highlighting (Swift,
Go, Rust, Python, TypeScript/JavaScript/JSX/TSX, Markdown), or set
`file_open_mode = "terminal"` to open files in your own `$EDITOR`/nvim
instead — the built-in editor is opt-in, not the only option.

**MCP server (`sidekick-mcp`)** — exposes pane orchestration as native MCP
tools (`pane_list`, `pane_split`, `pane_run`, `pane_read`,
`wait_agent_status`, and more) so Claude Code, Claude Desktop, Cursor, or any
other MCP client can drive Sidekick directly. See [MCP Server](#mcp-server).

**Quality of life** — quick open (`⌘P`) and a command palette (`⇧⌘P`),
paste an image straight into a terminal as a temp-file path, app-wide font
zoom, drag-to-reorder tabs, and `config.toml` changes that apply live with no
restart.

## Quick Start

### Run from Source
```bash
swift build
.build/debug/Sidekick
```

### Build the macOS App
```bash
# Build build/Sidekick.app, build/Sidekick.dmg, and build/Sidekick.zip
./build-app.sh

# Install by opening the DMG and dragging Sidekick to Applications
open build/Sidekick.dmg

# Or install to Applications non-interactively
./install.sh
```

The app isn't notarized yet, so on first launch you may need to go to
System Settings → Privacy & Security → "Open Anyway" (macOS no longer
supports right-click → Open to bypass this on recent versions).

Optional one-button setup, once it's installed:
- **Preferences → Terminal → Install for zsh** — shell integration (prompt
  marks, cwd tracking, agent-exit cleanup).
- **Preferences → Agents** — auto-detects Claude Code, Codex, and Pi and
  wires up the Agents panel. Safe to re-run.

Apple Silicon only for now — Intel would need a universal build
(`swift build --arch arm64 --arch x86_64`).

## Keyboard Shortcuts

A few of the most-used ones — the full, always-current list is in the app
via `⌘K` ("Keyboard Shortcuts").

| Shortcut | Action |
|---|---|
| `⌘T` / `⌘W` | New tab / close tab |
| `⌘1`–`⌘9` | Switch to tab by number |
| `⌘D` / `⇧⌘D` | Split right / split down |
| `⌘[` / `⌘]` | Focus previous / next pane |
| `⇧⌘E` / `⇧⌘G` / `⇧⌘F` | Files / Git / Search panel |
| `⌘P` / `⇧⌘P` | Quick open / command palette |
| `⇧⌘J` | Jump to the next agent that needs attention |
| `⌘B` | Toggle sidebar |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `⌘,` | Preferences |

## MCP Server

`sidekick-mcp` exposes Sidekick's pane orchestration as MCP tools over
stdio, so any MCP client can drive it directly — no `sidekick-ctl` shell-outs
needed:

```json
{ "mcpServers": { "sidekick": { "command": "/path/to/sidekick-mcp" } } }
```

```bash
# Register it with Claude Code (also installs a build to ~/.local/bin)
scripts/install-agent-status-hooks

# Or point Claude Code at the copy inside the app bundle directly
claude mcp add --scope user sidekick /Applications/Sidekick.app/Contents/MacOS/sidekick-mcp
```

Tools: `pane_list` / `pane_current` / `pane_split` / `pane_focus` /
`pane_close`, `pane_send_text` / `pane_run` / `pane_send_key`, `pane_read`
(incl. `--json` command records), `wait_agent_status` / `wait_output`, and
`new_tab`. Honors `SIDEKICK_SOCKET_PATH` (default
`~/.config/sidekick/sidekick.sock`).

## Pane Automation (`sidekick-ctl`)

For scripts and agents that want lower-level control, `sidekick-ctl` talks to
the same Unix socket the MCP server uses:

```bash
# Discover panes and the caller's own pane
sidekick-ctl pane list
sidekick-ctl pane current

# Split and launch a process without changing UI focus
sidekick-ctl pane split "$SIDEKICK_PANE_ID" \
  --direction right --cwd "$PWD" --no-focus --exec claude

# Fan an agent out onto its own git worktree (created if needed)
sidekick-ctl pane split "$SIDEKICK_PANE_ID" \
  --worktree feature/login --no-focus --exec claude

# Control and inspect a pane
sidekick-ctl pane run "$PANE_ID" "Review the API error handling"
sidekick-ctl pane read "$PANE_ID" --source recent --lines 100
sidekick-ctl wait agent-status "$PANE_ID" done --timeout 600000

# Subscribe to a live JSONL event stream: agent-state transitions,
# command completions, and edit-approval decisions
sidekick-ctl events --follow
```

`pane split --worktree <branch>` resolves the git repo containing the source
pane, creates (or reuses) a worktree for that branch in a sibling
`<repo>.worktrees/<branch>` directory, and opens the new pane there.

### Claude/Codex Agent Status Hooks

Sidekick can drive tab status indicators from Claude Code and Codex
lifecycle hooks — more reliable than parsing terminal text:

```bash
scripts/install-agent-status-hooks
```

This builds `sidekick-agent-status`, installs it to `~/.local/bin`, and adds
hooks to `~/.claude/settings.json` and `~/.codex/config.toml`
(`UserPromptSubmit` → busy, `PermissionRequest` → ready, `Stop` → done).
Restart open Claude Code/Codex sessions after installing.

## Configuration

Sidekick loads `~/.config/sidekick/config.toml`, created with defaults on
first launch. Changes apply live — no restart needed.

```toml
[theme]
name = "catppuccin-mocha"    # catppuccin-mocha | catppuccin-latte | auto (follow macOS)

[font]
family = "Menlo"
size = 13
bold_is_bright = true

[cursor]
shape = "block"              # block | ibeam | underline
blink = true

[window]
padding = 8
opacity = 0.9
enable_blur = true

[behavior]
scrollback_lines = 10000     # -1 for unlimited
scroll_on_output = false
scroll_on_keystroke = true
allow_hyperlinks = true
mouse_autohide = true
audible_bell = false
restore_session = true

[shell]
program = ""                 # empty = use $SHELL
args = []
default_cwd = "~"

[diff]
context_lines = 3

[editor]
file_open_mode = "terminal"  # terminal ($EDITOR/nvim) | builtin (Sidekick's editor pane)
font_family = ""
word_wrap = true
font_size = 13
show_hidden_files = false
```

Drop custom theme palettes (same JSON schema as the built-ins) into
`~/.config/sidekick/themes/`.

## Requirements

- macOS 13.0+ (Ventura)
- Swift 6.2+ toolchain (Xcode 26+) to build from source

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation
- [TOMLKit](https://github.com/LebJe/TOMLKit) — config file parsing
- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) + per-language
  tree-sitter grammars — editor syntax highlighting

## License

MIT — see [LICENSE](LICENSE).
