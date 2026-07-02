import Foundation

/// Result of the last finished shell command, reported via OSC 133 marks
/// from the shell integration script.
nonisolated struct TerminalCommandStatus {
    let exitCode: Int
    let duration: TimeInterval?

    var succeeded: Bool { exitCode == 0 }

    var summary: String {
        let outcome = succeeded ? "✓ exit 0" : "✗ exit \(exitCode)"
        guard let duration = duration else { return outcome }
        if duration >= 60 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(outcome) · \(minutes)m \(seconds)s"
        }
        return String(format: "%@ · %.1fs", outcome, duration)
    }
}

/// A finished shell command captured from OSC 133 marks: the command line
/// (carried base64-encoded in the `C` mark by the shell integration), its exit
/// code and duration (from the `D` mark), and the ANSI-stripped output printed
/// between the two marks. Output framing is approximate at the ~100ms
/// detection-coalescing boundary, which is fine for agent legibility.
nonisolated struct TerminalCommandRecord {
    let command: String
    let exitCode: Int
    let duration: TimeInterval?
    let output: String
    let finishedAt: Date
}

/// Captures per-command records from the OSC 133 C..D windows, surfaced by
/// `sidekick-ctl pane read --json` for agent-legible command history.
nonisolated struct CommandRecorder {
    private static let maxCommandRecords = 100
    /// Raw output captured per command is bounded so a runaway log tail can't
    /// grow this pane's memory without limit; the tail is what agents read.
    private static let maxCommandOutputChars = 256_000

    private struct InFlightCommand {
        let command: String
        let startDate: Date
    }
    private var inFlightCommand: InFlightCommand?
    /// Output captured for the in-flight command. Kept as a standalone property
    /// rather than inside `InFlightCommand` so appending doesn't copy the whole
    /// (up to `maxCommandOutputChars`) struct in and out of the Optional on
    /// every output chunk.
    private var inFlightOutput = ""
    private var commandRecords: [TerminalCommandRecord] = []

    /// True between a `C` mark and the matching `D` — a foreground command is
    /// running.
    var isCommandInFlight: Bool { inFlightCommand != nil }

    /// OSC 133 `C`: a command started — begin capturing a new record.
    mutating func commandStarted(command: String, at date: Date = Date()) {
        inFlightCommand = InFlightCommand(command: command, startDate: date)
        inFlightOutput = ""
    }

    /// Accumulates output for the in-flight command (no-op when none is
    /// running). ANSI is stripped at finalize.
    mutating func appendOutput(_ chunk: String) {
        guard inFlightCommand != nil else { return }
        TerminalText.appendBounded(chunk, to: &inFlightOutput, cap: Self.maxCommandOutputChars)
    }

    /// OSC 133 `D`: the command finished. Finalizes the in-flight record (when
    /// a `C` opened one) and returns the status for the delegate — a `D` with
    /// no preceding `C` still yields a status, just with no duration or record.
    mutating func commandFinished(exitCode: Int, at date: Date = Date()) -> TerminalCommandStatus {
        let duration = inFlightCommand.map { date.timeIntervalSince($0.startDate) }
        if let inFlight = inFlightCommand {
            let cleanOutput = TerminalText.stripANSIEscapes(TerminalText.stripOSCSequences(inFlightOutput))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            commandRecords.append(TerminalCommandRecord(
                command: inFlight.command,
                exitCode: exitCode,
                duration: duration,
                output: cleanOutput,
                finishedAt: date
            ))
            if commandRecords.count > Self.maxCommandRecords {
                commandRecords.removeFirst(commandRecords.count - Self.maxCommandRecords)
            }
        }
        inFlightCommand = nil
        inFlightOutput = ""
        return TerminalCommandStatus(exitCode: exitCode, duration: duration)
    }

    /// The most recently finished commands (oldest first), capped to `limit`
    /// when given.
    func recentRecords(limit: Int? = nil) -> [TerminalCommandRecord] {
        guard let limit, limit > 0 else { return commandRecords }
        return Array(commandRecords.suffix(limit))
    }
}
