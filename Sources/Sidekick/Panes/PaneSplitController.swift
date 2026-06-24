import Cocoa

protocol PaneSplitControllerDelegate: AnyObject {
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int)
    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int)
    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int)
}

class PaneSplitController: NSViewController {
    weak var delegate: PaneSplitControllerDelegate?

    private var rootSplitView: NSSplitView!
    private var panes: [PaneModel] = []
    private var activePaneIndex: Int = 0
    private let config: Config

    // Track which container view wraps each pane
    private var paneContainers: [PaneModel: NSView] = [:]
    private var paneCloseButtons: [PaneModel: PaneCloseButton] = [:]
    // Track all split views we've created (for delegate management)
    private var allSplitViews: Set<NSSplitView> = []

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
        rootSplitView = createSplitView(isVertical: true)
        rootSplitView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootSplitView)

        NSLayoutConstraint.activate([
            rootSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            rootSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // No initial pane here: every owner immediately calls
        // rebuildSplitView(for:) with the tab's real panes, and creating one
        // would spawn a shell that is discarded without being terminated.
    }

    private func createSplitView(isVertical: Bool) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = isVertical
        split.dividerStyle = .thin
        split.delegate = self
        allSplitViews.insert(split)
        return split
    }

    private func wrapPaneInContainer(_ pane: PaneModel, paneView: NSView) -> NSView {
        let container = ClickableContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneView)

        paneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: container.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let closeButton = PaneCloseButton()
        closeButton.pane = pane
        closeButton.target = self
        closeButton.action = #selector(closePaneButtonClicked(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        // Set click handler to make this pane active when clicked
        container.onMouseDown = { [weak self] in
            guard let self = self else { return }
            if let index = self.panes.firstIndex(of: pane) {
                print("🖱️ Clicked on pane \(index), making it active")
                self.setActivePane(index: index)
            }
        }

        paneContainers[pane] = container
        paneCloseButtons[pane] = closeButton
        updatePaneCloseButtons()
        return container
    }

    @objc private func closePaneButtonClicked(_ sender: PaneCloseButton) {
        guard let pane = sender.pane,
              let index = panes.firstIndex(of: pane) else { return }

        setActivePane(index: index)
        closePane(index: index)
    }

    private func updatePaneCloseButtons() {
        guard panes.count > 1 else {
            paneCloseButtons.values.forEach { $0.isHidden = true }
            return
        }

        // A terminal pane only needs a close button when it's one of several
        // terminals. When the split exists solely because the user opened an
        // editor/browser/diff alongside the terminal, leave the terminal alone
        // and show the X on that opened pane instead.
        let terminalCount = panes.filter { $0.paneType == .terminal }.count
        for (pane, button) in paneCloseButtons {
            let shouldShow = pane.paneType == .terminal ? terminalCount > 1 : true
            button.isHidden = !shouldShow || paneContainers[pane] == nil
        }
    }

    private func findParentSplitView(for pane: PaneModel) -> NSSplitView? {
        guard let container = paneContainers[pane] else { return nil }
        return findSplitView(containing: container, in: rootSplitView)
    }

    /// Activates the pane under a left-click. The window-level monitor in
    /// MainWindowController calls this only on the active tab's controller, so
    /// hidden tabs can't claim clicks meant for the visible one.
    func activatePane(containing event: NSEvent) {
        guard event.window === view.window,
              let contentView = view.window?.contentView else { return }

        let pointInContent = contentView.convert(event.locationInWindow, from: nil)

        for (pane, container) in paneContainers {
            let pointInContainer = container.convert(pointInContent, from: contentView)
            guard container.bounds.contains(pointInContainer),
                  let index = panes.firstIndex(of: pane),
                  index != activePaneIndex else { continue }

            setActivePane(index: index)
            return
        }
    }

    private func findSplitView(containing view: NSView, in splitView: NSSplitView) -> NSSplitView? {
        if splitView.arrangedSubviews.contains(view) {
            return splitView
        }

        for subview in splitView.arrangedSubviews {
            if let nestedSplit = subview as? NSSplitView {
                if let found = findSplitView(containing: view, in: nestedSplit) {
                    return found
                }
            }
        }

        return nil
    }

    @discardableResult
    func splitPane(
        direction: SplitDirection,
        targetPaneID: UUID? = nil,
        initialDirectory: String? = nil,
        command: [String]? = nil,
        focus: Bool = true
    ) -> PaneModel? {
        guard panes.count < Limits.maxPanesPerTab else { return nil }
        let targetIndex: Int
        if let targetPaneID {
            guard let index = panes.firstIndex(where: { $0.id == targetPaneID }) else { return nil }
            targetIndex = index
        } else {
            guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
            targetIndex = activePaneIndex
        }

        print("🔧 Splitting pane in \(direction) direction, current panes: \(panes.count)")

        let activePane = panes[targetIndex]
        guard let activePaneContainer = paneContainers[activePane],
              let parentSplit = findParentSplitView(for: activePane) else {
            print("⚠️ Cannot find active pane container or parent split")
            return nil
        }

        print("🔧 Parent split isVertical: \(parentSplit.isVertical), arrangedSubviews: \(parentSplit.arrangedSubviews.count)")

        // Get the current directory from the active pane to use for the new terminal.
        let currentDirectory = initialDirectory ?? activePane.resolvedWorkingDirectory()
        print("🔧 Starting new pane in directory: \(currentDirectory ?? "home")")

        let newPane = PaneModel()
        newPane.createTerminalViewController(
            config: config,
            initialDirectory: currentDirectory,
            command: command
        )
        panes.append(newPane)
        delegate?.paneSplitController(self, didAddPane: newPane, at: panes.count - 1)

        guard let newPaneView = newPane.view else {
            print("⚠️ New pane has no view!")
            return nil
        }

        let newContainer = wrapPaneInContainer(newPane, paneView: newPaneView)
        addPaneBorder(to: newPaneView, isActive: false)

        let needsVerticalSplit = (direction == .vertical) // top/bottom
        let parentIsVertical = parentSplit.isVertical

        print("🔧 needsVerticalSplit: \(needsVerticalSplit), parentIsVertical: \(parentIsVertical)")

        // Check if we need to create a nested split view
        if (needsVerticalSplit && parentIsVertical) || (!needsVerticalSplit && !parentIsVertical) {
            // Parent orientation doesn't match - need nested split
            print("🔧 Creating nested split view (nested will be vertical: \(!needsVerticalSplit))")

            let nestedSplit = createSplitView(isVertical: !needsVerticalSplit)
            nestedSplit.translatesAutoresizingMaskIntoConstraints = false

            // Find the index of the active pane's container in parent
            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                print("⚠️ Cannot find container index")
                return nil
            }

            print("🔧 Container index in parent: \(containerIndex)")
            print("🔧 Parent before removal has \(parentSplit.arrangedSubviews.count) subviews")

            // Remove active pane container from parent
            parentSplit.removeArrangedSubview(activePaneContainer)
            activePaneContainer.removeFromSuperview()

            print("🔧 Parent after removal has \(parentSplit.arrangedSubviews.count) subviews")

            // Add nested split at the same position
            parentSplit.insertArrangedSubview(nestedSplit, at: containerIndex)

            print("🔧 Parent after inserting nested split has \(parentSplit.arrangedSubviews.count) subviews")

            // Add both panes to the nested split
            nestedSplit.addArrangedSubview(activePaneContainer)
            nestedSplit.addArrangedSubview(newContainer)

            print("🔧 Nested split now has \(nestedSplit.arrangedSubviews.count) subviews")
            print("🔧 Total pane count: \(panes.count)")

            // Set 50/50 split after layout
            DispatchQueue.main.async { [weak nestedSplit, weak parentSplit] in
                guard let split = nestedSplit else { return }
                SplitLayoutManager.setEvenSplit(in: split)

                // Also redistribute the parent split to ensure it maintains proper spacing
                if let parent = parentSplit {
                    print("🔧 Redistributing parent split after nested split creation")
                    SplitLayoutManager.distributeEvenly(in: parent)
                }
            }
        } else {
            // Parent orientation matches - add to existing split
            print("🔧 Adding to existing split view")

            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                print("⚠️ Cannot find container index")
                return nil
            }

            print("🔧 Inserting at index \(containerIndex + 1)")

            // Insert new pane after the active pane
            parentSplit.insertArrangedSubview(newContainer, at: containerIndex + 1)

            print("🔧 Parent now has \(parentSplit.arrangedSubviews.count) subviews")

            // Redistribute space evenly after layout
            DispatchQueue.main.async { [weak parentSplit] in
                guard let split = parentSplit else { return }
                SplitLayoutManager.distributeEvenly(in: split)
            }
        }

        if focus {
            setActivePane(index: panes.count - 1)
        }
        updatePaneCloseButtons()
        return newPane
    }

    func splitWithBrowser(direction: SplitDirection, initialURL: URL? = nil) {
        print("🌐 splitWithBrowser called, current panes: \(panes.count), max: \(Limits.maxPanesPerTab)")
        guard panes.count < Limits.maxPanesPerTab else {
            print("⚠️ Max panes reached, not adding browser")
            return
        }
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return }

        print("🌐 Creating browser pane...")
        let activePane = panes[activePaneIndex]
        guard let activePaneContainer = paneContainers[activePane],
              let parentSplit = findParentSplitView(for: activePane) else {
            print("⚠️ Cannot find active pane container or parent split")
            return
        }

        let newPane = PaneModel()
        newPane.createBrowserViewController(initialURL: initialURL)
        panes.append(newPane)
        delegate?.paneSplitController(self, didAddPane: newPane, at: panes.count - 1)
        print("🌐 Browser pane created and added, total panes now: \(panes.count)")

        guard let newPaneView = newPane.view else {
            print("⚠️ New browser pane has no view!")
            return
        }

        let newContainer = wrapPaneInContainer(newPane, paneView: newPaneView)
        addPaneBorder(to: newPaneView, isActive: false)

        let needsVerticalSplit = (direction == .vertical)
        let parentIsVertical = parentSplit.isVertical

        if (needsVerticalSplit && parentIsVertical) || (!needsVerticalSplit && !parentIsVertical) {
            // Need nested split
            print("🌐 Creating nested split view for browser")

            let nestedSplit = createSplitView(isVertical: !needsVerticalSplit)
            nestedSplit.translatesAutoresizingMaskIntoConstraints = false

            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                print("⚠️ Cannot find container index")
                return
            }

            parentSplit.removeArrangedSubview(activePaneContainer)
            activePaneContainer.removeFromSuperview()
            parentSplit.insertArrangedSubview(nestedSplit, at: containerIndex)

            nestedSplit.addArrangedSubview(activePaneContainer)
            nestedSplit.addArrangedSubview(newContainer)

            DispatchQueue.main.async { [weak nestedSplit, weak parentSplit] in
                guard let split = nestedSplit else { return }
                SplitLayoutManager.setEvenSplit(in: split)

                // Also redistribute the parent split to ensure it maintains proper spacing
                if let parent = parentSplit {
                    print("🌐 Redistributing parent split after nested browser split creation")
                    SplitLayoutManager.distributeEvenly(in: parent)
                }
            }
        } else {
            // Add to existing split
            print("🌐 Adding browser to existing split view")

            guard let containerIndex = parentSplit.arrangedSubviews.firstIndex(of: activePaneContainer) else {
                print("⚠️ Cannot find container index")
                return
            }

            parentSplit.insertArrangedSubview(newContainer, at: containerIndex + 1)

            DispatchQueue.main.async { [weak parentSplit] in
                guard let split = parentSplit else { return }
                SplitLayoutManager.distributeEvenly(in: split)
            }
        }

        setActivePane(index: panes.count - 1)
        updatePaneCloseButtons()
    }

    func closePane(index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        let pane = panes[index]
        guard let container = paneContainers[pane],
              let parentSplit = findParentSplitView(for: pane) else {
            print("⚠️ Cannot find pane container or parent split")
            return
        }

        // Remove from parent split
        parentSplit.removeArrangedSubview(container)
        container.removeFromSuperview()

        // Clean up tracking
        paneContainers.removeValue(forKey: pane)
        paneCloseButtons.removeValue(forKey: pane)
        panes.remove(at: index)
        delegate?.paneSplitController(self, didClosePane: pane, at: index)

        // Clean up nested split views if needed
        cleanupEmptySplitViews()
        updatePaneCloseButtons()

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        } else if activePaneIndex > index {
            activePaneIndex -= 1
        }

        setActivePane(index: activePaneIndex)
    }

    private func cleanupEmptySplitViews() {
        cleanupSplitViewRecursive(rootSplitView)
    }

    private func cleanupSplitViewRecursive(_ splitView: NSSplitView) {
        // First, recursively clean up any nested splits
        for subview in splitView.arrangedSubviews {
            if let nestedSplit = subview as? NSSplitView {
                cleanupSplitViewRecursive(nestedSplit)
            }
        }

        // If this split (not root) has only one child, unwrap it
        if splitView != rootSplitView && splitView.arrangedSubviews.count == 1 {
            guard let onlyChild = splitView.arrangedSubviews.first,
                  let grandparent = splitView.superview as? NSSplitView,
                  let splitIndex = grandparent.arrangedSubviews.firstIndex(of: splitView) else {
                return
            }

            print("🧹 Unwrapping single-child split view")

            // Remove the child from this split
            splitView.removeArrangedSubview(onlyChild)
            onlyChild.removeFromSuperview()

            // Remove this split from grandparent
            grandparent.removeArrangedSubview(splitView)
            splitView.removeFromSuperview()

            // Add the child directly to grandparent at the same position
            grandparent.insertArrangedSubview(onlyChild, at: splitIndex)

            // Remove from tracking
            allSplitViews.remove(splitView)
        }
    }

    @discardableResult
    func closeActivePane() -> Bool {
        guard panes.count > 1 else { return false }
        closePane(index: activePaneIndex)
        return true
    }

    @discardableResult
    func closePane(id: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == id }), panes.count > 1 else {
            return false
        }
        closePane(index: index)
        return true
    }

    @discardableResult
    func focusPane(id: UUID) -> Bool {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return false }
        setActivePane(index: index)
        return true
    }

    func setActivePane(index: Int) {
        guard index >= 0 && index < panes.count else {
            print("⚠️ setActivePane: invalid index \(index), pane count: \(panes.count)")
            return
        }

        print("🎯 setActivePane: changing from \(activePaneIndex) to \(index)")

        // Unfocus previous pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].unfocus()
            if let paneView = panes[activePaneIndex].view {
                print("🎯 Removing active border from pane \(activePaneIndex)")
                addPaneBorder(to: paneView, isActive: false)
            }
        }

        // Focus new pane
        activePaneIndex = index
        panes[activePaneIndex].focus()
        if let paneView = panes[activePaneIndex].view {
            print("🎯 Adding active border to pane \(index)")
            addPaneBorder(to: paneView, isActive: true)
        }

        delegate?.paneSplitController(self, didActivatePane: panes[activePaneIndex], at: activePaneIndex)
    }

    func focusNextPane() {
        guard panes.count > 1 else {
            print("⌨️ focusNextPane: only 1 pane, skipping")
            return
        }
        let nextIndex = (activePaneIndex + 1) % panes.count
        print("⌨️ focusNextPane: moving from \(activePaneIndex) to \(nextIndex)")
        setActivePane(index: nextIndex)
    }

    func focusPreviousPane() {
        guard panes.count > 1 else {
            print("⌨️ focusPreviousPane: only 1 pane, skipping")
            return
        }
        let prevIndex = (activePaneIndex - 1 + panes.count) % panes.count
        print("⌨️ focusPreviousPane: moving from \(activePaneIndex) to \(prevIndex)")
        setActivePane(index: prevIndex)
    }

    private func addPaneBorder(to view: NSView, isActive: Bool) {
        // Remove existing border
        let existingBorders = view.subviews.filter { $0.identifier?.rawValue == "paneBorder" }
        print("🖼️ addPaneBorder: removing \(existingBorders.count) existing borders, isActive: \(isActive)")
        existingBorders.forEach { $0.removeFromSuperview() }

        // Only add border if there are multiple panes
        guard panes.count > 1 else {
            print("🖼️ Only one pane, skipping border")
            return
        }

        // Add new border
        let borderView = NSView()
        borderView.identifier = NSUserInterfaceItemIdentifier("paneBorder")
        borderView.wantsLayer = true

        let borderColor = isActive ?
            AppTheme.accent :                 // Blue for active
            Theme.shared.palette.surface0     // Dim for inactive

        borderView.layer?.borderColor = borderColor.cgColor
        borderView.layer?.borderWidth = isActive ? 2 : 1
        borderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(borderView)
        print("🖼️ Added \(isActive ? "active" : "inactive") border to view")

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

    var activePaneID: UUID? {
        activePane?.id
    }

    func rebuildSplitView(for tab: TabModel) {
        print("🔧 rebuildSplitView called with \(tab.panes.count) panes")

        // Clear all existing content
        for arrangedSubview in rootSplitView.arrangedSubviews {
            rootSplitView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        // Clear all nested split views
        allSplitViews.removeAll()
        allSplitViews.insert(rootSplitView)
        paneContainers.removeAll()
        paneCloseButtons.removeAll()

        // Update panes reference
        self.panes = tab.panes
        self.activePaneIndex = tab.activePaneIndex

        // Add all pane views to root split view in a flat structure
        for (index, pane) in panes.enumerated() {
            if let paneView = pane.view {
                print("🔧 Adding pane \(index) (\(pane.paneType)) to split view")
                let container = wrapPaneInContainer(pane, paneView: paneView)
                rootSplitView.addArrangedSubview(container)
                addPaneBorder(to: paneView, isActive: index == activePaneIndex)
            } else {
                print("⚠️ Pane \(index) (\(pane.paneType)) has no view!")
            }
        }

        print("🔧 Split view now has \(rootSplitView.arrangedSubviews.count) arranged subviews")
        updatePaneCloseButtons()

        // Distribute evenly
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SplitLayoutManager.distributeEvenly(in: self.rootSplitView)
        }

        // Focus the active pane
        if activePaneIndex < panes.count {
            panes[activePaneIndex].focus()
        }
    }

    func addPane(_ pane: PaneModel) {
        panes.append(pane)

        if let paneView = pane.view {
            let container = wrapPaneInContainer(pane, paneView: paneView)
            rootSplitView.addArrangedSubview(container)
            setActivePane(index: panes.count - 1)
            addPaneBorder(to: paneView, isActive: false)
            updatePaneCloseButtons()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                SplitLayoutManager.distributeEvenly(in: self.rootSplitView)
            }
        }
    }
}

