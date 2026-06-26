import XCTest
@testable import Sidekick

final class AgentWorkingCueTests: XCTestCase {
    func testAnchoredSpinnerCuesMatch() {
        XCTAssertTrue(TerminalViewController.containsAgentWorkingCue("✻ Thinking…"))
        XCTAssertTrue(TerminalViewController.containsAgentWorkingCue("Working... please wait"))
        XCTAssertTrue(TerminalViewController.containsAgentWorkingCue("running..."))
        XCTAssertTrue(TerminalViewController.containsAgentWorkingCue("Generating…"))
        XCTAssertTrue(TerminalViewController.containsAgentWorkingCue("(esc to interrupt)"))
    }

    func testBareWordsInOrdinaryOutputDoNotMatch() {
        // These would have flipped un-hooked state under the old bare-substring check.
        XCTAssertFalse(TerminalViewController.containsAgentWorkingCue("I'm working on the report."))
        XCTAssertFalse(TerminalViewController.containsAgentWorkingCue("nothing to commit, working tree clean"))
        XCTAssertFalse(TerminalViewController.containsAgentWorkingCue("thinking about the design"))
        XCTAssertFalse(TerminalViewController.containsAgentWorkingCue("the running total is 5"))
    }
}
