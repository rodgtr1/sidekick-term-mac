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

    public init() {
        self.theme = ThemeConfig()
        self.font = FontConfig()
        self.cursor = CursorConfig()
        self.window = WindowConfig()
        self.behavior = BehaviorConfig()
        self.tasks = []
        self.shell = ShellConfig()
        self.diff = DiffConfig()
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
            return Config()
        }

        do {
            let toml = try TOMLTable(string: tomlString)
            let decoder = TOMLDecoder()
            return try decoder.decode(Config.self, from: toml)
        } catch {
            print("Failed to parse config: \(error)")
            return Config()
        }
    }

    private static func createDefaultConfig(at url: URL) {
        let defaultConfig = """
[theme]
# Available themes: catppuccin-mocha
name = "catppuccin-mocha"
# Background opacity: 0.0 (fully transparent) to 1.0 (fully opaque)
opacity = 0.9

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
# Window opacity: 0.0 (fully transparent) to 1.0 (fully opaque)
opacity = 0.9

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

# Global run-panel tasks (available in every project)
# [[tasks]]
# name = "My task"
# cmd  = "echo hello"
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
            let encoder = TOMLEncoder()
            let toml = try encoder.encode(self)
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
    public var name: String
    public var opacity: Double

    public init() {
        self.name = "catppuccin-mocha"
        self.opacity = 0.9
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

    public init() {
        self.padding = 8
        self.opacity = 0.9
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

    enum CodingKeys: String, CodingKey {
        case scrollbackLines = "scrollback_lines"
        case scrollOnOutput = "scroll_on_output"
        case scrollOnKeystroke = "scroll_on_keystroke"
        case allowHyperlinks = "allow_hyperlinks"
        case mouseAutohide = "mouse_autohide"
        case audibleBell = "audible_bell"
    }

    public init() {
        self.scrollbackLines = 10000
        self.scrollOnOutput = false
        self.scrollOnKeystroke = true
        self.allowHyperlinks = true
        self.mouseAutohide = true
        self.audibleBell = false
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

// MARK: - Task Configuration
public struct Task: Codable {
    public var name: String
    public var cmd: String
    public var llmPrompt: String?
    public var hotkey: String?

    enum CodingKeys: String, CodingKey {
        case name
        case cmd
        case llmPrompt = "llm_prompt"
        case hotkey
    }

    public init(name: String, cmd: String, llmPrompt: String? = nil, hotkey: String? = nil) {
        self.name = name
        self.cmd = cmd
        self.llmPrompt = llmPrompt
        self.hotkey = hotkey
    }
}