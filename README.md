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
- Run-panel tasks run in a dedicated split below with a running/finished/failed
  dot; an optional `open_browser = "http://..."` field opens the embedded browser
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
│   ├── Info.plist          # App metadata
│   ├── MacOS/
│   │   ├── Sidekick        # Main GUI application
│   │   └── sidekick-ctl    # CLI utility
│   └── Resources/
│       └── AppIcon.png     # App icon
```

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

The app loads configuration from `~/.config/sidekick/config.toml`:

```toml
[colors]
foreground = "#cdd6f4"
background = "#1e1e2e"
# ... (Catppuccin Mocha palette)

[terminal]
fontFamily = "JetBrains Mono"
fontSize = 13.0

[window]
opacity = 0.95
defaultWidth = 1200
defaultHeight = 800

[shell]
program = ""  # Empty = use $SHELL
args = []

[[tasks.global]]
name = "Build"
command = "swift build"
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
