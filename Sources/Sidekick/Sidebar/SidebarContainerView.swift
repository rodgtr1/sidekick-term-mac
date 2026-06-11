import Cocoa

protocol SidebarContainerDelegate: AnyObject {
    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL)
    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String)
    func sidebarContainer(_ container: SidebarContainerView, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?)
    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String?)
    func sidebarContainer(
        _ container: SidebarContainerView,
        didRequestRunTask command: String,
        openBrowser: String?,
        taskName: String
    )
    func sidebarContainer(_ container: SidebarContainerView, didRequestPasteCommand command: String)
    func sidebarContainerTabs(_ container: SidebarContainerView) -> [TabModel]
    func sidebarContainer(_ container: SidebarContainerView, didRequestSwitchToTab index: Int)
    func sidebarContainer(_ container: SidebarContainerView, didRequestConnectCommand command: String)
}

class SidebarContainerView: NSView {
    weak var delegate: SidebarContainerDelegate?

    private(set) var currentPanel: SidebarPanel = .files
    private var isVisible: Bool = true
    private var panelViews: [SidebarPanel: NSView] = [:]
    private var panelControllers: [SidebarPanel: NSViewController] = [:]

    private let headerHeight: CGFloat = 32
    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var contentView: NSView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        applyBackground(enableBlur: true) // Default to blur enabled

        setupHeader()
        setupContent()
        createPanelViews()
        showPanel(.files)
    }

    private func setupHeader() {
        headerView = NSView()
        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        titleLabel = NSTextField(labelWithString: "FILES")
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(hex: "#cdd6f4")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight),

            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12)
        ])
    }

    private func setupContent() {
        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func applyBackground(enableBlur: Bool) {
        // Sidebar is always opaque (no blur)
        layer?.backgroundColor = NSColor(hex: "#181825")?.cgColor
        headerView?.layer?.backgroundColor = NSColor(hex: "#11111b")?.cgColor
    }

    private func createPanelViews() {
        // Create placeholder views for each panel
        for panel in SidebarPanel.allCases {
            let view = createPanelView(for: panel)
            panelViews[panel] = view
        }
    }

    private func createPanelView(for panel: SidebarPanel) -> NSView {
        switch panel {
        case .files:
            let fileTreeVC = FileTreeViewController()
            fileTreeVC.delegate = self
            panelControllers[panel] = fileTreeVC
            return fileTreeVC.view
        case .git:
            let gitPanelVC = GitPanelViewController()
            gitPanelVC.delegate = self
            panelControllers[panel] = gitPanelVC
            return gitPanelVC.view
        case .search:
            let searchPanelVC = SearchPanelViewController()
            searchPanelVC.delegate = self
            panelControllers[panel] = searchPanelVC
            return searchPanelVC.view
        case .run:
            let runPanelVC = RunPanelViewController()
            runPanelVC.delegate = self
            panelControllers[panel] = runPanelVC
            return runPanelVC.view
        case .agents:
            let agentDashboardVC = AgentDashboardViewController()
            agentDashboardVC.delegate = self
            panelControllers[panel] = agentDashboardVC
            return agentDashboardVC.view
        case .hosts:
            let hostsPanelVC = HostsPanelViewController()
            hostsPanelVC.delegate = self
            panelControllers[panel] = hostsPanelVC
            return hostsPanelVC.view
        }
    }

    func showPanel(_ panel: SidebarPanel) {
        // Hide current panel
        if let currentView = panelViews[currentPanel] {
            currentView.removeFromSuperview()
        }

        // Show new panel
        currentPanel = panel
        titleLabel.stringValue = panel.rawValue.uppercased()

        if let newView = panelViews[panel] {
            contentView.addSubview(newView)
            newView.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                newView.topAnchor.constraint(equalTo: contentView.topAnchor),
                newView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                newView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                newView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        if panel == .search {
            (panelControllers[.search] as? SearchPanelViewController)?.focusSearchField()
        }

        if panel == .agents {
            (panelControllers[.agents] as? AgentDashboardViewController)?.reload()
        }
    }

    func toggleVisibility() {
        setVisible(!isVisible)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        isHidden = !visible
    }

    var visible: Bool {
        return isVisible && !isHidden
    }

    func updateFileTree(path: String) {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.loadFileTree(for: path)
        }

        // Also update git panel if it exists
        if let gitPanelVC = panelControllers[.git] as? GitPanelViewController {
            gitPanelVC.setRepositoryPath(path)
        }

        // Update search panel working directory
        if let searchPanelVC = panelControllers[.search] as? SearchPanelViewController {
            searchPanelVC.updateWorkingDirectory(path)
        }

        // Update run panel working directory
        if let runPanelVC = panelControllers[.run] as? RunPanelViewController {
            runPanelVC.updateWorkingDirectory(path)
        }
    }

    func toggleHiddenFiles() {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.toggleHiddenFiles()
        }
    }

    func setShowHiddenFiles(_ show: Bool) {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.setShowHidden(show)
        }
    }

    func refreshFileTree() {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.refresh()
        }
    }

    func updateRunTaskStatus(name: String, status: TaskRunStatus?) {
        if let runPanelVC = panelControllers[.run] as? RunPanelViewController {
            runPanelVC.setTaskStatus(name: name, status: status)
        }
    }
}

extension SidebarContainerView: AgentDashboardDelegate {
    func agentDashboardTabs(_ dashboard: AgentDashboardViewController) -> [TabModel] {
        delegate?.sidebarContainerTabs(self) ?? []
    }

    func agentDashboard(_ dashboard: AgentDashboardViewController, didSelectTabAt index: Int) {
        delegate?.sidebarContainer(self, didRequestSwitchToTab: index)
    }
}

extension SidebarContainerView: HostsPanelDelegate {
    func hostsPanel(_ panel: HostsPanelViewController, didRequestConnectCommand command: String) {
        delegate?.sidebarContainer(self, didRequestConnectCommand: command)
    }
}

extension SidebarContainerView: FileTreeDelegate {
    func fileTree(_ fileTree: FileTreeViewController, didSelectFile url: URL) {
        // File selected but not opened
    }

    func fileTree(_ fileTree: FileTreeViewController, didOpenFile url: URL) {
        delegate?.sidebarContainer(self, didOpenFile: url)
    }
}

extension SidebarContainerView: GitPanelDelegate {
    func gitPanel(_ panel: GitPanelViewController, didRequestDiffFor filePath: String) {
        delegate?.sidebarContainer(self, didRequestDiffFor: filePath)
    }

    func gitPanel(_ panel: GitPanelViewController, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?) {
        delegate?.sidebarContainer(
            self,
            didRequestUncommittedChangesFor: repositoryPath,
            focusedFilePath: focusedFilePath
        )
    }
}

extension SidebarContainerView: SearchPanelDelegate {
    func searchPanel(_ panel: SearchPanelViewController, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String) {
        delegate?.sidebarContainer(self, didRequestOpenFile: filePath, atLine: line, highlighting: searchTerm)
    }
}

extension SidebarContainerView: RunPanelDelegate {
    func runPanel(
        _ panel: RunPanelViewController,
        didRequestRunTask command: String,
        openBrowser: String?,
        taskName: String
    ) {
        delegate?.sidebarContainer(self, didRequestRunTask: command, openBrowser: openBrowser, taskName: taskName)
    }

    func runPanel(_ panel: RunPanelViewController, didRequestPasteCommand command: String) {
        delegate?.sidebarContainer(self, didRequestPasteCommand: command)
    }
}
