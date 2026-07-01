import Foundation
import TOMLKit
import SidekickTelemetryCore

public struct Config: Codable {
    public var theme: ThemeConfig
    public var font: FontConfig
    public var cursor: CursorConfig
    public var window: WindowConfig
    public var behavior: BehaviorConfig
    public var shell: ShellConfig
    public var diff: DiffConfig
    public var editor: EditorConfig?  // Make optional for backwards compatibility
    public var approval: ApprovalConfig?  // Make optional for backwards compatibility
    public var telemetry: TelemetryConfig?  // Make optional for backwards compatibility

    /// True when this value is the defaults returned because the on-disk file
    /// existed but could not be read or parsed — as opposed to a legitimate
    /// fresh default. `save()` refuses to overwrite the file in that case so a
    /// recoverable-but-broken config is never silently clobbered with defaults.
    /// Transient runtime state, never encoded (excluded from `CodingKeys`).
    public var loadDidFail: Bool = false

    // Only the real config sections are (de)coded; `loadDidFail` is transient
    // and its default keeps synthesized Codable happy without persisting it.
    enum CodingKeys: String, CodingKey {
        case theme, font, cursor, window, behavior, shell, diff, editor, approval, telemetry
    }

    public init() {
        self.theme = ThemeConfig()
        self.font = FontConfig()
        self.cursor = CursorConfig()
        self.window = WindowConfig()
        self.behavior = BehaviorConfig()
        self.shell = ShellConfig()
        self.diff = DiffConfig()
        self.editor = EditorConfig()
        self.approval = ApprovalConfig()
        self.telemetry = TelemetryConfig()
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
            Log.error("Failed to read config file at \(expandedPath)", category: "config")
            return failedLoad()
        }

