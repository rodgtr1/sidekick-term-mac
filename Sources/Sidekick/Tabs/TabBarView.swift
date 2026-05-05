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

    private let tabHeight: CGFloat = 32
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 200
    private let closeButtonSize: CGFloat = 16
    private let tabSpacing: CGFloat = 1

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

        // Add new tab button on the right
        setupNewTabButton()
    }

    private func setupNewTabButton() {
        // This will be positioned dynamically based on tab count
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
        tabButtons.removeAll()
        closeButtons.removeAll()

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
        let dirtyIndicator = tab.isDirty ? "● " : ""
        let readyIndicator = tab.isAgentReady ? "🟢 " : "" // Green circle when agent is ready
        tabButton.title = "\(readyIndicator)\(dirtyIndicator)\(tab.title)"
        tabButton.bezelStyle = .recessed
        tabButton.font = NSFont.systemFont(ofSize: 12)
        tabButton.target = self
        tabButton.action = #selector(tabButtonClicked(_:))
        tabButton.tag = index

        // Style based on active state
        tabButton.wantsLayer = true
        if index == activeTabIndex {
            // Active tab: brighter background with blue border
            tabButton.layer?.backgroundColor = NSColor(hex: "#313244")?.cgColor
            tabButton.contentTintColor = NSColor(hex: "#cdd6f4")
            tabButton.layer?.borderColor = NSColor(hex: "#89b4fa")?.cgColor
            tabButton.layer?.borderWidth = 2
        } else {
            // Inactive tab: darker, no border
            tabButton.layer?.backgroundColor = NSColor(hex: "#11111b")?.cgColor
            tabButton.contentTintColor = NSColor(hex: "#6c7086")
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
        closeButton.contentTintColor = NSColor(hex: "#6c7086")

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
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        delegate?.tabBar(self, didSelectTab: sender.tag)
    }

    @objc private func closeButtonClicked(_ sender: NSButton) {
        delegate?.tabBar(self, didCloseTab: sender.tag)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check for double-click to create new tab
        if event.clickCount == 2 {
            // Double-click on empty area creates new tab
            let hitTab = tabButtons.first { $0.frame.contains(point) }
            if hitTab == nil {
                delegate?.tabBarDidRequestNewTab(self)
            }
        }

        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw separator line at bottom
        NSColor(hex: "#45475a")?.set()
        let separatorRect = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        separatorRect.fill()
    }

    override func layout() {
        super.layout()
        if !tabs.isEmpty {
            rebuildTabButtons()
        }
    }
}