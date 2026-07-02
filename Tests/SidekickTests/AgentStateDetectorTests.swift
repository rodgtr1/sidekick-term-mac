import XCTest
@testable import Sidekick

/// Exercises the extracted agent-state machine: explicit OSC 666 reports vs.
/// text heuristics, the done-after-quiet timer, user-input transitions, and
/// blocked-state screen polling with stale-prompt suppression.
@MainActor
final class AgentStateDetectorTests: XCTestCase {
    /// Spins the main run loop so main-queue state notifications and short
    /// test-scaled timers get to fire.
    private func spinMainRunLoop(for interval: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    func testExplicitStatusTokensMapToStatesAndNotifyOnce() {
        let detector = AgentStateDetector()
        var notified: [AgentState] = []
        detector.onStateChange = { notified.append($0) }

        detector.handleStatusToken("busy")
        detector.handleStatusToken("working") // same mapped state — deduped
        detector.handleStatusToken("ready")
        detector.handleStatusToken("done")
        spinMainRunLoop()

        XCTAssertEqual(notified, [.working, .ready, .done])
        XCTAssertEqual(detector.state, .done)
        XCTAssertTrue(detector.hasExplicitStatus)
    }

    func testUnknownStatusTokenIsIgnored() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("compacting")
        XCTAssertEqual(detector.state, .idle)
        XCTAssertFalse(detector.hasExplicitStatus)
    }

    func testHeuristicsStandDownOnceHookAuthoritative() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("done")
        // A spinner cue that would flip an un-hooked pane to working.
        detector.processHeuristics(chunk: "✻ Thinking…")
        XCTAssertEqual(detector.state, .done)
    }

    func testPromptMarkerInRecentOutputFlipsToReady() {
        let detector = AgentStateDetector()
        detector.processHeuristics(chunk: "Do you want to proceed?")
        XCTAssertEqual(detector.state, .ready)
    }

    func testInlinePermissionPromptNeedsBothHalves() {
        let detector = AgentStateDetector()
        detector.processHeuristics(chunk: "do you want to grab lunch")
        XCTAssertEqual(detector.state, .idle)
        detector.processHeuristics(chunk: "Do you want to edit main.swift?\n1. Yes\n3. No")
        XCTAssertEqual(detector.state, .ready)
    }

    func testWorkingCueThenQuietPeriodBecomesDone() {
        let detector = AgentStateDetector(doneQuietPeriod: 0.05, blockedPollInterval: 60)
        detector.processHeuristics(chunk: "Running… (esc to interrupt)")
        XCTAssertEqual(detector.state, .working)
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(detector.state, .done)
    }

    func testContinuedOutputPushesQuietPeriodOut() {
        let detector = AgentStateDetector(doneQuietPeriod: 0.15, blockedPollInterval: 60)
        detector.processHeuristics(chunk: "Thinking…")
        XCTAssertEqual(detector.state, .working)
        // Keep output flowing faster than the quiet period — still working.
        for _ in 0..<3 {
            spinMainRunLoop(for: 0.05)
            detector.processHeuristics(chunk: "more tokens")
            XCTAssertEqual(detector.state, .working)
        }
        spinMainRunLoop(for: 0.3)
        XCTAssertEqual(detector.state, .done)
    }

    func testUserInputFlipsReadyBackToWorking() {
        let detector = AgentStateDetector()
        detector.processHeuristics(chunk: "Do you want to proceed?")
        XCTAssertEqual(detector.state, .ready)
        detector.handleUserInput()
        XCTAssertEqual(detector.state, .working)
    }

    func testUserInputDoesNotMoveHookAuthoritativeState() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("done")
        detector.handleUserInput()
        XCTAssertEqual(detector.state, .done)
    }

    func testResetReArmsHeuristics() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("busy")
        detector.reset()
        XCTAssertEqual(detector.state, .idle)
        XCTAssertFalse(detector.hasExplicitStatus)
        // Heuristics work again for the next un-hooked process.
        detector.processHeuristics(chunk: "Thinking…")
        XCTAssertEqual(detector.state, .working)
    }

    func testWorkerFinishedMarksDoneWithoutReset() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("busy")
        detector.markWorkerFinished()
        XCTAssertEqual(detector.state, .done)
    }

    func testBlockedPollingDetectsPromptOnQuietScreen() {
        let detector = AgentStateDetector(doneQuietPeriod: 60, blockedPollInterval: 0.05)
        var screen = "✻ Working…"
        detector.readVisibleScreen = { screen }

        detector.processHeuristics(chunk: "Working…")
        XCTAssertEqual(detector.state, .working)

        // The dialog renders with no further PTY output — only polling sees it.
        screen = "Do you want to proceed?\n1. Yes\n2. No"
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(detector.state, .ready)
    }

    func testBlockedPollingSuppressesStalePromptFromAnsweredDialog() {
        let detector = AgentStateDetector(doneQuietPeriod: 60, blockedPollInterval: 0.05)
        var screen = "Do you want to proceed?"
        detector.readVisibleScreen = { screen }

        // Prompt visible → ready; the user answers it (keystroke) → working.
        detector.processHeuristics(chunk: "Do you want to proceed?")
        XCTAssertEqual(detector.state, .ready)
        detector.handleUserInput()
        XCTAssertEqual(detector.state, .working)

        // The answered dialog's text lingers on screen for a few redraws — it
        // must not flap the state back to ready.
        spinMainRunLoop(for: 0.15)
        XCTAssertEqual(detector.state, .working)

        // Once it clears, a NEW dialog is detected normally.
        screen = ""
        spinMainRunLoop(for: 0.15)
        screen = "Allow command?"
        spinMainRunLoop(for: 0.15)
        XCTAssertEqual(detector.state, .ready)
    }
}
