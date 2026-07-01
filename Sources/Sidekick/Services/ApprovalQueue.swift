import Foundation

/// One agent edit awaiting review: the hook's proposed old/new content for
/// `path`, the pane the edit hook ran in, and when it arrived.
struct PendingApproval {
    let id: UUID
    let paneID: UUID?
    let path: String
    let old: String
    let new: String
    let requestedAt: Date
}

/// The live queue of hook edits awaiting review — the model behind the agents
/// panel's approvals section (F3). `DiffApprovalCoordinator` enqueues entries
/// and owns the policy around them; the UI resolves them through `resolve`.
/// Every mutation posts `.pendingApprovalsChanged`, so the sidebar list, the
/// activity-bar badge, and the dock-attention logic all track one source of
/// truth instead of each shadowing the queue.
///
/// MainActor-isolated (the module default): entries arrive from the IPC
/// delegate on the main thread and are resolved from UI actions.
final class ApprovalQueue {
    static let shared = ApprovalQueue()

    private(set) var pending: [PendingApproval] = []

    /// Held hook responses, keyed by entry id. Kept out of `PendingApproval`
    /// so the UI can copy entries around freely without owning a closure that
    /// must fire exactly once.
    private var completions: [UUID: (ApprovalOutcome) -> Void] = [:]

    /// Adds an entry to the back of the queue. `completion` runs exactly once,
    /// when the entry is resolved by the user or by a drain.
    func enqueue(
        paneID: UUID?,
        path: String,
        old: String,
        new: String,
        completion: @escaping (ApprovalOutcome) -> Void
    ) {
        let entry = PendingApproval(
            id: UUID(),
            paneID: paneID,
            path: path,
            old: old,
            new: new,
            requestedAt: Date()
        )
        pending.append(entry)
        completions[entry.id] = completion
        notifyChanged()
    }

    /// Resolves one entry and releases its held hook response. An unknown id
    /// is a no-op — a click racing a window-close drain must not double-fire.
    func resolve(id: UUID, outcome: ApprovalOutcome) {
        guard let index = pending.firstIndex(where: { $0.id == id }),
              let completion = completions.removeValue(forKey: id) else { return }
        pending.remove(at: index)
        completion(outcome)
        notifyChanged()
    }

    /// Resolves every queued entry through `decide` — the window-close drain.
    /// The queue is emptied before any completion runs so a completion that
    /// re-reads `pending` sees the drained state.
    func drainAll(_ decide: (PendingApproval) -> ApprovalOutcome) {
        guard !pending.isEmpty else { return }
        let entries = pending
        let held = completions
        pending.removeAll()
        completions.removeAll()
        for entry in entries {
            held[entry.id]?(decide(entry))
        }
        notifyChanged()
    }

    /// Pending entries for one pane — the per-pane badge count.
    func count(forPane paneID: UUID?) -> Int {
        pending.filter { $0.paneID == paneID }.count
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .pendingApprovalsChanged, object: self)
    }
}