// MARK: - ClickableContainerView
class ClickableContainerView: NSView {
    var onMouseDown: (() -> Void)?
    private var clickGestureRecognizer: NSClickGestureRecognizer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGestureRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestureRecognizer()
    }

    private func setupGestureRecognizer() {
        let clickRecognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        clickRecognizer.delaysPrimaryMouseButtonEvents = false
        self.addGestureRecognizer(clickRecognizer)
        self.clickGestureRecognizer = clickRecognizer
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        print("🖱️ ClickableContainerView gesture recognizer triggered")
        onMouseDown?()
    }

    override func mouseDown(with event: NSEvent) {
        print("🖱️ ClickableContainerView mouseDown called")
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

final class PaneCloseButton: NSButton {
    weak var pane: PaneModel?

    init() {
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
        imagePosition = .imageOnly
        bezelStyle = .rounded
        isBordered = false
        contentTintColor = AppTheme.primaryText
        toolTip = "Close Pane"
        wantsLayer = true
        layer?.backgroundColor = Theme.shared.palette.surface0.withAlphaComponent(0.9).cgColor
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - NSSplitViewDelegate
extension PaneSplitController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false // Don't allow collapsing panes
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return true // Allow all panes to resize
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return max(proposedMinimumPosition, 100) // Minimum 100pt width/height
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalSize = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposedMaximumPosition, totalSize - 100) // Keep at least 100pt for other pane
    }
}
