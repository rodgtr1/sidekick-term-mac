import Foundation

/// Live, in-process record of the per-agent approval flags to apply to `claude`
/// and `codex` sessions started inside Sidekick — the scoped replacement for the
/// old global `~/.claude/settings.json` and `~/.codex/config.toml` writes. The
/// window controller keeps these in sync with the effective approval level
/// (persistent `[approval]` mode plus the per-session ⇧⌘A toggle);
/// `TerminalViewController` reads them when building a pane's shell environment,
/// so they only ever affect panes opened afterward — the same "future launches
/// only" semantics the global writes had, minus the machine-wide side effect.
///
/// MainActor-isolated (the module default) because both writer and reader live on
/// the main actor.
enum AgentApprovalState {
    /// The `--permission-mode` value for Sidekick-launched `claude` sessions,
    /// or `nil` for normal prompting.
    static var claudePermissionMode: String?

    /// The approval/sandbox flags (e.g. `--sandbox … --ask-for-approval …`) for
    /// Sidekick-launched `codex` sessions, or `[]` for normal prompting.
    static var codexApprovalArgs: [String] = []
}
