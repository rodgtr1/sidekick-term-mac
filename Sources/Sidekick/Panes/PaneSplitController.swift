import Cocoa

class PaneSplitController: NSViewController {
    private var splitView: NSSplitView!
    private var panes: [PaneModel] = []
    private var activePaneIndex: Int = 0
    private let config: Config

    init(config: Config) {
        self.config = config
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        setupSplitView()
    }

    private func setupSplitView() {
        splitView = NSSplitView()
        splitView.isVertical = true // Horizontal splits (side by side)
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Create initial pane
        addInitialPane()
    }

    private func addInitialPane() {
        let pane = PaneModel()
        pane.createTerminalViewController(config: config)
        panes.append(pane)
        activePaneIndex = 0

        if let paneView = pane.view {
            splitView.addArrangedSubview(paneView)
            pane.focus()
            addPaneBorder(to: paneView, isActive: true)
        }
    }

    func splitPane(direction: SplitDirection) {
        guard panes.count < Limits.maxPanesPerTab else { return }

        let newPane = PaneModel()
        newPane.createTerminalViewController(config: config)
        panes.append(newPane)

        if direction == .vertical {
            // Convert to vertical split (top/bottom)
            splitView.isVertical = false
        }

        if let paneView = newPane.view {
            splitView.addArrangedSubview(paneView)
            setActivePane(index: panes.count - 1)
            addPaneBorder(to: paneView, isActive: false)
        }
    }

    func closePane(index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        let pane = panes[index]
        if let paneView = pane.view {
            splitView.removeArrangedSubview(paneView)
            paneView.removeFromSuperview()
        }

        panes.remove(at: index)

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        } else if activePaneIndex > index {
            activePaneIndex -= 1
        }

        setActivePane(index: activePaneIndex)
    }

    func setActivePane(index: Int) {
        guard index >= 0 && index < panes.count else { return }

        // Unfocus previous pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].unfocus()
            if let paneView = panes[activePaneIndex].view {
                addPaneBorder(to: paneView, isActive: false)
            }
        }

        // Focus new pane
        activePaneIndex = index
        panes[activePaneIndex].focus()
        if let paneView = panes[activePaneIndex].view {
            addPaneBorder(to: paneView, isActive: true)
        }
    }

    private func addPaneBorder(to view: NSView, isActive: Bool) {
        // Remove existing border
        view.subviews.filter { $0.identifier?.rawValue == "paneBorder" }.forEach { $0.removeFromSuperview() }

        // Add new border
        let borderView = NSView()
        borderView.identifier = NSUserInterfaceItemIdentifier("paneBorder")
        borderView.wantsLayer = true

        let borderColor = isActive ?
            NSColor(hex: "#89b4fa") : // Blue for active
            NSColor(hex: "#313244")   // Dim for inactive

        borderView.layer?.borderColor = borderColor?.cgColor
        borderView.layer?.borderWidth = isActive ? 2 : 1
        borderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(borderView)

        NSLayoutConstraint.activate([
            borderView.topAnchor.constraint(equalTo: view.topAnchor),
            borderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            borderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            borderView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Send border to back
        view.addSubview(borderView, positioned: .below, relativeTo: nil)
    }

    func getActivePaneTerminal() -> TerminalViewController? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex].terminalViewController
    }

    var paneCount: Int {
        return panes.count
    }

    var activePane: PaneModel? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex]
    }

    func rebuildSplitView(for tab: TabModel) {
        // Clear existing views
        for arrangedSubview in splitView.arrangedSubviews {
            splitView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        // Update panes reference
        self.panes = tab.panes
        self.activePaneIndex = tab.activePaneIndex

        // Add all pane views to split view
        for (index, pane) in panes.enumerated() {
            if let paneView = pane.view {
                splitView.addArrangedSubview(paneView)
                addPaneBorder(to: paneView, isActive: index == activePaneIndex)
            }
        }

        // Focus the active pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].focus()
        }
    }

    func addPane(_ pane: PaneModel) {
        panes.append(pane)

        if let paneView = pane.view {
            splitView.addArrangedSubview(paneView)
            setActivePane(index: panes.count - 1)
            addPaneBorder(to: paneView, isActive: false)
        }
    }
}