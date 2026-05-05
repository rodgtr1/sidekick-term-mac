import Cocoa

protocol ActivityBarDelegate: AnyObject {
    func activityBar(_ activityBar: ActivityBarView, didSelectPanel panel: SidebarPanel)
    func activityBarDidToggleSidebar(_ activityBar: ActivityBarView)
}

enum SidebarPanel: String, CaseIterable {
    case files = "Files"
    case git = "Git"
    case search = "Search"
    case run = "Run"
    case browser = "Browser"

    var icon: String {
        switch self {
        case .files: return "folder"
        case .git: return "arrow.branch"
        case .search: return "magnifyingglass"
        case .run: return "play.circle"
        case .browser: return "globe"
        }
    }

    var shortcut: String {
        switch self {
        case .files: return "Cmd+Shift+E"
        case .git: return "Cmd+Shift+G"
        case .search: return "Cmd+Shift+F"
        case .run: return "Cmd+Shift+R"
        case .browser: return "Cmd+Shift+W"
        }
    }
}

class ActivityBarView: NSView {
    weak var delegate: ActivityBarDelegate?

    private var selectedPanel: SidebarPanel = .files
    private var buttons: [NSButton] = []
    private let buttonSize: CGFloat = 40
    private let buttonSpacing: CGFloat = 4

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
        layer?.backgroundColor = NSColor(hex: "#11111b")?.cgColor

        createActivityButtons()
    }

    private func createActivityButtons() {
        let panels = SidebarPanel.allCases

        for (index, panel) in panels.enumerated() {
            let button = createActivityButton(for: panel, at: index)
            buttons.append(button)
            addSubview(button)
        }

        // Select Files panel by default
        updateSelectedButton(panel: .files)
    }

    private func createActivityButton(for panel: SidebarPanel, at index: Int) -> NSButton {
        let y = CGFloat(index) * (buttonSize + buttonSpacing) + buttonSpacing
        let x = (48 - buttonSize) / 2 // Center in 48px width

        let button = NSButton(frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize))
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true

        // Use SF Symbol for icon
        if let image = NSImage(systemSymbolName: panel.icon, accessibilityDescription: panel.rawValue) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            button.image = image.withSymbolConfiguration(config)
        } else {
            // Fallback to text if SF Symbol not available
            button.title = String(panel.rawValue.first ?? "?")
            button.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        }

        button.target = self
        button.action = #selector(activityButtonClicked(_:))
        button.tag = index

        // Add tooltip
        button.toolTip = "\\(panel.rawValue) (\\(panel.shortcut))"

        // Style button
        styleButton(button, isSelected: false)

        return button
    }

    private func styleButton(_ button: NSButton, isSelected: Bool) {
        if isSelected {
            button.layer?.backgroundColor = NSColor(hex: "#313244")?.cgColor
            button.contentTintColor = NSColor(hex: "#cdd6f4")
            button.layer?.borderColor = NSColor(hex: "#89b4fa")?.cgColor
            button.layer?.borderWidth = 2
        } else {
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.contentTintColor = NSColor(hex: "#6c7086")
            button.layer?.borderWidth = 0
        }

        button.layer?.cornerRadius = 8
    }

    @objc private func activityButtonClicked(_ sender: NSButton) {
        let panel = SidebarPanel.allCases[sender.tag]

        if selectedPanel == panel {
            // Toggle sidebar if same panel clicked
            delegate?.activityBarDidToggleSidebar(self)
        } else {
            // Switch to new panel
            selectedPanel = panel
            updateSelectedButton(panel: panel)
            delegate?.activityBar(self, didSelectPanel: panel)
        }
    }

    private func updateSelectedButton(panel: SidebarPanel) {
        selectedPanel = panel

        for (index, button) in buttons.enumerated() {
            let isSelected = (index == SidebarPanel.allCases.firstIndex(of: panel))
            styleButton(button, isSelected: isSelected)
        }
    }

    func selectPanel(_ panel: SidebarPanel) {
        updateSelectedButton(panel: panel)
    }

    override func layout() {
        super.layout()

        // Reposition buttons if view size changed
        for (index, button) in buttons.enumerated() {
            let y = CGFloat(index) * (buttonSize + buttonSpacing) + buttonSpacing
            let x = (bounds.width - buttonSize) / 2
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
        }
    }
}