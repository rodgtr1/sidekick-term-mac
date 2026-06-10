import XCTest
@testable import Sidekick

final class InlineDiffRendererTests: XCTestCase {
    private let sampleDiff = """
    diff --git a/doc.mdx b/doc.mdx
    index 3eff452..d8eabce 100644
    --- a/doc.mdx
    +++ b/doc.mdx
    @@ -71,3 +71,3 @@ spec:
     environment: production
    -# whether by directly despatching the workflow.
    +# whether by directly dispatching the workflow.
     actor: octocat
    """

    func testRenderHidesGitMetadata() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string

        XCTAssertFalse(rendered.contains("diff --git"))
        XCTAssertFalse(rendered.contains("index 3eff452"))
        XCTAssertFalse(rendered.contains("@@"))
        XCTAssertFalse(rendered.contains("+++"))
    }

    func testRenderNumbersContextAndAddedLinesButNotRemoved() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string
        let lines = rendered.components(separatedBy: "\n")

        // Context line carries the hunk's starting line number.
        XCTAssertTrue(lines[0].hasSuffix("environment: production"))
        XCTAssertTrue(lines[0].contains("71"))

        // Removed line: blank gutter, no number anywhere in the gutter.
        XCTAssertTrue(lines[1].hasSuffix("despatching the workflow."))
        XCTAssertTrue(lines[1].hasPrefix("       "))

        // Added line gets the new file's number (72).
        XCTAssertTrue(lines[2].hasSuffix("dispatching the workflow."))
        XCTAssertTrue(lines[2].contains("72"))

        // Following context resumes numbering (73).
        XCTAssertTrue(lines[3].hasSuffix("actor: octocat"))
        XCTAssertTrue(lines[3].contains("73"))
    }

    func testRemovedLineRendersDirectlyAboveAddedLine() {
        let rendered = InlineDiffRenderer.render(sampleDiff).string
        let lines = rendered.components(separatedBy: "\n")
        let removedIndex = lines.firstIndex { $0.contains("despatching") }
        let addedIndex = lines.firstIndex { $0.contains("dispatching") }

        XCTAssertNotNil(removedIndex)
        XCTAssertEqual(removedIndex.map { $0 + 1 }, addedIndex)
    }

    func testIntralineDifferenceFindsChangedCharacters() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "# directly despatching the workflow.",
            "# directly dispatching the workflow."
        )

        // "despatching" vs "dispatching": common prefix ends after "d",
        // common suffix starts at "spatching…", leaving "e" vs "i".
        XCTAssertEqual(old, NSRange(location: 12, length: 1))
        XCTAssertEqual(new, NSRange(location: 12, length: 1))
    }

    func testIntralineDifferenceSkipsWhollyDifferentLines() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "completely different content here",
            "nothing in common with that line"
        )

        XCTAssertNil(old)
        XCTAssertNil(new)
    }

    func testIntralineDifferenceHandlesInsertion() {
        let (old, new) = InlineDiffRenderer.intralineDifference(
            "programatically issues",
            "programmatically issues"
        )

        // Pure insertion: nothing to emphasize on the removed side.
        XCTAssertNil(old)
        XCTAssertEqual(new?.length, 1)
    }

    func testUntrackedFileDiffRendersAllAddedWithNumbers() {
        let newFileDiff = """
        diff --git a/new.txt b/new.txt
        new file
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +first line
        +second line
        """

        let rendered = InlineDiffRenderer.render(newFileDiff).string
        let lines = rendered.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].contains("1"))
        XCTAssertTrue(lines[0].hasSuffix("first line"))
        XCTAssertTrue(lines[1].contains("2"))
        XCTAssertTrue(lines[1].hasSuffix("second line"))
    }
}
