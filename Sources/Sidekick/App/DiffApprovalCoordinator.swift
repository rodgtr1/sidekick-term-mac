import AppKit

/// The slice of the window controller `DiffApprovalCoordinator` needs to decide
/// a hook edit approval: the live `[approval]` config, the global auto-approve
/// toggle, and the window approvals are reviewed in (nil when the app is
/// closing and there's nothing left to review in). `AutomationHost` refines
/// this, so MainWindowController satisfies both through one conformance.
protocol DiffApprovalHost: AnyObject {
    /// When true, hook edits are approved without review — driven by the
    /// `[approval]` config mode and the per-session toggle.
    var shouldAutoApproveEdits: Bool { get }
    /// The active `[approval]` config, supplying the auto_allow / always_ask
    /// glob rules layered on top of `shouldAutoApproveEdits`.
    var approvalConfig: ApprovalConfig { get }
    /// The window approvals are reviewed in, or nil when there's none (app
    /// closing / already gone).
    var automationWindow: NSWindow? { get }
}

/// Owns hook diff-approval policy: silent allows, per-pane "approve & remember"
/// grants, and the fail-open drain when there is no window left to review in.
/// Approvals that need a human land in `ApprovalQueue` and are reviewed from
/// the agents panel's approvals list (F3) — a non-modal review queue — rather
/// than one blocking sheet at a time, so several agents' requests can be
/// decided in any order. Split out of AutomationCoordinator, which stays the
/// IPC + event-emit site and drives this through `requestApproval` /
/// `prepareForWindowClose`, reporting the diff lifecycle via `onEvent`.
final class DiffApprovalCoordinator {
    private weak var host: DiffApprovalHost?
    private let queue: ApprovalQueue

    /// Reports the approval lifecycle (pending/accepted/rejected) for `path` so
    /// the owner can emit a `diff` event — keeping event emission centralized
    /// there rather than spread across coordinators.
    private let onEvent: (_ path: String, _ decision: String) -> Void

    /// "Approve & remember" grants from the review list, scoped per pane (the
    /// pane the edit hook ran in; nil for a hook that didn't report one). Per-pane
    /// scoping keeps a grant in one agent's pane from auto-approving another's.
    /// Reset on relaunch, like the auto-approve menu toggle.
    private var sessionApprovals: [UUID?: SessionApprovals] = [:]

    init(
        host: DiffApprovalHost?,
        queue: ApprovalQueue = .shared,
        onEvent: @escaping (_ path: String, _ decision: String) -> Void
    ) {
        self.host = host
        self.queue = queue
        self.onEvent = onEvent
    }

    /// Decides `path` against policy and either allows it silently or parks it
    /// in the review queue, resolving `completion` with the accept/reject
    /// outcome once the user (or a drain) decides.
    func requestApproval(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        completion: @escaping (Bool) -> Void
    ) {
        if approvalDecision(for: path, pane: paneID) == .allow {
            // Allowed silently by glob rule, "remember" grant, or auto mode.
            onEvent(path, "accepted")
            completion(true)
            return
        }

        // No window at all to review in (app closing / already gone): resolve
        // with the drain's fail-open contract rather than park an entry no one
        // can ever see. A merely miniaturized or hidden window still has a
        // queue surface — entries just wait there.
        guard host?.automationWindow != nil else {
            let accepted = !isAlwaysAsk(path, pane: paneID)
            onEvent(path, accepted ? "accepted" : "rejected")
            completion(accepted)
            return
        }

        onEvent(path, "pending")
        queue.enqueue(paneID: paneID, path: path, old: old, new: new) { [weak self] outcome in
            // Record an "approve & remember" grant into the originating pane's
            // bucket before resolving, so later edits from that pane already
            // see it. always_ask still wins.
            if outcome.accepted {
                self?.sessionApprovals[paneID, default: SessionApprovals()]
                    .record(outcome.remember, path: path)
            }
            self?.onEvent(path, outcome.accepted ? "accepted" : "rejected")
            completion(outcome.accepted)
            if outcome.accepted && outcome.remember != .none {
                self?.resolveNewlyAllowed()
            }
        }
    }

    /// Called from the host's windowWillClose. Don't strand hook processes
    /// blocked on approval: resolve everything still queued. Most fail OPEN —
    /// allowing the edit — to match the hook's contract that an unavailable
    /// Sidekick lets edits through. The exception is `always_ask` paths: that
    /// list exists to force a human decision, so without a window to review in
    /// they fail CLOSED (reject) rather than slip through unreviewed.
    func prepareForWindowClose() {
        queue.drainAll { [weak self] entry in
            let alwaysAsk = self?.isAlwaysAsk(entry.path, pane: entry.paneID) ?? true
            return ApprovalOutcome(accepted: !alwaysAsk, remember: .none)
        }
    }

    // MARK: - Policy

    /// Resolves the approval policy for `path` against the config glob rules,
    /// the pane's own "remember" grants, and the global auto toggle.
    private func approvalDecision(for path: String, pane: UUID?) -> ApprovalPolicy.Decision {
        let config = host?.approvalConfig ?? ApprovalConfig()
        return ApprovalPolicy.decide(
            path: path,
            globalAuto: host?.shouldAutoApproveEdits ?? false,
            autoAllow: config.autoAllow,
            alwaysAsk: config.alwaysAsk,
            session: sessionApprovals[pane] ?? SessionApprovals()
        )
    }

    /// After an "approve & remember" grant, entries already queued from the
    /// same pane may now be allowed by policy — resolve them rather than make
    /// the user click through requests the grant they just gave already
    /// covers. (`queue.pending` is a value snapshot, so resolving while
    /// iterating is safe; the resolved entries' `remember` is `.none`, so this
    /// can't recurse.)
    private func resolveNewlyAllowed() {
        for entry in queue.pending where approvalDecision(for: entry.path, pane: entry.paneID) == .allow {
            queue.resolve(id: entry.id, outcome: ApprovalOutcome(accepted: true, remember: .none))
        }
    }

    /// Whether `path` matches an `always_ask` glob. Mirrors `decide`'s
    /// fail-closed semantics: an unparseable pattern counts as a match.
    private func isAlwaysAsk(_ path: String, pane: UUID?) -> Bool {
        let config = host?.approvalConfig ?? ApprovalConfig()
        let canonicalPath = ApprovalPolicy.canonical(path)
        return config.alwaysAsk.contains { pattern in
            ApprovalPolicy.globMatch(pattern, canonicalPath: canonicalPath) != .noMatch
        }
    }
}
