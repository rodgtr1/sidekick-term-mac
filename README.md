# Sidekick macOS — Native Swift/AppKit Terminal

A native macOS terminal application built with Swift and AppKit, featuring multi-tab support, split panes, and VS Code-style sidebar panels.

## Features

✅ **Terminal Core**
- SwiftTerm-powered terminal emulation
- Auto-detects shell from `$SHELL` environment variable
- Current working directory tracking with git branch display
- Catppuccin Mocha color scheme
- Full copy/paste support (Cmd+C/V)

✅ **Multi-Tab Interface**
- Custom tab bar with close buttons
- Tab switching with keyboard shortcuts (Ctrl+Tab, Cmd+1-9)
- Tab title shows current directory + git branch
- Visual tab indicators for Claude/Codex agent states
- Dock icon bounces when an agent waits for input or finishes
- Active tab highlighted with blue border

✅ **Split Panes**
- Horizontal splits (side-by-side)
- Vertical splits (top/bottom)
- Focus tracking with visual borders (blue = active)
- Pane navigation with Cmd+[ and Cmd+]
- Up to 4 panes per tab

✅ **Embedded Browser**
- WKWebView-based browser in split pane (50/50 layout)
- Navigation controls (back, forward, reload)
- URL bar with search support
- Opens alongside terminals and editors
- Access with Cmd+Shift+O

✅ **Activity Bar + Sidebar**
- VS Code-style activity bar with 4 panels
- File tree with git integration and hidden file toggle
- Toggle sidebar visibility
- SF Symbols icons with tooltips

✅ **Editor Integration**
- Built-in text editor for file viewing/editing
- Syntax highlighting support
- Auto-focus on file open
- Dirty state tracking (● indicator)

✅ **Git Panel**
- Real-time git status with color-coded indicators
- Stage/unstage individual files or all changes
- Commit with multi-line message editor
- Push/pull operations with progress feedback
- Branch display and auto-refresh

✅ **Session Restore**
- Tabs, split panes, and working directories saved to `~/.config/sidekick/session.json`
- Autosaves every minute and on window close; restores on launch
- Disable with `restore_session = false` under `[behavior]` in config.toml

✅ **Agent Edit Review (Claude Code hook)**
- `sidekick-hook` is a PreToolUse hook for Write/Edit/MultiEdit: the proposed
  change appears as a diff sheet in Sidekick with Accept/Reject buttons
- Reject blocks the edit (exit 2); if Sidekick isn't running the edit is allowed
- Install with `scripts/install-agent-status-hooks`

✅ **Quality of Life**
- App-wide font zoom: `Cmd+=` / `Cmd+-` / `Cmd+0`
- Paste an image from the clipboard into a terminal (`Cmd+V`): it's written to
  a temp PNG and the quoted path is typed — handy for handing screenshots to agents
- Rename tabs (right-click) and drag tabs to reorder
- macOS notifications when an agent waits for input / finishes or a long
  command (≥30s) ends while the app is in the background
- Activity-bar badge counts agents waiting for input
- config.toml changes apply live (no restart)

## Keyboard Shortcuts

### Tabs
- `Cmd+T` or `Cmd+Shift+T` - New tab
- `Cmd+W` - Close tab
- `Ctrl+Tab` - Next tab
- `Ctrl+Shift+Tab` - Previous tab
- `Cmd+1-9` - Switch to tab by index
- `Cmd+Shift+J` - Jump to next tab whose agent wants attention (needs-input first, then done, then working)

### Splits
- `Cmd+D` - Split right (horizontal)
- `Cmd+Shift+D` - Split right (horizontal, alternative)
- `Cmd+Shift+X` - Split down (vertical)
- `Cmd+Shift+W` - Close current pane

### Pane Navigation
- `Cmd+[` - Focus previous pane
- `Cmd+]` - Focus next pane

### Terminal
- `Cmd+C` - Copy selected text
- `Cmd+V` - Paste (clipboard images become a temp PNG path)
- `Cmd+F` - Find in terminal
- `Cmd+=` / `Cmd+-` / `Cmd+0` - Zoom in / out / reset (all terminals)

### Sidebar Panels
- `Cmd+B` - Toggle sidebar
- `Cmd+Shift+E` - Files panel
- `Cmd+Shift+G` - Git panel
- `Cmd+Shift+F` - Search panel
- `Cmd+Shift+R` - Run panel

### Browser
- `Cmd+Shift+O` - Split with browser (50/50 layout)

### File Operations
- `Cmd+P` - Quick open file
- `Cmd+S` - Save current editor file

### System
- `Cmd+,` - Preferences

## Quick Start

### Run from Source
```bash
cd sidekick-mac
swift build
.build/debug/Sidekick
```

