import XCTest
@testable import Sidekick

final class CommandTimelineFormatTests: XCTestCase {
    func testExitBadge() {
        XCTAssertEqual(CommandTimelineFormat.exitBadge(exitCode: 0), "✓")
        XCTAssertEqual(CommandTimelineFormat.exitBadge(exitCode: 1), "✗ 1")
        XCTAssertEqual(CommandTimelineFormat.exitBadge(exitCode: 130), "✗ 130")
    }

    func testDuration() {
        XCTAssertEqual(CommandTimelineFormat.duration(nil), "")
        XCTAssertEqual(CommandTimelineFormat.duration(1.234), "1.2s")
        XCTAssertEqual(CommandTimelineFormat.duration(0), "0.0s")
        XCTAssertEqual(CommandTimelineFormat.duration(65), "1m 5s")
        XCTAssertEqual(CommandTimelineFormat.duration(600), "10m 0s")
    }

    func testSingleLineCommand() {
        XCTAssertEqual(CommandTimelineFormat.singleLineCommand("git status"), "git status")
        XCTAssertEqual(CommandTimelineFormat.singleLineCommand("  ls -la \n"), "ls -la")
        XCTAssertEqual(CommandTimelineFormat.singleLineCommand("echo a\necho b"), "echo a echo b")
    }

    func testOutputTailKeepsWholeWhenWithinCap() {
        let output = "line1\nline2\nline3"
        XCTAssertEqual(CommandTimelineFormat.outputTail(output, maxLines: 5), output)
    }

    func testOutputTailKeepsLastLinesWhenOverCap() {
        let output = "1\n2\n3\n4\n5"
        XCTAssertEqual(CommandTimelineFormat.outputTail(output, maxLines: 2), "4\n5")
    }

    func testOutputTailEmptyStaysEmpty() {
        XCTAssertEqual(CommandTimelineFormat.outputTail("", maxLines: 3), "")
    }
}
