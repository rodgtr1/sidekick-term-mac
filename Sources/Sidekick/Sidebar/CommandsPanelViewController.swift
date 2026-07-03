import Cocoa

protocol CommandsPanelDelegate: AnyObject {
    /// The terminal whose command history the panel shows and acts on — the
    /// active pane's, or nil when the active pane isn't a terminal.
    func commandsPanelActiveTerminal(_ panel: CommandsPanelViewController) -> TerminalViewController?
}

/// Pure presentation helpers for the command timeline, kept apart from the view
/// so the formatting is unit-testable. `nonisolated` so tests (and any
/// off-main-actor caller) can reach it despite the module's main-actor default.
nonisolated enum CommandTimelineFormat {
    /// Badge text for an exit code: a check on success, else a cross with code.
    static func exitBadge(exitCode: Int) -> String {
        exitCode == 0 ? "✓" : "✗ \(exitCode)"
    }

    /// Human duration for a finished command, or "" when it wasn't measured.
    static func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "" }
        if duration >= 60 {
            return "\(Int(duration) / 60)m \(Int(duration) % 60)s"
        }
        return String(format: "%.1fs", duration)
    }

    /// A command flattened to a single trimmed line for the row title — a pasted
    /// multi-line command would otherwise break the row layout.
    static func singleLineCommand(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last `maxLines` lines of captured output, for the expandable tail.
    /// Returns the whole output when it's already within the cap.
    static func outputTail(_ output: String, maxLines: Int) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return output }
        return lines.suffix(maxLines).map(String.init).joined(separator: "\n")
    }
}

/// Sidebar panel listing the active terminal's recent OSC 133 commands,
/// newest-first: command line, exit badge, duration, and an expandable output
/// tail. Rows carry copy / re-run / jump-to actions. Refreshes on the
/// `paneCommandStatusChanged` notification and whenever the active pane changes.
final class CommandsPanelViewController: NSViewController {
    weak var delegate: CommandsPanelDelegate?

    /// Newest-first snapshot of the active terminal's finished commands.
    private var records: [TerminalCommandRecord] = []
    /// Row keys whose output tail is expanded, kept across reloads so a new
    /// command finishing doesn't collapse the row the user is reading.
    private var expandedKeys: Set<String> = []

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var themeObserver: ThemeObserver?

    /// Output tail lines shown when a row is expanded.
    private static let maxTailLines = 12

    /// Geometry for the expandable output tail. The label soft-wraps, so its
    /// height depends on the laid-out width; `heightOfRow` measures against this
    /// (font + insets) rather than counting logical lines, and `viewDidLayout`
    /// re-measures when the sidebar width changes. Mirrors the seed-then-correct
    /// fix in `UncommittedChangesViewController`.
    private static let outputFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let outputLeadingInset: CGFloat = 12
    private static let outputTrailingInset: CGFloat = 8
    /// Top gap above the tail plus its bottom inset.
    private static let outputVerticalPadding: CGFloat = 12

    /// Table width the expanded rows were last measured at; a change triggers a
    /// re-measure in `viewDidLayout`.
    private var lastMeasuredTableWidth: CGFloat = 0

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(commandStatusChanged),
            name: .paneCommandStatusChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The expanded output tail wraps to the table's width; re-measure the
        // open rows when that width changes so a sidebar resize doesn't clip
        // (or leave dead space under) long, wrapped output lines.
        let width = tableView.bounds.width
        guard abs(width - lastMeasuredTableWidth) > 0.5 else { return }
        lastMeasuredTableWidth = width
        let expandedRows = IndexSet(records.indices.filter { isExpanded(records[$0]) })
        guard !expandedRows.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: expandedRows)
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        tableView?.backgroundColor = AppTheme.sidebarBackground
        emptyLabel?.textColor = AppTheme.mutedText
        tableView?.reloadData()
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommandColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "No commands yet.\nRun a command in a shell with\nintegration to see it here.")
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

    @objc private func commandStatusChanged() {
        reload()
    }

    /// Re-reads the active terminal's records (newest-first) and repaints.
    func reload() {
        guard isViewLoaded else { return }
        let terminal = delegate?.commandsPanelActiveTerminal(self)
        records = (terminal?.recentCommandRecords() ?? []).reversed()

        // Forget expansion state for rows no longer present (pane switched, or
        // the record aged out of the recorder's ring buffer).
        let liveKeys = Set(records.map(Self.key(for:)))
        expandedKeys.formIntersection(liveKeys)

        emptyLabel.isHidden = !records.isEmpty
        tableView.reloadData()
    }

    /// Stable identity for a record across reloads: its finish time plus command.
    private static func key(for record: TerminalCommandRecord) -> String {
        "\(record.finishedAt.timeIntervalSince1970)|\(record.command)"
    }

    private func isExpanded(_ record: TerminalCommandRecord) -> Bool {
        expandedKeys.contains(Self.key(for: record))
    }

    // MARK: - Row actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < records.count else { return }
        let key = Self.key(for: records[row])
        if expandedKeys.contains(key) {
            expandedKeys.remove(key)
        } else {
            expandedKeys.insert(key)
        }
        tableView.reloadData()
    }

    @objc private func copyClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < records.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(records[row].output, forType: .string)
    }

    @objc private func rerunClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < records.count,
              let terminal = delegate?.commandsPanelActiveTerminal(self) else { return }
        terminal.send(text: records[row].command)
        terminal.send(key: "enter")
    }

    @objc private func jumpClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < records.count,
              let promptRow = records[row].promptRow,
              let terminal = delegate?.commandsPanelActiveTerminal(self) else { return }
        terminal.jumpToPrompt(row: promptRow)
    }
}

