# Sidekick macOS — Native Swift/AppKit Terminal

A native macOS terminal application built with Swift and AppKit, featuring multi-tab support, split panes, and VS Code-style sidebar panels.

## Features

✅ **Terminal Core**
- SwiftTerm-powered terminal emulation
- Auto-detects shell from `$SHELL` environment variable
- Current working directory tracking with git branch display
- Catppuccin Mocha color scheme

✅ **Multi-Tab Interface**
- Custom tab bar with close buttons
- Tab switching and management
- Window title shows current directory + git branch

✅ **Split Panes**
- Horizontal splits (side-by-side)
- Vertical splits (top/bottom)
- Focus tracking with visual borders
- Up to 4 panes per tab

✅ **Activity Bar + Sidebar**
- VS Code-style activity bar with 5 panels
- File tree with git integration and hidden file toggle
- Toggle sidebar visibility
- SF Symbols icons with tooltips

✅ **Git Panel**
- Real-time git status with color-coded indicators
- Stage/unstage individual files or all changes
- Commit with multi-line message editor
- Push/pull operations with progress feedback
- Branch display and auto-refresh

## Keyboard Shortcuts

### Tabs
- `Cmd+T` - New tab
- `Cmd+W` - Close tab
- `Cmd+1-9` - Switch to tab by index

### Splits
- `Cmd+D` - Split right (horizontal)
- `Cmd+Shift+D` - Split down (vertical)

### Sidebar
- `Cmd+B` - Toggle sidebar
- `Cmd+Shift+E` - Files panel
- `Cmd+Shift+G` - Git panel
- `Cmd+Shift+F` - Search panel
- `Cmd+Shift+R` - Run panel
- `Cmd+Shift+W` - Browser panel

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

# Or if installed system-wide
sidekick-ctl ping
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