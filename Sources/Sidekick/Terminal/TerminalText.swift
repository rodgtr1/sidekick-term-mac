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

    /// Keeps the last `lineLimit` newline-delimited lines of `text` (all of it
    /// when `lineLimit` is nil or non-positive). Shared by the pane readers so
    /// line-capping stays identical across visible/recent/delta reads.
    static func lastLines(of text: String, limit lineLimit: Int?) -> String {
        guard let lineLimit, lineLimit > 0 else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineLimit)
            .joined(separator: "\n")
    }

    /// The outcome of a cursor-scoped delta read of a rolling output buffer.
    struct RecentDelta: Equatable {
        let text: String
        let cursor: String
        let truncated: Bool
    }

    /// Computes a cursor-scoped delta of a rolling recent-output buffer. `buffer`
    /// is the current (ANSI-bearing) rolling buffer; `total` is the monotonic
    /// UTF-8 byte count ever appended and `dropped` how many leading bytes the
    /// trim has since evicted, so `dropped + buffer.utf8.count == total`.
    /// `generation` scopes the cursor to the shell's lifetime.
    ///
    /// With no `since`, returns the full (line-capped, ANSI-stripped) buffer and
    /// `truncated: false`. With a `since` cursor, returns only the output after
    /// it. When the cursor names another generation, points before the retained
    /// window, or is unparseable, returns the full buffer with `truncated: true`
    /// so the caller re-syncs — a stale cursor is never an error. Pure so the
    /// cursor math is testable off the AppKit-bound view controller.
    static func recentDelta(
        buffer: String,
        total: Int,
        dropped: Int,
        generation: Int,
        since: String?,
        lineLimit: Int?
    ) -> RecentDelta {
        let cursor = "\(generation):\(total)"
        func full(truncated: Bool) -> RecentDelta {
            RecentDelta(text: lastLines(of: stripANSIEscapes(buffer), limit: lineLimit),
                        cursor: cursor, truncated: truncated)
        }
        guard let since else { return full(truncated: false) }
        guard let offset = parseRecentCursor(since, generation: generation),
              offset >= dropped, offset <= total else {
            return full(truncated: true)
        }
        // `offset` is a byte position recorded as a prior `total`, i.e. the end
        // of an appended chunk and thus a valid UTF-8 scalar boundary. Slice on
        // the UTF-8 view and re-decode so an arbitrary byte offset can't split a
        // codepoint or trap on a grapheme boundary.
        let utf8 = buffer.utf8
        let start = utf8.index(utf8.startIndex, offsetBy: offset - dropped)
        let delta = stripANSIEscapes(String(decoding: utf8[start...], as: UTF8.self))
        return RecentDelta(text: lastLines(of: delta, limit: lineLimit), cursor: cursor, truncated: false)
    }

    /// Parses a `"<generation>:<offset>"` cursor, returning the byte offset only
    /// when the generation half matches `generation` (a cursor from a prior
    /// shell reads as stale). Nil on any mismatch or malformed token.
    static func parseRecentCursor(_ token: String, generation: Int) -> Int? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let tokenGeneration = Int(parts[0]), tokenGeneration == generation,
              let offset = Int(parts[1]), offset >= 0 else { return nil }
        return offset
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
