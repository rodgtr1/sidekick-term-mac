import Foundation

/// Parses a Codex rollout JSONL (`~/.codex/sessions/Y/M/D/rollout-*.jsonl`) into
/// the shared `TranscriptUsage`. Codex's schema differs from Claude's:
///
///  - the model is on `turn_context.payload.model`;
///  - token usage rides `event_msg` payloads of `type: "token_count"`, whose
///    `info.total_token_usage` is **cumulative**, so the last one is the session
///    total. There `input_tokens` already includes `cached_input_tokens`
///    (OpenAI's cache reads), and `input + output == total`, so reasoning tokens
///    are already inside `output_tokens`. Codex doesn't bill cache writes.
public enum CodexTranscriptParser {
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var usage = TranscriptUsage()
        var latestTotal: [String: Any]?

        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            // The model can change mid-session; keep the most recent.
            if type == "turn_context", let model = payload?["model"] as? String {
                usage.model = model
            }

            guard type == "event_msg", let payload else { continue }
            switch payload["type"] as? String {
            case "user_message":
                usage.userPrompts += 1
            case "token_count":
                usage.assistantResponses += 1
                if let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    latestTotal = total   // cumulative — last wins
                }
            default:
                break
            }
        }

        if let total = latestTotal {
            let input = int(total["input_tokens"])
            let cached = int(total["cached_input_tokens"])
            usage.inputTokens = max(0, input - cached)   // fresh (uncached) input
            usage.cacheReadTokens = cached
            usage.outputTokens = int(total["output_tokens"])
        }
        return usage
    }

    /// Aggregates the rollout file at `path`, or nil if it can't be read.
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return aggregate(jsonl: text)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