### Build macOS App Bundle
```bash
# Build optimized .app bundle
./build-app.sh

# Install to Applications (optional)
./install.sh

# Or manually install
cp -r build/Sidekick.app /Applications/
```

### CLI Tools
```bash
# Test IPC connection
.build/debug/sidekick-ctl ping

# Emit agent status markers for hooks
.build/debug/sidekick-agent-status busy

# Or if installed system-wide
sidekick-ctl ping
```

### Pane Automation

`sidekick-ctl` exposes live terminal panes to scripts and coding agents. Pane
IDs are returned as JSON and remain stable for the lifetime of the pane.

```bash
# Discover panes and the caller's own pane
sidekick-ctl pane list
sidekick-ctl pane current

# Split and launch a real process without changing UI focus
sidekick-ctl pane split "$SIDEKICK_PANE_ID" \
  --direction right --cwd "$PWD" --no-focus --exec claude

# Control and inspect the returned pane ID
sidekick-ctl pane run "$PANE_ID" "Review the API error handling"
sidekick-ctl pane read "$PANE_ID" --source recent --lines 100
sidekick-ctl wait agent-status "$PANE_ID" done --timeout 600000
```

Managed terminals receive `SIDEKICK_ENV`, `SIDEKICK_SOCKET_PATH`, and
`SIDEKICK_PANE_ID`. Direct `--exec` launches use an argv array rather than a
shell command. Sidekick currently allows four panes per tab.

The bundled `scripts/install-agent-status-hooks` installer copies the pane
orchestration skill to both `~/.claude/skills` and `~/.codex/skills`; its source
is `.claude/skills/sidekick-panes/SKILL.md`.

### Claude/Codex Agent Status Hooks

Sidekick can drive tab status indicators from Claude Code and Codex lifecycle hooks.
This is more reliable than detecting agent state from terminal text. The helper
writes an OSC 666 terminal property directly to `/dev/tty`, so hook stdout stays
clean for the agent.

```bash
scripts/install-agent-status-hooks
```

The installer builds `sidekick-agent-status`, installs it to `~/.local/bin`, and
adds hooks to `~/.claude/settings.json` and `~/.codex/config.toml`. Restart open
Claude Code or Codex sessions after installing.

Hook status mapping:

```text
UserPromptSubmit  -> busy
PermissionRequest -> ready
Stop              -> done
```

Manual status commands are also available:

```bash
sidekick-agent-status busy
sidekick-agent-status ready
sidekick-agent-status done
sidekick-agent-status idle
```

## IPC Commands

Sidekick supports IPC commands via Unix socket at `~/.config/sidekick/sidekick.sock`:

```bash
# Notify that an agent is busy (shows 🟢 on tab)
echo '{"action":"agent_busy"}' | nc -U ~/.config/sidekick/sidekick.sock

# Notify that an agent is waiting for input (shows 🟡 on tab, bounces dock icon)
echo '{"action":"agent_ready"}' | nc -U ~/.config/sidekick/sidekick.sock

# Notify that an agent finished the last run (shows 🔵 on tab, bounces dock icon)
echo '{"action":"agent_done"}' | nc -U ~/.config/sidekick/sidekick.sock

# Create a new tab
echo '{"action":"new_tab","cwd":"/path/to/dir"}' | nc -U ~/.config/sidekick/sidekick.sock

# List panes
echo '{"action":"pane_list"}' | nc -U ~/.config/sidekick/sidekick.sock

# Split a pane and directly launch a command
echo '{"action":"pane_split","pane_id":"UUID","direction":"right","focus":false,"command":["claude"]}' \
  | nc -U ~/.config/sidekick/sidekick.sock

# Show a diff
echo '{"action":"show_diff","path":"file.txt","old":"old content","new":"new content"}' | nc -U ~/.config/sidekick/sidekick.sock

# Ping
echo '{"action":"ping"}' | nc -U ~/.config/sidekick/sidekick.sock
```

## Deployment

### App Bundle Structure
```
Sidekick.app/
├── Contents/
│   ├── Info.plist                  # App metadata
│   ├── MacOS/
│   │   ├── Sidekick                # Main GUI application
│   │   ├── sidekick-ctl            # CLI utility
│   │   ├── sidekick-agent-status   # Agent state reporter (used by hooks)
│   │   └── sidekick-hook           # Claude PreToolUse edit review
│   └── Resources/
│       └── AppIcon.icns            # App icon
```

### Handing It to Another Mac

The bundle is self-contained — no source checkout or Swift toolchain needed
on the receiving end:

1. `./build-app.sh` produces `build/Sidekick.zip` alongside the bundle.
2. Transfer it. `scp`/USB skips macOS quarantine entirely; browser or
   AirDrop transfers will need right-click → Open (or System Settings →
   Privacy & Security → "Open Anyway") on first launch, since the app is
   not notarized.
