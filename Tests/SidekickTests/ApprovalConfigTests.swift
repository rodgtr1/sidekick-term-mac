import XCTest
import TOMLKit
@testable import Sidekick

@MainActor
final class ApprovalConfigTests: XCTestCase {
    private func approval(from toml: String) throws -> ApprovalConfig {
        try TOMLDecoder().decode(ApprovalConfig.self, from: try TOMLTable(string: toml))
    }

    func testAutoModeApproves() throws {
        XCTAssertTrue(try approval(from: "mode = \"auto\"").autoApprove)
    }

    func testAskModeDoesNotAutoApprove() throws {
        XCTAssertFalse(try approval(from: "mode = \"ask\"").autoApprove)
    }

    func testModeIsCaseInsensitive() throws {
        XCTAssertTrue(try approval(from: "mode = \"AUTO\"").autoApprove)
    }

    func testReviewAndLegacyClaudeAutoBothNormalizeToReviewedMode() throws {
        XCTAssertEqual(ApprovalMode(configValue: "review"), .review)
        XCTAssertEqual(ApprovalMode(configValue: "claude-auto"), .review)
        XCTAssertTrue(try approval(from: "mode = \"review\"").autoApprove)
        XCTAssertTrue(try approval(from: "mode = \"claude-auto\"").autoApprove)
    }

    func testUnknownModeFailsClosedToAsk() {
        XCTAssertEqual(ApprovalMode(configValue: "surprise-me"), .ask)
    }

    func testMissingModeDefaultsToAsk() throws {
        // A config written before the key existed must still parse, and must not
        // silently start auto-approving edits.
        XCTAssertFalse(try approval(from: "").autoApprove)
    }

    func testDefaultConfigDoesNotAutoApprove() {
        XCTAssertEqual(Config().approval?.autoApprove, false)
    }

    func testGlobListsParse() throws {
        let config = try approval(from: """
        mode = "ask"
        auto_allow = ["Sources/**", "docs/**"]
        always_ask = [".env"]
        """)
        XCTAssertEqual(config.autoAllow, ["Sources/**", "docs/**"])
        XCTAssertEqual(config.alwaysAsk, [".env"])
    }

    func testMissingGlobListsDefaultToEmpty() throws {
        // Configs written before these keys existed must still parse.
        let config = try approval(from: "mode = \"ask\"")
        XCTAssertTrue(config.autoAllow.isEmpty)
        XCTAssertTrue(config.alwaysAsk.isEmpty)
    }

    func testLiveApprovalModeSnapshotIsDataOnlyAndAtomic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick-approval-mode-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("mode")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = AgentApprovalState.mode
        defer { AgentApprovalState.mode = original }
        AgentApprovalState.mode = .review
        try AgentApprovalState.persistMode(to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "review\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