extension CommandsPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }
}

extension CommandsPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < records.count else { return nil }
        let record = records[row]
        let succeeded = record.exitCode == 0

        let cell = NSTableCellView()

        let badge = NSTextField(labelWithString: CommandTimelineFormat.exitBadge(exitCode: record.exitCode))
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = succeeded ? AppTheme.success : AppTheme.error
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let commandLabel = NSTextField(labelWithString: CommandTimelineFormat.singleLineCommand(record.command))
        commandLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandLabel.textColor = AppTheme.primaryText
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.toolTip = record.command
        commandLabel.translatesAutoresizingMaskIntoConstraints = false

        let durationText = CommandTimelineFormat.duration(record.duration)
        let metaLabel = NSTextField(labelWithString: durationText.isEmpty ? "exit \(record.exitCode)" : "\(durationText) · exit \(record.exitCode)")
        metaLabel.font = NSFont.systemFont(ofSize: 10.5)
        metaLabel.textColor = AppTheme.mutedText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = Self.actionButton(symbol: "doc.on.doc", tooltip: "Copy output", target: self, action: #selector(copyClicked(_:)))
        let rerunButton = Self.actionButton(symbol: "arrow.clockwise", tooltip: "Re-run command", target: self, action: #selector(rerunClicked(_:)))
        let jumpButton = Self.actionButton(symbol: "arrow.right.to.line", tooltip: "Jump to command in terminal", target: self, action: #selector(jumpClicked(_:)))
        // Jump needs a prompt mark; disable it when the record has none.
        jumpButton.isEnabled = record.promptRow != nil
        let buttons = NSStackView(views: [copyButton, rerunButton, jumpButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(badge)
        cell.addSubview(commandLabel)
        cell.addSubview(metaLabel)
        cell.addSubview(buttons)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),

            commandLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            commandLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            commandLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),

            metaLabel.leadingAnchor.constraint(equalTo: commandLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 3),

            buttons.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: metaLabel.trailingAnchor, constant: 6)
        ])

        // Expanded output tail below the meta row.
        if isExpanded(record) {
            let tail = CommandTimelineFormat.outputTail(record.output, maxLines: Self.maxTailLines)
            let outputLabel = NSTextField(wrappingLabelWithString: tail.isEmpty ? "(no output)" : tail)
            outputLabel.font = Self.outputFont
            outputLabel.textColor = tail.isEmpty ? AppTheme.mutedText : AppTheme.primaryText
            outputLabel.isSelectable = true
            outputLabel.wantsLayer = true
            outputLabel.layer?.backgroundColor = AppTheme.windowBackground.cgColor
            outputLabel.layer?.cornerRadius = 4
            outputLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(outputLabel)
            // Fixed insets (not aligned to the command label, whose leading
            // shifts with the badge width) so heightOfRow can measure the exact
            // wrap width.
            NSLayoutConstraint.activate([
                outputLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.outputLeadingInset),
                outputLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.outputTrailingInset),
                outputLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 5),
                outputLabel.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6)
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < records.count else { return 44 }
        let base: CGFloat = 44
        guard isExpanded(records[row]) else { return base }
        return base + expandedOutputHeight(records[row])
    }

    /// Height the expanded output tail needs, measured against the real wrap
    /// width so soft-wrapped long lines (build logs, minified output) aren't
    /// clipped. Falls back to a line-count seed before the table has a width;
    /// `viewDidLayout` re-measures once it does.
    private func expandedOutputHeight(_ record: TerminalCommandRecord) -> CGFloat {
        let tail = CommandTimelineFormat.outputTail(record.output, maxLines: Self.maxTailLines)
        let text = tail.isEmpty ? "(no output)" : tail
        let available = tableView.bounds.width - Self.outputLeadingInset - Self.outputTrailingInset
        guard available > 0 else {
            let lineCount = tail.isEmpty ? 1 : tail.split(separator: "\n", omittingEmptySubsequences: false).count
            return CGFloat(lineCount) * 14 + Self.outputVerticalPadding
        }
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: Self.outputFont]
        )
        return ceil(bounding.height) + Self.outputVerticalPadding
    }

    /// A small borderless SF Symbol button for a row action.
    private static func actionButton(symbol: String, tooltip: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = AppTheme.mutedText
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }
}
