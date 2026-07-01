import Cocoa
import SidekickTelemetryCore

protocol AgentDashboardDelegate: AnyObject {
    func agentDashboardTabs(_ dashboard: AgentDashboardViewController) -> [TabModel]
    func agentDashboard(_ dashboard: AgentDashboardViewController, didSelectTabAt index: Int)
}

/// Sidebar panel showing every tab's agent state with elapsed time.
/// Clicking a row jumps to that tab.
final class AgentDashboardViewController: NSViewController {
    weak var delegate: AgentDashboardDelegate?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    // Set on the main actor; invalidated in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var refreshTimer: Timer?

    /// The pending-approvals section above the agent list: a header plus one
    /// card per queued edit, keyed by approval id so queue changes add/remove
    /// cards without rebuilding the survivors (a rebuild would collapse an
    /// expanded diff mid-review).
    private var approvalsStack: NSStackView!
    private var approvalsHeader: NSTextField!
    private var approvalCards: [UUID: ApprovalCardView] = [:]

    private struct Row: Equatable {
        let tabIndex: Int
        let title: String
        let state: AgentState
        let since: Date
        let isActive: Bool
        let usage: TranscriptUsage?
        let cost: Double?
    }

    private var rows: [Row] = []

    /// Tag on each row's "state · elapsed" label, so the per-second tick can
    /// refresh it in place instead of reloading the table. A full reloadData
    /// rebuilds the cells and resets their tooltip tracking rects, which is why
    /// the telemetry tooltip never survived long enough to appear.
    private static let detailLabelTag = 0x5DE7A11   // "sidetail"

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .paneAgentStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .paneTelemetryChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentStateChanged),
            name: .pendingApprovalsChanged,
            object: nil
        )
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        emptyLabel?.textColor = AppTheme.mutedText
        approvalsHeader?.textColor = AppTheme.mutedText
        tableView?.reloadData()
        // Cards bake theme colors in at construction; rebuild them. (Loses an
        // expanded diff on theme switch — a rare, low-cost event.)
        for card in approvalCards.values { card.removeFromSuperview() }
        approvalCards.removeAll()
        reloadApprovals()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        // Tick to keep elapsed times fresh while the panel is visible.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func setupViews() {
        approvalsHeader = NSTextField(labelWithString: "PENDING APPROVALS")
        approvalsHeader.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        approvalsHeader.textColor = AppTheme.mutedText

        approvalsStack = NSStackView()
        approvalsStack.orientation = .vertical
        approvalsStack.alignment = .leading
        approvalsStack.spacing = 6
        approvalsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            tableView.style = .plain
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AgentColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "No agent activity.\nAgent states from Claude/Codex\nsessions appear here.")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = AppTheme.mutedText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(approvalsStack)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            approvalsStack.topAnchor.constraint(equalTo: view.topAnchor),
            approvalsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            approvalsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: approvalsStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)
        ])
    }

    @objc private func agentStateChanged() {
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        reloadApprovals()
        let tabs = delegate?.agentDashboardTabs(self) ?? []

        var newRows = tabs.enumerated().compactMap { index, tab -> Row? in
            guard tab.agentState != .idle else { return nil }
            return Row(
                tabIndex: index,
                title: tab.title,
                state: tab.agentState,
                since: tab.agentStateChangedAt,
                isActive: tab.isActive,
                usage: tab.telemetry,
                cost: tab.telemetryCostUSD
            )
        }
        // Actionable tabs first: needs-input, then working, then done.
        newRows.sort { lhs, rhs in
            let l = Self.sortPriority(lhs.state), r = Self.sortPriority(rhs.state)
            return l == r ? lhs.tabIndex < rhs.tabIndex : l < r
        }

        // Nothing structural changed (the common per-second tick): just advance
        // the elapsed times in place. Avoiding reloadData keeps the cells — and
        // their telemetry tooltip tracking — alive long enough to show on hover.
        if newRows == rows {
            refreshElapsedInPlace()
            return
        }

        rows = newRows
        emptyLabel.isHidden = !rows.isEmpty || !ApprovalQueue.shared.pending.isEmpty
        tableView.reloadData()
        selectActiveRow()
    }

    /// Syncs the approvals section with the queue: cards for resolved entries
    /// go, cards for new entries are appended (queue order — FIFO), surviving
    /// cards are left alone so their expanded diff and popup state persist.
    /// The per-second tick lands here too, refreshing each card's elapsed time.
    private func reloadApprovals() {
        let pending = ApprovalQueue.shared.pending
        let pendingIDs = Set(pending.map(\.id))

        for (id, card) in approvalCards where !pendingIDs.contains(id) {
            card.removeFromSuperview()
            approvalCards[id] = nil
        }

        if pending.isEmpty {
            approvalsHeader.removeFromSuperview()
            approvalsStack.edgeInsets = NSEdgeInsets()
        } else {
            approvalsStack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 6, right: 0)
            if approvalsHeader.superview == nil {
                approvalsStack.insertArrangedSubview(approvalsHeader, at: 0)
            }
        }

        for entry in pending where approvalCards[entry.id] == nil {
            let card = ApprovalCardView(approval: entry, paneLabel: paneLabel(forPane: entry.paneID)) { outcome in
                ApprovalQueue.shared.resolve(id: entry.id, outcome: outcome)
            }
            approvalCards[entry.id] = card
            approvalsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: approvalsStack.widthAnchor).isActive = true
        }

        for card in approvalCards.values {
            card.refreshElapsed()
        }
    }

    /// Display label for the pane an approval came from: the owning tab's
    /// title, disambiguated with the pane's position when the tab is split.
    private func paneLabel(forPane paneID: UUID?) -> String {
        guard let paneID,
              let tabs = delegate?.agentDashboardTabs(self),
              let tab = tabs.first(where: { $0.panes.contains { $0.id == paneID } }) else {
            return "Unknown pane"
        }
        if tab.panes.count > 1, let index = tab.panes.firstIndex(where: { $0.id == paneID }) {
            return "\(tab.title) · pane \(index + 1)"
        }
        return tab.title
    }

    /// Keeps the highlighted row in sync with the active tab, so cycling tabs
    /// (Ctrl+Tab) moves the selection here too — not just the standard arrow
    /// keys when the table itself is focused.
    private func selectActiveRow() {
        guard let activeRow = rows.firstIndex(where: { $0.isActive }) else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRow != activeRow {
            tableView.selectRowIndexes(IndexSet(integer: activeRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(activeRow)
        }
    }

    /// Updates each visible row's "state · elapsed" label from its current data,
    /// without rebuilding the cell.
    private func refreshElapsedInPlace() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< (visible.location + visible.length) {
            guard row < rows.count,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
                  let detail = cell.viewWithTag(Self.detailLabelTag) as? NSTextField else { continue }
            let rowData = rows[row]
            let (stateLabel, _) = Self.describe(rowData.state)
            detail.stringValue = "\(stateLabel) · \(Self.elapsedString(since: rowData.since))"
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count else { return }
        delegate?.agentDashboard(self, didSelectTabAt: rows[row].tabIndex)
    }

    private static func sortPriority(_ state: AgentState) -> Int {
        switch state {
        case .ready: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }

    fileprivate static func describe(_ state: AgentState) -> (label: String, color: NSColor) {
        switch state {
        case .working: return ("Working", AppTheme.warning)
        case .ready: return ("Needs input", AppTheme.success)
        case .done: return ("Done", AppTheme.accent)
        case .idle: return ("Idle", AppTheme.mutedText)
        }
    }

    fileprivate static func elapsedString(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    // MARK: - Telemetry formatting

    /// Compact one-line telemetry for a row: `opus-4.8 · $0.36 · 7t`. Cost and
    /// turns are dropped when unavailable. Returns nil when there's nothing
    /// billed yet to show.
    fileprivate static func telemetryLine(_ usage: TranscriptUsage, cost: Double?) -> String? {
        guard usage.assistantResponses > 0 else { return nil }
        var parts: [String] = []
        if let model = usage.model { parts.append(TelemetryFormat.shortModel(model)) }
        if let cost { parts.append(TelemetryFormat.cost(cost)) }
        if usage.userPrompts > 0 { parts.append("\(usage.userPrompts)t") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Full breakdown for the row tooltip.
    fileprivate static func telemetryTooltip(_ usage: TranscriptUsage) -> String {
        var lines = ["in \(TelemetryFormat.compactTokens(usage.totalInputTokens)) · out \(TelemetryFormat.compactTokens(usage.outputTokens))"]
        if usage.cacheReadTokens > 0 { lines.append("cache read \(TelemetryFormat.compactTokens(usage.cacheReadTokens))") }
        lines.append("\(usage.assistantResponses) responses · \(usage.userPrompts) prompts")
        return lines.joined(separator: "\n")
    }
}

extension AgentDashboardViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension AgentDashboardViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let rowData = rows[row]
        let (stateLabel, stateColor) = Self.describe(rowData.state)

        let cell = NSTableCellView()
        cell.wantsLayer = true

        if rowData.isActive {
            cell.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor

            let accent = NSView()
            accent.wantsLayer = true
            accent.layer?.backgroundColor = stateColor.withAlphaComponent(0.7).cgColor
            accent.layer?.cornerRadius = 1
            accent.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(accent)
            NSLayoutConstraint.activate([
                accent.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                accent.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                accent.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
                accent.widthAnchor.constraint(equalToConstant: 2)
            ])
        }

        let dot = NSTextField(labelWithString: "●")
        dot.font = NSFont.systemFont(ofSize: 10)
        dot.textColor = stateColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: rowData.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(
            labelWithString: "\(stateLabel) · \(Self.elapsedString(since: rowData.since))"
        )
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = stateColor
        detailLabel.tag = Self.detailLabelTag
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(dot)
        cell.addSubview(titleLabel)
        cell.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])

        // Telemetry line (model · est$ · turns), with the full breakdown on hover.
        var lastBottom: NSLayoutYAxisAnchor = detailLabel.bottomAnchor
        if let usage = rowData.usage, let line = Self.telemetryLine(usage, cost: rowData.cost) {
            let telemetryLabel = NSTextField(labelWithString: line)
            telemetryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            telemetryLabel.textColor = AppTheme.mutedText
            telemetryLabel.lineBreakMode = .byTruncatingTail
            telemetryLabel.toolTip = Self.telemetryTooltip(usage)
            telemetryLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(telemetryLabel)
            NSLayoutConstraint.activate([
                telemetryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                telemetryLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 2),
                telemetryLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
            ])
            lastBottom = telemetryLabel.bottomAnchor
        }

        // Context-window bar: fills left→right with the share of the model's
        // context window the latest turn occupies. Only shown once a turn has
        // been billed (fraction != nil).
        if let usage = rowData.usage, let fraction = usage.contextFraction() {
            let bar = Self.makeContextBar(fraction: fraction)
            bar.toolTip = Self.contextTooltip(usage)
            cell.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                bar.topAnchor.constraint(equalTo: lastBottom, constant: 5)
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count, let usage = rows[row].usage else { return 42 }
        var height: CGFloat = 42
        if Self.telemetryLine(usage, cost: rows[row].cost) != nil { height += 16 }
        if usage.contextFraction() != nil { height += 9 }
        return height
    }

    // MARK: - Context bar

    /// A thin two-layer bar (muted track + colored fill) whose fill spans
    /// `fraction` of the width. Color shifts green→yellow→red as it fills.
    private static func makeContextBar(fraction: Double) -> NSView {
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = AppTheme.divider.withAlphaComponent(0.6).cgColor
        track.layer?.cornerRadius = 2

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = contextBarColor(fraction).cgColor
        fill.layer?.cornerRadius = 2
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        track.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 4),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            // A near-empty window still shows a sliver so the bar reads as a bar.
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: CGFloat(max(0.02, fraction)))
        ])
        return track
    }

    private static func contextBarColor(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.6: return AppTheme.success
        case ..<0.85: return AppTheme.warning
        default: return AppTheme.error
        }
    }

    /// Hover text for the context bar, e.g. `context 82k / 200k (41%)`.
    private static func contextTooltip(_ usage: TranscriptUsage) -> String {
        guard let fraction = usage.contextFraction() else { return "" }
        let window = ContextWindow.tokens(forModel: usage.model, occupancy: usage.contextTokens)
        let percent = Int((fraction * 100).rounded())
        return "context \(TelemetryFormat.compactTokens(usage.contextTokens)) / \(TelemetryFormat.compactTokens(window)) (\(percent)%)"
    }
}

