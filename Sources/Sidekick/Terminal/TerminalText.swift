import Foundation

/// Shared text plumbing for the terminal output pipeline: ANSI/OSC escape
/// stripping and the amortized bounded-append used by every rolling output
/// buffer (automation output, the agent-detection window, command records).
nonisolated enum TerminalText {
    static let ansiEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")

    /// OSC sequences (ESC ] … BEL/ST) — cwd reports, title sets, and Sidekick's
    /// own 7/133/666 marks. Stripped from command records so the captured output
    /// is the command's actual text, not control chatter.
    static let oscEscapeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)")

    static func stripANSIEscapes(_ output: String) -> String {
        guard let regex = ansiEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    static func stripOSCSequences(_ output: String) -> String {
        guard let regex = oscEscapeRegex else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    /// ANSI-stripped, lowercased output for the case-insensitive heuristics.
    static func normalize(_ output: String) -> String {
        stripANSIEscapes(output).lowercased()
    }

    /// Appends `chunk` to a rolling buffer, keeping roughly the last `cap`
    /// characters. The old `buffer = String(buffer.suffix(cap))` reallocated and
    /// copied the whole buffer on *every* output chunk once it reached `cap`.
    /// Here the grapheme-aware trim runs only after the buffer grows a quarter
    /// past `cap`, so under noisy throughput (builds, log tails) it amortizes to
    /// one trim per slack-of-growth instead of one per chunk.
    static func appendBounded(_ chunk: String, to buffer: inout String, cap: Int) {
        buffer += chunk
        // utf8.count is O(1) on Swift's native UTF-8 storage; Character `count`
        // is O(n) grapheme-breaking and ran on every chunk. The bound is
        // approximate ("roughly the last cap chars"), so bytes-vs-graphemes here
        // is fine — the occasional suffix() trim still keeps memory bounded.
        if buffer.utf8.count > cap + cap / 4 {
            buffer = String(buffer.suffix(cap))
        }
    }
}
