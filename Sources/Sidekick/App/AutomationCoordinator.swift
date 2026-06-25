import AppKit

/// The surface `AutomationCoordinator` needs from the window controller to
/// resolve panes and drive the UI. MainWindowController stays the source of
/// truth for tabs/panes/window; the coordinator only reads through this seam,
/// so the IPC translation, wait logic, and diff-approval queue can live outside
/// the 1,900-line controller.
protocol AutomationHost: AnyObject {
    /// All tabs, in order. The active one is identified by `activeAutomationTabID`.
    var automationTabs: [TabModel] { get }
    /// ID of the tab the user is currently looking at (drives `focused`).
    var activeAutomationTabID: UUID? { get }
    /// The window a diff-approval sheet attaches to, or nil when there's none
    /// to review in (app closing / backgrounded).
    var automationWindow: NSWindow? { get }
    /// When true, hook edits are approved without a review popup — driven by the
    /// `[approval]` config mode and the per-session toggle.
    var shouldAutoApproveEdits: Bool { get }

    func automationSplitController(forTab tabID: UUID) -> PaneSplitController?
    func automationCreateNewTab(workingDirectory: String?)
    func automationOpenFile(_ url: URL)
    func automationSetActiveTabAgentState(_ state: AgentState)
}

/// Translates IPC commands (from `sidekick-ctl`, `sidekick-mcp`, and the
/// edit-approval hook) into operations on the live pane tree, and owns the
/// hook diff-approval queue. Extracted from MainWindowController — see
/// AutomationHost for the seam back to it.
final class AutomationCoordinator: NSObject, IPCServerDelegate {
    private weak var host: AutomationHost?

    /// Pending hook diff approvals, shown one sheet at a time.
    private var diffApprovalQueue: [(path: String, old: String, new: String, completion: (Bool) -> Void)] = []
    private var activeDiffApproval: DiffApprovalPanel?

    /// In-flight `wait agent-status` requests, resolved by the
    /// PaneAgentStateChanged push rather than a poll. Keyed by request id so a
    /// fired deadline and a matching transition can't both resolve one twice.
    private struct StatusWait {
        let paneID: UUID
        let target: AgentState
        let completion: (Bool) -> Void
        let deadlineTimer: Timer
    }
    private var statusWaits: [UUID: StatusWait] = [:]

    /// In-flight `wait output` requests. The terminal does the incremental
    /// matching; this just holds the deadline + completion and the matcher
    /// handle so a fired deadline can cancel it.
    private struct OutputWait {
        let completion: (Bool) -> Void
        let deadlineTimer: Timer
        weak var terminal: TerminalViewController?
        let matcherID: UUID
    }
    private var outputWaits: [UUID: OutputWait] = [:]

