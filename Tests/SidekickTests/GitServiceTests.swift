import XCTest
@testable import Sidekick

final class GitServiceTests: XCTestCase {
    func testParsesUnstagedModifiedStatusWithoutLosingLeadingSpace() {
        let entries = GitService.parseStatusOutput(" M docs/pages/agentic-identity-framework.mdx\n")

        XCTAssertEqual(entries, [
            GitStatusEntry(
                path: "docs/pages/agentic-identity-framework.mdx",
                stagedStatus: " ",
                unstagedStatus: "M"
            )
        ])
        XCTAssertFalse(entries[0].hasStagedChanges)
        XCTAssertTrue(entries[0].hasUnstagedChanges)
    }

    func testParsesStagedModifiedStatus() {
        let entry = GitService.parseStatusLine("M  README.md")

        XCTAssertEqual(entry?.path, "README.md")
        XCTAssertEqual(entry?.stagedStatus, "M")
        XCTAssertEqual(entry?.unstagedStatus, " ")
        XCTAssertEqual(entry?.hasStagedChanges, true)
        XCTAssertEqual(entry?.hasUnstagedChanges, false)
    }

    func testParsesUntrackedStatus() {
        let entry = GitService.parseStatusLine("?? Sources/NewFile.swift")

        XCTAssertEqual(entry?.path, "Sources/NewFile.swift")
        XCTAssertEqual(entry?.isUntracked, true)
    }

    func testParsesRenamedPathAsDestination() {
        let entry = GitService.parseStatusLine("R  old/path.swift -> new/path.swift")

        XCTAssertEqual(entry?.path, "new/path.swift")
        XCTAssertEqual(entry?.stagedStatus, "R")
    }
}
