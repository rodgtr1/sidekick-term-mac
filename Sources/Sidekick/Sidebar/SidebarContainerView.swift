import Cocoa

protocol SidebarContainerDelegate: AnyObject {
    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL)
    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String)
}

class SidebarContainerView: NSView {
    weak var delegate: SidebarContainerDelegate?

    private var currentPanel: SidebarPanel = .files
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
        layer?.backgroundColor = NSColor(hex: "#181825")?.cgColor

        setupHeader()
        setupContent()
        createPanelViews()
        showPanel(.files)
    }

    private func setupHeader() {
        headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(hex: "#11111b")?.cgColor
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
        default:
            // Placeholder for other panels
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(hex: "#181825")?.cgColor

            let label = NSTextField(labelWithString: "\\(panel.rawValue) Panel\\n\\nComing soon...")
            label.font = NSFont.systemFont(ofSize: 14)
            label.textColor = NSColor(hex: "#6c7086")
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)

            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])

            return view
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
    }

    func toggleVisibility() {
        isVisible.toggle()
        isHidden = !isVisible
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
    }

    func toggleHiddenFiles() {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.toggleHiddenFiles()
        }
    }

    func refreshFileTree() {
        if let fileTreeVC = panelControllers[.files] as? FileTreeViewController {
            fileTreeVC.refresh()
        }
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
}