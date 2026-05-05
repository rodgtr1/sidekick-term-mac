import Cocoa
import SwiftTerm

class MainWindowController: NSWindowController {
    private var config: Config = Config.load()
    private var tabBarView: TabBarView!
    private var activityBarView: ActivityBarView!
    private var sidebarContainerView: SidebarContainerView!
    private var mainContentView: NSView!
    private var editorViewController: EditorViewController?
    private var tabs: [TabModel] = []
    private var activeTabIndex: Int = 0
    private var currentPaneSplitController: PaneSplitController?

    convenience init() {
        print("🏗️ Creating MainWindowController...")

        let config = Config.load()
        print("✅ Config loaded")

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        print("✅ NSWindow created")

        window.title = "Sidekick"
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = false
        window.isOpaque = true  // Make sure window is opaque
        window.alphaValue = 1.0  // Set to fully opaque for debugging
        window.center()  // Center the window on screen
        window.makeKeyAndOrderFront(nil)  // Ensure window is visible
        print("✅ Window configured")

        self.init(window: window)
        self.config = config
        print("✅ WindowController initialized")

        setupUI()
        print("✅ UI setup completed")
    }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.wantsLayer = true
        window.contentView = contentView

        setupTabBar()
        setupActivityBar()
        setupSidebar()
        setupMainContent()

        layoutViews()
    }

    private func setupTabBar() {
        tabBarView = TabBarView()
        tabBarView.delegate = self
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabBarView)

        // Create initial tab
        createNewTab()
    }

    private func setupActivityBar() {
        activityBarView = ActivityBarView()
        activityBarView.delegate = self
        activityBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(activityBarView)
    }

    private func setupSidebar() {
        sidebarContainerView = SidebarContainerView()
        sidebarContainerView.delegate = self
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarContainerView)
    }

    private func setupMainContent() {
        mainContentView = NSView()
        mainContentView.wantsLayer = true
        mainContentView.layer?.backgroundColor = NSColor(hex: "#1e1e2e")?.cgColor
        mainContentView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(mainContentView)
    }

    private func layoutViews() {
        guard let contentView = window?.contentView else { return }

        NSLayoutConstraint.activate([
            tabBarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarView.heightAnchor.constraint(equalToConstant: 36),

            activityBarView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            activityBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            activityBarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            activityBarView.widthAnchor.constraint(equalToConstant: 48),

            sidebarContainerView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            sidebarContainerView.leadingAnchor.constraint(equalTo: activityBarView.trailingAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarContainerView.widthAnchor.constraint(equalToConstant: 240),

            mainContentView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            mainContentView.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            mainContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        setupKeyboardShortcuts()
        setupCWDTracking()
    }

    private func setupKeyboardShortcuts() {
        // This will be implemented to handle keyboard shortcuts
    }

    private func setupCWDTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalCWDChanged(_:)),
            name: NSNotification.Name("TerminalCWDChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneDirtyStateChanged(_:)),
            name: NSNotification.Name("PaneDirtyStateChanged"),
            object: nil
        )
    }

    @objc private func terminalCWDChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let directory = userInfo["directory"] as? String else { return }

        // Update file tree to show current directory
        sidebarContainerView.updateFileTree(path: directory)
    }

    @objc private func paneDirtyStateChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let isDirty = userInfo["isDirty"] as? Bool,
              let pane = notification.object as? PaneModel else { return }

        // Find the tab containing this pane and update its dirty state
        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                tab.isDirty = isDirty
                updateTabBar()
                break
            }
        }
    }

    private func createNewTab() {
        let tab = TabModel()
        tabs.append(tab)
        activeTabIndex = tabs.count - 1

        tab.isActive = true

        // Create pane split controller for this tab
        let paneSplitController = PaneSplitController(config: config)
        currentPaneSplitController = paneSplitController

        // Add to main content view
        mainContentView.addSubview(paneSplitController.view)
        paneSplitController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            paneSplitController.view.topAnchor.constraint(equalTo: mainContentView.topAnchor),
            paneSplitController.view.leadingAnchor.constraint(equalTo: mainContentView.leadingAnchor),
            paneSplitController.view.trailingAnchor.constraint(equalTo: mainContentView.trailingAnchor),
            paneSplitController.view.bottomAnchor.constraint(equalTo: mainContentView.bottomAnchor)
        ])

        updateTabBar()
    }

    private func updateTabBar() {
        tabBarView.updateTabs(tabs, activeIndex: activeTabIndex)
    }

    private func switchToTab(index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        // Hide current tab content
        currentPaneSplitController?.view.isHidden = true

        // Update active state
        tabs[activeTabIndex].isActive = false
        activeTabIndex = index
        tabs[activeTabIndex].isActive = true

        // Show new tab content (simplified for now)
        currentPaneSplitController?.view.isHidden = false

        updateTabBar()
    }

    private func closeTab(index: Int) {
        guard index >= 0 && index < tabs.count && tabs.count > 1 else { return }

        tabs.remove(at: index)

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        switchToTab(index: activeTabIndex)
    }
}

