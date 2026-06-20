import Cocoa

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

    private struct Row {
        let tabIndex: Int
        let title: String
        let state: AgentState
        let since: Date
        let isActive: Bool
    }

    private var rows: [Row] = []

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
            name: NSNotification.Name("PaneAgentStateChanged"),
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

        rows = tabs.enumerated().compactMap { index, tab in
            guard tab.agentState != .idle else { return nil }
            return Row(
                tabIndex: index,
                title: tab.title,
                state: tab.agentState,
                since: tab.agentStateChangedAt,
                isActive: tab.isActive
            )
        }
        // Actionable tabs first: needs-input, then working, then done.
        rows.sort { lhs, rhs in
            let l = Self.sortPriority(lhs.state), r = Self.sortPriority(rhs.state)
            return l == r ? lhs.tabIndex < rhs.tabIndex : l < r
        }

        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
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

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        42
    }
}
