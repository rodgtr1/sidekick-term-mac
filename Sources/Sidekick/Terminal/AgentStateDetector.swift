import Foundation

/// The per-pane agent-state machine, extracted from TerminalViewController so
/// its interacting pieces (explicit OSC 666 reports vs. text heuristics, the
/// done-after-quiet timer, blocked-state screen polling, prompt-marker
/// suppression) are testable on their own.
///
/// Inputs arrive from the terminal pipeline:
///  - `handleStatusToken(_:)` for explicit OSC 666 hook reports,
///  - `processHeuristics(chunk:)` for ANSI-raw output when no report arrived,
///  - `handleUserInput()` for genuine keystrokes,
///  - `reset()` / `markWorkerFinished()` for process lifecycle.
/// State changes surface through `onStateChange`; blocked-state polling reads
/// the visible screen through `readVisibleScreen`.
final class AgentStateDetector {
    /// Called (async on the main queue, deduped) whenever the detected state
    /// changes.
    var onStateChange: ((AgentState) -> Void)?
    /// Supplies the bottom-of-screen text for blocked-state polling.
    var readVisibleScreen: (() -> String)?

    private(set) var state: AgentState = .idle
    // Once the session reports state via OSC 666 (Claude/Codex hooks), those
    // reports are authoritative and the text heuristics stand down.
    private(set) var hasExplicitStatus = false

    private var recentOutput = ""
    private var suppressedPromptMarkers: Set<String> = []
    // nonisolated(unsafe) only so deinit's off-main branch can hand the timers
    // to the main queue for invalidation; every other access is MainActor.
    nonisolated(unsafe) private var agentDoneTimer: Timer?
    nonisolated(unsafe) private var blockedPollingTimer: Timer?

    /// Timer intervals, injectable so tests don't wait wall-clock seconds.
    private let doneQuietPeriod: TimeInterval
    private let blockedPollInterval: TimeInterval

    init(doneQuietPeriod: TimeInterval = 2.5, blockedPollInterval: TimeInterval = 1.5) {
        self.doneQuietPeriod = doneQuietPeriod
        self.blockedPollInterval = blockedPollInterval
    }

