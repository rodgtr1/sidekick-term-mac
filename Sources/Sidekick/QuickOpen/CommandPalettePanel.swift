import Cocoa

/// One executable action in the command palette.
struct PaletteAction {
    let title: String
    let subtitle: String?
    let symbolName: String
    let handler: () -> Void

    init(title: String, subtitle: String? = nil, symbolName: String = "command", handler: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.handler = handler
    }
}

/// Cmd+Shift+P palette: fuzzy-filters app actions and runs the selected one.
class CommandPalettePanel: NSPanel {
    private var searchField: NSSearchField!
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var searchFieldDelegate: SearchFieldDelegate?

    private var allActions: [PaletteAction] = []
    private var filteredActions: [PaletteAction] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        setupPanel()
        setupUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupPanel() {
        title = "Commands"
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        center()
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(hex: "#1e1e2e")?.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        searchField = NSSearchField()
        searchField.placeholderString = "Type a command…"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchFieldDelegate = SearchFieldDelegate()
        searchFieldDelegate?.escapeHandler = { [weak self] in
            self?.close()
        }
        searchFieldDelegate?.moveUpHandler = { [weak self] in
            self?.moveSelection(by: -1)
        }
        searchFieldDelegate?.moveDownHandler = { [weak self] in
            self?.moveSelection(by: 1)
        }
        searchFieldDelegate?.enterHandler = { [weak self] in
            self?.runSelectedAction()
        }
        searchField.delegate = searchFieldDelegate

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = .clear
        if #available(macOS 12.0, *) {
            tableView.style = .sourceList
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PaletteAction"))
        column.width = 520
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(searchField)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])

        tableView.dataSource = self
        tableView.delegate = self
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            close()
        case 125: // Down arrow
            moveSelection(by: 1)
        case 126: // Up arrow
            moveSelection(by: -1)
        case 36: // Return
            runSelectedAction()
        default:
            super.keyDown(with: event)
        }
    }

    private func moveSelection(by delta: Int) {
        let next = tableView.selectedRow + delta
        guard next >= 0 && next < filteredActions.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func runSelectedAction() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredActions.count else { return }
        let action = filteredActions[row]
        close()
        action.handler()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        applyFilter(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func tableViewDoubleClick(_ sender: NSTableView) {
        runSelectedAction()
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filteredActions = allActions
        } else {
            filteredActions = allActions
                .compactMap { action -> (PaletteAction, Int)? in
                    guard let score = Self.fuzzyScore(candidate: action.title, query: query) else { return nil }
                    return (action, score)
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        tableView.reloadData()
        if !filteredActions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Subsequence fuzzy match; higher scores for prefix/substring hits.
    static func fuzzyScore(candidate: String, query: String) -> Int? {
        let lowerCandidate = candidate.lowercased()
        let lowerQuery = query.lowercased()

        if lowerCandidate == lowerQuery { return 1000 }
        if lowerCandidate.hasPrefix(lowerQuery) { return 800 }
        if lowerCandidate.contains(lowerQuery) { return 600 }

        var queryIndex = lowerQuery.startIndex
        var score = 0
        for character in lowerCandidate {
            if queryIndex < lowerQuery.endIndex && character == lowerQuery[queryIndex] {
                score += 10
                queryIndex = lowerQuery.index(after: queryIndex)
            }
        }
        return queryIndex >= lowerQuery.endIndex ? score : nil
    }

    func show(relativeTo parentWindow: NSWindow, actions: [PaletteAction]) {
        allActions = actions
        filteredActions = actions

        let parentFrame = parentWindow.frame
        setFrameOrigin(NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.midY + 80
        ))

        searchField.stringValue = ""
        tableView.reloadData()
        if !filteredActions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }
}

extension CommandPalettePanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredActions.count
    }
}

extension CommandPalettePanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredActions.count else { return nil }
        let cell = PaletteActionCellView()
        cell.configure(with: filteredActions[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        32
    }
}

private final class PaletteActionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = NSColor(hex: "#89b4fa")

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(hex: "#cdd6f4")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor(hex: "#6c7086")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    func configure(with action: PaletteAction) {
        iconView.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        titleLabel.stringValue = action.title
        subtitleLabel.stringValue = action.subtitle ?? ""
    }
}
