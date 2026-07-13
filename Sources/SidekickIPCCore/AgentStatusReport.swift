import Foundation

/// How an agent's hook reports a status change to Sidekick.
///
/// The original transport was an OSC 666 escape written to `/dev/tty`, which the
/// pane's terminal picks out of the output stream. That works from anything with
/// a controlling terminal — the shell integration, a pane's own shell, an agent
/// that runs its hooks as ordinary children.
///
/// It does not work from Claude Code, whose hook processes are spawned detached
/// from the controlling terminal: opening `/dev/tty` there fails with ENXIO
/// ("device not configured"), so every report was written nowhere and the pane
/// sat at `idle` for the entire run. Those processes *can* still reach Sidekick's
/// control socket (the telemetry hook already does), and they inherit
/// `SIDEKICK_PANE_ID` from the pane's environment, so the report is addressed to
/// the pane directly instead of riding its output stream.
///
/// Both transports land in the same place — the pane's `AgentStateDetector`,
/// marked hook-authoritative — so a report is delivered exactly once, by whichever
/// route is open.
public enum AgentStatusReport {
    /// The terminal property the OSC 666 sequence carries.
    public static let termprop = "vte.ext.sidekick.agent"

    /// The four statuses a hook may report. The raw values are what both
    /// transports put on the wire, and what `AgentStateDetector` parses.
    public enum Status: String, Sendable, CaseIterable {
        case busy, ready, done, idle
    }

    /// Normalizes a hook's status argument. The aliases match the ones
    /// `AgentStateDetector.state(fromStatus:)` accepts, so a config written
    /// against either vocabulary keeps working.
    public static func status(fromArgument argument: String?) -> Status? {
        switch argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy", "working", "running": return .busy
        case "ready", "prompt", "waiting", "needs-user", "needs_user": return .ready
        case "done", "finished", "complete": return .done
        case "idle", "clear", "reset": return .idle
        default: return nil
        }
    }

    /// Claude Code's Notification hook fires both for genuine permission requests
    /// ("Claude needs your permission to use Bash") and for the idle reminder
    /// ("Claude is waiting for your input") that arrives ~60s after a turn ends.
    /// The reminder must not flip a finished agent back to "Needs input", so a
    /// `ready` carrying it is dropped — leaving the pane in whatever state the
    /// Stop hook last set.
    public static func isIdleReminder(status: Status, hookMessage: String?) -> Bool {
        guard status == .ready, let hookMessage else { return false }
        return hookMessage.lowercased().contains("waiting for your input")
    }

    /// The OSC 666 sequence for `status` — the in-band transport.
    public static func escapeSequence(for status: Status) -> String {
        "\u{001B}]666;\(termprop)=\(status.rawValue)\u{001B}\\"
    }

    /// The pane-addressed IPC command for `status` — the out-of-band transport,
    /// used when the hook has no controlling terminal to write the escape to.
    public static func ipcCommand(status: Status, paneID: String) -> [String: Any] {
        ["action": "agent_status", "pane_id": paneID, "status": status.rawValue]
    }
}
