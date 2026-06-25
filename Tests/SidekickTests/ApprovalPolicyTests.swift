import XCTest
@testable import Sidekick

final class ApprovalPolicyTests: XCTestCase {
    // MARK: - Glob matching

    func testStarStaysWithinSegment() {
        XCTAssertTrue(ApprovalPolicy.glob("*.swift", matches: "/repo/Sources/Foo.swift"))
        XCTAssertFalse(ApprovalPolicy.glob("Sources/*.swift", matches: "/repo/Sources/Nested/Foo.swift"))
    }

    func testDoubleStarSpansSeparators() {
        XCTAssertTrue(ApprovalPolicy.glob("Sources/**", matches: "/repo/Sources/A/B/Foo.swift"))
        XCTAssertTrue(ApprovalPolicy.glob("**/secrets/**", matches: "/repo/app/secrets/key.pem"))
    }

    func testUnanchoredMatchesAnywhereOnBoundary() {
        XCTAssertTrue(ApprovalPolicy.glob(".env", matches: "/repo/.env"))
        // Must match on a path boundary, not a substring.
        XCTAssertFalse(ApprovalPolicy.glob(".env", matches: "/repo/.envrc"))
        XCTAssertFalse(ApprovalPolicy.glob("env", matches: "/repo/preventer"))
    }

    func testAnchoredPatternRequiresFullPath() {
        XCTAssertTrue(ApprovalPolicy.glob("/repo/Sources/**", matches: "/repo/Sources/Foo.swift"))
        XCTAssertFalse(ApprovalPolicy.glob("/other/**", matches: "/repo/Sources/Foo.swift"))
    }

    // MARK: - Decision precedence

    private func decide(
        _ path: String,
        globalAuto: Bool = false,
        autoAllow: [String] = [],
        alwaysAsk: [String] = [],
        session: SessionApprovals = SessionApprovals()
    ) -> ApprovalPolicy.Decision {
        ApprovalPolicy.decide(
            path: path,
            globalAuto: globalAuto,
            autoAllow: autoAllow,
            alwaysAsk: alwaysAsk,
            session: session
        )
    }

    func testDefaultAsks() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift"), .ask)
    }

    func testGlobalAutoAllows() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift", globalAuto: true), .allow)
    }

    func testAutoAllowOverridesAskMode() {
        XCTAssertEqual(decide("/repo/Sources/Foo.swift", autoAllow: ["Sources/**"]), .allow)
    }

    func testAlwaysAskWinsOverGlobalAuto() {
        XCTAssertEqual(decide("/repo/.env", globalAuto: true, alwaysAsk: [".env"]), .ask)
    }

    func testAlwaysAskWinsOverAutoAllow() {
        XCTAssertEqual(
            decide("/repo/.env", autoAllow: ["**"], alwaysAsk: [".env"]),
            .ask
        )
    }

    func testAlwaysAskWinsOverRememberedFolder() {
        var session = SessionApprovals()
        session.record(.folder, path: "/repo/.env")  // remembers /repo
        XCTAssertEqual(decide("/repo/.env", alwaysAsk: [".env"], session: session), .ask)
    }

    // MARK: - Session "approve & remember"

    func testRememberFileAllowsOnlyThatFile() {
        var session = SessionApprovals()
        session.record(.file, path: "/repo/a.txt")
        XCTAssertEqual(decide("/repo/a.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/b.txt", session: session), .ask)
    }

    func testRememberFolderAllowsSubtree() {
        var session = SessionApprovals()
        session.record(.folder, path: "/repo/src/a.txt")  // remembers /repo/src
        XCTAssertEqual(decide("/repo/src/a.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/src/deep/b.txt", session: session), .allow)
        XCTAssertEqual(decide("/repo/other/c.txt", session: session), .ask)
    }

    func testRememberSessionAllowsEverything() {
        var session = SessionApprovals()
        session.record(.session, path: "/repo/a.txt")
        XCTAssertEqual(decide("/anywhere/else.txt", session: session), .allow)
    }

    func testRememberNoneGrantsNothing() {
        var session = SessionApprovals()
        session.record(.none, path: "/repo/a.txt")
        XCTAssertEqual(decide("/repo/a.txt", session: session), .ask)
    }
}
