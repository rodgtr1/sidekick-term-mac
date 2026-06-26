import AppKit

/// The slice of the window controller `DiffApprovalCoordinator` needs to decide
/// and present a hook edit approval: the live `[approval]` config, the global
/// auto-approve toggle, and the window a review sheet attaches to (nil when
/// there's nothing on screen to review in). `AutomationHost` refines this, so
/// MainWindowController satisfies both through one conformance.
protocol DiffApprovalHost: AnyObject {
    /// When true, hook edits are approved without a review popup — driven by the
    /// `[approval]` config mode and the per-session toggle.
    var shouldAutoApproveEdits: Bool { get }
    /// The active `[approval]` config, supplying the auto_allow / always_ask
    /// glob rules layered on top of `shouldAutoApproveEdits`.
    var approvalConfig: ApprovalConfig { get }
    /// The window a diff-approval sheet attaches to, or nil when there's none
    /// to review in (app closing / backgrounded).
    var automationWindow: NSWindow? { get }
}

/// Owns the hook diff-approval queue: the policy decision, the one-sheet-at-a-time
/// review presentation, per-pane "approve & remember" grants, and the fail-open
/// drain when there's no window to review in. Split out of AutomationCoordinator,
/// which stays the IPC + event-emit site and drives this through `requestApproval`
/// / `prepareForWindowClose`, reporting the diff lifecycle via `onEvent`.
final class DiffApprovalCoordinator {
    private weak var host: DiffApprovalHost?

    /// Reports the approval lifecycle (pending/accepted/rejected) for `path` so
    /// the owner can emit a `diff` event — keeping event emission centralized
    /// there rather than spread across coordinators.
    private let onEvent: (_ path: String, _ decision: String) -> Void

    /// Pending hook diff approvals, shown one sheet at a time.
    private var queue: [(paneID: UUID?, path: String, old: String, new: String, completion: (Bool) -> Void)] = []
    private var activePanel: DiffApprovalPanel?

    /// "Approve & remember" grants from the review sheet, scoped per pane (the
    /// pane the edit hook ran in; nil for a hook that didn't report one). Per-pane
    /// scoping keeps a grant in one agent's pane from auto-approving another's.
    /// Reset on relaunch, like the auto-approve menu toggle.
    private var sessionApprovals: [UUID?: SessionApprovals] = [:]

    init(host: DiffApprovalHost?, onEvent: @escaping (_ path: String, _ decision: String) -> Void) {
        self.host = host
        self.onEvent = onEvent
    }

    /// Decides `path` against policy and either allows it silently or queues a
    /// review sheet, resolving `completion` with the accept/reject outcome.
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
        } else {
            // Hook approval: hold the response until the user decides.
            onEvent(path, "pending")
            enqueue(paneID: paneID, path: path, old: old, new: new) { [weak self] accepted in
                self?.onEvent(path, accepted ? "accepted" : "rejected")
                completion(accepted)
            }
        }
    }

    /// Called from the host's windowWillClose. Don't strand hook processes
    /// blocked on approval: cancel the visible sheet and resolve the queue.
    func prepareForWindowClose() {
        activePanel?.cancel()
        activePanel = nil
        drainQueue()
    }

    // MARK: - Policy + queue

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

    private func enqueue(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        completion: @escaping (Bool) -> Void
    ) {
        queue.append((paneID: paneID, path: path, old: old, new: new, completion: completion))
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard activePanel == nil, !queue.isEmpty else { return }

        // No window to attach a sheet to: fail open rather than leave the hook
        // blocked and the queue wedged.
        guard let window = host?.automationWindow, window.isVisible else {
            drainQueue()
            return
        }

        let request = queue.removeFirst()
        let panel = DiffApprovalPanel()
        activePanel = panel
        panel.show(relativeTo: window, path: request.path, old: request.old, new: request.new) { [weak self] outcome in
            // Record an "approve & remember" grant into the originating pane's
            // bucket before resolving, so later edits from that pane already see
            // it. always_ask still wins.
            if outcome.accepted {
                self?.sessionApprovals[request.paneID, default: SessionApprovals()]
                    .record(outcome.remember, path: request.path)
            }
            request.completion(outcome.accepted)
            self?.activePanel = nil
            self?.presentNextIfIdle()
        }
    }

    /// Resolves every queued approval when there is no window to review in
    /// (app closing, or a diff arrived while the window was hidden). These
    /// fail OPEN — allowing the edit — to match the hook's own contract that
    /// an unavailable Sidekick lets edits through, rather than silently
    /// blocking an agent's work because the reviewer wasn't on screen.
    private func drainQueue() {
        let pending = queue
        queue.removeAll()
        for request in pending {
            request.completion(true)
        }
    }
}
