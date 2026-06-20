import Cocoa
import TOMLKit

protocol RunPanelDelegate: AnyObject {
    func runPanel(
        _ panel: RunPanelViewController,
        didRequestRunTask command: String,
        openBrowser: String?,
        taskName: String
    )
    func runPanel(_ panel: RunPanelViewController, didRequestPasteCommand command: String)
}

/// Live status of a task launched from the Run panel.
enum TaskRunStatus {
    case running
    case succeeded
    case failed
}

struct ProjectTask {
    let name: String
    let cmd: String
    let llmPrompt: String?
    let openBrowser: String?
}

class RunPanelViewController: NSViewController {
    weak var delegate: RunPanelDelegate?

    // UI Elements
    private var scrollView: NSScrollView!
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    // Data
    private var globalTasks: [Task] = []
    private var projectTasks: [ProjectTask] = []
    private var currentWorkingDirectory: String = FileManager.default.currentDirectoryPath
    private var taskStatuses: [String: TaskRunStatus] = [:]

    private enum TaskSection: Int, CaseIterable {
        case global = 0
        case project = 1

        var title: String {
            switch self {
            case .global: return "GLOBAL"
            case .project: return "PROJECT"
            }
        }
    }

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
        loadTasks()
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

    override func viewDidLayout() {
        super.viewDidLayout()
        resizeTaskColumnToVisibleWidth()
    }

    private func setupUI() {
        // Status label
        statusLabel = NSTextField(labelWithString: "Loading tasks...")
        statusLabel.textColor = AppTheme.mutedText
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowSizeStyle = .medium
        tableView.backgroundColor = AppTheme.sidebarBackground
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Column for tasks
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TaskColumn"))
        column.width = 300
        column.minWidth = 120
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

        view.addSubview(statusLabel)
        view.addSubview(scrollView)
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            // Status label
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func resizeTaskColumnToVisibleWidth() {
        guard let column = tableView.tableColumns.first else { return }

        let scrollerWidth = scrollView.hasVerticalScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle) : 0
        let visibleWidth = max(scrollView.contentView.bounds.width - scrollerWidth, column.minWidth)

        if abs(column.width - visibleWidth) > 0.5 {
            column.width = visibleWidth
        }
    }

    private func loadTasks() {
        // Load global tasks from config
        let config = Config.load()
        globalTasks = config.tasks ?? []

        // Load project tasks from .sidekick.toml
        loadProjectTasks()

        // Update UI
        updateStatusLabel()
        tableView.reloadData()
    }

    private func loadProjectTasks() {
        projectTasks = []

        let projectConfigPath = URL(fileURLWithPath: currentWorkingDirectory).appendingPathComponent(".sidekick.toml")

        guard FileManager.default.fileExists(atPath: projectConfigPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: projectConfigPath)
            guard let tomlString = String(data: data, encoding: .utf8) else { return }

            let toml = try TOMLTable(string: tomlString)

            // Look for tasks array
            if let tasksTable = toml["tasks"]?.array {
                for taskValue in tasksTable {
                    if let taskDict = taskValue.table,
                       let name = taskDict["name"]?.string,
                       let cmd = taskDict["cmd"]?.string {
                        let llmPrompt = taskDict["llm_prompt"]?.string ?? taskDict["llm"]?.string
                        let openBrowser = taskDict["open_browser"]?.string
                        let task = ProjectTask(name: name, cmd: cmd, llmPrompt: llmPrompt, openBrowser: openBrowser)
                        projectTasks.append(task)
                    }
                }
            }
        } catch {
            print("Failed to load project tasks: \(error)")
        }
    }

    private func updateStatusLabel() {
        let globalCount = globalTasks.count
        let projectCount = projectTasks.count
        statusLabel.stringValue = "\(globalCount) global, \(projectCount) project tasks"
    }

    func updateWorkingDirectory(_ directory: String) {
        currentWorkingDirectory = directory
        loadTasks()
    }

    /// Called by the window controller as a launched task starts/finishes.
    func setTaskStatus(name: String, status: TaskRunStatus?) {
        guard taskStatuses[name] != status else { return }
        if let status = status {
            taskStatuses[name] = status
        } else {
            taskStatuses.removeValue(forKey: name)
        }
        tableView.reloadData()
    }

    private func taskForRow(_ row: Int) -> (section: TaskSection, task: Any)? {
        var currentRow = 0

        // Global section header
        if row == currentRow {
            return (.global, "header")
        }
        currentRow += 1

        // Global tasks
        if currentRow <= globalTasks.count {
            let taskIndex = row - currentRow
            if taskIndex >= 0 && taskIndex < globalTasks.count {
                return (.global, globalTasks[taskIndex])
            }
            currentRow += globalTasks.count
        }

        // Project section header (only if we have project tasks)
        if !projectTasks.isEmpty {
            if row == currentRow {
                return (.project, "header")
            }
            currentRow += 1

            // Project tasks
            let taskIndex = row - currentRow
            if taskIndex >= 0 && taskIndex < projectTasks.count {
                return (.project, projectTasks[taskIndex])
            }
        }

        return nil
    }

    private func totalRows() -> Int {
        var rows = 1 // Global header
        rows += globalTasks.count

        if !projectTasks.isEmpty {
            rows += 1 // Project header
            rows += projectTasks.count
        }

        return rows
    }

    private func runTask(name: String, command: String, openBrowser: String?) {
        delegate?.runPanel(self, didRequestRunTask: command, openBrowser: openBrowser, taskName: name)
    }

    private func pasteCommand(_ command: String) {
        delegate?.runPanel(self, didRequestPasteCommand: command)
    }

    private func copyLLMPrompt(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
}

