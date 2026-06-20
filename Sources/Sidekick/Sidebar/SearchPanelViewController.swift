import Cocoa
import Combine

protocol SearchPanelDelegate: AnyObject {
    func searchPanel(_ panel: SearchPanelViewController, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String)
}

struct SearchMatch {
    let filePath: String
    let fileName: String
    let line: Int
    let column: Int
    let text: String
    let matchedText: String
}

struct SearchFileResult {
    let filePath: String
    let fileName: String
    let matches: [SearchMatch]

    var firstMatch: SearchMatch {
        matches[0]
    }
}

class SearchPanelViewController: NSViewController {
    private enum SearchBackend {
        case ripgrep(URL)
        case grep(URL)
    }

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Process?
    private var debounceWorkItem: DispatchWorkItem?
    private var searchTimeoutWorkItem: DispatchWorkItem?

    weak var delegate: SearchPanelDelegate?

    // UI Elements
    private var searchField: NSSearchField!
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    // Data
    private var searchMatches: [SearchMatch] = []
    private var searchFileResults: [SearchFileResult] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupTableView()
        layoutViews()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        statusLabel?.textColor = AppTheme.mutedText
        tableView?.backgroundColor = AppTheme.sidebarBackground
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        scrollView?.contentView.backgroundColor = AppTheme.sidebarBackground
        tableView?.reloadData()
    }

    private func setupUI() {
        // Search field
        searchField = NSSearchField()
        searchField.placeholderString = "Search files..."
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Status label
        statusLabel = NSTextField(labelWithString: "Type to search files")
        statusLabel.textColor = AppTheme.mutedText
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

        // Cancel current search. Clearing the reference also makes any
        // late results from the terminated task fail the identity check
        // instead of rendering for the old query.
        searchTimeoutWorkItem?.cancel()
        searchTimeoutWorkItem = nil
        searchTask?.terminate()
        searchTask = nil

        if searchText.isEmpty {
            searchMatches = []
            searchFileResults = []
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

    func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.view.window?.makeFirstResponder(self.searchField)
            self.searchField.currentEditor()?.selectedRange = NSRange(location: self.searchField.stringValue.count, length: 0)
        }
    }

    private func performSearch(_ searchText: String) {
        statusLabel.stringValue = "Searching..."

        guard let backend = searchBackend() else {
            statusLabel.stringValue = "Search failed: grep not found"
            return
        }

        if case .grep = backend, isBroadSearchRoot(currentWorkingDirectory) {
            statusLabel.stringValue = "Install ripgrep to search this folder"
            searchMatches = []
            searchFileResults = []
            tableView.reloadData()
            return
        }

        let task = Process()
        switch backend {
        case .ripgrep(let url):
            task.executableURL = url
            task.arguments = [
                "--json",
                "--no-heading",
                "--line-number",
                "--column",
                "--fixed-strings",
                "--max-count", "10", // Limit matches per file
                "--max-filesize", "2M", // Skip large files
                "--",
                searchText,
                currentWorkingDirectory
            ]
        case .grep(let url):
            task.executableURL = url
            task.arguments = [
                "-R",
                "-n",
                "-I",
                "-F",
                "-m", "1000",
                "--exclude-dir=.git",
                "--exclude-dir=node_modules",
                "--exclude-dir=.build",
                "--exclude-dir=target",
                "--exclude-dir=Library",
                "--",
                searchText,
                currentWorkingDirectory
            ]
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress errors

        // Replace any in-flight search before starting this one
        searchTask?.terminate()
        searchTask = task

        do {
            try task.run()
            let timeoutWorkItem = DispatchWorkItem { [weak task] in
                task?.terminate()
            }
            searchTimeoutWorkItem = timeoutWorkItem
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeoutWorkItem)

            DispatchQueue.global(qos: .userInitiated).async { [weak self, task] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                DispatchQueue.main.async {
                    guard let self = self, self.searchTask === task else { return }
                    self.searchTimeoutWorkItem?.cancel()
                    self.searchTimeoutWorkItem = nil

                    // ripgrep and grep both use status 1 for a successful search
                    // with no matches. Higher statuses indicate an actual failure.
                    if task.terminationStatus > 1 && data.isEmpty {
                        self.statusLabel.stringValue = "Search failed"
                        return
                    }

                    switch backend {
                    case .ripgrep:
                        self.parseRipgrepResults(data)
                    case .grep:
                        self.parseGrepResults(data, searchText: searchText)
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    private func searchBackend() -> SearchBackend? {
        if let rgURL = ProcessRunner.executableURL(named: "rg", commonPaths: [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/opt/local/bin/rg",
            "/usr/bin/rg"
        ]) {
            return .ripgrep(rgURL)
        }

        if let grepURL = ProcessRunner.executableURL(named: "grep", commonPaths: [
            "/usr/bin/grep",
            "/bin/grep"
        ]) {
            return .grep(grepURL)
        }

        return nil
    }

    private func isBroadSearchRoot(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return standardizedPath == homePath || standardizedPath == "/"
    }

    private func parseRipgrepResults(_ data: Data) {
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

        updateSearchResults(matches)
    }

    private func parseGrepResults(_ data: Data, searchText: String) {
        guard let output = String(data: data, encoding: .utf8) else {
            statusLabel.stringValue = "No results"
            return
        }

        let lines = output.components(separatedBy: .newlines)
        let matches = lines.compactMap { line -> SearchMatch? in
            guard !line.isEmpty else { return nil }

            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let lineNumber = Int(parts[1]) else { return nil }

            let filePath = String(parts[0])
            let text = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent

            return SearchMatch(
                filePath: filePath,
                fileName: fileName,
                line: lineNumber,
                column: 0,
                text: text,
                matchedText: searchText
            )
        }

        updateSearchResults(Array(matches.prefix(1000)))
    }

    private func updateSearchResults(_ matches: [SearchMatch]) {
        searchMatches = matches
        searchFileResults = groupedFileResults(from: matches)
        statusLabel.stringValue = resultSummary(fileCount: searchFileResults.count, matchCount: matches.count)
        tableView.reloadData()
    }

    private func groupedFileResults(from matches: [SearchMatch]) -> [SearchFileResult] {
        let grouped = Dictionary(grouping: matches) { $0.filePath }

        return grouped.map { filePath, matches in
            let sortedMatches = matches.sorted { lhs, rhs in
                if lhs.line == rhs.line {
                    return lhs.column < rhs.column
                }
                return lhs.line < rhs.line
            }

            return SearchFileResult(
                filePath: filePath,
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                matches: sortedMatches
            )
        }
        .sorted { lhs, rhs in
            lhs.filePath.localizedStandardCompare(rhs.filePath) == .orderedAscending
        }
    }

    private func resultSummary(fileCount: Int, matchCount: Int) -> String {
        guard matchCount > 0 else { return "No results" }

        let fileWord = fileCount == 1 ? "file" : "files"
        let matchWord = matchCount == 1 ? "match" : "matches"
        return "\(fileCount) \(fileWord), \(matchCount) \(matchWord)"
    }

    @objc private func tableViewDoubleClick(_ sender: NSTableView) {
        let selectedRow = sender.selectedRow
        guard selectedRow >= 0 && selectedRow < searchFileResults.count else { return }

        let result = searchFileResults[selectedRow]
        let match = result.firstMatch
        delegate?.searchPanel(self, didRequestOpenFile: result.filePath, atLine: match.line, highlighting: match.matchedText)
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
        return searchFileResults.count
    }
}

// MARK: - NSTableViewDelegate
extension SearchPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < searchFileResults.count else { return nil }

        let result = searchFileResults[row]
        let cellView = SearchResultCellView()
        cellView.configure(with: result)

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 64
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
        fileLabel.textColor = AppTheme.primaryText
        fileLabel.lineBreakMode = .byTruncatingTail
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        pathLabel.textColor = AppTheme.mutedText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        lineLabel = NSTextField(labelWithString: "")
        lineLabel.font = NSFont.systemFont(ofSize: 10)
        lineLabel.textColor = AppTheme.error
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.alignment = .right

        textLabel = NSTextField(labelWithString: "")
        textLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textLabel.textColor = AppTheme.secondaryText
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.lineBreakMode = .byTruncatingTail

        addSubview(fileLabel)
        addSubview(pathLabel)
        addSubview(lineLabel)
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            fileLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            fileLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fileLabel.trailingAnchor.constraint(equalTo: lineLabel.leadingAnchor, constant: -8),

            lineLabel.firstBaselineAnchor.constraint(equalTo: fileLabel.firstBaselineAnchor),
            lineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            lineLabel.widthAnchor.constraint(equalToConstant: 40),

            pathLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 3),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            textLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 4),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])
    }

    func configure(with result: SearchFileResult) {
        let firstMatch = result.firstMatch

        fileLabel.stringValue = result.fileName
        pathLabel.stringValue = result.filePath
        lineLabel.stringValue = "\(result.matches.count)"
        textLabel.stringValue = firstMatch.text
    }
}
