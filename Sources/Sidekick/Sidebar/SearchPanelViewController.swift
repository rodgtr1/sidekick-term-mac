import Cocoa
import Combine

protocol SearchPanelDelegate: AnyObject {
    func searchPanel(_ panel: SearchPanelViewController, didRequestOpenFile filePath: String, atLine line: Int)
}

struct SearchMatch {
    let filePath: String
    let fileName: String
    let line: Int
    let column: Int
    let text: String
    let matchedText: String
}

class SearchPanelViewController: NSViewController {
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Process?
    private var debounceWorkItem: DispatchWorkItem?

    weak var delegate: SearchPanelDelegate?

    // UI Elements
    private var searchField: NSSearchField!
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    // Data
    private var searchMatches: [SearchMatch] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupTableView()
        layoutViews()
    }

    private func setupUI() {
        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Search files..."
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Status label
        statusLabel = NSTextField(labelWithString: "Type to search files")
        statusLabel.textColor = NSColor(hex: "#6c7086")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .small
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClick(_:))

        // Column for search results
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SearchResult"))
        column.width = 300
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        // Scroll view
        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppTheme.sidebarBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(statusLabel)
        view.addSubview(scrollView)
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            // Search field
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 22),

            // Status label
            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        let searchText = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel previous debounce work
        debounceWorkItem?.cancel()

        // Cancel current search
        searchTask?.terminate()

        if searchText.isEmpty {
            searchMatches = []
            statusLabel.stringValue = "Type to search files"
            tableView.reloadData()
            return
        }

        // Debounce search by 200ms
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSearch(searchText)
        }
        debounceWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func performSearch(_ searchText: String) {
        statusLabel.stringValue = "Searching..."

        // Create ripgrep process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/local/bin/rg")
        task.arguments = [
            "--json",
            "--no-heading",
            "--line-number",
            "--column",
            "--max-count", "10", // Limit matches per file
            "--max-filesize", "2M", // Skip large files
            "--type-not", "binary",
            searchText,
            currentWorkingDirectory
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress errors

        // Store reference to cancel if needed
        searchTask = task

        do {
            try task.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            DispatchQueue.main.async { [weak self] in
                self?.parseSearchResults(data)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "Search failed: ripgrep not found"
            }
        }
    }

    private func parseSearchResults(_ data: Data) {
        guard let output = String(data: data, encoding: .utf8) else {
            statusLabel.stringValue = "No results"
            return
        }

        var matches: [SearchMatch] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            guard !line.isEmpty else { continue }

            // Parse JSON line from ripgrep
            if let jsonData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let type = json["type"] as? String,
               type == "match",
               let data = json["data"] as? [String: Any],
               let path = data["path"] as? [String: Any],
               let filePath = path["text"] as? String,
               let lineNumber = data["line_number"] as? Int,
               let lines = data["lines"] as? [String: Any],
               let text = lines["text"] as? String {

                let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                let column = data["absolute_offset"] as? Int ?? 0

                let match = SearchMatch(
                    filePath: filePath,
                    fileName: fileName,
                    line: lineNumber,
                    column: column,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    matchedText: searchField.stringValue
                )

                matches.append(match)
            }
        }

        searchMatches = matches
        statusLabel.stringValue = matches.isEmpty ? "No results" : "\(matches.count) matches"
        tableView.reloadData()
    }

    @objc private func tableViewDoubleClick(_ sender: NSTableView) {
        let selectedRow = sender.selectedRow
        guard selectedRow >= 0 && selectedRow < searchMatches.count else { return }

        let match = searchMatches[selectedRow]
        delegate?.searchPanel(self, didRequestOpenFile: match.filePath, atLine: match.line)
    }

    func updateWorkingDirectory(_ directory: String) {
        currentWorkingDirectory = directory

        // Re-run search if there's text in the search field
        let searchText = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchText.isEmpty {
            performSearch(searchText)
        }
    }
}

// MARK: - NSTableViewDataSource
extension SearchPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return searchMatches.count
    }
}

// MARK: - NSTableViewDelegate
extension SearchPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < searchMatches.count else { return nil }

        let match = searchMatches[row]
        let cellView = SearchResultCellView()
        cellView.configure(with: match)

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44
    }
}

// MARK: - Custom Cell View
class SearchResultCellView: NSTableCellView {
    private var fileLabel: NSTextField!
    private var pathLabel: NSTextField!
    private var lineLabel: NSTextField!
    private var textLabel: NSTextField!

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

        fileLabel = NSTextField(labelWithString: "")
        fileLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fileLabel.textColor = NSColor(hex: "#cdd6f4")
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        pathLabel.textColor = NSColor(hex: "#6c7086")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        lineLabel = NSTextField(labelWithString: "")
        lineLabel.font = NSFont.systemFont(ofSize: 10)
        lineLabel.textColor = NSColor(hex: "#f38ba8")
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.alignment = .right

        textLabel = NSTextField(labelWithString: "")
        textLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textLabel.textColor = NSColor(hex: "#a6adc8")
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.lineBreakMode = .byTruncatingTail

        addSubview(fileLabel)
        addSubview(pathLabel)
        addSubview(lineLabel)
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            fileLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            fileLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileLabel.trailingAnchor.constraint(equalTo: lineLabel.leadingAnchor, constant: -8),

            lineLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            lineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lineLabel.widthAnchor.constraint(equalToConstant: 40),

            pathLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 1),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            textLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    func configure(with match: SearchMatch) {
        fileLabel.stringValue = match.fileName
        pathLabel.stringValue = match.filePath
        lineLabel.stringValue = "\(match.line)"
        textLabel.stringValue = match.text
    }
}
