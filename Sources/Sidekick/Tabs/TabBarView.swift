import Cocoa

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTab index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTab index: Int)
    func tabBarDidRequestNewTab(_ tabBar: TabBarView)
}

class TabBarView: NSView {
    weak var delegate: TabBarDelegate?

    private var tabs: [TabModel] = []
    private var activeTabIndex: Int = 0
    private var tabButtons: [NSButton] = []
    private var closeButtons: [NSButton] = []
    private var activeIndicators: [NSView] = []
    private var pulseTimer: Timer?
    private var workingPulseIsBright = false

    private let tabHeight: CGFloat = 32
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 200
    private let closeButtonSize: CGFloat = 16
    private let tabSpacing: CGFloat = 1
    private let tabHorizontalPadding: CGFloat = 12

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
            guard let self = self else { return }

            let hasWorkingTab = self.tabs.contains { $0.agentState == .working }
            guard hasWorkingTab else {
                self.workingPulseIsBright = false
                return
            }

            self.workingPulseIsBright.toggle()
            self.rebuildTabButtons()
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

        // Create tab buttons
        for (index, tab) in tabs.enumerated() {
            createTabButton(for: tab, at: index, width: tabWidth)
        }
    }

    private func createTabButton(for tab: TabModel, at index: Int, width: CGFloat) {
        let x = CGFloat(index) * (width + tabSpacing)
        let tabRect = NSRect(x: x, y: 0, width: width, height: tabHeight)

        // Tab button
        let tabButton = NSButton(frame: tabRect)
        tabButton.cell = TabButtonCell(textLeadingPadding: tabHorizontalPadding, textTrailingPadding: closeButtonSize + 18)

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

        tabButton.attributedTitle = attributedTitle
        tabButton.toolTip = tab.title
        tabButton.bezelStyle = .regularSquare
        tabButton.isBordered = false
        tabButton.cell?.lineBreakMode = .byTruncatingMiddle
        tabButton.cell?.truncatesLastVisibleLine = true
        tabButton.cell?.wraps = false
        tabButton.target = self
        tabButton.action = #selector(tabButtonClicked(_:))
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
            return NSColor(hex: "#f9e2af") ?? Theme.shared.current.yellow
        }

        return NSColor(hex: "#c9a96a") ?? Theme.shared.current.yellow.blended(withFraction: 0.3, of: .black) ?? Theme.shared.current.yellow
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        delegate?.tabBar(self, didSelectTab: sender.tag)
    }

    @objc private func closeButtonClicked(_ sender: NSButton) {
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
        if !tabs.isEmpty {
            rebuildTabButtons()
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
