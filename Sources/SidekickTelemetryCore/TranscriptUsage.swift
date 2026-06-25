import Foundation

/// Token usage aggregated from a Claude Code transcript JSONL — the raw material
/// for the per-pane telemetry dashboard. Counts are summed across the session's
/// billed assistant responses; `model` is the most recent assistant model seen.
///
/// Pure value type with no AppKit dependency, so it is shared by the
/// `sidekick-telemetry` helper (which parses the transcript off the agent
/// process) and the app (which prices and renders it).
public struct TranscriptUsage: Equatable, Codable {
    /// Most recent assistant model id (e.g. `claude-opus-4-8`), or nil if the
    /// transcript had no billed assistant response.
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreation5mTokens: Int
    public var cacheCreation1hTokens: Int
    /// Billed model responses (assistant lines carrying a `usage` block).
    public var assistantResponses: Int
    /// Typed user prompts (user lines whose content is a plain string, i.e. not
    /// a tool-result array). The dashboard surfaces this as "turns".
    public var userPrompts: Int

    public init(
        model: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        assistantResponses: Int = 0,
        userPrompts: Int = 0
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.assistantResponses = assistantResponses
        self.userPrompts = userPrompts
    }

    /// All cache-creation (cache-write) tokens, 5-minute + 1-hour.
    public var cacheCreationTokens: Int { cacheCreation5mTokens + cacheCreation1hTokens }

    /// Total input-side tokens the user might think of as "in" (fresh input +
    /// cache writes + cache reads).
    public var totalInputTokens: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }
}

public enum TranscriptParser {
    /// Aggregates usage from newline-delimited transcript JSON. Tolerant by
    /// design: non-message lines (`mode`, `system`, `attachment`, …) and any
    /// malformed line are skipped rather than failing the whole parse, since a
    /// live transcript is appended to while we read it.
    public static func aggregate<S: StringProtocol>(jsonl: S) -> TranscriptUsage {
        var usage = TranscriptUsage()
        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = object["type"] as? String
            let message = object["message"] as? [String: Any]

            // A typed prompt: a user line whose content is a plain string. Array
            // content is a tool-result turn, which we don't count as a prompt.
            if type == "user", message?["content"] is String {
                usage.userPrompts += 1
                continue
            }

            guard type == "assistant",
                  let message,
                  let usageObject = message["usage"] as? [String: Any] else { continue }

            usage.assistantResponses += 1
            if let model = message["model"] as? String { usage.model = model }
            usage.inputTokens += int(usageObject["input_tokens"])
            usage.outputTokens += int(usageObject["output_tokens"])
            usage.cacheReadTokens += int(usageObject["cache_read_input_tokens"])

            if let cacheCreation = usageObject["cache_creation"] as? [String: Any] {
                usage.cacheCreation5mTokens += int(cacheCreation["ephemeral_5m_input_tokens"])
                usage.cacheCreation1hTokens += int(cacheCreation["ephemeral_1h_input_tokens"])
            } else {
                // Older transcripts only carry the flat total; bill it as 5-min.
                usage.cacheCreation5mTokens += int(usageObject["cache_creation_input_tokens"])
            }
        }
        return usage
    }

    /// Aggregates the transcript file at `path`, or nil if it can't be read.
    public static func aggregate(contentsOfFile path: String) -> TranscriptUsage? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return aggregate(jsonl: text)
    }

    /// JSON numbers decode as `NSNumber`; coerce to `Int`, defaulting to 0.
    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}
