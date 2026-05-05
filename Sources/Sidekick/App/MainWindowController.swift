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
    private var tabSplitControllers: [UUID: PaneSplitController] = [:] // Map tab IDs to their split controllers
    private var quickOpenPanel: QuickOpenPanel?
    private var preferencesWindowController: PreferencesWindowController?

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
        window.isOpaque = false  // Allow transparency
        window.alphaValue = CGFloat(config.window.opacity)  // Apply opacity from config
        window.backgroundColor = .clear  // Clear background for blur effect

        window.center()  // Center the window on screen
        window.makeKeyAndOrderFront(nil)  // Ensure window is visible
        print("✅ Window configured")

        self.init(window: window)
        self.config = config
        print("✅ WindowController initialized")

        setupUI()
        print("✅ UI setup completed")

        setupIPC()
        print("✅ IPC server started")
    }

    private func setupUI() {
        guard let window = window else { return }

        // Create visual effect view for blur as the window's content view
        let visualEffectView = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        // Set the visual effect view as the window's content view
        window.contentView = visualEffectView

        setupTabBar()
        setupActivityBar()
        setupSidebar()
        setupMainContent()

        layoutViews()

        // Create initial tab after all views are set up
        createNewTab()
    }

    private func setupTabBar() {
        tabBarView = TabBarView()
        tabBarView.delegate = self
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabBarView)
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneTitleChanged(_:)),
            name: NSNotification.Name("PaneTitleChanged"),
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

    @objc private func paneTitleChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }

        // Find the tab containing this pane
        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                // Only update if this is the active pane in the tab
                if tab.activePane?.id == pane.id {
                    tab.updateTitleFromActivePane()
                    updateTabBar()
                }
                break
            }
        }
    }

    func createNewTab() {
        // Hide current tab's split controller if exists
        if let currentController = currentPaneSplitController {
            currentController.view.isHidden = true
        }

        let tab = TabModel()
        tabs.append(tab)

        // Mark old tab as inactive
        if activeTabIndex < tabs.count - 1 {
            tabs[activeTabIndex].isActive = false
        }

        activeTabIndex = tabs.count - 1
        tab.isActive = true

        // Initialize the first pane with a terminal
        if let firstPane = tab.panes.first {
            firstPane.createTerminalViewController(config: config)
        }

        // Create pane split controller for this tab
        let paneSplitController = PaneSplitController(config: config)
        currentPaneSplitController = paneSplitController

        // Store the mapping of tab to split controller
        tabSplitControllers[tab.id] = paneSplitController

        // Add to main content view (this triggers loadView which creates splitView)
        mainContentView.addSubview(paneSplitController.view)
        paneSplitController.view.translatesAutoresizingMaskIntoConstraints = false

        // Now rebuild the split view with the tab's panes
        paneSplitController.rebuildSplitView(for: tab)

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
        guard index != activeTabIndex else { return } // Already on this tab

        print("🔄 Switching from tab \(activeTabIndex) to tab \(index)")

        // Hide current tab's split controller
        if let currentController = currentPaneSplitController {
            currentController.view.isHidden = true
            print("  Hiding current controller")
        }

        // Update active state
        tabs[activeTabIndex].isActive = false
        activeTabIndex = index
        tabs[activeTabIndex].isActive = true

        // Get the split controller for the new tab
        let newTab = tabs[index]
        if let newController = tabSplitControllers[newTab.id] {
            currentPaneSplitController = newController
            newController.view.isHidden = false
            print("  Showing new controller for tab \(index)")
        } else {
            print("  ⚠️ No split controller found for tab \(index)")
        }

        updateTabBar()
    }

    private func closeTab(index: Int) {
        guard index >= 0 && index < tabs.count && tabs.count > 1 else { return }

        let tabToClose = tabs[index]

        // Remove and cleanup the split controller for this tab
        if let controller = tabSplitControllers[tabToClose.id] {
            controller.view.removeFromSuperview()
            tabSplitControllers.removeValue(forKey: tabToClose.id)
        }

        tabs.remove(at: index)

        // Adjust active index
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        // Switch to the new active tab
        let newTab = tabs[activeTabIndex]
        if let newController = tabSplitControllers[newTab.id] {
            currentPaneSplitController = newController
            newController.view.isHidden = false
        }

        updateTabBar()
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
        showPanel(panel)
    }

    func activityBarDidToggleSidebar(_ activityBar: ActivityBarView) {
        toggleSidebar()
    }
}

