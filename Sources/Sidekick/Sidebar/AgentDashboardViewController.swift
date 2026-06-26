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
    private var refreshTimer: Timer?

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
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        emptyLabel?.textColor = AppTheme.mutedText
        tableView?.reloadData()
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
            self?.reload()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func setupViews() {
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

        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
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
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count, let usage = rows[row].usage,
              Self.telemetryLine(usage, cost: rows[row].cost) != nil else {
            return 42
        }
        return 58
    }
}