    init(host: AutomationHost) {
        self.host = host
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneAgentStateChanged(_:)),
            name: .paneAgentStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneCommandStatusChanged(_:)),
            name: .paneCommandStatusChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called from the host's windowWillClose. Don't strand hook processes
    /// blocked on approval: cancel the visible sheet and resolve the queue.
    func prepareForWindowClose() {
        activeDiffApproval?.cancel()
        activeDiffApproval = nil
        drainDiffApprovalQueue()
    }

    // MARK: - Pane resolution

    private func automationPane(id: UUID) -> (tab: TabModel, pane: PaneModel, controller: PaneSplitController)? {
        guard let host else { return nil }
        for tab in host.automationTabs {
            guard let pane = tab.panes.first(where: { $0.id == id }),
                  let controller = host.automationSplitController(forTab: tab.id) else { continue }
            return (tab, pane, controller)
        }
        return nil
    }

    private func activeAutomationContext() -> (tab: TabModel, pane: PaneModel, controller: PaneSplitController)? {
        guard let host,
              let tabID = host.activeAutomationTabID,
              let tab = host.automationTabs.first(where: { $0.id == tabID }),
              let pane = tab.activePane,
              let controller = host.automationSplitController(forTab: tabID) else { return nil }
        return (tab, pane, controller)
    }

    private func automationPaneInfo(tab: TabModel, pane: PaneModel, controller: PaneSplitController) -> IPCPaneInfo {
        let type: String
        switch pane.paneType {
        case .terminal: type = "terminal"
        case .editor: type = "editor"
        case .diff: type = "diff"
        case .uncommittedChanges: type = "uncommitted_changes"
        case .browser: type = "browser"
        }
        let pid = pane.terminalViewController?.shellProcessID ?? 0
        return IPCPaneInfo(
            paneID: pane.id.uuidString.lowercased(),
            tabID: tab.id.uuidString.lowercased(),
            type: type,
            cwd: pane.resolvedWorkingDirectory(),
            focused: controller.activePaneID == pane.id && tab.id == host?.activeAutomationTabID,
            agentStatus: pane.agentState.rawValue,
            processID: pid > 0 ? Int32(pid) : nil
        )
    }

    private func allAutomationPaneInfo() -> [IPCPaneInfo] {
        guard let host else { return [] }
        return host.automationTabs.flatMap { tab -> [IPCPaneInfo] in
            guard let controller = host.automationSplitController(forTab: tab.id) else { return [] }
            return tab.panes.map { automationPaneInfo(tab: tab, pane: $0, controller: controller) }
        }
    }

    // MARK: - Output waits (incremental match, not poll)

    /// Resolves when `match` appears in the terminal's output stream. The
    /// terminal matches each chunk incrementally; we only own the deadline and
    /// the completion. Replaces a 100ms timer that re-scanned the whole buffer
    /// and could miss a string that scrolled past the ring between two polls.
    private func waitForOutput(
        terminal: TerminalViewController,
        match: String,
        timeoutMS: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let id = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: Double(timeoutMS) / 1000, repeats: false) { [weak self] _ in
            self?.resolveOutputWait(id, matched: false)
        }
        guard let matcherID = terminal.registerOutputMatcher(match, onMatch: { [weak self] in
            self?.resolveOutputWait(id, matched: true)
        }) else {
            // Already present — resolve now without registering.
            timer.invalidate()
            completion(true)
            return
        }
        outputWaits[id] = OutputWait(completion: completion, deadlineTimer: timer, terminal: terminal, matcherID: matcherID)
    }

    private func resolveOutputWait(_ id: UUID, matched: Bool) {
        guard let wait = outputWaits.removeValue(forKey: id) else { return }
        wait.deadlineTimer.invalidate()
        wait.terminal?.cancelOutputMatcher(wait.matcherID)
        wait.completion(matched)
    }

    // MARK: - Agent-status waits (push, not poll)

    /// Resolves when the pane reaches `target` — driven by the
    /// PaneAgentStateChanged notification, with a one-shot deadline timer as the
    /// only fallback. Replaces a 100ms poll that woke thousands of times on a
    /// long timeout even though every transition already fires the push.
    private func waitForAgentStatus(
        paneID: UUID,
        target: AgentState,
        timeoutMS: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if automationPane(id: paneID)?.pane.agentState == target {
            completion(true)
            return
        }
        let id = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: Double(timeoutMS) / 1000, repeats: false) { [weak self] _ in
            self?.resolveStatusWait(id, matched: false)
        }
        statusWaits[id] = StatusWait(paneID: paneID, target: target, completion: completion, deadlineTimer: timer)
    }

    private func resolveStatusWait(_ id: UUID, matched: Bool) {
        guard let wait = statusWaits.removeValue(forKey: id) else { return }
        wait.deadlineTimer.invalidate()
        wait.completion(matched)
    }

    @objc private func paneAgentStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }
        let matched = statusWaits.filter { $0.value.paneID == pane.id && pane.agentState == $0.value.target }
        for id in matched.keys {
            resolveStatusWait(id, matched: true)
        }
        emitAgentStateEvent(for: pane)
    }

    @objc private func paneCommandStatusChanged(_ notification: Notification) {
        // Posted on both command start (status nil) and finish (status set);
        // the event stream only reports finished commands.
        guard let pane = notification.object as? PaneModel,
              let status = notification.userInfo?["status"] as? TerminalCommandStatus else { return }
        emitCommandEvent(for: pane, status: status)
    }

    // MARK: - Event stream emission

    private func emitAgentStateEvent(for pane: PaneModel) {
        guard EventBroadcaster.shared.hasSubscribers,
              let context = automationPane(id: pane.id) else { return }
        var event = SidekickEvent(type: "agent_state", at: pane.agentStateChangedAt)
        event.paneID = pane.id.uuidString.lowercased()
        event.tabID = context.tab.id.uuidString.lowercased()
        event.state = pane.agentState.rawValue
        EventBroadcaster.shared.emit(event)
    }

    private func emitCommandEvent(for pane: PaneModel, status: TerminalCommandStatus) {
        guard EventBroadcaster.shared.hasSubscribers,
              let context = automationPane(id: pane.id) else { return }
        // The just-finished command line lives in the terminal's last record;
        // fall back to the status alone if integration didn't capture it.
        let lastRecord = pane.terminalViewController?.recentCommandRecords(limit: 1).last
        var event = SidekickEvent(type: "command")
        event.paneID = pane.id.uuidString.lowercased()
        event.tabID = context.tab.id.uuidString.lowercased()
        event.command = lastRecord?.command
        event.exitCode = status.exitCode
        event.duration = status.duration
        EventBroadcaster.shared.emit(event)
    }

    /// Emits a `diff` event for the hook edit-approval lifecycle so a supervisor
    /// can see edits queue and resolve without polling.
    private func emitDiffEvent(path: String, decision: String) {
        guard EventBroadcaster.shared.hasSubscribers else { return }
        var event = SidekickEvent(type: "diff")
        event.path = path
        event.decision = decision
        EventBroadcaster.shared.emit(event)
    }

    // MARK: - IPCServerDelegate

    func ipcServer(
        _ server: IPCServer,
        didReceiveCommand command: IPCCommandType,
        completion: @escaping (IPCResponse) -> Void
    ) {
        switch command {
        case .ping:
            completion(IPCResponse(ok: true))

        case .newTab(let cwd):
            host?.automationCreateNewTab(workingDirectory: cwd)
            completion(IPCResponse(ok: true))

        case .showDiff(let path, let old, let new):
            if old.isEmpty && new.isEmpty {
                // `sidekick-ctl open-diff <file>`: just view the file.
                host?.automationOpenFile(URL(fileURLWithPath: path))
                completion(IPCResponse(ok: true))
            } else if host?.shouldAutoApproveEdits == true {
                // Auto-approve mode (config or session toggle): allow silently.
                emitDiffEvent(path: path, decision: "accepted")
                completion(IPCResponse(ok: true, accepted: true))
            } else {
                // Hook approval: hold the response until the user decides.
                emitDiffEvent(path: path, decision: "pending")
                enqueueDiffApproval(path: path, old: old, new: new) { [weak self] accepted in
                    self?.emitDiffEvent(path: path, decision: accepted ? "accepted" : "rejected")
                    completion(IPCResponse(ok: true, accepted: accepted))
                }
            }

        case .agentReady:
            host?.automationSetActiveTabAgentState(.ready)
            completion(IPCResponse(ok: true))

        case .agentBusy:
            host?.automationSetActiveTabAgentState(.working)
            completion(IPCResponse(ok: true))

        case .agentDone:
            host?.automationSetActiveTabAgentState(.done)
            completion(IPCResponse(ok: true))

        case .agentIdle:
            host?.automationSetActiveTabAgentState(.idle)
            completion(IPCResponse(ok: true))

        case .paneList:
            completion(IPCResponse(result: IPCResult(panes: allAutomationPaneInfo())))

        case .paneCurrent(let requestedPaneID):
            let context = requestedPaneID.map { automationPane(id: $0) } ?? activeAutomationContext()
            guard let context else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            completion(IPCResponse(result: IPCResult(
                pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
            )))

        case .paneSplit(let paneID, let direction, let cwd, let command, let focus, let worktree):
            guard let context = automationPane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            guard let branch = worktree else {
                completeSplit(paneID: paneID, direction: direction, cwd: cwd, command: command, focus: focus, completion: completion)
                return
            }
            // Creating the worktree shells out to git (checks out files), so do
            // it off the main thread, then hop back to perform the UI split in
            // the resulting directory.
            let repoDirectory = context.pane.resolvedWorkingDirectory()
                ?? cwd ?? FileManager.default.currentDirectoryPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try WorktreeService().ensureWorktree(forBranch: branch, directory: repoDirectory) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let worktreePath):
                        self?.completeSplit(paneID: paneID, direction: direction, cwd: worktreePath, command: command, focus: focus, completion: completion)
                    case .failure(let error):
                        completion(IPCResponse(ok: false, error: Self.worktreeErrorMessage(error)))
                    }
                }
            }

        case .paneFocus(let paneID):
            guard let context = automationPane(id: paneID), context.controller.focusPane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            completion(IPCResponse(result: IPCResult(
                pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
            )))

        case .paneClose(let paneID):
            guard let context = automationPane(id: paneID), context.controller.closePane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found or cannot close the last pane"))
                return
            }
            completion(IPCResponse())

        case .paneSendText(let paneID, let text):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            terminal.send(text: text)
            completion(IPCResponse())

        case .paneSendKey(let paneID, let key):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            guard terminal.send(key: key) else {
                completion(IPCResponse(ok: false, error: "Unsupported key: \(key)"))
                return
            }
            completion(IPCResponse())

        case .paneRead(let paneID, let source, let lines, let json):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            if json {
                let records = terminal.recentCommandRecords(limit: lines).map {
                    IPCCommandRecord(command: $0.command, exitCode: $0.exitCode, duration: $0.duration, output: $0.output)
                }
                completion(IPCResponse(result: IPCResult(commands: records)))
            } else {
                let text = source == "recent"
                    ? terminal.recentOutputText(lineLimit: lines)
                    : terminal.visibleScreenText(lineLimit: lines)
                completion(IPCResponse(result: IPCResult(text: text)))
            }

        case .waitAgentStatus(let paneID, let status, let timeoutMS):
            guard automationPane(id: paneID) != nil else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            waitForAgentStatus(paneID: paneID, target: status, timeoutMS: timeoutMS) { matched in
                completion(IPCResponse(result: IPCResult(matched: matched)))
            }

        case .waitOutput(let paneID, let match, let timeoutMS):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            waitForOutput(terminal: terminal, match: match, timeoutMS: timeoutMS) { matched in
                completion(IPCResponse(result: IPCResult(matched: matched)))
            }
        }
    }

    // MARK: - Pane split

    /// Performs the UI split and replies with the new pane, re-resolving the
    /// target so a worktree split (which detoured through a background queue)
    /// still finds it.
    private func completeSplit(
        paneID: UUID,
        direction: SplitDirection,
        cwd: String?,
        command: [String]?,
        focus: Bool,
        completion: @escaping (IPCResponse) -> Void
    ) {
        guard let context = automationPane(id: paneID) else {
            completion(IPCResponse(ok: false, error: "Pane not found"))
            return
        }
        guard let pane = context.controller.splitPane(
            direction: direction,
            targetPaneID: paneID,
            initialDirectory: cwd,
            command: command,
            focus: focus
        ) else {
            completion(IPCResponse(ok: false, error: "Unable to split pane (the tab may be at its pane limit)"))
            return
        }
        completion(IPCResponse(result: IPCResult(
            pane: automationPaneInfo(tab: context.tab, pane: pane, controller: context.controller)
        )))
    }

    private static func worktreeErrorMessage(_ error: Error) -> String {
        switch error {
        case WorktreeService.WorktreeError.notAGitRepository:
            return "Not a git repository — --worktree needs the pane to be inside one"
        case WorktreeService.WorktreeError.gitFailed(let message):
            return "git worktree failed: \(message)"
        default:
            return "Unable to create worktree: \(error.localizedDescription)"
        }
    }

    // MARK: - Hook diff approval

    private func enqueueDiffApproval(
        path: String,
        old: String,
        new: String,
        completion: @escaping (Bool) -> Void
    ) {
        diffApprovalQueue.append((path: path, old: old, new: new, completion: completion))
        presentNextDiffApprovalIfIdle()
    }

    private func presentNextDiffApprovalIfIdle() {
        guard activeDiffApproval == nil, !diffApprovalQueue.isEmpty else { return }

        // No window to attach a sheet to: fail open rather than leave the hook
        // blocked and the queue wedged.
        guard let window = host?.automationWindow, window.isVisible else {
            drainDiffApprovalQueue()
            return
        }

        let request = diffApprovalQueue.removeFirst()
        let panel = DiffApprovalPanel()
        activeDiffApproval = panel
        panel.show(relativeTo: window, path: request.path, old: request.old, new: request.new) { [weak self] accepted in
            request.completion(accepted)
            self?.activeDiffApproval = nil
            self?.presentNextDiffApprovalIfIdle()
        }
    }

    /// Resolves every queued approval when there is no window to review in
    /// (app closing, or a diff arrived while the window was hidden). These
    /// fail OPEN — allowing the edit — to match the hook's own contract that
    /// an unavailable Sidekick lets edits through, rather than silently
    /// blocking an agent's work because the reviewer wasn't on screen.
    private func drainDiffApprovalQueue() {
        let pending = diffApprovalQueue
        diffApprovalQueue.removeAll()
        for request in pending {
            request.completion(true)
        }
    }
}