extension MainWindowController: SidebarContainerDelegate {
    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL) {
        print("📂 Sidebar requested to open file: \(url.path)")
        // Open file in nvim in the terminal instead of built-in editor
        openFileInTerminalEditor(url)
    }

    private func openFileInTerminalEditor(_ url: URL) {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nvim"
        let command = "\(editor) \"\(url.path)\""
        runCommandInActiveTerminal(command)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String) {
        openDiffViewer(for: filePath)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenFile filePath: String, atLine line: Int) {
        let url = URL(fileURLWithPath: filePath)
        openFileInEditor(url, atLine: line)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestRunTask command: String) {
        runCommandInActiveTerminal(command)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestPasteCommand command: String) {
        pasteCommandToActiveTerminal(command)
    }

    private func openFileInEditor(_ url: URL) {
        // Don't try to open directories as files
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard exists && !isDirectory.boolValue else {
            print("Attempted to open directory or non-existent file: \(url.path)")
            return
        }

        // Create a new editor pane in the current tab
        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        // Create a new pane for the editor
        let editorPane = PaneModel()
        editorPane.createEditorViewController(for: url)

        // Add the editor pane to the current tab
        currentTab.addPane(editorPane, splitDirection: .horizontal)

        // Set the new pane as active (it's the last pane added)
        currentTab.activePaneIndex = currentTab.panes.count - 1

        // Update the split view with the new pane
        currentPaneSplitController?.rebuildSplitView(for: currentTab)

        // Focus the editor so cursor is active immediately
        currentPaneSplitController?.setActivePane(index: currentTab.activePaneIndex)

        updateTabBar()
    }

    private func openFileInEditor(_ url: URL, atLine line: Int) {
        // Don't try to open directories as files
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard exists && !isDirectory.boolValue else {
            print("Attempted to open directory or non-existent file: \(url.path)")
            return
        }

        // Create a new editor pane in the current tab
        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        // Create a new pane for the editor
        let editorPane = PaneModel()
        editorPane.createEditorViewController(for: url)

        // Add the editor pane to the current tab
        currentTab.addPane(editorPane, splitDirection: .horizontal)

        // Set the new pane as active (it's the last pane added)
        currentTab.activePaneIndex = currentTab.panes.count - 1

        // Update the split view with the new pane
        currentPaneSplitController?.rebuildSplitView(for: currentTab)

        // Navigate to the specific line
        if let editorVC = editorPane.editorViewController {
            editorVC.navigateToLine(line)
        }

        // Focus the editor so cursor is active immediately
        currentPaneSplitController?.setActivePane(index: currentTab.activePaneIndex)

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

    func showQuickOpen() {
        guard let window = window else { return }

        // Get current working directory from active terminal
        let currentWorkingDirectory: String
        if let activeTab = tabs[safe: activeTabIndex],
           let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }),
           let terminalVC = terminalPane.terminalViewController {
            currentWorkingDirectory = terminalVC.getCurrentWorkingDirectory()
        } else {
            currentWorkingDirectory = FileManager.default.currentDirectoryPath
        }

        // Create or reuse quick open panel
        if quickOpenPanel == nil {
            quickOpenPanel = QuickOpenPanel(
                contentRect: .zero,
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            quickOpenPanel?.quickOpenDelegate = self
        }

        quickOpenPanel?.show(relativeTo: window, workingDirectory: currentWorkingDirectory)
    }

    func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(config: config, mainWindowController: self)
        }

        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func openConfigFile() {
        // Get EDITOR from environment or default to nvim
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nvim"
        let configPath = "~/.config/sidekick/config.toml"
        let command = "\(editor) \(configPath)"

        print("📝 Opening config file with command: \(command)")

        // Make sure window is focused
        window?.makeKeyAndOrderFront(nil)

        // Send command to terminal
        runCommandInActiveTerminal(command)
    }

    func closeCurrentTab() {
        closeTab(index: activeTabIndex)
    }

    func saveCurrentFile() {
        // Save the current file if there's an active editor pane
        if let activePane = currentPaneSplitController?.activePane,
           activePane.paneType == .editor,
           let editor = activePane.editorViewController {
            _ = editor.saveFile()
        }
    }

    private func runCommandInActiveTerminal(_ command: String) {
        print("🖥️ runCommandInActiveTerminal called with: \(command)")
        print("🖥️ tabs.count: \(tabs.count), activeTabIndex: \(activeTabIndex)")

        guard activeTabIndex < tabs.count else {
            print("❌ activeTabIndex out of bounds!")
            return
        }

        let activeTab = tabs[activeTabIndex]
        print("🖥️ Active tab has \(activeTab.panes.count) panes")

        guard let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }) else {
            print("❌ No terminal pane found in active tab!")
            return
        }

        guard let terminalVC = terminalPane.terminalViewController else {
            print("❌ Terminal pane has no terminalViewController!")
            return
        }

        // Send the command followed by Enter to the terminal
        let commandWithEnter = command + "\n"
        print("✅ Sending command to terminal: \(commandWithEnter)")
        terminalVC.send(text: commandWithEnter)
    }

    private func pasteCommandToActiveTerminal(_ command: String) {
        guard let activeTab = tabs[safe: activeTabIndex],
              let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }),
              let terminalVC = terminalPane.terminalViewController else {
            return
        }

        // Send just the command without Enter, so user can edit it
        terminalVC.send(text: command)
    }

    private func setupIPC() {
        IPCServer.shared.delegate = self
        IPCServer.shared.start()
    }
}