    /// Maps a raw OSC 666 status token to an agent state; nil for unknown
    /// tokens.
    nonisolated static func state(fromStatus status: String) -> AgentState? {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy", "working", "running":
            return .working
        case "ready", "prompt", "waiting", "needs-user", "needs_user":
            return .ready
        case "done", "finished", "complete":
            return .done
        case "idle", "clear", "reset":
            return .idle
        default:
            return nil
        }
    }

    /// Applies an explicit OSC 666 status report. Unknown tokens are ignored
    /// (they don't flip the pane hook-authoritative).
    func handleStatusToken(_ raw: String) {
        guard let state = Self.state(fromStatus: raw) else { return }
        applyExplicitState(state)
    }

    private func applyExplicitState(_ state: AgentState) {
        hasExplicitStatus = true
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        notifyStateChange(state)
    }

    /// Runs the text heuristics over an output chunk for sessions WITHOUT the
    /// status hook installed.
    ///
    /// Once any OSC 666 has arrived this pane is hook-authoritative: the
    /// agent reports busy/ready/done/idle itself, so the text heuristics
    /// stand down entirely. Running them alongside the hooks only
    /// fabricates transitions the agent never reported — the root of the
    /// "stuck on Working" / Working↔NeedsInput-flicker races. Heuristics
    /// remain for un-hooked sessions (a plain shell, or an agent whose
    /// integration isn't installed), and resume if the agent process exits
    /// (`reset()` clears hasExplicitStatus).
    func processHeuristics(chunk: String) {
        if hasExplicitStatus { return }

        TerminalText.appendBounded(chunk, to: &recentOutput, cap: 8_000)

        let normalizedRecentOutput = TerminalText.normalize(recentOutput)
        let normalizedCurrentOutput = TerminalText.normalize(chunk)
        let actionablePromptMarkers = Self.agentPromptMarkers(in: normalizedRecentOutput)
            .subtracting(suppressedPromptMarkers)

        if !actionablePromptMarkers.isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyStateChange(.ready)
        } else if Self.containsAgentWorkingCue(normalizedCurrentOutput),
                  state != .ready {
            notifyStateChange(.working)
            scheduleDoneAfterQuietPeriod()
        } else if state == .working {
            scheduleDoneAfterQuietPeriod()
        }
    }

    /// A genuine keystroke reached the terminal.
    ///
    /// Hook-equipped agents report every transition over OSC 666, so input
    /// must never move agent state: Working comes from UserPromptSubmit /
    /// PreToolUse, Ready from Notification, Done from Stop. Guessing from
    /// keystrokes is what stranded finished agents on "Working" once their
    /// pane was focused. (Focus/mouse reports are already filtered upstream,
    /// but real keystrokes are silenced here too — the next hook is
    /// authoritative and effectively instant.)
    func handleUserInput() {
        if hasExplicitStatus { return }

        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil

        if state == .ready || state == .done {
            notifyStateChange(.working)
            scheduleDoneAfterQuietPeriod()
        }
    }

    /// Returns agent tracking to a clean slate (state idle, heuristics
    /// re-armed) once the agent process is known to be gone.
    ///
    /// Runs unconditionally — never short-circuits on `state == .idle`. A
    /// hooked agent often reports `idle` (OSC 666) as its last status before
    /// exiting; guarding on idle would skip `hasExplicitStatus = false` and
    /// latch the pane in hook-authoritative mode, so the text heuristics never
    /// resume for a later un-hooked process here. Every line below is
    /// idempotent, and `notifyStateChange` self-dedups, so the redundant-idle
    /// case this guard once handled is covered without the latch.
    func reset() {
        hasExplicitStatus = false
        recentOutput = ""
        agentDoneTimer?.invalidate()
        agentDoneTimer = nil
        stopBlockedPolling()
        notifyStateChange(.idle)
    }

    /// A directly launched worker's process exited. It has no parent shell to
    /// return to, so keep the finished pane actionable for waiters and the
    /// dashboard instead of resetting to idle.
    func markWorkerFinished() {
        notifyStateChange(.done)
    }

    private func scheduleDoneAfterQuietPeriod() {
        agentDoneTimer?.invalidate()
        agentDoneTimer = Timer.scheduledTimer(withTimeInterval: doneQuietPeriod, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.state == .working else { return }
                self.notifyStateChange(.done)
            }
        }
    }

    private func notifyStateChange(_ state: AgentState) {
        guard state != self.state else { return }
        let previousState = self.state
        self.state = state

        // Blocked-polling scrapes the visible screen for permission dialogs —
        // a heuristic only needed when no hook reports .ready. Hook-authoritative
        // panes get .ready from the Notification hook, so skip the scraping.
        if state == .working && !hasExplicitStatus {
            startBlockedPolling(suppressingVisiblePrompt: previousState == .ready)
        } else {
            stopBlockedPolling()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    // MARK: - Prompt/working heuristics

    nonisolated static func agentPromptMarkers(in output: String) -> Set<String> {
        // Claude Code — specific dialog/prompt phrases only.
        // "esc to cancel" alone is intentionally excluded: it appears in the
        // normal running-spinner footer ("Running... (esc to cancel)") and
        // causes constant Working↔NeedsInput flicker when the poller reads it.
        // "tab to add additional instructions" is also excluded: it is the
        // normal input footer Claude renders after Stop, not a request that is
        // blocking an active run.
        let markers = [
            "do you want to proceed?",
            "do you want to continue?",
            "don't ask again",
            // Codex
            "allow command?",
            "press enter to confirm or esc to cancel",
            "enter to submit answer",
            "enter to submit all"
        ]
        var matched = Set(markers.filter { output.contains($0) })
        // Modern Claude Code inline permission prompt: "Do you want to <verb>…?"
        // above a numbered menu ("1. Yes  2. …  3. No"). Require BOTH halves so
        // the broad "do you want to" stem can't trip on ordinary prose. (Hooked
        // sessions get this authoritatively via PermissionRequest; this is the
        // fallback for un-integrated ones.)
        if output.contains("do you want to") && output.contains("1. yes") {
            matched.insert("interactive permission prompt")
        }
        return matched
    }

    /// Heuristic "agent is working" signal for sessions WITHOUT the status hook
    /// installed (hooked sessions never reach here — see `processHeuristics`).
    /// Anchored to the spinner ellipsis the agents render ("Thinking…",
    /// "Working…", "running...") and the "esc to interrupt" footer, so the bare
    /// words don't flip state when they appear in ordinary command output. For
    /// reliable state, install the agent hooks.
    nonisolated static func containsAgentWorkingCue(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("esc to interrupt") { return true }
        for cue in ["running", "thinking", "working", "generating"] {
            if lower.contains("\(cue)...") || lower.contains("\(cue)…") { return true }
        }
        return false
    }

    // MARK: - Blocked-state polling

    // Polls the visible screen content while the agent is working so we can
    // detect permission dialogs even when no new PTY data arrives after the UI
    // renders (the OSC hook fires before the dialog, then data stops flowing).
    private func startBlockedPolling(suppressingVisiblePrompt: Bool) {
        stopBlockedPolling()
        if suppressingVisiblePrompt {
            let screen = TerminalText.normalize(readVisibleScreen?() ?? "")
            suppressedPromptMarkers = Self.agentPromptMarkers(in: screen)
        }
        blockedPollingTimer = Timer.scheduledTimer(withTimeInterval: blockedPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForBlockedState() }
        }
    }

    private func stopBlockedPolling() {
        blockedPollingTimer?.invalidate()
        blockedPollingTimer = nil
        suppressedPromptMarkers.removeAll()
    }

    private func pollForBlockedState() {
        guard state == .working else {
            stopBlockedPolling()
            return
        }
        let screen = readVisibleScreen?() ?? ""
        let normalized = TerminalText.normalize(screen)
        let visibleMarkers = Self.agentPromptMarkers(in: normalized)

        // When a user answers a permission dialog, its text can remain in the
        // terminal for another redraw. Ignore those same markers until they
        // disappear; otherwise polling changes ready -> working -> ready using
        // stale cells from the dialog that was just answered.
        suppressedPromptMarkers.formIntersection(visibleMarkers)
        if !visibleMarkers.subtracting(suppressedPromptMarkers).isEmpty {
            agentDoneTimer?.invalidate()
            agentDoneTimer = nil
            notifyStateChange(.ready)
        }
    }

    deinit {
        // The timers are main-run-loop scheduled. deinit is nonisolated:
        // assumeIsolated is only safe while the final release lands on the main
        // thread. If a future off-main strong capture ever deallocates us
        // elsewhere, hand the timers to the main queue for invalidation there —
        // repeating timers are retained by the run loop indefinitely, so each
        // leaked one would fire no-ops for the app's lifetime.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                agentDoneTimer?.invalidate()
                blockedPollingTimer?.invalidate()
            }
        } else {
            let timers = [agentDoneTimer, blockedPollingTimer]
            DispatchQueue.main.async {
                for timer in timers {
                    timer?.invalidate()
                }
            }
        }
    }
}
