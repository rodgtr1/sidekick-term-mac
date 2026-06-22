import Foundation
import TOMLKit

public struct Config: Codable {
    public var theme: ThemeConfig
    public var font: FontConfig
    public var cursor: CursorConfig
    public var window: WindowConfig
    public var behavior: BehaviorConfig
    public var tasks: [Task]?  // Make optional since it's not always in config
    public var shell: ShellConfig
    public var diff: DiffConfig
    public var editor: EditorConfig?  // Make optional for backwards compatibility
    public var hosts: HostsConfig?  // Make optional for backwards compatibility

    public init() {
        self.theme = ThemeConfig()
        self.font = FontConfig()
        self.cursor = CursorConfig()
        self.window = WindowConfig()
        self.behavior = BehaviorConfig()
        self.tasks = []
        self.shell = ShellConfig()
        self.diff = DiffConfig()
        self.editor = EditorConfig()
        self.hosts = HostsConfig()
    }

    public static func load(from path: String = "~/.config/sidekick/config.toml") -> Config {
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Create default config if doesn't exist
        let fileURL = URL(fileURLWithPath: expandedPath)
        if !FileManager.default.fileExists(atPath: expandedPath) {
            createDefaultConfig(at: fileURL)
            return Config()
        }

        guard let data = try? Data(contentsOf: fileURL),
              let tomlString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to read config file")
            return Config()
        }

        do {
            let toml = try TOMLTable(string: tomlString)
            let decoder = TOMLDecoder()
            let config = try decoder.decode(Config.self, from: toml)
            print("✅ Config loaded: font=\(config.font.family) size=\(config.font.size) opacity=\(config.window.opacity)")
            return config
        } catch {
            print("❌ Failed to parse config: \(error)")
            return Config()
        }
    }

    private static func createDefaultConfig(at url: URL) {
        let defaultConfig = """
[theme]
# Themes: catppuccin-mocha (dark), catppuccin-latte (light), or "auto" to
# follow the macOS light/dark setting. Drop custom palettes (same JSON schema)
# into ~/.config/sidekick/themes/ to add your own.
name = "catppuccin-mocha"

[font]
# Font family — use any monospace font installed on your system
family = "Menlo"
# Size in points
size = 13
# Bold text uses bright palette colors (like most terminals)
bold_is_bright = true

[cursor]
# shape: block | ibeam | underline
shape = "block"
blink = true

[window]
# Inner padding around the terminal content (pixels)
padding = 8
# Terminal background opacity: 0.0 (fully transparent) to 1.0 (fully opaque)
opacity = 0.9
# Enable macOS background blur/vibrancy effect
enable_blur = true

[behavior]
# Lines of scrollback (-1 for unlimited)
scrollback_lines = 10000
# Scroll to bottom when new output appears
scroll_on_output = false
# Scroll to bottom when you type
scroll_on_keystroke = true
# Clickable URLs
allow_hyperlinks = true
# Hide mouse cursor while typing
mouse_autohide = true
audible_bell = false
# Restore tabs and working directories from the previous session on launch
restore_session = true

[shell]
# Shell program (leave empty to use $SHELL)
program = ""
# Shell arguments
args = []
# Default working directory (~ for home)
default_cwd = "~"

[diff]
# Number of context lines to show in diffs
context_lines = 3

[editor]
# File tree open mode: terminal | builtin
# terminal opens files in $EDITOR or nvim inside the active terminal.
# builtin opens files in Sidekick's editor pane with syntax highlighting.
file_open_mode = "terminal"
# Wrap long lines in the editor (true = word wrap, false = horizontal scroll)
word_wrap = true
# Built-in editor text size in points
font_size = 13
# Show hidden files and gitignored files in the file tree (rendered dimmed)
show_hidden_files = false

[hosts]
# Show Teleport nodes (from `tsh ls`) in the Hosts sidebar panel
show_teleport = false

# Global run-panel tasks (available in every project)
# [[tasks]]
# name = "My task"
# cmd  = "echo hello"
# open_browser = "http://localhost:3000"  # optional: open embedded browser when run
"""

        // Create directory if needed
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? defaultConfig.write(to: url, atomically: true, encoding: .utf8)
    }

    public func save(to path: String = "~/.config/sidekick/config.toml") {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        do {
            // Reload config from disk to preserve manual edits (like tasks)
            var configToSave = self
            if FileManager.default.fileExists(atPath: expandedPath),
               let data = try? Data(contentsOf: fileURL),
               let tomlString = String(data: data, encoding: .utf8),
               let toml = try? TOMLTable(string: tomlString),
               let diskConfig = try? TOMLDecoder().decode(Config.self, from: toml) {
                // Preserve tasks from the file on disk
                configToSave.tasks = diskConfig.tasks
            }

            let encoder = TOMLEncoder()
            let toml = try encoder.encode(configToSave)
            let tomlString = toml.description

            // Create directory if needed
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)

            try tomlString.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save config: \(error)")
        }
    }
}

// MARK: - Theme Configuration
public struct ThemeConfig: Codable {
    // Theme name ("catppuccin-mocha", "catppuccin-latte", a user theme's name)
    // or "auto" to follow the macOS light/dark setting.
    public var name: String

    public init() {
        self.name = "catppuccin-mocha"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? name
    }
}

// MARK: - Font Configuration
public struct FontConfig: Codable {
    public var family: String
    public var size: Int
    public var boldIsBright: Bool

