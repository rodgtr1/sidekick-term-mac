import XCTest
@testable import SidekickTelemetryCore

final class TranscriptUsageTests: XCTestCase {
    /// A representative slice of a Claude Code transcript: noise lines, a typed
    /// prompt, two billed assistant responses (one with the nested cache split,
    /// one with only the flat legacy field), a tool-result user turn, and a
    /// malformed line — all of which the parser must handle.
    private let fixture = """
    {"type":"system","subtype":"init"}
    {"type":"user","message":{"role":"user","content":"hello, fix the bug"}}
    {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":100}}}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}
    {"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":300}}}
    {"type":"attachment","foo":1}
    this is not json at all
    {"type":"mode"}
    """

    func testAggregatesUsageAndSkipsNoise() {
        let u = TranscriptParser.aggregate(jsonl: fixture)
        XCTAssertEqual(u.model, "claude-opus-4-8")
        XCTAssertEqual(u.inputTokens, 1200)
        XCTAssertEqual(u.outputTokens, 600)
        XCTAssertEqual(u.cacheReadTokens, 2000)
        XCTAssertEqual(u.cacheCreation5mTokens, 700)   // 400 nested + 300 legacy-flat
        XCTAssertEqual(u.cacheCreation1hTokens, 100)
        XCTAssertEqual(u.cacheCreationTokens, 800)
        XCTAssertEqual(u.assistantResponses, 2)
        XCTAssertEqual(u.userPrompts, 1)               // the tool-result user line doesn't count
        XCTAssertEqual(u.totalInputTokens, 1200 + 800 + 2000)
    }

    func testEmptyAndAllNoiseYieldZero() {
        XCTAssertEqual(TranscriptParser.aggregate(jsonl: ""), TranscriptUsage())
        XCTAssertEqual(
            TranscriptParser.aggregate(jsonl: "{\"type\":\"mode\"}\nnonsense\n"),
            TranscriptUsage()
        )
    }

    // MARK: - Cost

    func testEstimatedCostMatchesRateCard() {
        let u = TranscriptParser.aggregate(jsonl: fixture)
        // opus 4.8: $5/$25 per 1M. reads ×0.1, 5m writes ×1.25, 1h writes ×2.
        // 1200·5e-6 + 600·25e-6 + 2000·0.1·5e-6 + 700·1.25·5e-6 + 100·2·5e-6
        XCTAssertEqual(try XCTUnwrap(u.estimatedCostUSD()), 0.027375, accuracy: 1e-9)
    }

    func testRateResolutionToleratesDateSuffix() {
        let rate = TelemetryRates.rate(forModel: "claude-haiku-4-5-20251001")
        XCTAssertEqual(rate, TelemetryRate(inputPerMTok: 1, outputPerMTok: 5))
    }

    func testNilForUnknownOrMissingModel() {
        XCTAssertNil(TranscriptUsage(model: nil, inputTokens: 100).estimatedCostUSD())
        XCTAssertNil(TranscriptUsage(model: "gpt-4o", inputTokens: 100).estimatedCostUSD())
    }
}