// MARK: - QuickOpenPanelDelegate
extension MainWindowController: QuickOpenPanelDelegate {
    func quickOpenPanel(_ panel: QuickOpenPanel, didSelectFile filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        openFileInEditor(url)
    }
}

extension MainWindowController {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Ctrl+Tab / Ctrl+Shift+Tab - Cycle through tabs
        if modifiers.contains(.control) && keyCode == 48 { // Tab key
            if modifiers.contains(.shift) {
                // Ctrl+Shift+Tab - Previous tab
                cycleTabs(forward: false)
            } else {
                // Ctrl+Tab - Next tab
                cycleTabs(forward: true)
            }
            return
        }

        // Cmd+Shift combinations (check these first to avoid conflicts)
        if modifiers.contains([.command, .shift]) {
            switch keyCode {
            case 14: // Cmd+Shift+E (Files)
                showPanel(.files)
                return
            case 5: // Cmd+Shift+G (Git)
                showPanel(.git)
                return
            case 3: // Cmd+Shift+F (Search)
                showPanel(.search)
                return
            case 15: // Cmd+Shift+R (Run)
                showPanel(.run)
                return
            case 13: // Cmd+Shift+W (Close Pane)
                closeCurrentPane()
                return
            case 2: // Cmd+Shift+D (Split Right)
                currentPaneSplitController?.splitPane(direction: .horizontal)
                return
            case 6: // Cmd+Shift+X (Split Down)
                currentPaneSplitController?.splitPane(direction: .vertical)
                return
            case 17: // Cmd+Shift+T (New Tab)
                createNewTab()
                return
            case 47: // Cmd+Shift+. (Toggle hidden files)
                sidebarContainerView.toggleHiddenFiles()
                return
            default:
                break
            }
        }