    enum CodingKeys: String, CodingKey {
        case family
        case size
        case boldIsBright = "bold_is_bright"
    }

    public init() {
        self.family = "Menlo"
        self.size = 13
        self.boldIsBright = true
    }
}

// MARK: - Cursor Configuration
public struct CursorConfig: Codable {
    public var shape: String  // block | ibeam | underline
    public var blink: Bool

    public init() {
        self.shape = "block"
        self.blink = true
    }
}

// MARK: - Window Configuration
public struct WindowConfig: Codable {
    public var padding: Int
    public var opacity: Double
    public var enableBlur: Bool

    enum CodingKeys: String, CodingKey {
        case padding
        case opacity
        case enableBlur = "enable_blur"
    }

    public init() {
        self.padding = 8
        self.opacity = 0.9
        self.enableBlur = true
    }
}

// MARK: - Behavior Configuration
public struct BehaviorConfig: Codable {
    public var scrollbackLines: Int
    public var scrollOnOutput: Bool
    public var scrollOnKeystroke: Bool
    public var allowHyperlinks: Bool
    public var mouseAutohide: Bool
    public var audibleBell: Bool
    public var restoreSession: Bool

    enum CodingKeys: String, CodingKey {
        case scrollbackLines = "scrollback_lines"
        case scrollOnOutput = "scroll_on_output"
        case scrollOnKeystroke = "scroll_on_keystroke"
        case allowHyperlinks = "allow_hyperlinks"
        case mouseAutohide = "mouse_autohide"
        case audibleBell = "audible_bell"
        case restoreSession = "restore_session"
    }

    public init() {
        self.scrollbackLines = 10000
        self.scrollOnOutput = false
        self.scrollOnKeystroke = true
        self.allowHyperlinks = true
        self.mouseAutohide = true
        self.audibleBell = false
        self.restoreSession = true
    }

    // Tolerant decoding so configs written before a key existed still parse;
    // missing keys keep the defaults from init() (stated once, there).
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scrollbackLines = try container.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? scrollbackLines
        scrollOnOutput = try container.decodeIfPresent(Bool.self, forKey: .scrollOnOutput) ?? scrollOnOutput
        scrollOnKeystroke = try container.decodeIfPresent(Bool.self, forKey: .scrollOnKeystroke) ?? scrollOnKeystroke
        allowHyperlinks = try container.decodeIfPresent(Bool.self, forKey: .allowHyperlinks) ?? allowHyperlinks
        mouseAutohide = try container.decodeIfPresent(Bool.self, forKey: .mouseAutohide) ?? mouseAutohide
        audibleBell = try container.decodeIfPresent(Bool.self, forKey: .audibleBell) ?? audibleBell
        restoreSession = try container.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? restoreSession
    }
}

// MARK: - Shell Configuration
public struct ShellConfig: Codable {
    public var program: String
    public var args: [String]
    public var defaultCwd: String

    enum CodingKeys: String, CodingKey {
        case program
        case args
        case defaultCwd = "default_cwd"
    }

    public init() {
        self.program = ""
        self.args = []
        self.defaultCwd = "~"
    }
}

// MARK: - Diff Configuration
public struct DiffConfig: Codable {
    public var contextLines: Int

    enum CodingKeys: String, CodingKey {
        case contextLines = "context_lines"
    }

    public init() {
        self.contextLines = 3
    }
}

// MARK: - Editor Configuration
public struct EditorConfig: Codable {
    public var fileOpenMode: String
    public var wordWrap: Bool
    public var fontSize: Int
    public var showHiddenFiles: Bool
    /// Editor font family. Empty means use the system monospaced font.
    public var fontFamily: String

    enum CodingKeys: String, CodingKey {
        case fileOpenMode = "file_open_mode"
        case wordWrap = "word_wrap"
        case fontSize = "font_size"
        case showHiddenFiles = "show_hidden_files"
        case fontFamily = "font_family"
    }

    public init() {
        self.fileOpenMode = "terminal"
        self.wordWrap = true
        self.fontSize = 13
        self.showHiddenFiles = false
        self.fontFamily = ""
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileOpenMode = try container.decodeIfPresent(String.self, forKey: .fileOpenMode) ?? "terminal"
        self.wordWrap = try container.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? true
        self.fontSize = try container.decodeIfPresent(Int.self, forKey: .fontSize) ?? 13
        self.showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        self.fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
    }
}

// MARK: - Hosts Panel Configuration
public struct HostsConfig: Codable {
    public var showTeleport: Bool

    enum CodingKeys: String, CodingKey {
        case showTeleport = "show_teleport"
    }

    public init() {
        self.showTeleport = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.showTeleport = try container.decodeIfPresent(Bool.self, forKey: .showTeleport) ?? false
    }
}

// MARK: - Task Configuration
public struct Task: Codable {
    public var name: String
    public var cmd: String
    public var llmPrompt: String?
    public var hotkey: String?
    public var openBrowser: String?

    enum CodingKeys: String, CodingKey {
        case name
        case cmd
        case llmPrompt = "llm_prompt"
        case hotkey
        case openBrowser = "open_browser"
    }

    public init(name: String, cmd: String, llmPrompt: String? = nil, hotkey: String? = nil, openBrowser: String? = nil) {
        self.name = name
        self.cmd = cmd
        self.llmPrompt = llmPrompt
        self.hotkey = hotkey
        self.openBrowser = openBrowser
    }
}