// MARK: - Approval card

/// One queued edit in the approvals section: file name, originating pane,
/// elapsed wait, an expandable inline diff, and the approve/reject controls
/// with the same "remember" scopes the old modal sheet offered. Resolving
/// reports the outcome and the card's removal follows from the queue change.
private final class ApprovalCardView: NSView {
    private let approval: PendingApproval
    private let onResolve: (ApprovalOutcome) -> Void

    private let metaLabel = NSTextField(labelWithString: "")
    private let paneLabel: String
    private let rememberPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let diffButton = NSButton(title: "Show diff", target: nil, action: nil)
    private let stack = NSStackView()
    private var diffScroll: NSScrollView?

    /// Menu order for the "remember" popup; index maps to `RememberScope`.
    /// Titles are shorter than the sheet's — the sidebar is ~250pt wide.
    private static let rememberScopes: [(title: String, scope: RememberScope)] = [
        ("Just this once", .none),
        ("Remember file", .file),
        ("Remember folder", .folder),
        ("Whole session", .session)
    ]

    init(approval: PendingApproval, paneLabel: String, onResolve: @escaping (ApprovalOutcome) -> Void) {
        self.approval = approval
        self.paneLabel = paneLabel
        self.onResolve = onResolve
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = AppTheme.divider.withAlphaComponent(0.6).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let fileLabel = NSTextField(labelWithString: (approval.path as NSString).lastPathComponent)
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        fileLabel.textColor = AppTheme.primaryText
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.toolTip = approval.path

        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = AppTheme.mutedText
        metaLabel.lineBreakMode = .byTruncatingTail
        refreshElapsed()

        diffButton.target = self
        diffButton.action = #selector(toggleDiff)
        diffButton.bezelStyle = .inline
        diffButton.controlSize = .small
        diffButton.font = NSFont.systemFont(ofSize: 11)

        for entry in Self.rememberScopes {
            rememberPopup.addItem(withTitle: entry.title)
        }
        rememberPopup.controlSize = .small
        rememberPopup.font = NSFont.systemFont(ofSize: 11)
        rememberPopup.toolTip = "Whether to keep approving similar edits for the rest of this session"

        let rejectButton = NSButton(title: "Reject", target: self, action: #selector(rejectClicked))
        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small

        let approveButton = NSButton(title: "Approve", target: self, action: #selector(approveClicked))
        approveButton.bezelStyle = .rounded
        approveButton.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [diffButton, spacer, rejectButton, approveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(fileLabel)
        stack.addArrangedSubview(metaLabel)
        stack.addArrangedSubview(rememberPopup)
        stack.addArrangedSubview(buttonRow)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Updates the "pane · waiting 12s" line; driven by the dashboard's
    /// per-second tick while the panel is visible.
    func refreshElapsed() {
        let seconds = max(0, Int(Date().timeIntervalSince(approval.requestedAt)))
        let elapsed: String
        if seconds < 60 { elapsed = "\(seconds)s" }
        else if seconds < 3600 { elapsed = "\(seconds / 60)m \(seconds % 60)s" }
        else { elapsed = "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        metaLabel.stringValue = "\(paneLabel) · waiting \(elapsed)"
    }

    @objc private func approveClicked() {
        let scope = Self.rememberScopes[safe: rememberPopup.indexOfSelectedItem]?.scope ?? .none
        onResolve(ApprovalOutcome(accepted: true, remember: scope))
    }

    @objc private func rejectClicked() {
        onResolve(.rejected)
    }

    @objc private func toggleDiff() {
        if let diffScroll {
            diffScroll.isHidden.toggle()
            diffButton.title = diffScroll.isHidden ? "Show diff" : "Hide diff"
            return
        }
        diffButton.title = "Hide diff"
        buildDiffView()
    }

    /// Builds the inline diff on first expansion. The diff shells out to
    /// /usr/bin/diff, so it's computed off the main thread and rendered when
    /// ready — same pattern the old sheet used.
    private func buildDiffView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = AppTheme.windowBackground
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = AppTheme.windowBackground
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = "Computing diff…"
        scroll.documentView = textView

        // Below the button row, above the card's bottom inset.
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 200),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        diffScroll = scroll

        let (old, new, path) = (approval.old, approval.new, approval.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak textView] in
            let diffText = UnifiedDiff.text(old: old, new: new, path: path)
            let ext = (path as NSString).pathExtension.lowercased()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let rendered = InlineDiffRenderer.render(diffText, fileExtension: ext)
                    textView?.textStorage?.setAttributedString(rendered)
                }
            }
        }
    }
}