        do {
            let toml = try TOMLTable(string: tomlString)
            let decoder = TOMLDecoder()
            let config = try decoder.decode(Config.self, from: toml)
            Log.debug("✅ Config loaded: font=\(config.font.family) size=\(config.font.size) opacity=\(config.window.opacity)", category: "config")
            return config
        } catch {
            Log.error("Failed to parse config: \(error)", category: "config")
            // Preserve the user's broken-but-recoverable file alongside itself so
            // it survives even if something later recreates a default in place.
            let bakURL = fileURL.appendingPathExtension("bak")
            do {
                try data.write(to: bakURL)
                Log.error("Backed up unparseable config to \(bakURL.path)", category: "config")
            } catch {
                Log.error("Failed to back up unparseable config: \(error)", category: "config")
            }
            return failedLoad()
        }
    }

    /// Defaults tagged as originating from a failed load, so `save()` won't
    /// overwrite the on-disk file with them. See `loadDidFail`.
    private static func failedLoad() -> Config {
        var config = Config()
        config.loadDidFail = true
        return config
    }

    private static func createDefaultConfig(at url: URL) {
        let defaultConfig = """
# Sidekick configuration — ~/.config/sidekick/config.toml
#
# Every key is listed with its default value and valid choices. To change a
# setting, edit the VALUE here, then relaunch Sidekick (most apply live).
# Enum-like fields fall back to a default when given an unrecognized value
# (noted per field).
#
# NOTE: the [font], [cursor], [window], [shell], and [diff] keys are REQUIRED —
# commenting one out makes the whole file fail to parse and Sidekick silently
# falls back to its built-in defaults (Menlo, size 13). The other sections
# tolerate missing keys. Either way, prefer editing values in place.
#
# Editing settings in the in-app Preferences panel rewrites this file and strips
# these comments, so prefer editing here directly.

[theme]
# name: "catppuccin-mocha" (dark; also the fallback for unknown names),
#   "catppuccin-latte" (light), "min-light" (light), or "auto" to follow the
#   macOS light/dark setting. Drop custom *.json palettes into
#   ~/.config/sidekick/themes/ and reference one by name here.
name = "catppuccin-mocha"

[font]
# family: any monospace font installed on your system (free-form string).
family = "Menlo"
# size: integer points.
size = 13
# bold_is_bright: true | false — bold text uses bright palette colors.
bold_is_bright = true

[cursor]
# shape: "block" | "ibeam" | "underline"
shape = "block"
# blink: true | false
blink = true

[window]
# padding: integer pixels of inset around the terminal content.
padding = 8
# opacity: 0.0 (transparent) – 1.0 (opaque). Only visible when enable_blur = true.
opacity = 0.9
# enable_blur: true | false — translucent terminal with desktop blur behind.
enable_blur = true

[behavior]
# scrollback_lines: integer; -1 for unlimited.
scrollback_lines = 10000
# scroll_on_output: true | false — scroll to bottom when new output appears.
scroll_on_output = false
# scroll_on_keystroke: true | false — scroll to bottom when you type.
scroll_on_keystroke = true
# allow_hyperlinks: true | false — clickable URLs.
allow_hyperlinks = true
# mouse_autohide: true | false — hide the mouse cursor while typing.
mouse_autohide = true
# audible_bell: true | false — play a sound on the terminal bell.
audible_bell = false
# restore_session: true | false — restore tabs and working dirs on launch.
restore_session = true

[shell]
# program: shell path (free-form); "" uses the $SHELL environment variable.
program = ""
# args: array of strings passed to the shell, e.g. ["-l"].
args = []
# default_cwd: starting directory (free-form path); "~" expands to home.
default_cwd = "~"

[diff]
# context_lines: integer number of unchanged lines shown around each change.
context_lines = 3

[editor]
# file_open_mode: "terminal" (open files in $EDITOR/nvim in the terminal) |
#   "builtin" (Sidekick's editor pane with syntax highlighting). Unrecognized
#   values fall back to "terminal".
file_open_mode = "terminal"
# word_wrap: true (wrap long lines) | false (horizontal scroll).
word_wrap = true
# font_size: integer points for the built-in editor.
font_size = 13
# font_family: editor font name (free-form); "" uses the system monospace font.
font_family = ""
# show_hidden_files: true | false — show hidden/gitignored files (dimmed).
show_hidden_files = false

[approval]
# mode: whether agents launched in panes prompt before applying file edits.
# Sidekick passes Claude Code's --permission-mode only to claude sessions started
# inside Sidekick (interactive panes via the shell-integration wrapper, launched
# workers via the argv) — it no longer touches global ~/.claude/settings.json, so
# claude run outside Sidekick is unaffected. Applies to the next agent started in a
# pane, not running ones.
#   "ask"    — leave Claude Code's normal per-edit prompting in place (default)
#   "auto"   — --permission-mode acceptEdits: file edits apply without a prompt
#              (risky Bash like `git push` still prompts). Works even on
#              corporate machines that disable bypass mode.
#   "bypass" — --permission-mode bypassPermissions: no prompts at all. Falls back
#              to "acceptEdits" when a managed policy disables bypass mode.
#   A managed/enterprise policy that pins defaultMode wins regardless, so on a
#   fully locked-down machine prompts may remain. Unrecognized values fall back
#   to "ask". Also toggle per session from the menu — View ▸ Auto-approve Agent
#   Edits (⇧⌘A); that turns on "auto" for the session and resets on relaunch.
mode = "ask"
# Glob rules layered on top of `mode`, matched against each edited file path.
# Patterns match anywhere in the path on a "/" boundary unless they start with
# "/" (absolute) or "~". Wildcards: "*" stays within one path segment, "**"
# spans directories, "?" matches one character. Both default to [] (no rules).
#
# auto_allow: approve these silently EVEN WHEN mode = "ask". No effect under
#   "auto" (everything is already auto-approved). Example:
#     auto_allow = ["Sources/**", "docs/**"]
auto_allow = []
# always_ask: ALWAYS show the popup for these, even under "auto" or after an
#   in-popup "Approve & remember" grant. Highest precedence — good for secrets.
#   Example:
#     always_ask = [".env", "**/secrets/**", "*.pem"]
always_ask = []

[telemetry]
# Per-model prices (USD per 1M tokens) for the agents-panel "est $" column.
# Built-in defaults match the current Claude rate card; set entries here only
# to override a price or add a model. Cache reads bill ~0.1x input, 5-min cache
# writes 1.25x, 1-hour writes 2x — derived from the input rate automatically.
# Example:
#   [telemetry.rates."claude-opus-4-8"]
#   input = 5.0
#   output = 25.0
"""

        // Create directory if needed
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? defaultConfig.write(to: url, atomically: true, encoding: .utf8)
    }

    public func save(to path: String = "~/.config/sidekick/config.toml") {
        // Never write defaults back over a file that failed to load — doing so
        // would destroy a config that is merely broken (and recoverable). The
        // original is left untouched, with a copy at config.toml.bak.
        guard !loadDidFail else {
            Log.error("Refusing to save config: the on-disk file failed to load, so writing would clobber it with defaults. Fix or remove ~/.config/sidekick/config.toml (a backup is at config.toml.bak).", category: "config")
            return
        }

        let expandedPath = NSString(string: path).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)
        // Write to the real target when the config is a stowed symlink, so the
        // atomic write doesn't replace the link with a regular file.
        let writeURL = Self.resolvingSymlinkForWrite(fileURL)

        do {
            let encoder = TOMLEncoder()
            let toml = try encoder.encode(self)
            let tomlString = toml.description

            // Create directory if needed
            try FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)

            try tomlString.write(to: writeURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error("Failed to save config: \(error)", category: "config")
        }
    }

    /// If `url` is a symlink (e.g. a dotfile stow-linked into `~/.config`),
    /// returns the link's real target so an atomic write (temp file + rename)
    /// replaces the linked file rather than clobbering the symlink — keeping a
    /// dotfiles/stow setup and its version control intact. Otherwise returns
    /// `url` unchanged. Resolves only the final component, by design: a relative
    /// stow target is resolved against the symlink's own directory.
    static func resolvingSymlinkForWrite(_ url: URL) -> URL {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        if (target as NSString).isAbsolutePath {
            return URL(fileURLWithPath: target).standardizedFileURL
        }
        return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL
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

// MARK: - Approval Configuration
nonisolated public struct ApprovalConfig: Codable, Sendable {
    /// How agents launched in panes prompt before acting:
    /// "ask"    — leave Claude Code's normal per-edit prompting (default).
    /// "auto"   — auto-approve file edits (maps to Claude's `acceptEdits`);
    ///            risky Bash still prompts.
    /// "bypass" — auto-approve everything (maps to Claude's `bypassPermissions`),
    ///            falling back to `acceptEdits` where a managed policy blocks it.
    public var mode: String

    /// Globs whose edits are approved silently even while `mode = "ask"`.
    /// e.g. `["Sources/**"]`. Matched anywhere in the path tree.
    public var autoAllow: [String]

    /// Globs that always show the review panel, even in `mode = "auto"` or
    /// after an "approve & remember" grant. A security override, e.g. `[".env"]`.
    public var alwaysAsk: [String]

    enum CodingKeys: String, CodingKey {
        case mode
        case autoAllow = "auto_allow"
        case alwaysAsk = "always_ask"
    }

    public init() {
        self.mode = "ask"
        self.autoAllow = []
        self.alwaysAsk = []
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? mode
        autoAllow = try container.decodeIfPresent([String].self, forKey: .autoAllow) ?? autoAllow
        alwaysAsk = try container.decodeIfPresent([String].self, forKey: .alwaysAsk) ?? alwaysAsk
    }

    /// True when edits should be approved without a popup — both "auto" and the
    /// broader "bypass" auto-approve edits.
    public var autoApprove: Bool {
        let m = mode.lowercased()
        return m == "auto" || m == "bypass"
    }
}

// MARK: - Telemetry Configuration

/// One model's price, in USD per 1M tokens, as written in `[telemetry.rates]`.
public struct TelemetryRateConfig: Codable {
    public var input: Double
    public var output: Double
}

/// Overrides for the dashboard's est-$ rate card. Anything set here layers over
/// the built-in defaults (current Claude prices), so a price change — or a new
/// model — is a config edit, not a rebuild.
nonisolated public struct TelemetryConfig: Codable, Sendable {
    public var rates: [String: TelemetryRateConfig]

    enum CodingKeys: String, CodingKey {
        case rates
    }

    public init() {
        self.rates = [:]
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rates = try container.decodeIfPresent([String: TelemetryRateConfig].self, forKey: .rates) ?? rates
    }

    /// The effective rate card: configured overrides merged over the built-in
    /// defaults from SidekickTelemetryCore.
    public func resolvedRates() -> [String: TelemetryRate] {
        var resolved = TelemetryRates.defaults
        for (model, rate) in rates {
            resolved[model] = TelemetryRate(inputPerMTok: rate.input, outputPerMTok: rate.output)
        }
        return resolved
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

