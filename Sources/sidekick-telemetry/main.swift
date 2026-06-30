import Foundation
import SidekickTelemetryCore
import SidekickIPCCore

// Invoked by an agent's Stop hook. Reads the hook payload on stdin (which carries
// `transcript_path`), aggregates token usage from that transcript via
// SidekickTelemetryCore, and reports it to the running Sidekick app over the IPC
// socket — tagged with `SIDEKICK_PANE_ID`, the pane whose shell the hook ran in
// (the same correlation `sidekick-ctl` uses).
//
// A hook must never disrupt the agent: every failure path exits 0 silently.

@main
struct SidekickTelemetry {
    static func main() {
        guard let paneID = ProcessInfo.processInfo.environment["SIDEKICK_PANE_ID"],
              !paneID.isEmpty else { return }   // not running inside a Sidekick pane

        // The hook passes the agent flavor as its first argument ("codex"); Claude
        // (no argument) is the default. It selects the transcript schema to parse.
        let agent = CommandLine.arguments.dropFirst().first ?? "claude"

        guard let transcriptPath = hookTranscriptPath() else { return }
        let parsed: TranscriptUsage?
        switch agent {
        case "codex": parsed = CodexTranscriptParser.aggregate(contentsOfFile: transcriptPath)
        case "pi":    parsed = PiTranscriptParser.aggregate(contentsOfFile: transcriptPath)
        default:      parsed = TranscriptParser.aggregate(contentsOfFile: transcriptPath)
        }

        guard let usage = parsed,
              usage.assistantResponses > 0,
              let usageData = try? JSONEncoder().encode(usage),
              let usageString = String(data: usageData, encoding: .utf8) else { return }

        SidekickIPCClient().sendFireAndForget(
            ["action": "report_telemetry", "pane_id": paneID, "telemetry": usageString]
        )
    }

    /// Reads the transcript path from the hook payload on stdin. Both Claude and
    /// Codex deliver JSON on stdin; Claude uses `transcript_path`, Codex
    /// `transcript_path` or `agent_transcript_path`. Only read when stdin is a
    /// pipe (never a TTY, which would block an interactive invocation).
    private static func hookTranscriptPath() -> String? {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = (json["transcript_path"] as? String) ?? (json["agent_transcript_path"] as? String)
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }
}
