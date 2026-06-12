import Foundation

/// Detects installed agent CLIs (Claude Code, Codex, Pi) and wires their
/// hook/extension systems to report status to Sidekick's agents panel.
///
/// Unlike scripts/install-agent-status-hooks (the from-source dev installer),
/// this uses the helper binaries shipped inside the app bundle, so it works
/// on machines that never had the source tree. Safe to run repeatedly — every
/// step is idempotent and existing user configuration is preserved.
enum AgentIntegrationInstaller {
    enum AgentID: CaseIterable {
        case claude
        case codex
        case pi

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .pi: return "Pi"
            }
        }
    }

    enum Status {
        case notDetected       // agent has never run on this machine
        case available         // detected, integration not installed
        case installed
        case helperMissing     // bundled helper binaries not found

        var description: String {
            switch self {
            case .notDetected: return "Not detected on this Mac."
            case .available: return "Detected — integration not installed."
            case .installed: return "Integration installed."
            case .helperMissing: return "Helper binaries missing from the app bundle."
            }
        }
    }

    enum InstallError: LocalizedError {
        case helperMissing
        case message(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "sidekick-agent-status was not found next to the app executable."
            case .message(let text):
                return text
            }
        }
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// The helper CLIs live alongside the main executable, both in the app
    /// bundle (Contents/MacOS) and in SwiftPM build output (.build/<config>).
    private static func helperURL(named name: String) -> URL? {
        guard let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent() else { return nil }
        let url = executableDirectory.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Detection

    static func status(of agent: AgentID) -> Status {
        switch agent {
        case .claude:
            guard directoryExists(home.appendingPathComponent(".claude")) else { return .notDetected }
            guard helperURL(named: "sidekick-agent-status") != nil else { return .helperMissing }
            let settings = (try? String(
                contentsOf: home.appendingPathComponent(".claude/settings.json"),
                encoding: .utf8
            )) ?? ""
            return settings.contains("sidekick-agent-status") ? .installed : .available
        case .codex:
            guard directoryExists(home.appendingPathComponent(".codex")) else { return .notDetected }
            guard helperURL(named: "sidekick-agent-status") != nil else { return .helperMissing }
            let config = (try? String(
                contentsOf: home.appendingPathComponent(".codex/config.toml"),
                encoding: .utf8
            )) ?? ""
            return config.contains("sidekick-agent-status") ? .installed : .available
        case .pi:
            guard directoryExists(home.appendingPathComponent(".pi/agent")) else { return .notDetected }
            let extensionURL = home.appendingPathComponent(".pi/agent/extensions/sidekick-status.ts")
            return FileManager.default.fileExists(atPath: extensionURL.path) ? .installed : .available
        }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Install

    static func install(_ agent: AgentID) throws {
        switch agent {
        case .claude: try installClaude()
        case .codex: try installCodex()
        case .pi: try installPi()
        }
    }

    /// Hook events shared by the Claude and Codex integrations.
    private static let statusHooks: [(event: String, state: String)] = [
        ("UserPromptSubmit", "busy"),
        ("PermissionRequest", "ready"),
        ("Stop", "done")
    ]

    /// Claude-only refinements (Codex doesn't expose these events).
    private static let claudeOnlyStatusHooks: [(event: String, state: String)] = [
        ("PreToolUse", "busy"),     // approved tool starts running
        ("SessionEnd", "idle")      // clears the tab from the agents panel
    ]

    private static func installClaude() throws {
        guard let statusBinary = helperURL(named: "sidekick-agent-status") else {
            throw InstallError.helperMissing
        }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.message("~/.claude/settings.json is not a JSON object.")
            }
            settings = parsed
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, state) in statusHooks + claudeOnlyStatusHooks {
            addClaudeHook(to: &hooks, event: event, command: "\(statusBinary.path) \(state)")
        }
        if let hookBinary = helperURL(named: "sidekick-hook") {
            // Edit review: shows Write/Edit diffs in Sidekick before they apply.
            addClaudeHook(
                to: &hooks,
                event: "PreToolUse",
                command: hookBinary.path,
                matcher: "Write|Edit|MultiEdit"
            )
        }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL)
    }

    /// Appends a command hook group for `event` unless an equivalent hook is
    /// already registered (matched by binary name + argument, so an existing
    /// from-source install at another path counts). Internal for tests.
    static func addClaudeHook(
        to hooks: inout [String: Any],
        event: String,
        command: String,
        matcher: String? = nil
    ) {
        var groups = hooks[event] as? [[String: Any]] ?? []
        let signature = command.components(separatedBy: "/").last ?? command

        for group in groups {
            for hook in group["hooks"] as? [[String: Any]] ?? [] {
                guard let existing = hook["command"] as? String else { continue }
                if existing == command || existing.hasSuffix(signature) {
                    return
                }
            }
        }

        var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
        if let matcher = matcher {
            group["matcher"] = matcher
        }
        groups.append(group)
        hooks[event] = groups
    }

    private static func installCodex() throws {
        guard let statusBinary = helperURL(named: "sidekick-agent-status") else {
            throw InstallError.helperMissing
        }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        config = ensureCodexHooksEnabled(in: config)

        for (event, state) in statusHooks {
            let signature = "sidekick-agent-status \(state)"
            if config.contains(signature) && config.contains("[[hooks.\(event)]]") {
                continue
            }
            let command = "\(statusBinary.path) \(state)"
            config = config.trimmingTrailingNewlines() + """


            [[hooks.\(event)]]
            [[hooks.\(event).hooks]]
            type = "command"
            command = \(tomlString(command))

            """
        }

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Makes sure config.toml has `hooks = true` under `[features]`, adding
    /// either or both without disturbing the rest of the file. Internal for
    /// tests.
    static func ensureCodexHooksEnabled(in config: String) -> String {
        var lines = config.components(separatedBy: "\n")

        guard let featuresIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) else {
            // No [features] table: add one ahead of the first table so any
            // top-level keys above it stay top-level.
            let block = ["[features]", "hooks = true", ""]
            if let firstTable = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) {
                lines.insert(contentsOf: block, at: firstTable)
            } else {
                lines.append(contentsOf: block)
            }
            return lines.joined(separator: "\n")
        }

        // Section runs until the next table header.
        var sectionEnd = lines.count
        for index in (featuresIndex + 1)..<lines.count
        where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            sectionEnd = index
            break
        }

        for index in (featuresIndex + 1)..<sectionEnd {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("hooks") {
                lines[index] = "hooks = true"
                return lines.joined(separator: "\n")
            }
        }

        lines.insert("hooks = true", at: featuresIndex + 1)
        return lines.joined(separator: "\n")
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func installPi() throws {
        let extensionsDirectory = home.appendingPathComponent(".pi/agent/extensions")
        try FileManager.default.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        try piExtensionSource.write(
            to: extensionsDirectory.appendingPathComponent("sidekick-status.ts"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Pi status extension. Mirror of scripts/pi-sidekick-status.ts — embedded
    /// like ShellIntegration's scripts so the app needs no source checkout.
    private static let piExtensionSource = #"""
    // Sidekick agent-status extension for the Pi coding agent.
    //
    // Reports Pi's lifecycle to Sidekick's agents panel using the same OSC 666
    // termprop sequence that sidekick-agent-status emits for Claude Code/Codex
    // hooks. Installed by Sidekick (Preferences -> Agents).
    //
    // Mapping:
    //   agent_start            -> busy  (working on a prompt)
    //   agent_end              -> done  (back at the input prompt)
    //   session_shutdown(quit) -> idle  (removed from the agents panel)
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { closeSync, openSync, writeSync } from "node:fs";

    const TERMPROP = "vte.ext.sidekick.agent";

    function report(status: "busy" | "ready" | "done" | "idle"): void {
      try {
        const fd = openSync("/dev/tty", "w");
        try {
          writeSync(fd, `\x1b]666;${TERMPROP}=${status}\x1b\\`);
        } finally {
          closeSync(fd);
        }
      } catch {
        // No controlling terminal (print/RPC mode) — nothing to report to.
      }
    }

    export default function (pi: ExtensionAPI) {
      pi.on("agent_start", async () => report("busy"));
      pi.on("agent_end", async () => report("done"));
      pi.on("session_shutdown", async (event) => {
        if (event.reason === "quit") {
          report("idle");
        }
      });
    }
    """#
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var result = self
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }
}
