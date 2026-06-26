import Cocoa

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTab index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTab index: Int)
    func tabBarDidRequestNewTab(_ tabBar: TabBarView)
    func tabBar(_ tabBar: TabBarView, didMoveTab fromIndex: Int, to toIndex: Int)
    func tabBar(_ tabBar: TabBarView, didRenameTab index: Int, to title: String?)
}

/// Tab buttons forward mouse-downs to the tab bar so it can distinguish a
/// click (select) from a horizontal drag (reorder).
private final class TabButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        (superview as? TabBarView)?.handleTabMouseDown(event, button: self)
    }
}

class TabBarView: NSView {
    weak var delegate: TabBarDelegate?

    private var tabs: [TabModel] = []
    private var activeTabIndex: Int = 0
    private var tabButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private var activeIndicators: [NSView] = []
    // Set on the main actor; invalidated in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var pulseTimer: Timer?
    private var workingPulseIsBright = false

    private let tabHeight: CGFloat = 32
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 200
    private let closeButtonSize: CGFloat = 16
    private let tabSpacing: CGFloat = 1
    private let tabHorizontalPadding: CGFloat = 12
    private var lastTabWidth: CGFloat = 120

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        observeThemeChanges()
        startPulseTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        observeThemeChanges()
        startPulseTimer()
    }

    deinit {
        pulseTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func observeThemeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .themeDidChange,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        applyTheme()
        if !tabs.isEmpty {
            rebuildTabButtons()
        }
    }

    private func setupView() {
        wantsLayer = true
        applyTheme()

        // Add new tab button on the right
        setupNewTabButton()
    }

    private func applyTheme() {
        applyBackground(enableBlur: true) // Default to blur enabled
    }

    func applyBackground(enableBlur: Bool) {
        let bgColor = Theme.shared.current.windowBackground
        // Tab bar is always opaque (no blur)
        layer?.backgroundColor = bgColor.cgColor
        layer?.isOpaque = true
    }

    private func setupNewTabButton() {
        // This will be positioned dynamically based on tab count
    }

    private func startPulseTimer() {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self = self else { return }

            let hasWorkingTab = self.tabs.contains { $0.agentState == .working }
            guard hasWorkingTab else {
                self.workingPulseIsBright = false
                return
            }

            self.workingPulseIsBright.toggle()
            // Refresh only the titles of working tabs; rebuilding every
            // button twice a second thrashes the view hierarchy.
            for (index, tab) in self.tabs.enumerated() where tab.agentState == .working {
                guard index < self.tabButtons.count else { continue }
                self.tabButtons[index].attributedTitle = self.makeAttributedTitle(for: tab)
            }
            }
        }
    }

    func updateTabs(_ tabs: [TabModel], activeIndex: Int) {
        self.tabs = tabs
        self.activeTabIndex = activeIndex
        rebuildTabButtons()
    }

    private func rebuildTabButtons() {
        // Remove existing buttons
        tabButtons.forEach { $0.removeFromSuperview() }
        closeButtons.forEach { $0.removeFromSuperview() }
        activeIndicators.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        closeButtons.removeAll()
        activeIndicators.removeAll()

        // Calculate tab width
        let availableWidth = bounds.width - 40 // Leave space for new tab button
        let tabCount = CGFloat(tabs.count)
        var tabWidth = tabCount > 0 ? availableWidth / tabCount : tabMinWidth
        tabWidth = max(tabMinWidth, min(tabMaxWidth, tabWidth))
        lastTabWidth = tabWidth

        // Create tab buttons
        for (index, tab) in tabs.enumerated() {
            createTabButton(for: tab, at: index, width: tabWidth)
        }
    }

    private func createTabButton(for tab: TabModel, at index: Int, width: CGFloat) {
        let x = CGFloat(index) * (width + tabSpacing)
        let tabRect = NSRect(x: x, y: 0, width: width, height: tabHeight)

        // Tab button
        let tabButton = TabButton(frame: tabRect)
        tabButton.cell = TabButtonCell(textLeadingPadding: tabHorizontalPadding, textTrailingPadding: closeButtonSize + 18)

        let theme = Theme.shared.current
        tabButton.attributedTitle = makeAttributedTitle(for: tab)
        if let commandTooltip = tab.lastCommandTooltip {
            tabButton.toolTip = "\(tab.title)\n\(commandTooltip)"
        } else {
            tabButton.toolTip = tab.title
        }
        tabButton.bezelStyle = .regularSquare
        tabButton.isBordered = false
        tabButton.cell?.lineBreakMode = .byTruncatingMiddle
        tabButton.cell?.truncatesLastVisibleLine = true
        tabButton.cell?.wraps = false
        tabButton.tag = index

        // Style based on active state
        tabButton.wantsLayer = true
        tabButton.layer?.cornerRadius = 5
        tabButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // Round top corners only

        if index == activeTabIndex {
            // Active tab
            tabButton.layer?.backgroundColor = theme.activeTabBackground.cgColor
            tabButton.contentTintColor = theme.activeTabText
            tabButton.layer?.borderWidth = 0
        } else {
            // Inactive tab
            tabButton.layer?.backgroundColor = theme.controlBackground.cgColor
            tabButton.contentTintColor = theme.inactiveTabText
            tabButton.layer?.borderWidth = 0
        }

        // Close button
        let closeButtonX = x + width - closeButtonSize - 8
        let closeButtonY = (tabHeight - closeButtonSize) / 2
        let closeRect = NSRect(x: closeButtonX, y: closeButtonY,
                              width: closeButtonSize, height: closeButtonSize)

        let closeButton = NSButton(frame: closeRect)
        closeButton.title = "×"
        closeButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeButtonClicked(_:))
        closeButton.tag = index
        closeButton.contentTintColor = Theme.shared.current.secondaryText

        // Hover effect for close button
        let trackingArea = NSTrackingArea(
            rect: closeButton.bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: closeButton,
            userInfo: nil
        )
        closeButton.addTrackingArea(trackingArea)

        addSubview(tabButton)
        addSubview(closeButton)

        tabButtons.append(tabButton)
        closeButtons.append(closeButton)

        if index == activeTabIndex {
            let indicator = NSView(frame: NSRect(x: x, y: 0, width: width, height: 2))
            indicator.wantsLayer = true
            indicator.layer?.backgroundColor = theme.activeTabBorder.cgColor
            indicator.layer?.cornerRadius = 1
            addSubview(indicator)
            activeIndicators.append(indicator)
        }
    }

    private func makeAttributedTitle(for tab: TabModel) -> NSAttributedString {
        // Build title with attributed string for proper icon/color rendering
        let attributedTitle = NSMutableAttributedString()
        let titleParagraphStyle = NSMutableParagraphStyle()
        titleParagraphStyle.lineBreakMode = .byTruncatingMiddle
        titleParagraphStyle.alignment = .center

        // Agent state indicator
        let theme = Theme.shared.current
        switch tab.agentState {
        case .idle:
            break // No indicator
        case .working:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Working",
                color: workingAgentIndicatorColor,
                to: attributedTitle
            )
        case .ready:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Waiting",
                color: theme.green,
                to: attributedTitle
            )
        case .done:
            appendAgentIndicator(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent Done",
                color: theme.blue,
                to: attributedTitle
            )
        }

        // Failed-command indicator (from shell integration)
        if tab.lastCommandFailed {
            let failedText = NSAttributedString(string: "✗ ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: theme.red
            ])
            attributedTitle.append(failedText)
        }

        // Dirty indicator
        if tab.isDirty {
            let dirtyText = NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 9)
            ])
            attributedTitle.append(dirtyText)
        }

        // Tab title
        let titleText = NSAttributedString(string: tab.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .paragraphStyle: titleParagraphStyle
        ])
        attributedTitle.append(titleText)

        return attributedTitle
    }

    private func appendAgentIndicator(
        systemSymbolName: String,
        accessibilityDescription: String,
        color: NSColor,
        to attributedTitle: NSMutableAttributedString
    ) {
        guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: accessibilityDescription) else {
            attributedTitle.append(NSAttributedString(string: "* "))
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let coloredImage = image.withSymbolConfiguration(config) ?? image

        let attachment = NSTextAttachment()
        attachment.image = coloredImage
        attachment.bounds = NSRect(x: 0, y: -1, width: 8, height: 8)
        attributedTitle.append(NSAttributedString(attachment: attachment))
        attributedTitle.append(NSAttributedString(string: " "))
    }

    private var workingAgentIndicatorColor: NSColor {
        if workingPulseIsBright {
            return AppTheme.warning
        }

        return AppTheme.warning.blended(withFraction: 0.3, of: .black) ?? AppTheme.warning
    }

    @objc private func closeButtonClicked(_ sender: NSButton) {
        delegate?.tabBar(self, didCloseTab: sender.tag)
    }

    // MARK: - Click / drag-reorder tracking

    /// Runs a synchronous tracking loop: a mouse-up without much horizontal
    /// movement selects the tab; dragging slides the button and reorders on
    /// release.
    fileprivate func handleTabMouseDown(_ event: NSEvent, button: NSButton) {
        let index = button.tag
        let startPoint = convert(event.locationInWindow, from: nil)
        let originalX = button.frame.origin.x
        var dragging = false

        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                // Tracking aborted: snap everything back to layout positions.
                rebuildTabButtons()
                return
            }

            // The tab bar can be rebuilt mid-drag (title/agent updates run on
            // the main queue during event tracking); the captured button and
            // index are stale then, so abort the drag.
            guard !tabButtons.isEmpty, index < tabs.count,
                  button === tabButtons[safe: index] || button.superview === self else {
                rebuildTabButtons()
                return
            }

            let point = convert(next.locationInWindow, from: nil)

            if next.type == .leftMouseUp {
                if dragging {
                    let target = dragTargetIndex(for: button)
                    if target != index, index < tabs.count {
                        delegate?.tabBar(self, didMoveTab: index, to: target)
                    } else {
                        rebuildTabButtons()
                    }
                } else {
                    delegate?.tabBar(self, didSelectTab: index)
                }
                return
            }

            let deltaX = point.x - startPoint.x
            if dragging || abs(deltaX) > 6 {
                if !dragging {
                    dragging = true
                    // Keep the dragged tab above its siblings while it slides.
                    button.removeFromSuperview()
                    addSubview(button)
                }
                let maxX = bounds.width - button.frame.width
                button.frame.origin.x = min(max(0, originalX + deltaX), max(0, maxX))
            }
        }
    }

    private func dragTargetIndex(for button: NSButton) -> Int {
        guard !tabs.isEmpty else { return 0 }
        let slot = Int(round(button.frame.origin.x / (lastTabWidth + tabSpacing)))
        return min(max(0, slot), tabs.count - 1)
    }

    // MARK: - Right-click menu (rename)

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = tabButtons.first(where: { $0.frame.contains(point) }) else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        let renameItem = NSMenuItem(title: "Rename Tab…", action: #selector(renameTabMenuClicked(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.tag = button.tag
        menu.addItem(renameItem)

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTabMenuClicked(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.tag = button.tag
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameTabMenuClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard let tab = tabs[safe: index] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to restore the automatic title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? ""
        field.placeholderString = tab.title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        delegate?.tabBar(self, didRenameTab: index, to: name.isEmpty ? nil : name)
    }

    @objc private func closeTabMenuClicked(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didCloseTab: sender.tag)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if clicking on empty area (not on a tab or close button)
        let hitTab = tabButtons.first { $0.frame.contains(point) }
        let hitClose = closeButtons.first { $0.frame.contains(point) }

        if hitTab == nil && hitClose == nil {
            if event.clickCount == 2 {
                window?.performConfiguredTitlebarDoubleClickAction()
                return
            }

            // Clicking on empty tab bar area - allow window dragging
            window?.performDrag(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        // Only move existing buttons here. Rebuilding (remove/add subviews)
        // during a layout pass dirties constraints and re-enters layout,
        // which AppKit eventually kills with an NSInternalInconsistencyException
        // ("too many Update Constraints in Window passes").
        if !tabs.isEmpty {
            repositionTabButtons()
        }
    }

    /// Recomputes tab widths for the current bounds and updates frames of the
    /// existing buttons without touching the view hierarchy.
    private func repositionTabButtons() {
        let availableWidth = bounds.width - 40 // Leave space for new tab button
        let tabCount = CGFloat(tabs.count)
        var tabWidth = tabCount > 0 ? availableWidth / tabCount : tabMinWidth
        tabWidth = max(tabMinWidth, min(tabMaxWidth, tabWidth))
        lastTabWidth = tabWidth

        for (index, button) in tabButtons.enumerated() {
            let x = CGFloat(index) * (tabWidth + tabSpacing)
            button.frame = NSRect(x: x, y: 0, width: tabWidth, height: tabHeight)
            if index < closeButtons.count {
                closeButtons[index].frame = NSRect(
                    x: x + tabWidth - closeButtonSize - 8,
                    y: (tabHeight - closeButtonSize) / 2,
                    width: closeButtonSize,
                    height: closeButtonSize
                )
            }
        }

        if let indicator = activeIndicators.first, activeTabIndex < tabButtons.count {
            let x = CGFloat(activeTabIndex) * (tabWidth + tabSpacing)
            indicator.frame = NSRect(x: x, y: 0, width: tabWidth, height: 2)
        }
    }
}

private final class TabButtonCell: NSButtonCell {
    private let textLeadingPadding: CGFloat
    private let textTrailingPadding: CGFloat

    init(textLeadingPadding: CGFloat, textTrailingPadding: CGFloat) {
        self.textLeadingPadding = textLeadingPadding
        self.textTrailingPadding = textTrailingPadding
        super.init(textCell: "")
        lineBreakMode = .byTruncatingMiddle
        truncatesLastVisibleLine = true
        wraps = false
    }

    required init(coder: NSCoder) {
        self.textLeadingPadding = 12
        self.textTrailingPadding = 34
        super.init(coder: coder)
        lineBreakMode = .byTruncatingMiddle
        truncatesLastVisibleLine = true
        wraps = false
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        titleRect.origin.x = rect.minX + textLeadingPadding
        titleRect.size.width = max(0, rect.width - textLeadingPadding - textTrailingPadding)
        titleRect.size.height = rect.height
        return titleRect
    }
}
