import XCTest
@testable import Sidekick

final class QuickOpenFuzzyTests: XCTestCase {
    func testFuzzyRegexBuildsSubsequencePattern() {
        XCTAssertEqual(QuickOpenPanel.fuzzyRegex(for: "abc"), "a.*b.*c")
    }

    func testFuzzyRegexEscapesMetacharacters() {
        // A "." in the query must be a literal, not "any character".
        XCTAssertEqual(QuickOpenPanel.fuzzyRegex(for: "a.b"), "a.*\\..*b")
    }

    func testRelativePathStripsRootAndLeadingSlash() {
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/repo/Sources/App.swift", under: "/repo"),
            "Sources/App.swift"
        )
        // Tolerates a trailing slash on the root.
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/repo/Sources/App.swift", under: "/repo/"),
            "Sources/App.swift"
        )
    }

    func testRelativePathReturnsOriginalWhenNotUnderRoot() {
        XCTAssertEqual(
            QuickOpenPanel.relativePath(of: "/other/file.swift", under: "/repo"),
            "/other/file.swift"
        )
    }
}
