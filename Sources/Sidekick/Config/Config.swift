import Foundation
import TOMLKit

public struct Config: Codable {
    public var colors: Colors
    public var terminal: Terminal
    public var tasks: Tasks
    public var diff: Diff
    public var window: Window
    public var shell: Shell

    public init() {
        self.colors = Colors()
        self.terminal = Terminal()
        self.tasks = Tasks()
        self.diff = Diff()
        self.window = Window()
        self.shell = Shell()
    }

    public static func load(from path: String = "~/.config/sidekick/config.toml") -> Config {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)),
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
}

public struct Colors: Codable {
    public var foreground: String = "#cdd6f4"
    public var background: String = "#1e1e2e"
    public var cursor: String = "#f5e0dc"
    public var selection: String = "#45475a"

    public var black: String = "#45475a"
    public var red: String = "#f38ba8"
    public var green: String = "#a6e3a1"
    public var yellow: String = "#f9e2af"
    public var blue: String = "#89b4fa"
    public var magenta: String = "#f5c2e7"
    public var cyan: String = "#94e2d5"
    public var white: String = "#bac2de"

    public var brightBlack: String = "#585b70"
    public var brightRed: String = "#f38ba8"
    public var brightGreen: String = "#a6e3a1"
    public var brightYellow: String = "#f9e2af"
    public var brightBlue: String = "#89b4fa"
    public var brightMagenta: String = "#f5c2e7"
    public var brightCyan: String = "#94e2d5"
    public var brightWhite: String = "#a6adc8"

    public init() {}
}

public struct Terminal: Codable {
    public var fontFamily: String = "JetBrains Mono"
    public var fontSize: Double = 13.0
    public var lineHeight: Double = 1.2
    public var scrollback: Int = 10000
    public var copyOnSelect: Bool = true
    public var pasteOnMiddleClick: Bool = true

    public init() {}
}

public struct Tasks: Codable {
    public var global: [Task] = []

    public init() {}
}

public struct Task: Codable {
    public var name: String
    public var command: String
    public var llmPrompt: String?
    public var hotkey: String?

    public init(name: String, command: String, llmPrompt: String? = nil, hotkey: String? = nil) {
        self.name = name
        self.command = command
        self.llmPrompt = llmPrompt
        self.hotkey = hotkey
    }
}

public struct Diff: Codable {
    public var contextLines: Int = 3

    public init() {}
}

public struct Window: Codable {
    public var opacity: Double = 0.95
    public var blur: Bool = false
    public var defaultWidth: Int = 1200
    public var defaultHeight: Int = 800

    public init() {}
}

public struct Shell: Codable {
    public var program: String = ""
    public var args: [String] = []

    public init() {}
}