3. Recipient unzips and drags `Sidekick.app` to `/Applications`.
4. In-app setup (all optional, each one button):
   - **Preferences → Terminal → Install for zsh** — shell integration
     (prompt marks, cwd tracking, agent-exit cleanup).
   - **Preferences → Agents** — detects Claude Code, Codex, and Pi and
     wires whichever are present to the agents panel, using the binaries
     inside the app bundle. Safe to re-run; existing config is preserved.

Note: the app is Apple Silicon (arm64) only as built; Intel Macs would
need a universal build (`swift build --arch arm64 --arch x86_64`).

### Installation Options

**1. Direct Download**
- Users download & drag `Sidekick.app` to Applications

**2. Command Line**
```bash
# Install app bundle
cp -r build/Sidekick.app /Applications/

# Add CLI tools to PATH (optional)
ln -sf /Applications/Sidekick.app/Contents/MacOS/sidekick-ctl /usr/local/bin/sidekick-ctl
```

**3. Future Distribution**
- Homebrew Cask: `brew install --cask sidekick`
- Mac App Store (requires Apple Developer account)
- Notarization for Gatekeeper compatibility

## Requirements

- macOS 13.0+ (Ventura)
- Swift 5.9+
- Xcode command line tools

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulation
- [TOMLKit](https://github.com/LebJe/TOMLKit) - Configuration file parsing

## Architecture

### Phase Progress
- ✅ Phase 1: Project scaffold, dependencies, config
- ✅ Phase 2: Terminal core with SwiftTerm
- ✅ Phase 3: Multi-tab + Split panes
- ✅ Phase 4: Activity bar + Sidebar
- ✅ Phase 5: File Tree (NSOutlineView)
- ✅ Phase 6: Git Panel
- 📋 Phase 7: Search Panel
- 📋 Phase 8: Quick Open (Cmd+P)
- 📋 Phase 9: Task Runner Panel
- 📋 Phase 10: Browser Panel (WKWebView)
- 📋 Phase 11: IPC (Unix Socket)
- 📋 Phase 12: Polish + Packaging

### Project Structure
```
sidekick-mac/
├── Package.swift           # SPM configuration
├── Sources/Sidekick/
│   ├── App/                # AppDelegate, MainWindowController
│   ├── Config/             # Configuration structs
│   ├── Terminal/           # Terminal emulation + CWD detection
│   ├── Tabs/               # Tab management
│   ├── Panes/              # Split pane management
│   └── Sidebar/            # Activity bar + sidebar panels
├── Sources/sidekick-ctl/   # CLI utility
├── Info.plist             # App bundle metadata
├── build-app.sh           # Build script
└── install.sh             # Installation script
```

## Configuration

The app loads configuration from `~/.config/sidekick/config.toml`. It's created
with defaults on first launch; changes apply live (no restart). Every supported
key is shown below with its default value:

```toml
[theme]
# catppuccin-mocha (dark), catppuccin-latte (light), or "auto" to follow macOS.
# Drop custom palettes (same JSON schema) into ~/.config/sidekick/themes/.
name = "catppuccin-mocha"

[font]
family = "Menlo"          # any monospace font installed on your system
size = 13                 # points
bold_is_bright = true     # bold text uses bright palette colors

[cursor]
shape = "block"           # block | ibeam | underline
blink = true

[window]
padding = 8               # inner padding around terminal content (pixels)
opacity = 0.9             # 0.0 (transparent) … 1.0 (opaque)
enable_blur = true        # macOS background blur/vibrancy

[behavior]
scrollback_lines = 10000  # -1 for unlimited
scroll_on_output = false  # scroll to bottom when new output appears
scroll_on_keystroke = true
allow_hyperlinks = true   # clickable URLs
mouse_autohide = true     # hide mouse cursor while typing
audible_bell = false
restore_session = true    # restore tabs/cwd from previous session on launch

[shell]
program = ""              # empty = use $SHELL
args = []
default_cwd = "~"

[diff]
context_lines = 3         # context lines shown in diffs

[editor]
file_open_mode = "terminal"  # terminal (opens in $EDITOR/nvim) | builtin (Sidekick editor pane)
font_family = ""             # empty = system monospaced font
word_wrap = true             # true = word wrap, false = horizontal scroll
font_size = 13               # built-in editor text size (points)
show_hidden_files = false    # show hidden/gitignored files in the file tree (dimmed)

[hosts]
show_teleport = false        # show Teleport nodes (from `tsh ls`) in the Hosts panel
```

## Development

### Building
```bash
# Debug build
swift build

# Release build
swift build --configuration release

# Build app bundle
./build-app.sh
```

### Testing
```bash
# Run main app
.build/debug/Sidekick

# Test CLI
.build/debug/sidekick-ctl ping
```

## License

MIT License - see LICENSE file for details.
