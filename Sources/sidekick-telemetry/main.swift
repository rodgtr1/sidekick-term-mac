import Foundation
import Darwin
import SidekickTelemetryCore

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
        default:      parsed = TranscriptParser.aggregate(contentsOfFile: transcriptPath)
        }

        guard let usage = parsed,
              usage.assistantResponses > 0,
              let usageData = try? JSONEncoder().encode(usage),
              let usageString = String(data: usageData, encoding: .utf8) else { return }

        let socketPath = ProcessInfo.processInfo.environment["SIDEKICK_SOCKET_PATH"]
            ?? NSString("~/.config/sidekick/sidekick.sock").expandingTildeInPath

        sendReport(
            ["action": "report_telemetry", "pane_id": paneID, "telemetry": usageString],
            socketPath: socketPath
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

    /// Fire-and-forget: connect, write one newline-terminated JSON line, close.
    /// Mirrors sidekick-ctl's IPC connect; we don't need a response.
    private static func sendReport(_ request: [String: Any], socketPath: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8CString.count <= maxPathLength else { return }
        socketPath.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                strncpy(destination, path, maxPathLength - 1)
                destination[maxPathLength - 1] = 0
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              var payload = try? JSONSerialization.data(withJSONObject: request) else { return }
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var remaining = bytes.count
            var cursor = base
            while remaining > 0 {
                let count = write(fd, cursor, remaining)
                guard count > 0 else { return }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
        }
    }
}
