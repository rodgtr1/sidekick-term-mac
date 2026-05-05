import Cocoa

protocol QuickOpenPanelDelegate: AnyObject {
    func quickOpenPanel(_ panel: QuickOpenPanel, didSelectFile filePath: String)
}

struct FileResult {
    let path: String
    let relativePath: String
    let fileName: String
    let score: Int
    let directory: String
}

class QuickOpenPanel: NSPanel {
    private var searchField: NSSearchField!
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var findTask: Process?
    private var debounceWorkItem: DispatchWorkItem?

    weak var quickOpenDelegate: QuickOpenPanelDelegate?

    private var fileResults: [FileResult] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath
    private let maxResults = 50

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        setupPanel()
        setupUI()
        setupKeyboardHandling()
    }

    private func setupPanel() {
        title = "Quick Open"
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false

        // Center on screen
        center()

        // Style
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Make sure it can become key - handled by override methods
    }

    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return false
    }

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Container view with padding
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(hex: "#1e1e2e")?.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(containerView)

        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Type to search files..."
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false

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
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))

        // Column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileResult"))
        column.width = 560
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        // Scroll view
        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.backgroundColor = NSColor.clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(searchField)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Container view
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Search field
            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])

        // Setup table view
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func setupKeyboardHandling() {
        // Override key handling
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            close()
        case 125: // Down arrow
            selectNextRow()
        case 126: // Up arrow
            selectPreviousRow()
        case 36: // Return
            if let selectedRow = getSelectedRow() {
                selectFileAtRow(selectedRow)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func selectNextRow() {
        let selectedRow = tableView.selectedRow
        let nextRow = selectedRow + 1
        if nextRow < fileResults.count {
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(nextRow)
        }
    }

    private func selectPreviousRow() {
        let selectedRow = tableView.selectedRow
        let previousRow = selectedRow - 1
        if previousRow >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: previousRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(previousRow)
        }
    }

    private func getSelectedRow() -> Int? {
        let selectedRow = tableView.selectedRow
        return selectedRow >= 0 && selectedRow < fileResults.count ? selectedRow : nil
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let searchText = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel previous debounce work
        debounceWorkItem?.cancel()

        // Cancel current find task
        findTask?.terminate()

        if searchText.isEmpty {
            fileResults = []
            tableView.reloadData()
            return
        }

        // Debounce search by 150ms
        let workItem = DispatchWorkItem { [weak self] in
            self?.performFileSearch(searchText)
        }
        debounceWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performFileSearch(_ searchText: String) {
        // Use fd for fast file finding, fall back to find
        let task = Process()

        // Try fd first (faster)
        if FileManager.default.fileExists(atPath: "/usr/local/bin/fd") {
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/fd")
            task.arguments = [
                "--type", "f",
                "--max-results", String(maxResults),
                "--exclude", ".git",
                "--exclude", "node_modules",
                "--exclude", ".build",
                "--exclude", "target",
                ".",
                currentWorkingDirectory
            ]
        } else {
            // Fallback to find
            task.executableURL = URL(fileURLWithPath: "/usr/bin/find")
            task.arguments = [
                currentWorkingDirectory,
                "-type", "f",
                "-not", "-path", "*/.*",
                "-not", "-path", "*/node_modules/*",
                "-not", "-path", "*/.build/*",
                "-not", "-path", "*/target/*"
            ]
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress errors

        // Store reference
        findTask = task

        do {
            try task.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            DispatchQueue.main.async { [weak self] in
                self?.parseFileResults(data, searchText: searchText)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.fileResults = []
                self?.tableView.reloadData()
            }
        }
    }

    private func parseFileResults(_ data: Data, searchText: String) {
        guard let output = String(data: data, encoding: .utf8) else {
            fileResults = []
            tableView.reloadData()
            return
        }

        let lines = output.components(separatedBy: .newlines)
        var results: [FileResult] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let url = URL(fileURLWithPath: trimmedLine)
            let fileName = url.lastPathComponent
            let directory = url.deletingLastPathComponent().lastPathComponent

            // Calculate fuzzy match score
            let score = calculateFuzzyScore(fileName: fileName, searchText: searchText)
            guard score > 0 else { continue }

            let relativePath = trimmedLine.hasPrefix(currentWorkingDirectory) ?
                String(trimmedLine.dropFirst(currentWorkingDirectory.count + 1)) : trimmedLine

            let result = FileResult(
                path: trimmedLine,
                relativePath: relativePath,
                fileName: fileName,
                score: score,
                directory: directory
            )

            results.append(result)
        }

        // Sort by score (higher is better) and limit results
        fileResults = results.sorted { $0.score > $1.score }.prefix(maxResults).map { $0 }

        tableView.reloadData()

        // Auto-select first result
        if !fileResults.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func calculateFuzzyScore(fileName: String, searchText: String) -> Int {
        let lowerFileName = fileName.lowercased()
        let lowerSearchText = searchText.lowercased()

        // Exact match gets highest score
        if lowerFileName == lowerSearchText {
            return 1000
        }

        // Starts with search text gets high score
        if lowerFileName.hasPrefix(lowerSearchText) {
            return 800
        }

        // Contains search text gets medium score
        if lowerFileName.contains(lowerSearchText) {
            return 600
        }

        // Fuzzy match: check if all characters from search exist in order
        var searchIndex = lowerSearchText.startIndex
        var score = 0

        for char in lowerFileName {
            if searchIndex < lowerSearchText.endIndex && char == lowerSearchText[searchIndex] {
                score += 10
                searchIndex = lowerSearchText.index(after: searchIndex)
            }
        }

        // Return score only if all search characters were matched
        return searchIndex >= lowerSearchText.endIndex ? score : 0
    }

    @objc private func tableViewDoubleClick(_ sender: NSTableView) {
        if let selectedRow = getSelectedRow() {
            selectFileAtRow(selectedRow)
        }
    }

    private func selectFileAtRow(_ row: Int) {
        guard row < fileResults.count else { return }

        let result = fileResults[row]
        quickOpenDelegate?.quickOpenPanel(self, didSelectFile: result.path)
        close()
    }

    func show(relativeTo parentWindow: NSWindow, workingDirectory: String) {
        currentWorkingDirectory = workingDirectory

        // Position relative to parent window
        let parentFrame = parentWindow.frame
        let panelSize = frame.size
        let newOrigin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.midY + 100
        )
        setFrameOrigin(newOrigin)

        // Clear previous search
        fileResults = []
        tableView.reloadData()
        searchField.stringValue = ""

        // Show and focus
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
    }

    override func close() {
        // Cancel any running tasks
        debounceWorkItem?.cancel()
        findTask?.terminate()

        super.close()
    }
}

// MARK: - NSTableViewDataSource
extension QuickOpenPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return fileResults.count
    }
}

// MARK: - NSTableViewDelegate
extension QuickOpenPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < fileResults.count else { return nil }

        let result = fileResults[row]
        let cellView = QuickOpenCellView()
        cellView.configure(with: result)

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 32
    }
}

// MARK: - Custom Cell View
class QuickOpenCellView: NSTableCellView {
    private var fileNameLabel: NSTextField!
    private var pathLabel: NSTextField!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        fileNameLabel = NSTextField(labelWithString: "")
        fileNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fileNameLabel.textColor = NSColor(hex: "#cdd6f4")
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = NSColor(hex: "#6c7086")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(fileNameLabel)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            fileNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            fileNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            pathLabel.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 1),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(with result: FileResult) {
        fileNameLabel.stringValue = result.fileName
        pathLabel.stringValue = result.relativePath
    }
}