        // Cmd key combinations
        if modifiers.contains(.command) && !modifiers.contains(.shift) {
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
            case 35: // Cmd+P (Quick Open)
                showQuickOpen()
                return
            case 43: // Cmd+, (Preferences)
                showPreferences()
                return
            case 2: // Cmd+D (Split Right)
                currentPaneSplitController?.splitPane(direction: .horizontal)
                return
            case 33: // Cmd+[ (Focus previous pane)
                currentPaneSplitController?.focusPreviousPane()
                return
            case 30: // Cmd+] (Focus next pane)
                currentPaneSplitController?.focusNextPane()
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

        super.keyDown(with: event)
    }

    private func cycleTabs(forward: Bool) {
        guard tabs.count > 1 else { return }

        if forward {
            // Next tab
            let nextIndex = (activeTabIndex + 1) % tabs.count
            switchToTab(index: nextIndex)
        } else {
            // Previous tab
            let prevIndex = (activeTabIndex - 1 + tabs.count) % tabs.count
            switchToTab(index: prevIndex)
        }
    }

    private func closeCurrentPane() {
        currentPaneSplitController?.closeActivePane()
    }

    func toggleSidebar() {
        sidebarContainerView.toggleVisibility()
        updateMainContentConstraints()
    }

    func showPanel(_ panel: SidebarPanel) {
        sidebarContainerView.showPanel(panel)
        activityBarView.selectPanel(panel)

        if sidebarContainerView.isHidden {
            sidebarContainerView.toggleVisibility()
            updateMainContentConstraints()
        }
    }

    func splitWithBrowser() {
        print("🌐 MainWindowController: splitWithBrowser called")
        currentPaneSplitController?.splitWithBrowser(direction: .horizontal)
    }

    private func updateMainContentConstraints() {
        // This is simplified - in a real implementation you'd update constraints
        // For now, just ensure the sidebar state is correct
        sidebarContainerView.layoutSubtreeIfNeeded()
    }

}

// MARK: - IPCServerDelegate
extension MainWindowController: IPCServerDelegate {
    func ipcServer(_ server: IPCServer, didReceiveCommand command: IPCCommandType) -> IPCResponse {
        switch command {
        case .ping:
            return IPCResponse(ok: true)

        case .newTab(let cwd):
            // Create new tab with optional working directory
            createNewTab(workingDirectory: cwd)
            return IPCResponse(ok: true)

        case .showDiff(let path, _, _):
            // For now, just open the file - could be enhanced to show actual diff
            let url = URL(fileURLWithPath: path)
            openFileInEditor(url)
            return IPCResponse(ok: true)

        case .agentReady:
            // Mark the active tab as agent ready
            if activeTabIndex < tabs.count {
                tabs[activeTabIndex].isAgentReady = true
                updateTabBar()

                // Notification: Play sound and bounce dock icon
                NSSound.beep()
                NSApp.requestUserAttention(.informationalRequest) // Bounce dock icon once
            }
            return IPCResponse(ok: true)

        case .agentBusy:
            // Mark the active tab as agent busy
            if activeTabIndex < tabs.count {
                tabs[activeTabIndex].isAgentReady = false
                updateTabBar()
            }
            return IPCResponse(ok: true)
        }
    }

    private func createNewTab(workingDirectory: String? = nil) {
        let newTab = TabModel()
        tabs.append(newTab)

        // Switch to the new tab
        activeTabIndex = tabs.count - 1
        switchToTab(index: activeTabIndex)

        updateTabBar()

        // If a working directory was specified, change to it in the new terminal
        if let cwd = workingDirectory,
           let terminalPane = newTab.panes.first(where: { $0.terminalViewController != nil }),
           let terminalVC = terminalPane.terminalViewController {
            terminalVC.send(text: "cd \"\(cwd)\"\n")
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