extension MainWindowController: TabBarDelegate {
    func tabBar(_ tabBar: TabBarView, didSelectTab index: Int) {
        switchToTab(index: index)
    }

    func tabBar(_ tabBar: TabBarView, didCloseTab index: Int) {
        closeTab(index: index)
    }

    func tabBarDidRequestNewTab(_ tabBar: TabBarView) {
        createNewTab()
    }
}

extension MainWindowController: ActivityBarDelegate {
    func activityBar(_ activityBar: ActivityBarView, didSelectPanel panel: SidebarPanel) {
        showSidebarPanel(panel)
    }

    func activityBarDidToggleSidebar(_ activityBar: ActivityBarView) {
        toggleSidebar()
    }
}

extension MainWindowController: SidebarContainerDelegate {
    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL) {
        openFileInEditor(url)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String) {
        openDiffViewer(for: filePath)
    }

    private func openFileInEditor(_ url: URL) {
        // Create a new editor pane in the current tab
        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        // Create a new pane for the editor
        let editorPane = PaneModel()
        editorPane.createEditorViewController(for: url)

        // Add the editor pane to the current tab
        currentTab.addPane(editorPane, splitDirection: .horizontal)

        // Update the split view with the new pane
        currentPaneSplitController?.rebuildSplitView(for: currentTab)

        updateTabBar()
    }

    private func openDiffViewer(for filePath: String) {
        // Create a new diff viewer pane in the current tab
        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        // Create a new pane for the diff viewer
        let diffPane = PaneModel()
        diffPane.createDiffViewController(for: filePath)

        // Add the diff pane to the current tab
        currentTab.addPane(diffPane, splitDirection: .horizontal)

        // Update the split view with the new pane
        currentPaneSplitController?.rebuildSplitView(for: currentTab)

        updateTabBar()
    }
}

extension MainWindowController {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Cmd key combinations
        if modifiers.contains(.command) {
            switch keyCode {
            case 17: // Cmd+T (New Tab)
                createNewTab()
                return
            case 13: // Cmd+W (Close Tab)
                closeTab(index: activeTabIndex)
                return
            case 1: // Cmd+S (Save File)
                saveCurrentFile()
                return
            case 11: // Cmd+B (Toggle Sidebar)
                toggleSidebar()
                return
            case 2: // Cmd+D (Split Right)
                currentPaneSplitController?.splitPane(direction: .horizontal)
                return
            case 2 where modifiers.contains(.shift): // Cmd+Shift+D (Split Down)
                currentPaneSplitController?.splitPane(direction: .vertical)
                return
            case 2 where modifiers.contains(.shift): // Cmd+Shift+W (Close Pane)
                // TODO: Implement close pane
                return
            case 18...26: // Cmd+1-9 (Switch tabs)
                let tabIndex = Int(keyCode) - 18
                if tabIndex < tabs.count {
                    switchToTab(index: tabIndex)
                }
                return
            default:
                break
            }
        }

        // Cmd+Shift combinations for sidebar panels
        if modifiers.contains([.command, .shift]) {
            switch keyCode {
            case 14: // Cmd+Shift+E (Files)
                showSidebarPanel(.files)
                return
            case 5: // Cmd+Shift+G (Git)
                showSidebarPanel(.git)
                return
            case 3: // Cmd+Shift+F (Search)
                showSidebarPanel(.search)
                return
            case 15: // Cmd+Shift+R (Run)
                showSidebarPanel(.run)
                return
            case 13: // Cmd+Shift+W (Browser)
                showSidebarPanel(.browser)
                return
            case 47: // Cmd+Shift+. (Toggle hidden files)
                sidebarContainerView.toggleHiddenFiles()
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    private func toggleSidebar() {
        sidebarContainerView.toggleVisibility()
        updateMainContentConstraints()
    }

    private func showSidebarPanel(_ panel: SidebarPanel) {
        sidebarContainerView.showPanel(panel)
        activityBarView.selectPanel(panel)

        if sidebarContainerView.isHidden {
            sidebarContainerView.toggleVisibility()
            updateMainContentConstraints()
        }
    }

    private func updateMainContentConstraints() {
        // This is simplified - in a real implementation you'd update constraints
        // For now, just ensure the sidebar state is correct
        sidebarContainerView.layoutSubtreeIfNeeded()
    }

    private func saveCurrentFile() {
        // Save the current file if there's an active editor pane
        if let activePane = currentPaneSplitController?.activePane,
           activePane.paneType == .editor,
           let editor = activePane.editorViewController {
            _ = editor.saveFile()
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") {
            hexString = String(hexString.dropFirst())
        }

        guard hexString.count == 6,
              let hexInt = Int(hexString, radix: 16) else {
            return nil
        }

        let r = CGFloat((hexInt >> 16) & 0xFF) / 255.0
        let g = CGFloat((hexInt >> 8) & 0xFF) / 255.0
        let b = CGFloat(hexInt & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}