// MARK: - NSTableViewDataSource
extension RunPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return totalRows()
    }
}

// MARK: - NSTableViewDelegate
extension RunPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let (section, task) = taskForRow(row) else { return nil }

        if let headerString = task as? String, headerString == "header" {
            // Section header
            let cellView = TaskSectionHeaderView()
            cellView.configure(title: section.title)
            return cellView
        } else if let globalTask = task as? Task {
            // Global task
            let cellView = TaskCellView()
            cellView.configure(
                name: globalTask.name,
                command: globalTask.cmd,
                llmPrompt: globalTask.llmPrompt,
                openBrowser: globalTask.openBrowser,
                status: taskStatuses[globalTask.name],
                delegate: self
            )
            return cellView
        } else if let projectTask = task as? ProjectTask {
            // Project task
            let cellView = TaskCellView()
            cellView.configure(
                name: projectTask.name,
                command: projectTask.cmd,
                llmPrompt: projectTask.llmPrompt,
                openBrowser: projectTask.openBrowser,
                status: taskStatuses[projectTask.name],
                delegate: self
            )
            return cellView
        }

        return nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let (_, task) = taskForRow(row) else { return 0 }

        if let headerString = task as? String, headerString == "header" {
            return 24 // Header height
        } else {
            return 44 // Task cell height
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Disable row selection
        return false
    }
}

// MARK: - TaskCellViewDelegate
extension RunPanelViewController: TaskCellViewDelegate {
    func taskCell(_ cell: TaskCellView, didRequestRunNamed name: String, command: String, openBrowser: String?) {
        runTask(name: name, command: command, openBrowser: openBrowser)
    }

    func taskCell(_ cell: TaskCellView, didRequestPaste command: String) {
        pasteCommand(command)
    }

    func taskCell(_ cell: TaskCellView, didRequestCopyLLM prompt: String) {
        copyLLMPrompt(prompt)
    }
}

// MARK: - Task Section Header View
class TaskSectionHeaderView: NSTableCellView {
    private var titleLabel: NSTextField!

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
        layer?.backgroundColor = AppTheme.headerBackground.cgColor

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        ])
    }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

// MARK: - Task Cell View Protocol
protocol TaskCellViewDelegate: AnyObject {
    func taskCell(_ cell: TaskCellView, didRequestRunNamed name: String, command: String, openBrowser: String?)
    func taskCell(_ cell: TaskCellView, didRequestPaste command: String)
    func taskCell(_ cell: TaskCellView, didRequestCopyLLM prompt: String)
}

// MARK: - Task Cell View
private class TaskCellLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

class TaskCellView: NSTableCellView {
    private var nameLabel: NSTextField!
    private var commandLabel: NSTextField!
    private var statusDot: NSTextField!
    private var pasteButton: NSButton!
    private var runButton: NSButton!
    private var llmButton: NSButton!

    private var currentName: String = ""
    private var currentCommand: String = ""
    private var currentLLMPrompt: String?
    private var currentOpenBrowser: String?

    weak var taskDelegate: TaskCellViewDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let clickedView = hitTest(localPoint)

