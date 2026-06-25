import XCTest
import TOMLKit
@testable import Sidekick

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

    func testMissingModeDefaultsToAsk() throws {
        // A config written before the key existed must still parse, and must not
        // silently start auto-approving edits.
        XCTAssertFalse(try approval(from: "").autoApprove)
    }

    func testDefaultConfigDoesNotAutoApprove() {
        XCTAssertEqual(Config().approval?.autoApprove, false)
    }
}
