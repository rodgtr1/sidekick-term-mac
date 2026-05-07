import Cocoa

struct KeyboardShortcut {
    let keys: String
    let description: String
    let category: String
}

class KeyboardShortcutsPanel: NSPanel {
    private var tableView: NSTableView!
    private var shortcuts: [KeyboardShortcut] = []

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        loadShortcuts()
        setupUI()
    }

    private func setupPanel() {
        title = "Keyboard Shortcuts"
        level = .floating
        isFloatingPanel = true
        center()
    }

    private func loadShortcuts() {
        shortcuts = [
            // Tab Management
            KeyboardShortcut(keys: "⌘T", description: "New terminal tab", category: "Tabs"),
            KeyboardShortcut(keys: "⌘W", description: "Close the current tab", category: "Tabs"),
            KeyboardShortcut(keys: "⌃Tab", description: "Cycle to next tab", category: "Tabs"),
            KeyboardShortcut(keys: "⌃⇧Tab", description: "Cycle to previous tab", category: "Tabs"),
            KeyboardShortcut(keys: "⌘1-9", description: "Switch to specific tab by number", category: "Tabs"),

            // Pane Management
            KeyboardShortcut(keys: "⌘⇧W", description: "Close the current pane", category: "Panes"),
            KeyboardShortcut(keys: "⌘⇧D", description: "Split terminal right", category: "Panes"),
            KeyboardShortcut(keys: "⌘⇧X", description: "Split terminal down", category: "Panes"),
            KeyboardShortcut(keys: "⌘[", description: "Cycle to previous pane", category: "Panes"),
            KeyboardShortcut(keys: "⌘]", description: "Cycle to next pane", category: "Panes"),
            KeyboardShortcut(keys: "⌘⌥←/↑", description: "Cycle to previous pane (alternative)", category: "Panes"),
            KeyboardShortcut(keys: "⌘⌥→/↓", description: "Cycle to next pane (alternative)", category: "Panes"),

            // Sidebar
            KeyboardShortcut(keys: "⌘⇧B", description: "Toggle sidebar", category: "Sidebar"),
            KeyboardShortcut(keys: "⌘⇧E", description: "Show file explorer panel", category: "Sidebar"),
            KeyboardShortcut(keys: "⌘⇧G", description: "Show git panel", category: "Sidebar"),
            KeyboardShortcut(keys: "⌘⇧F", description: "Show search-in-files panel", category: "Sidebar"),
            KeyboardShortcut(keys: "⌘⇧R", description: "Show run panel", category: "Sidebar"),
            KeyboardShortcut(keys: "⌘⇧O", description: "Toggle embedded browser panel", category: "Sidebar"),

            // File Operations
            KeyboardShortcut(keys: "⌘F", description: "Quick open: search file names", category: "Files"),
            KeyboardShortcut(keys: "⌘S", description: "Save the current editor tab", category: "Files"),

            // General
            KeyboardShortcut(keys: "⌘K", description: "Show Keyboard Shortcuts", category: "General"),
            KeyboardShortcut(keys: "Esc", description: "Close Panel/Dialog", category: "General"),
        ]
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Container view with padding
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(hex: "#1e1e2e")?.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        // Title label
        let titleLabel = NSTextField(labelWithString: "Keyboard Shortcuts")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor(hex: "#cdd6f4")
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: "Press Esc to close this panel")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = NSColor(hex: "#6c7086")
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = NSColor.clear
        if #available(macOS 12.0, *) {
            tableView.style = .sourceList
        } else {
            tableView.selectionHighlightStyle = .sourceList
        }

        // Columns
        let keysColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Keys"))
        keysColumn.width = 150
        keysColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(keysColumn)

        let descColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Description"))
        descColumn.width = 400
        descColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(descColumn)

        let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        categoryColumn.width = 100
        categoryColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(categoryColumn)

        // Scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.backgroundColor = NSColor.clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(titleLabel)
        containerView.addSubview(subtitleLabel)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Container view
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Title
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Subtitle
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])

        // Setup table view
        tableView.dataSource = self
        tableView.delegate = self
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            close()
        default:
            super.keyDown(with: event)
        }
    }

    func show(relativeTo parentWindow: NSWindow) {
        // Position relative to parent window
        let parentFrame = parentWindow.frame
        let panelSize = frame.size
        let newOrigin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.midY - panelSize.height / 2
        )
        setFrameOrigin(newOrigin)

        // Show
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSTableViewDataSource
extension KeyboardShortcutsPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return shortcuts.count
    }
}

// MARK: - NSTableViewDelegate
extension KeyboardShortcutsPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shortcuts.count else { return nil }

        let shortcut = shortcuts[row]
        let cellView = NSTableCellView()

        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.textColor = NSColor(hex: "#cdd6f4")
        textField.translatesAutoresizingMaskIntoConstraints = false

        if tableColumn?.identifier.rawValue == "Keys" {
            textField.stringValue = shortcut.keys
            textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            textField.textColor = NSColor(hex: "#89b4fa") // Blue
        } else if tableColumn?.identifier.rawValue == "Description" {
            textField.stringValue = shortcut.description
        } else if tableColumn?.identifier.rawValue == "Category" {
            textField.stringValue = shortcut.category
            textField.textColor = NSColor(hex: "#6c7086") // Dim
            textField.font = NSFont.systemFont(ofSize: 11)
        }

        cellView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 28
    }
}
