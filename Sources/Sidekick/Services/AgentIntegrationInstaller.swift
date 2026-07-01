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
            guard settings.contains("sidekick-agent-status") else { return .available }
            // A pre-PermissionRequest install lacks the needs-input hook; prompt
            // a reinstall so addClaudeHook idempotently adds it.
            guard settings.contains("PermissionRequest") else { return .available }
            // A pre-SessionStart telemetry install keeps a stale context meter
            // after /clear; prompt a reinstall so the reset hook gets added.
            if isTelemetryHelperBundled, !settings.contains("SessionStart") { return .available }
            return telemetryFullyInstalled(in: settings) ? .installed : .available
        case .codex:
            guard directoryExists(home.appendingPathComponent(".codex")) else { return .notDetected }
            guard helperURL(named: "sidekick-agent-status") != nil else { return .helperMissing }
            let config = (try? String(
                contentsOf: home.appendingPathComponent(".codex/config.toml"),
                encoding: .utf8
            )) ?? ""
            guard config.contains("sidekick-agent-status") else { return .available }
            return telemetryFullyInstalled(in: config) ? .installed : .available
        case .pi:
            guard directoryExists(home.appendingPathComponent(".pi/agent")) else { return .notDetected }
            let extensionURL = home.appendingPathComponent(".pi/agent/extensions/sidekick-status.ts")
            guard let ext = try? String(contentsOf: extensionURL, encoding: .utf8) else { return .available }
            // The telemetry-enabled extension defines reportTelemetry.
            if isTelemetryHelperBundled, !ext.contains("reportTelemetry") { return .available }
            return .installed
        }
    }

    /// Whether the telemetry helper is bundled and thus expected in a fully
    /// installed integration. When it isn't (a build without the helper), the
    /// status shouldn't perpetually read "available".
    private static var isTelemetryHelperBundled: Bool {
        helperURL(named: "sidekick-telemetry") != nil
    }

    /// True when an integration that has the status hook is also wired for
    /// telemetry — i.e. the config already references `sidekick-telemetry`, or
    /// the helper isn't bundled to install one. Drives the reinstall prompt when
    /// a pre-telemetry integration is detected.
    private static func telemetryFullyInstalled(in config: String) -> Bool {
        !isTelemetryHelperBundled || config.contains("sidekick-telemetry")
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
        ("Stop", "done")
    ]

    /// Claude-only refinements (Codex doesn't expose these events).
    private static let claudeOnlyStatusHooks: [(event: String, state: String)] = [
        // PermissionRequest fires the instant an interactive permission prompt
        // is waiting on the user — the correct "needs input" signal. (An earlier
        // version wrongly believed Claude Code had no such event and removed it;
        // it does, and is the only hook that fires for an inline prompt.)
        ("PermissionRequest", "ready"),
        // Notification is kept as a secondary trigger for the idle/gated case;
        // the helper suppresses its "waiting for your input" idle reminder.
        ("Notification", "ready"),
        ("PreToolUse", "busy"),     // tool about to run (overridden by ready if it prompts)
        ("SessionEnd", "idle")      // clears the tab from the agents panel
    ]

    /// Ready hook for Codex, whose permission event isn't the shared trio.
    private static let codexOnlyStatusHooks: [(event: String, state: String)] = [
        ("PermissionRequest", "ready")
    ]

    /// Claude Code's auto-approve-edits permission mode: silences the prompt for
    /// file Edit/Write/MultiEdit while still asking for risky Bash, and — unlike
    /// `bypassPermissions` — is not blocked by a corporate
    /// `disableBypassPermissionsMode` policy, so it keeps working on locked-down
    /// machines. Also the fallback when bypass is requested but disabled.
    static let autoApproveMode = "acceptEdits"

    /// Claude Code's "no prompts at all" permission mode.
    static let bypassMode = "bypassPermissions"

    /// The defaultMode values Sidekick manages. On returning to "ask" we clear
    /// only these, leaving a user's own pick (e.g. "plan") intact.
    static let managedModes: Set<String> = [autoApproveMode, bypassMode]

    /// The `--permission-mode` value to apply to `claude` sessions launched from
    /// within Sidekick, or `nil` for normal prompting. This is the *scoped*
    /// replacement for writing `permissions.defaultMode` globally: Sidekick passes
    /// it per-session (env var + shell wrapper for interactive panes, argv flag for
    /// Sidekick-launched workers) so it never affects `claude` run outside Sidekick.
    ///
    /// When `bypassPermissions` is requested but a managed/enterprise policy
    /// disables it, falls back to `acceptEdits` so a locked-down machine still gets
    /// the strongest available silencing instead of a rejected launch.
    static func claudePermissionMode(forApprovalMode mode: String) -> String? {
        guard let target = claudeMode(forApprovalMode: mode) else { return nil }
        if target == bypassMode, managedBypassDisabled() {
            return autoApproveMode
        }
        return target
    }

    /// Removes any Sidekick-managed `permissions.defaultMode` (acceptEdits /
    /// bypassPermissions) left in the global `~/.claude/settings.json` by older
    /// versions, which disabled prompts for *every* `claude` session machine-wide.
    /// Permission mode is now scoped to Sidekick sessions via `claudePermissionMode`,
    /// so this just migrates old global state back to clean. A user's own,
    /// unmanaged pick (e.g. "plan") is left intact. No-ops when Claude isn't present.
    static func clearManagedClaudeDefaultMode() throws {
        guard directoryExists(home.appendingPathComponent(".claude")) else { return }

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.message("~/.claude/settings.json is not a JSON object.")
            }
            settings = parsed
        }

        // Nothing managed to clear.
        guard applyAutoApproveMode(to: &settings, desiredMode: nil) else { return }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Pure core of `syncClaudeAutoApprove`: mutates a parsed settings dict to
    /// the `desired` defaultMode (`nil` clears it) and returns whether anything
    /// changed, so callers can skip a needless rewrite. Internal for tests.
    static func applyAutoApproveMode(to settings: inout [String: Any], desiredMode desired: String?) -> Bool {
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        let current = permissions["defaultMode"] as? String

        if let desired {
            // acceptEdits is satisfied by the broader bypass too — don't downgrade.
            if desired == autoApproveMode, current == autoApproveMode || current == bypassMode {
                return false
            }
            if current == desired { return false }
            permissions["defaultMode"] = desired
        } else {
            // Restoring prompting: clear only a mode we manage.
            guard let current, managedModes.contains(current) else { return false }
            permissions.removeValue(forKey: "defaultMode")
        }

        if permissions.isEmpty {
            settings.removeValue(forKey: "permissions")
        } else {
            settings["permissions"] = permissions
        }
        return true
    }

    /// Whether a managed (enterprise) settings file disables `bypassPermissions`.
    /// macOS reads `/Library/Application Support/ClaudeCode/managed-settings.json`;
    /// when its `permissions.disableBypassPermissionsMode` is `"disable"`, writing
    /// bypass to the user file would be rejected, so we fall back to acceptEdits.
    private static func managedBypassDisabled() -> Bool {
        let url = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = parsed["permissions"] as? [String: Any] else {
            return false
        }
        return (permissions["disableBypassPermissionsMode"] as? String) == "disable"
    }

    /// Maps a Sidekick approval level ("ask"/"auto"/"bypass") to the Claude Code
    /// `permissions.defaultMode`, or `nil` for normal prompting. Centralizes the
    /// agent-specific mapping so callers only deal in the abstract level.
    static func claudeMode(forApprovalMode mode: String) -> String? {
        switch mode.lowercased() {
        case "auto": return autoApproveMode
        case "bypass": return bypassMode
        default: return nil
        }
    }

    // MARK: - Codex auto-approve

    /// Reflects a Sidekick approval level into Codex's own config by writing the
    /// top-level `approval_policy` + `sandbox_mode` keys in `~/.codex/config.toml`.
    /// Codex re-reads the file per launch, so this affects the next `codex`
    /// started in a pane — the same model as the Claude path.
    ///
    /// Codex has no exact `acceptEdits` analog: its "auto" safety comes from the
    /// sandbox (edits confined to the workspace), not per-command gating. Mapping:
    ///   - "auto":   sandbox `workspace-write` + approval `on-request` (= --full-auto)
    ///   - "bypass": sandbox `danger-full-access` + approval `never` (= --yolo)
    ///   - "ask":    remove the keys we manage, restoring Codex's own behavior.
    ///
    /// No-ops when Codex isn't present. A managed `requirements.toml` policy that
    /// disallows a value makes Codex silently downgrade to a permitted one and
    /// notify the user, so locked-down machines degrade gracefully on their own.
    static func syncCodexAutoApprove(forMode mode: String) throws {
        guard directoryExists(home.appendingPathComponent(".codex")) else { return }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = applyCodexAutoApprove(to: original, mode: mode)
        guard updated != original else { return }

        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Codex (sandbox_mode, approval_policy) pairs Sidekick writes per level.
    private static let codexAutoSettings = (sandbox: "workspace-write", approval: "on-request")
    private static let codexBypassSettings = (sandbox: "danger-full-access", approval: "never")

    /// Pure core of `syncCodexAutoApprove`: returns the config text with our two
    /// keys set (auto/bypass) or removed (ask). Internal for tests.
    static func applyCodexAutoApprove(to config: String, mode: String) -> String {
        switch mode.lowercased() {
        case "auto":
            return setCodexKeys(in: config, codexAutoSettings)
        case "bypass":
            return setCodexKeys(in: config, codexBypassSettings)
        default:
            // Restore Codex's own behavior — but only undo a combo we'd have set,
            // leaving a user's hand-picked policy intact.
            guard codexHasManagedAutoApprove(config) else { return config }
            var c = removeCodexTopLevelKey(in: config, key: "sandbox_mode")
            c = removeCodexTopLevelKey(in: c, key: "approval_policy")
            return c
        }
    }

    private static func setCodexKeys(in config: String, _ settings: (sandbox: String, approval: String)) -> String {
        var c = setCodexTopLevelKey(in: config, key: "sandbox_mode", value: "\"\(settings.sandbox)\"")
        c = setCodexTopLevelKey(in: c, key: "approval_policy", value: "\"\(settings.approval)\"")
        return c
    }

    /// True when the current top-level keys match one of the combos we set, so
    /// "ask" knows it's safe to clear them.
    static func codexHasManagedAutoApprove(_ config: String) -> Bool {
        let sandbox = codexTopLevelValue(in: config, key: "sandbox_mode")
        let approval = codexTopLevelValue(in: config, key: "approval_policy")
        return (sandbox == codexAutoSettings.sandbox && approval == codexAutoSettings.approval)
            || (sandbox == codexBypassSettings.sandbox && approval == codexBypassSettings.approval)
    }

    /// Index of the first TOML table header (`[...]`), before which top-level
    /// keys must live. Returns the line count when there's no table.
    private static func firstCodexTableIndex(_ lines: [String]) -> Int {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
    }

    private static func lineDefinesKey(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=")
    }

    /// Sets a top-level scalar `key = value` (value written verbatim, already
    /// quoted), replacing an existing top-level occurrence or inserting at the
    /// top so it stays ahead of every table header. Internal for tests.
    static func setCodexTopLevelKey(in config: String, key: String, value: String) -> String {
        var lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        for index in 0..<firstTable where lineDefinesKey(lines[index], key) {
            lines[index] = "\(key) = \(value)"
            return lines.joined(separator: "\n")
        }
        lines.insert("\(key) = \(value)", at: 0)
        return lines.joined(separator: "\n")
    }

    /// Removes a top-level scalar `key` (occurrences before the first table).
    /// Internal for tests.
    static func removeCodexTopLevelKey(in config: String, key: String) -> String {
        let lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        let kept = lines.enumerated().filter { index, line in
            !(index < firstTable && lineDefinesKey(line, key))
        }.map(\.element)
        return kept.joined(separator: "\n")
    }

    /// The unquoted value of a top-level scalar `key`, or nil when absent.
    private static func codexTopLevelValue(in config: String, key: String) -> String? {
        let lines = config.components(separatedBy: "\n")
        let firstTable = firstCodexTableIndex(lines)
        for index in 0..<firstTable where lineDefinesKey(lines[index], key) {
            guard let eq = lines[index].firstIndex(of: "=") else { continue }
            return lines[index][lines[index].index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

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
        // Telemetry (Claude-first): a second Stop hook reports per-pane token
        // usage to the dashboard. Best-effort — registered only when the helper
        // is bundled; it dedups against the status Stop hook by binary name.
        if let telemetryBinary = helperURL(named: "sidekick-telemetry") {
            addClaudeHook(to: &hooks, event: "Stop", command: telemetryBinary.path)
            // SessionStart (startup, /clear, resume) re-reports or resets the
            // pane's telemetry so the context meter doesn't keep showing the
            // previous session until the new one finishes a turn.
            addClaudeHook(to: &hooks, event: "SessionStart", command: telemetryBinary.path)
        }
        // The sidekick-hook PreToolUse diff popup duplicated Claude Code's own
        // approval prompt (the hook never emitted a permission decision, so the
        // harness still asked), so it's no longer installed. Strip any copy a
        // previous version left behind.
        removeClaudeHook(from: &hooks, event: "PreToolUse", signature: "sidekick-hook")
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
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

    /// Removes any hook group under `event` that invokes a command whose path
    /// ends in `signature` (the binary name), dropping groups left empty. Used
    /// to retire integrations a previous install added. Internal for tests.
    static func removeClaudeHook(
        from hooks: inout [String: Any],
        event: String,
        signature: String
    ) {
        guard var groups = hooks[event] as? [[String: Any]] else { return }

        groups = groups.compactMap { group in
            let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { hook in
                guard let command = hook["command"] as? String else { return true }
                let name = command.split(separator: " ").first.map(String.init) ?? command
                return !(name == signature || name.hasSuffix("/\(signature)"))
            }
            if kept.isEmpty { return nil }
            var updated = group
            updated["hooks"] = kept
            return updated
        }

        if groups.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = groups
        }
    }

    private static func installCodex() throws {
        guard let statusBinary = helperURL(named: "sidekick-agent-status") else {
            throw InstallError.helperMissing
        }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        config = ensureCodexHooksEnabled(in: config)

        for (event, state) in statusHooks + codexOnlyStatusHooks {
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

        // Telemetry: a Stop hook reporting per-pane token usage, parsing Codex's
        // rollout schema (hence the "codex" argument). Best-effort, dedup by the
        // helper name + flavor.
        if let telemetryBinary = helperURL(named: "sidekick-telemetry"),
           !config.contains("sidekick-telemetry codex") {
            let command = "\(telemetryBinary.path) codex"
            config = config.trimmingTrailingNewlines() + """


            [[hooks.Stop]]
            [[hooks.Stop.hooks]]
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
        // Embed the absolute telemetry-helper path (best-effort: empty when the
        // helper isn't bundled, in which case the extension skips telemetry).
        let telemetryPath = helperURL(named: "sidekick-telemetry")?.path ?? ""
        let escaped = telemetryPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = piExtensionSource.replacingOccurrences(
            of: "__SIDEKICK_TELEMETRY_BIN__", with: escaped
        )
        try source.write(
            to: extensionsDirectory.appendingPathComponent("sidekick-status.ts"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Pi status + telemetry extension. Mirror of scripts/pi-sidekick-status.ts —
    /// embedded like ShellIntegration's scripts so the app needs no source
    /// checkout. `__SIDEKICK_TELEMETRY_BIN__` is replaced at install time with the
    /// absolute sidekick-telemetry path (or "" to disable telemetry).
    private static let piExtensionSource = #"""
    // Sidekick agent-status + telemetry extension for the Pi coding agent.
    //
    // Reports Pi's lifecycle to Sidekick's agents panel using the same OSC 666
    // termprop sequence that sidekick-agent-status emits for Claude Code/Codex
    // hooks, and on each turn end hands Pi's session transcript to
    // sidekick-telemetry for the token/cost dashboard. Installed by Sidekick
    // (Preferences -> Agents).
    //
    // Mapping:
    //   agent_start            -> busy  (working on a prompt)
    //   agent_end              -> done  (back at the input prompt) + telemetry
    //   session_shutdown(quit) -> idle  (removed from the agents panel)
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { closeSync, openSync, writeSync } from "node:fs";
    import { spawn } from "node:child_process";

    const TERMPROP = "vte.ext.sidekick.agent";
    const TELEMETRY_BIN = "__SIDEKICK_TELEMETRY_BIN__";

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

    // Best-effort: hand the session transcript to sidekick-telemetry, tagged via
    // the SIDEKICK_PANE_ID the helper reads from the inherited environment. Never
    // throws into Pi.
    function reportTelemetry(sessionFile: string | undefined): void {
      if (!TELEMETRY_BIN || !sessionFile || !process.env.SIDEKICK_PANE_ID) return;
      try {
        const child = spawn(TELEMETRY_BIN, ["pi"], {
          stdio: ["pipe", "ignore", "ignore"],
          env: process.env,
        });
        child.on("error", () => {});
        child.stdin.write(JSON.stringify({ transcript_path: sessionFile }));
        child.stdin.end();
      } catch {
        // ignore
      }
    }

    export default function (pi: ExtensionAPI) {
      pi.on("agent_start", async () => report("busy"));
      pi.on("agent_end", async (_event, ctx) => {
        report("done");
        try {
          reportTelemetry(ctx.sessionManager.getSessionFile());
        } catch {
          // ignore
        }
      });
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
