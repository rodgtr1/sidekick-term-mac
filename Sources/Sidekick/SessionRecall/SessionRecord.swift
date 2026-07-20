import Foundation

/// Which agent CLI produced a session log.
nonisolated enum SessionAgent: String, Codable, Sendable {
    case claude
    case codex
}

/// One past agent session, unified across Claude Code and Codex CLI logs.
///
/// This is a pure value type produced by `SessionLogScanner` off the main
/// thread, so it is explicitly `nonisolated`/`Sendable` even though the
/// `Sidekick` module defaults to `@MainActor` (see `Package.swift`
/// `.defaultIsolation(MainActor.self)`).
///
/// `Codable` so `SessionRecallCache` can persist records to (and reload them
/// from) an on-disk JSON cache without re-parsing every log file.
nonisolated struct SessionRecord: Codable, Sendable, Equatable {
    /// The agent CLI that wrote the log.
    let agent: SessionAgent
    /// The session's working directory, taken ONLY from an in-record field.
    /// Nil when the log never recorded it — the encoded project dir name is a
    /// lossy source (`/`→`-`) and is never decoded back into a cwd.
    let cwd: String?
    /// Last path component of `cwd`, or nil when `cwd` is nil.
    let repo: String?
    /// The agent's own session identifier (Claude filename stem; Codex
    /// `session_id`). Falls back to `resumeID` for Codex when absent.
    let sessionID: String
    /// The id used to resume the session (`claude --resume <id>` /
    /// `codex resume <id>`). For Codex this is the rollout uuid.
    let resumeID: String
    /// Session start time, preferring the in-record/session_meta timestamp.
    let timestamp: Date?
    /// The first genuine human prompt (wrapper/injected text skipped),
    /// whitespace-collapsed and truncated to 100 chars, or "(no prompt found)".
    let title: String
    /// Claude's own generated title (`ai-title` line), when present. Always
    /// nil for Codex.
    let aiTitle: String?
    /// A ready-to-run shell command that resumes the session, prefixed with a
    /// `cd <cwd>` only when the cwd is known.
    let resumeCommand: String
    /// Absolute path to the source log file.
    let logPath: String

    /// The bare ARGV that resumes this session, for launching a process
    /// directly (a new tab's `command:`) rather than pasting a shell string.
    /// Unlike `resumeCommand`, it carries no `cd` prefix — the cwd is supplied
    /// out of band via the tab's working directory. The verb differs by agent:
    /// Claude uses `--resume`, Codex uses a `resume` subcommand.
    ///
    /// `nonisolated` (inherited from the type) so it is safe to read off the
    /// main thread; it is the correctness-critical bit and is unit-tested.
    var resumeArgv: [String] {
        switch agent {
        case .claude: return ["claude", "--resume", resumeID]
        case .codex: return ["codex", "resume", resumeID]
        }
    }
}