        if clickedView === pasteButton || clickedView === runButton || clickedView === llmButton {
            super.mouseDown(with: event)
            return
        }

        taskDelegate?.taskCell(self, didRequestRunNamed: currentName, command: currentCommand, openBrowser: currentOpenBrowser)
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Status dot (running/done indicator for tasks launched in a split)
        statusDot = TaskCellLabel(labelWithString: "●")
        statusDot.font = NSFont.systemFont(ofSize: 9)
        statusDot.isHidden = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        // Name label
        nameLabel = TaskCellLabel(labelWithString: "")
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Command label
        commandLabel = TaskCellLabel(labelWithString: "")
        commandLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        commandLabel.textColor = AppTheme.mutedText
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.lineBreakMode = .byTruncatingTail

        // Buttons
        pasteButton = NSButton()
        pasteButton.title = "→"
        pasteButton.bezelStyle = .texturedRounded
        pasteButton.font = NSFont.systemFont(ofSize: 12)
        pasteButton.target = self
        pasteButton.action = #selector(pasteButtonClicked)
        pasteButton.toolTip = "Paste command to terminal"
        pasteButton.translatesAutoresizingMaskIntoConstraints = false

        runButton = NSButton()
        runButton.title = "▶"
        runButton.bezelStyle = .texturedRounded
        runButton.font = NSFont.systemFont(ofSize: 12)
        runButton.target = self
        runButton.action = #selector(runButtonClicked)
        runButton.toolTip = "Run in a split below"
        runButton.translatesAutoresizingMaskIntoConstraints = false

        llmButton = NSButton()
        llmButton.title = "✦"
        llmButton.bezelStyle = .texturedRounded
        llmButton.font = NSFont.systemFont(ofSize: 12)
        llmButton.target = self
        llmButton.action = #selector(llmButtonClicked)
        llmButton.toolTip = "Copy LLM prompt"
        llmButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusDot)
        addSubview(nameLabel)
        addSubview(commandLabel)
        addSubview(pasteButton)
        addSubview(runButton)
        addSubview(llmButton)

        NSLayoutConstraint.activate([
            // Status dot
            statusDot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            // Name label
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: llmButton.leadingAnchor, constant: -8),

            // Command label
            commandLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            commandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            commandLabel.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -8),
            commandLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),

            // Buttons (right-aligned)
            llmButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            llmButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            llmButton.widthAnchor.constraint(equalToConstant: 24),
            llmButton.heightAnchor.constraint(equalToConstant: 18),

            runButton.topAnchor.constraint(equalTo: llmButton.bottomAnchor, constant: 2),
            runButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            runButton.widthAnchor.constraint(equalToConstant: 24),
            runButton.heightAnchor.constraint(equalToConstant: 18),

            pasteButton.topAnchor.constraint(equalTo: llmButton.bottomAnchor, constant: 2),
            pasteButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -4),
            pasteButton.widthAnchor.constraint(equalToConstant: 24),
            pasteButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    func configure(
        name: String,
        command: String,
        llmPrompt: String?,
        openBrowser: String?,
        status: TaskRunStatus?,
        delegate: TaskCellViewDelegate?
    ) {
        nameLabel.stringValue = name
        commandLabel.stringValue = command
        currentName = name
        currentCommand = command
        currentLLMPrompt = llmPrompt
        currentOpenBrowser = openBrowser
        taskDelegate = delegate

        let theme = Theme.shared.current
        let style: (color: NSColor, tip: String)? = status.map {
            switch $0 {
            case .running: return (theme.yellow, "Running")
            case .succeeded: return (theme.green, "Finished")
            case .failed: return (theme.red, "Failed")
            }
        }
        statusDot.stringValue = style == nil ? "" : "●"
        statusDot.textColor = style?.color
        statusDot.toolTip = style?.tip
        statusDot.isHidden = style == nil

        // Show/hide LLM button based on whether there's a prompt
        llmButton.isHidden = llmPrompt == nil
    }

    @objc private func pasteButtonClicked() {
        taskDelegate?.taskCell(self, didRequestPaste: currentCommand)
    }

    @objc private func runButtonClicked() {
        taskDelegate?.taskCell(self, didRequestRunNamed: currentName, command: currentCommand, openBrowser: currentOpenBrowser)
    }

    @objc private func llmButtonClicked() {
        if let prompt = currentLLMPrompt {
            taskDelegate?.taskCell(self, didRequestCopyLLM: prompt)
        }
    }
}
