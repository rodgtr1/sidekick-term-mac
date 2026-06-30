import Foundation

/// Live, in-process record of the Claude `--permission-mode` value to apply to
/// `claude` sessions started inside Sidekick — the scoped replacement for the
/// old global `~/.claude/settings.json` write. The window controller keeps this
/// in sync with the effective approval level (persistent `[approval]` mode plus
/// the per-session ⇧⌘A toggle); `TerminalViewController` reads it when building a
/// pane's shell environment, so it only ever affects panes opened afterward —
/// the same "future launches only" semantics the global write had, minus the
/// machine-wide side effect.
///
/// MainActor-isolated (the module default) because both writer and reader live on
/// the main actor.
enum AgentApprovalState {
    static var claudePermissionMode: String?
}
