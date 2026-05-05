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

    func splitWithBrowser(direction: SplitDirection) {
        print("🌐 splitWithBrowser called, current panes: \(panes.count), max: \(Limits.maxPanesPerTab)")
        guard panes.count < Limits.maxPanesPerTab else {
            print("⚠️ Max panes reached, not adding browser")
            return
        }

        print("🌐 Creating browser pane...")
        let newPane = PaneModel()
        newPane.createBrowserViewController()
        panes.append(newPane)
        print("🌐 Browser pane created and added, total panes now: \(panes.count)")

        if direction == .vertical {
            // Convert to vertical split (top/bottom)
            splitView.isVertical = false
        } else {
            // For horizontal split (side by side), ensure splitView is vertical
            splitView.isVertical = true
        }

        if let paneView = newPane.view {
            splitView.addArrangedSubview(paneView)
            setActivePane(index: panes.count - 1)
            addPaneBorder(to: paneView, isActive: false)

            // Set 50/50 split after layout
            if panes.count == 2 {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let totalSize = self.splitView.isVertical ? self.splitView.bounds.width : self.splitView.bounds.height
                    let dividerPosition = totalSize / 2.0
                    self.splitView.setPosition(dividerPosition, ofDividerAt: 0)
                }
            }
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

    func closeActivePane() {
        closePane(index: activePaneIndex)
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

    func focusNextPane() {
        guard panes.count > 1 else { return }
        let nextIndex = (activePaneIndex + 1) % panes.count
        setActivePane(index: nextIndex)
    }

    func focusPreviousPane() {
        guard panes.count > 1 else { return }
        let prevIndex = (activePaneIndex - 1 + panes.count) % panes.count
        setActivePane(index: prevIndex)
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
        print("🔧 rebuildSplitView called with \(tab.panes.count) panes")
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
                print("🔧 Adding pane \(index) (\(pane.paneType)) to split view, view bounds: \(paneView.bounds)")
                splitView.addArrangedSubview(paneView)
                addPaneBorder(to: paneView, isActive: index == activePaneIndex)
                print("🔧 After adding, view bounds: \(paneView.bounds)")
            } else {
                print("⚠️ Pane \(index) (\(pane.paneType)) has no view!")
            }
        }

        print("🔧 Split view now has \(splitView.arrangedSubviews.count) arranged subviews")

        // Force layout update
        splitView.layout()

        // Set equal distribution for split view (do this after layout in next run loop)
        if splitView.arrangedSubviews.count == 2 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let totalSize = self.splitView.isVertical ? self.splitView.bounds.width : self.splitView.bounds.height
                let dividerPosition = totalSize / 2.0
                print("🔧 Setting divider position to: \(dividerPosition) (total: \(totalSize))")
                self.splitView.setPosition(dividerPosition, ofDividerAt: 0)

                // Force another layout after setting position
                self.splitView.layout()

                // Log final sizes after adjustment
                for (index, pane) in self.panes.enumerated() {
                    if let paneView = pane.view {
                        print("🔧 After divider adjustment, pane \(index) bounds: \(paneView.bounds)")
                    }
                }
            }
        }

        // Log sizes before async adjustment
        for (index, pane) in panes.enumerated() {
            if let paneView = pane.view {
                print("🔧 Before divider adjustment, pane \(index) bounds: \(paneView.bounds)")
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