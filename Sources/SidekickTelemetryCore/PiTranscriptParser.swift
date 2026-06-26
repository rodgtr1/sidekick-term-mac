import Foundation

/// Parses a Pi session JSONL (`~/.pi/agent/sessions/<project>/*.jsonl`) into the
/// shared `TranscriptUsage`. Pi's schema is the richest of the three: each
/// assistant `message` carries a per-turn `usage` with separate `input`
/// (fresh), `output`, `cacheRead`, `cacheWrite`, and a nested `cost` object Pi
/// computes itself. Usage is per-message, so it sums (like Claude); the summed
/// `cost.total` is carried as `reportedCostUSD`, which the dashboard prefers
/// over the rate card — so a Pi pane shows an accurate $ even though its model
/// isn't in the built-in Claude rate card.
public enum PiTranscriptParser {
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var usage = TranscriptUsage()
        var totalCost = 0.0
        var sawCost = false

        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String
            else { continue }

            // Pi gives tool results their own `toolResult` role, so every
            // `user` message is a genuine prompt (content may be a string or an
            // array of blocks).
            if role == "user" {
                usage.userPrompts += 1
                continue
            }

            guard role == "assistant",
                  let turn = message["usage"] as? [String: Any] else { continue }

            usage.assistantResponses += 1
            if let model = message["model"] as? String { usage.model = model }
            usage.inputTokens += int(turn["input"])           // fresh input (excludes cacheRead)
            usage.outputTokens += int(turn["output"])
            usage.cacheReadTokens += int(turn["cacheRead"])
            usage.cacheCreation5mTokens += int(turn["cacheWrite"])

            if let cost = turn["cost"] as? [String: Any], let total = double(cost["total"]) {
                totalCost += total
                sawCost = true
            }
        }

        if sawCost { usage.reportedCostUSD = totalCost }
        return usage
    }

    /// Aggregates the session file at `path`, or nil if it can't be read.
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return aggregate(jsonl: text)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}
