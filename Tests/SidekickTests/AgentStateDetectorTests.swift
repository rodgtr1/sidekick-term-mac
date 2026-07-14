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

    /// Spins the main run loop until `condition` holds, so timer-driven
    /// assertions wait for the transition instead of guessing how long a
    /// loaded CI runner needs. Returns without asserting; the caller's
    /// assertion reports the failure if the timeout expires first.
    private func spinMainRunLoop(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
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
        spinMainRunLoop(until: { detector.state == .done })
        XCTAssertEqual(detector.state, .done)
    }

    func testContinuedOutputPushesQuietPeriodOut() {
        // The quiet period dwarfs the spin interval so the mid-loop `.working`
        // assertions can't lose a race against the done timer on a stalled CI
        // runner (the flake this test used to have at 0.15s/0.05s).
        let detector = AgentStateDetector(doneQuietPeriod: 1.0, blockedPollInterval: 60)
        detector.processHeuristics(chunk: "Thinking…")
        XCTAssertEqual(detector.state, .working)
        // Keep output flowing faster than the quiet period — still working.
        for _ in 0..<3 {
            spinMainRunLoop(for: 0.05)
            detector.processHeuristics(chunk: "more tokens")
            XCTAssertEqual(detector.state, .working)
        }
        spinMainRunLoop(until: { detector.state == .done })
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

    // No hook fires when the user ANSWERS a permission prompt or an
    // AskUserQuestion — the next authoritative busy is the tool's PostToolUse,
    // after the approved tool already ran. The answer keystroke is the only
    // signal at that instant, so it may flip ready → working; nothing else may
    // move a hook-authoritative pane.

    func testAnswerKeystrokeFlipsHookAuthoritativeReadyToWorking() {
        let enter = AgentStateDetector()
        enter.handleStatusToken("ready")
        enter.handleUserInput(bytes: [0x0D][...])                    // Enter
        XCTAssertEqual(enter.state, .working)

        let digit = AgentStateDetector()
        digit.handleStatusToken("ready")
        digit.handleUserInput(bytes: [UInt8]("2".utf8)[...])         // option shortcut
        XCTAssertEqual(digit.state, .working)
    }

    func testNonAnswerKeystrokesLeaveHookAuthoritativeReadyAlone() {
        let detector = AgentStateDetector()
        detector.handleStatusToken("ready")

        detector.handleUserInput(bytes: [UInt8]("\u{1B}[B".utf8)[...]) // arrow down
        XCTAssertEqual(detector.state, .ready)
        detector.handleUserInput(bytes: [UInt8]("y".utf8)[...])        // typing feedback
        XCTAssertEqual(detector.state, .ready)
        detector.handleUserInput(bytes: [0x1B][...])                   // bare Escape
        XCTAssertEqual(detector.state, .ready)
        detector.handleUserInput()                                     // no byte info
        XCTAssertEqual(detector.state, .ready)
    }

    func testAnswerKeystrokeNeverMovesHookAuthoritativeDoneOrWorking() {
        // .done stays untouchable — flipping it on input is the old
        // stranded-on-Working bug this guard exists for.
        let done = AgentStateDetector()
        done.handleStatusToken("done")
        done.handleUserInput(bytes: [0x0D][...])
        XCTAssertEqual(done.state, .done)

        let working = AgentStateDetector()
        working.handleStatusToken("busy")
        working.handleUserInput(bytes: [0x0D][...])
        XCTAssertEqual(working.state, .working)
    }

    func testAnswerKeystrokeFlipKeepsHookAuthority() {
        // The optimistic flip is a display correction, not a return to
        // heuristics: the pane stays hook-authoritative and the next report
        // still rules.
        let detector = AgentStateDetector()
        detector.handleStatusToken("ready")
        detector.handleUserInput(bytes: [0x0D][...])
        XCTAssertEqual(detector.state, .working)
        XCTAssertTrue(detector.hasExplicitStatus)
        detector.processHeuristics(chunk: "Do you want to proceed?")   // must be ignored
        XCTAssertEqual(detector.state, .working)
        detector.handleStatusToken("done")
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

    // MARK: - Long thinking stretches (the `idle`-while-thinking bug)

    /// One tick of Claude Code's spinner, captured from a live pane: erase the
    /// line, draw the frame, return the cursor. Note what it does *not* contain —
    /// see `testClaudeSpinnerFramesCarryNoWorkingCue`.
    private func claudeSpinnerFrame(_ glyph: String, elapsed: String) -> String {
        "\u{001B}[2K\u{001B}[38;5;213m\(glyph)\u{001B}[0m Deciphering… (\(elapsed) · ↓ 21.9k tokens)\r"
    }

    /// The observed bug: a pane that had been thinking for minutes reported
    /// `idle`, so `wait agent-status working` never fired. Once the hook's report
    /// reaches the pane (it now does — see AgentStatusReportTests), nothing in the
    /// quiet minutes that follow may knock the state back off `working`: not the
    /// done-after-quiet timer, and not the heuristics reading redraw frames.
    func testHookedAgentStaysWorkingThroughMinutesOfSpinnerRedraws() {
        // A quiet period far shorter than the stretch we simulate: if the timer
        // were armed under an explicit status at all, it would fire here.
        let detector = AgentStateDetector(doneQuietPeriod: 0.05, blockedPollInterval: 0.05)
        detector.readVisibleScreen = { "✽ Deciphering… (3m 15s · ↓ 21.9k tokens)" }

        // UserPromptSubmit → busy. This is the report that was being dropped.
        detector.handleStatusReport(.working)
        XCTAssertEqual(detector.state, .working)
        XCTAssertTrue(detector.hasExplicitStatus)

        // Minutes of thinking, whose only output is the spinner rewriting one line.
        let glyphs = ["✻", "✽", "✢", "·"]
        for tick in 0..<240 {
            detector.processHeuristics(
                chunk: claudeSpinnerFrame(glyphs[tick % 4], elapsed: "\(tick / 60)m \(tick % 60)s"))
            if tick % 40 == 0 { spinMainRunLoop(for: 0.06) }  // outlast the quiet period
            XCTAssertEqual(detector.state, .working, "state left working at tick \(tick)")
        }

        // And a final stretch of complete silence — no chunks at all.
        spinMainRunLoop(for: 0.2)
        XCTAssertEqual(detector.state, .working)

        // The turn ends the way it started: with a hook report (Stop → done).
        detector.handleStatusReport(.done)
        XCTAssertEqual(detector.state, .done)
    }

    /// Why the fix had to restore the hook's report rather than tune the cue list.
    /// Claude Code's spinner names its thinking with a randomized gerund
    /// ("Deciphering…", "Percolating…"), and the "esc to interrupt" footer is
    /// truncated to fit the pane ("esc to i…"). An un-hooked pane therefore sees
    /// no working cue for the entire run — the heuristics cannot cover this, and
    /// widening them to "any word + ellipsis" would fire on ordinary output.
    func testClaudeSpinnerFramesCarryNoWorkingCue() {
        let frame = claudeSpinnerFrame("✽", elapsed: "3m 15s")
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue(TerminalText.normalize(frame)))
        XCTAssertFalse(AgentStateDetector.containsAgentWorkingCue(
            "⏵⏵ auto mode on (shift+tab to cycle) · esc to i…"))
        // The cues it does catch are unchanged — an agent that spells it out.
        XCTAssertTrue(AgentStateDetector.containsAgentWorkingCue("thinking… (esc to interrupt)"))
    }

    func testReportedStatusIsAuthoritativeLikeAnOSCToken() {
        let detector = AgentStateDetector()
        detector.handleStatusReport(.working)
        XCTAssertTrue(detector.hasExplicitStatus)
        // Heuristics stand down for a socket-reported status exactly as they do
        // for the OSC 666 escape — it is the same report by another road.
        detector.processHeuristics(chunk: "Do you want to proceed?")
        XCTAssertEqual(detector.state, .working)
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
