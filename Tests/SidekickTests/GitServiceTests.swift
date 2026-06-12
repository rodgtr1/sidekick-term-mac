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

    func testParsesPathWithSpaces() {
        let entry = GitService.parseStatusLine(" M docs/my notes.md")

        XCTAssertEqual(entry?.path, "docs/my notes.md")
    }

    func testUnquotesQuotedPathWithEscapedQuote() {
        let entry = GitService.parseStatusLine("?? \"weird \\\"name\\\".txt\"")

        XCTAssertEqual(entry?.path, "weird \"name\".txt")
    }

    func testUnquotesOctalEscapedUnicodePath() {
        // git renders "é" (UTF-8 0xC3 0xA9) as \303\251 in quoted paths
        let entry = GitService.parseStatusLine("?? \"caf\\303\\251.txt\"")

        XCTAssertEqual(entry?.path, "café.txt")
    }

    func testParsesQuotedRenameDestination() {
        let entry = GitService.parseStatusLine("R  \"old name.txt\" -> \"new name.txt\"")

        XCTAssertEqual(entry?.path, "new name.txt")
    }

    func testRejectsMalformedShortLine() {
        XCTAssertNil(GitService.parseStatusLine("M"))
        XCTAssertNil(GitService.parseStatusLine(""))
    }

    func testParsesUnmergedStatusAsConflicted() {
        let bothModified = GitService.parseStatusLine("UU src/conflicted.swift")

        XCTAssertEqual(bothModified?.path, "src/conflicted.swift")
        XCTAssertEqual(bothModified?.isConflicted, true)

        XCTAssertEqual(GitService.parseStatusLine("AA both-added.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("DD both-deleted.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("DU deleted-by-us.txt")?.isConflicted, true)
        XCTAssertEqual(GitService.parseStatusLine("UA added-by-them.txt")?.isConflicted, true)

        XCTAssertEqual(GitService.parseStatusLine("M  staged.txt")?.isConflicted, false)
        XCTAssertEqual(GitService.parseStatusLine(" M unstaged.txt")?.isConflicted, false)
        XCTAssertEqual(GitService.parseStatusLine("?? untracked.txt")?.isConflicted, false)
    }

    func testConflictMarkerDiffShowsWorkingTreeWithMarkers() {
        let content = """
        one
        <<<<<<< HEAD
        main-change
        =======
        feature-change
        >>>>>>> b81eefa (feat)
        three

        """

        let diff = GitService.conflictMarkerDiff(relativePath: "f.txt", content: content)
        let lines = diff.components(separatedBy: "\n")

        XCTAssertEqual(lines[0], "diff --git a/f.txt b/f.txt")
        XCTAssertEqual(lines[1], "conflict")
        XCTAssertEqual(lines[4], "@@ -1,7 +1,7 @@")
        // Every content line is emitted as context (leading space) so the
        // renderer numbers it; conflict markers survive verbatim.
        XCTAssertEqual(lines[5], " one")
        XCTAssertEqual(lines[6], " <<<<<<< HEAD")
        XCTAssertEqual(lines[8], " =======")
        XCTAssertEqual(lines[10], " >>>>>>> b81eefa (feat)")
    }

    func testSplitDiffByFileSeparatesFiles() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        index 111..222 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/bar.swift b/bar.swift
        @@ -2 +2 @@
        +added
        """

        let byFile = GitService.splitDiffByFile(diff)

        XCTAssertEqual(byFile.count, 2)
        XCTAssertTrue(byFile["foo.swift"]?.contains("+new") ?? false)
        XCTAssertTrue(byFile["bar.swift"]?.contains("+added") ?? false)
        XCTAssertFalse(byFile["foo.swift"]?.contains("+added") ?? true)
    }

    func testParsePathFromQuotedDiffHeader() {
        let path = GitService.parsePathFromDiffHeader("diff --git \"a/my file.txt\" \"b/my file.txt\"")

        XCTAssertEqual(path, "my file.txt")
    }
}
