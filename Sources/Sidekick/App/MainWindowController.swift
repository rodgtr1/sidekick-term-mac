import Cocoa
import SwiftTerm
import UserNotifications

@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> UnsafeMutableRawPointer?

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: UnsafeMutableRawPointer?,
    _ windowNumber: Int,
    _ radius: Int32
) -> Int32

private final class MainWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           isInTitlebarDoubleClickRegion(event.locationInWindow) {
            performConfiguredTitlebarDoubleClickAction()
            return
        }

        super.sendEvent(event)
    }

    private func isInTitlebarDoubleClickRegion(_ location: NSPoint) -> Bool {
        guard let contentView = contentView else { return false }

        if isPointOverStandardWindowButton(location) {
            return false
        }

        let titlebarHeight = contentView.safeAreaInsets.top
        guard titlebarHeight > 0 else { return false }

        let titlebarMinY = contentView.frame.maxY - titlebarHeight
        return location.y >= titlebarMinY && location.y <= contentView.frame.maxY
    }

    private func isPointOverStandardWindowButton(_ location: NSPoint) -> Bool {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        return buttonTypes.contains { buttonType in
            guard let button = standardWindowButton(buttonType), !button.isHidden else {
                return false
            }

            let buttonFrame = button.convert(button.bounds, to: nil).insetBy(dx: -8, dy: -8)
            return buttonFrame.contains(location)
        }
    }
}

extension NSWindow {
    func performConfiguredTitlebarDoubleClickAction() {
        if let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")?.lowercased() {
            switch action {
            case "minimize":
                if styleMask.contains(.miniaturizable) {
                    performMiniaturize(nil)
                }
            case "none":
                break
            default:
                if styleMask.contains(.resizable) {
                    performZoom(nil)
                }
            }
            return
        }

        if UserDefaults.standard.object(forKey: "AppleMiniaturizeOnDoubleClick") != nil,
           UserDefaults.standard.bool(forKey: "AppleMiniaturizeOnDoubleClick"),
           styleMask.contains(.miniaturizable) {
            performMiniaturize(nil)
            return
        }

        if styleMask.contains(.resizable) {
            performZoom(nil)
        }
    }
}

private final class TitlebarBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performConfiguredTitlebarDoubleClickAction()
            return
        }

        window?.performDrag(with: event)
    }

    func applyTheme() {
        layer?.backgroundColor = Theme.shared.current.windowBackground.cgColor
        layer?.isOpaque = true
    }

    private func setupView() {
        wantsLayer = true
        applyTheme()
    }
}

class MainWindowController: NSWindowController {
    private var config: Config = Config.load()
    private var titlebarBackgroundView: TitlebarBackgroundView!
    private var tabBarSpacerView: TitlebarBackgroundView!
    private var tabBarView: TabBarView!
    private var activityBarView: ActivityBarView!
    private var sidebarContainerView: SidebarContainerView!
    private var mainContentView: NSView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var editorViewController: EditorViewController?
    private var tabs: [TabModel] = []
    private var activeTabIndex: Int = 0
    private var currentPaneSplitController: PaneSplitController?
    private var tabSplitControllers: [UUID: PaneSplitController] = [:] // Map tab IDs to their split controllers
    private var quickOpenPanel: QuickOpenPanel?
    private var preferencesWindowController: PreferencesWindowController?
    fileprivate var commandPalette: CommandPalettePanel?
    private var keyEventMonitor: Any?
    private let keyboardCommandRouter = KeyboardCommandRouter()

    convenience init() {
        print("🏗️ Creating MainWindowController...")

        let config = Config.load()
        Theme.shared.loadFromConfig(config)
        print("✅ Config loaded")

        let window = MainWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        print("✅ NSWindow created")

        window.title = "Sidekick"
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 1.0
        window.hasShadow = true

        // Make window movable by background
        window.isMovableByWindowBackground = true

        window.center()
        window.makeKeyAndOrderFront(nil)
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

        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        configureWindowBackgroundEffect()

        setupTitlebarBackground()
        setupTabBarSpacer()
        setupTabBar()
        setupActivityBar()
        setupSidebar()
        setupMainContent()

        layoutViews()

        // Create initial tab after all views are set up
        createNewTab()
    }

    private func setupTitlebarBackground() {
        titlebarBackgroundView = TitlebarBackgroundView()
        titlebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(titlebarBackgroundView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .themeDidChange,
            object: nil
        )
    }

    private func setupTabBarSpacer() {
        tabBarSpacerView = TitlebarBackgroundView()
        tabBarSpacerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabBarSpacerView)
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
        activityBarView.topInset = CGFloat(config.window.padding)
        activityBarView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(activityBarView)
    }

    private func setupSidebar() {
        sidebarContainerView = SidebarContainerView()
        sidebarContainerView.delegate = self
        sidebarContainerView.setVisible(false)
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarContainerView)
    }

    private func setupMainContent() {
        mainContentView = NSView()
        mainContentView.wantsLayer = true
        // Keep main content transparent so blur shows through terminal
        mainContentView.layer?.backgroundColor = NSColor.clear.cgColor
        mainContentView.layer?.isOpaque = false
        mainContentView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(mainContentView)
    }

    private func layoutViews() {
        guard let contentView = window?.contentView else { return }

        sidebarWidthConstraint = sidebarContainerView.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Fill the transparent native titlebar area with the app theme.
            titlebarBackgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            titlebarBackgroundView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titlebarBackgroundView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titlebarBackgroundView.bottomAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),

            // Fill the left spacer next to the tab strip so the whole chrome band matches.
            tabBarSpacerView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            tabBarSpacerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarSpacerView.trailingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
            tabBarSpacerView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),

            // Keep tabs below the native titlebar/traffic-light safe area.
            tabBarView.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: mainContentView.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarView.heightAnchor.constraint(equalToConstant: 36),

            // Activity bar starts below tab bar
            activityBarView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            activityBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            activityBarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            activityBarView.widthAnchor.constraint(equalToConstant: 48),

            // Sidebar starts below tab bar, to the right of activity bar
            sidebarContainerView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            sidebarContainerView.leadingAnchor.constraint(equalTo: activityBarView.trailingAnchor),
            sidebarContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarWidthConstraint,

            // Main content starts below tab bar, to the right of sidebar
            mainContentView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            mainContentView.leadingAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            mainContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        setupKeyboardShortcuts()
        setupCWDTracking()
    }

    @objc private func themeDidChange() {
        titlebarBackgroundView?.applyTheme()
        tabBarSpacerView?.applyTheme()
    }

    func applyRuntimeConfig(_ newConfig: Config) {
        config = newConfig
        window?.alphaValue = 1.0
        configureWindowBackgroundEffect()
        activityBarView?.topInset = CGFloat(newConfig.window.padding)
        sidebarContainerView?.setShowHiddenFiles(newConfig.editor?.showHiddenFiles ?? false)

        for tab in tabs {
            for pane in tab.panes {
                pane.terminalViewController?.applyConfig(newConfig)
            }
        }
    }

    private func configureWindowBackgroundEffect() {
        guard let window else { return }

        if config.window.enableBlur {
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)
            setBackgroundBlurRadius(20)
        } else {
            setBackgroundBlurRadius(0)
            window.isOpaque = true
            window.backgroundColor = NSColor(hex: "#1e1e2e") ?? .windowBackgroundColor
        }
    }

    private func setBackgroundBlurRadius(_ radius: Int32) {
        guard let window else { return }
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            window.windowNumber,
            radius
        )
    }

    private func setupKeyboardShortcuts() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneCommandStatusChanged(_:)),
            name: NSNotification.Name("PaneCommandStatusChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenURLRequested(_:)),
            name: NSNotification.Name("PaneOpenURLRequested"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenFileRequested(_:)),
            name: NSNotification.Name("PaneOpenFileRequested"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneAgentStateChanged(_:)),
            name: NSNotification.Name("PaneAgentStateChanged"),
            object: nil
        )
    }

    @objc private func terminalCWDChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let directory = userInfo["directory"] as? String else { return }

        if let pane = notification.object as? PaneModel,
           let activeTab = tabs[safe: activeTabIndex] {
            guard activeTab.activePane?.id == pane.id else { return }
        }

        // Update sidebar panels to show current active pane directory.
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

    @objc private func paneOpenFileRequested(_ notification: Notification) {
        guard let path = notification.userInfo?["path"] as? String else { return }
        let line = notification.userInfo?["line"] as? Int
        openFileInEditor(URL(fileURLWithPath: path), atLine: line ?? 1, highlighting: nil)
    }

    @objc private func paneOpenURLRequested(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }

        // Reuse an existing browser pane in the active tab if there is one.
        if let browserPane = tabs[safe: activeTabIndex]?.panes.first(where: { $0.paneType == .browser }),
           let browserVC = browserPane.browserViewController {
            browserVC.navigate(to: url)
            return
        }

        currentPaneSplitController?.splitWithBrowser(direction: .horizontal, initialURL: url)
    }

    @objc private func paneCommandStatusChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel else { return }
        let status = notification.userInfo?["status"] as? TerminalCommandStatus

        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                notifyIfLongCommandFinished(status, tabTitle: tab.title)

                // Only surface status from the pane the tab is showing as active.
                guard tab.activePane?.id == pane.id else { break }
                tab.lastCommandFailed = status.map { !$0.succeeded } ?? false
                tab.lastCommandTooltip = status.map { "Last command: \($0.summary)" }
                updateTabBar()
                break
            }
        }
    }

    /// Commands that ran longer than this notify the user when they finish
    /// while Sidekick is in the background.
    private static let longCommandThreshold: TimeInterval = 30

    private func notifyIfLongCommandFinished(_ status: TerminalCommandStatus?, tabTitle: String) {
        guard let status = status,
              let duration = status.duration,
              duration >= Self.longCommandThreshold,
              !NSApp.isActive else { return }

        NSApp.requestUserAttention(.informationalRequest)

        // UNUserNotificationCenter requires a real bundle; skip when running
        // the bare debug binary.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = status.succeeded ? "Command finished" : "Command failed"
            content.body = "\(tabTitle) — \(status.summary)"
            content.sound = status.succeeded ? nil : .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    @objc private func paneAgentStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel,
              let state = notification.userInfo?["agentState"] as? AgentState else { return }

        for tab in tabs {
            if tab.panes.contains(where: { $0.id == pane.id }) {
                tab.agentState = state
                updateTabBar()

                if state == .ready || state == .done {
                    NSApp.requestUserAttention(.informationalRequest)
                }
                break
            }
        }
    }

    func createNewTab(workingDirectory: String? = nil) {
        let startDirectory = workingDirectory ?? currentWorkingDirectoryForNewTerminal()

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
            firstPane.createTerminalViewController(config: config, initialDirectory: startDirectory)
        }

        // Create pane split controller for this tab
        let paneSplitController = PaneSplitController(config: config)
        paneSplitController.delegate = self
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

    private func syncSidebarToActiveTab() {
        guard let directory = currentSidebarDirectoryForActiveTab() else { return }
        sidebarContainerView.updateFileTree(path: directory)
    }

    private func currentSidebarDirectoryForActiveTab() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }

        if let activePaneDirectory = directoryForSidebar(from: activeTab.activePane) {
            return activePaneDirectory
        }

        return activeTab.panes.compactMap { directoryForSidebar(from: $0) }.first
    }

    private func directoryForSidebar(from pane: PaneModel?) -> String? {
        guard let pane = pane else { return nil }

        if let directory = pane.resolvedWorkingDirectory() {
            return directory
        }

        return nil
    }

    private func currentWorkingDirectoryForNewTerminal() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }

        if let activePaneDirectory = activeTab.activePane?.resolvedWorkingDirectory() {
            return activePaneDirectory
        }

        return activeTab.panes.compactMap { $0.resolvedWorkingDirectory() }.first
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
        syncSidebarToActiveTab()
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
        syncSidebarToActiveTab()
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

extension MainWindowController: PaneSplitControllerDelegate {
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int) {
        guard let activeTab = tabs[safe: activeTabIndex],
              tabSplitControllers[activeTab.id] === controller else { return }

        if !activeTab.panes.contains(where: { $0.id == pane.id }) {
            activeTab.panes.append(pane)
        }
        activeTab.activePaneIndex = index
        updateTabBar()
    }

    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int) {
        guard let activeTab = tabs[safe: activeTabIndex],
              tabSplitControllers[activeTab.id] === controller else { return }

        activeTab.activePaneIndex = index
        if let directory = pane.resolvedWorkingDirectory() {
            sidebarContainerView.updateFileTree(path: directory)
        }
    }

    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int) {
        guard let activeTab = tabs[safe: activeTabIndex],
              tabSplitControllers[activeTab.id] === controller else { return }

        if index < activeTab.panes.count, activeTab.panes[index].id == pane.id {
            activeTab.panes.remove(at: index)
        } else if let paneIndex = activeTab.panes.firstIndex(of: pane) {
            activeTab.panes.remove(at: paneIndex)
        }

        if activeTab.activePaneIndex >= activeTab.panes.count {
            activeTab.activePaneIndex = max(activeTab.panes.count - 1, 0)
        } else if activeTab.activePaneIndex > index {
            activeTab.activePaneIndex -= 1
        }

        activeTab.updateTitleFromActivePane()
        updateTabBar()
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
    func sidebarContainerTabs(_ container: SidebarContainerView) -> [TabModel] {
        tabs
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestSwitchToTab index: Int) {
        switchToTab(index: index)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestConnectCommand command: String) {
        createNewTab()
        // Give the new shell a moment to start before typing the command.
        let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            terminal?.send(text: command + "\n")
        }
    }

    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL) {
        print("📂 Sidebar requested to open file: \(url.path)")

        if config.editor?.fileOpenMode == "builtin" {
            openFileInEditor(url)
        } else {
            openFileInTerminalEditor(url)
        }
    }

    private func openFileInTerminalEditor(_ url: URL) {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "nvim"
        let command = "\(editor) \"\(url.path)\""
        runCommandInActiveTerminal(command)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestDiffFor filePath: String) {
        openDiffViewer(for: filePath)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestUncommittedChangesFor repositoryPath: String, focusedFilePath: String?) {
        openUncommittedChangesInNewTab(repositoryPath: repositoryPath, focusedFilePath: focusedFilePath)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenFile filePath: String, atLine line: Int, highlighting searchTerm: String?) {
        let url = URL(fileURLWithPath: filePath)
        openFileInEditor(url, atLine: line, highlighting: searchTerm)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestRunTask command: String) {
        runCommandInActiveTerminal(command)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestPasteCommand command: String) {
        pasteCommandToActiveTerminal(command)
    }

    private func openFileInEditor(_ url: URL) {
        openEditorPane(for: url)
    }

    private func openFileInEditor(_ url: URL, atLine line: Int) {
        openEditorPane(for: url, line: line)
    }

    private func openFileInEditor(_ url: URL, atLine line: Int, highlighting searchTerm: String?) {
        openEditorPane(for: url, line: line, searchTerm: searchTerm)
    }

    private func openEditorPane(for url: URL, line: Int? = nil, searchTerm: String? = nil) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        guard exists && !isDirectory.boolValue else {
            print("Attempted to open directory or non-existent file: \(url.path)")
            return
        }

        guard let currentTab = tabs[safe: activeTabIndex] else { return }

        let editorPane = PaneFactory.editorPane(for: url, line: line, searchTerm: searchTerm)
        currentTab.addPane(editorPane, splitDirection: .horizontal)
        currentTab.activePaneIndex = currentTab.panes.count - 1
        currentPaneSplitController?.rebuildSplitView(for: currentTab)
        currentPaneSplitController?.setActivePane(index: currentTab.activePaneIndex)

        updateTabBar()
    }

    private func openDiffViewer(for filePath: String) {
        openDiffInNewTab(for: filePath)
    }

    private func openDiffInNewTab(for filePath: String) {
        openSinglePaneTab(pane: PaneFactory.diffPane(for: filePath))
    }

    private func openUncommittedChangesInNewTab(repositoryPath: String, focusedFilePath: String?) {
        if let existingIndex = tabs.firstIndex(where: { tab in
            tab.panes.count == 1 &&
            tab.panes.first?.paneType == .uncommittedChanges &&
            tab.panes.first?.currentDirectory == repositoryPath
        }) {
            switchToTab(index: existingIndex)
            tabs[existingIndex].panes.first?.uncommittedChangesViewController?.reload(focusedFilePath: focusedFilePath)
            return
        }

        let pane = PaneFactory.uncommittedChangesPane(
            repositoryPath: repositoryPath,
            focusedFilePath: focusedFilePath,
            onOpenFile: { [weak self] filePath in
                self?.openFileInEditor(URL(fileURLWithPath: filePath))
            }
        )
        openSinglePaneTab(pane: pane)
    }

    private func openSinglePaneTab(pane: PaneModel) {
        if let currentController = currentPaneSplitController {
            currentController.view.isHidden = true
        }

        if activeTabIndex < tabs.count {
            tabs[activeTabIndex].isActive = false
        }

        let tab = TabModel()
        tab.panes = [pane]
        tab.activePaneIndex = 0
        tab.isActive = true
        tab.updateTitleFromActivePane()

        tabs.append(tab)
        activeTabIndex = tabs.count - 1

        let paneSplitController = PaneSplitController(config: config)
        paneSplitController.delegate = self
        currentPaneSplitController = paneSplitController
        tabSplitControllers[tab.id] = paneSplitController

        mainContentView.addSubview(paneSplitController.view)
        paneSplitController.view.translatesAutoresizingMaskIntoConstraints = false
        paneSplitController.rebuildSplitView(for: tab)

        NSLayoutConstraint.activate([
            paneSplitController.view.topAnchor.constraint(equalTo: mainContentView.topAnchor),
            paneSplitController.view.leadingAnchor.constraint(equalTo: mainContentView.leadingAnchor),
            paneSplitController.view.trailingAnchor.constraint(equalTo: mainContentView.trailingAnchor),
            paneSplitController.view.bottomAnchor.constraint(equalTo: mainContentView.bottomAnchor)
        ])

        updateTabBar()
        syncSidebarToActiveTab()
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

    func showCommandPalette() {
        guard let window = window else { return }

        if commandPalette == nil {
            commandPalette = CommandPalettePanel()
        }

        let actions: [PaletteAction] = [
            PaletteAction(title: "New Tab", subtitle: "⌘T", symbolName: "plus.rectangle") { [weak self] in
                self?.createNewTab()
            },
            PaletteAction(title: "Close Tab", subtitle: "⌘W", symbolName: "xmark.rectangle") { [weak self] in
                guard let self = self else { return }
                self.closeTab(index: self.activeTabIndex)
            },
            PaletteAction(title: "Split Pane Horizontally", subtitle: "⌘D", symbolName: "rectangle.split.2x1") { [weak self] in
                self?.currentPaneSplitController?.splitPane(direction: .horizontal)
            },
            PaletteAction(title: "Split Pane Vertically", subtitle: "⇧⌘D", symbolName: "rectangle.split.1x2") { [weak self] in
                self?.currentPaneSplitController?.splitPane(direction: .vertical)
            },
            PaletteAction(title: "Open Browser Pane", subtitle: "⇧⌘O", symbolName: "globe") { [weak self] in
                self?.splitWithBrowser()
            },
            PaletteAction(title: "Find in Terminal", subtitle: "⌘F", symbolName: "magnifyingglass") { [weak self] in
                guard let self = self else { return }
                self.tabs[safe: self.activeTabIndex]?.activePane?.terminalViewController?.showFindBar()
            },
            PaletteAction(title: "Jump to Previous Prompt", subtitle: "⌘↑", symbolName: "arrow.up.to.line") { [weak self] in
                guard let self = self else { return }
                self.tabs[safe: self.activeTabIndex]?.activePane?.terminalViewController?.scrollToPreviousPrompt()
            },
            PaletteAction(title: "Jump to Next Prompt", subtitle: "⌘↓", symbolName: "arrow.down.to.line") { [weak self] in
                guard let self = self else { return }
                self.tabs[safe: self.activeTabIndex]?.activePane?.terminalViewController?.scrollToNextPrompt()
            },
            PaletteAction(title: "Quick Open File", subtitle: "⌘P", symbolName: "doc.text.magnifyingglass") { [weak self] in
                self?.showQuickOpen()
            },
            PaletteAction(title: "Show Files Panel", subtitle: "⇧⌘E", symbolName: "folder") { [weak self] in
                self?.showPanel(.files)
            },
            PaletteAction(title: "Show Git Panel", subtitle: "⇧⌘G", symbolName: "arrow.branch") { [weak self] in
                self?.showPanel(.git)
            },
            PaletteAction(title: "Show Search Panel", subtitle: "⇧⌘F", symbolName: "magnifyingglass.circle") { [weak self] in
                self?.showPanel(.search)
            },
            PaletteAction(title: "Show Run Panel", subtitle: "⇧⌘R", symbolName: "play.circle") { [weak self] in
                self?.showPanel(.run)
            },
            PaletteAction(title: "Toggle Sidebar", subtitle: "⌘B", symbolName: "sidebar.left") { [weak self] in
                self?.toggleSidebar()
            },
            PaletteAction(title: "Toggle Hidden Files", subtitle: "⇧⌘.", symbolName: "eye.slash") { [weak self] in
                self?.sidebarContainerView.toggleHiddenFiles()
            },
            PaletteAction(title: "Preferences", subtitle: "⌘,", symbolName: "gearshape") { [weak self] in
                self?.showPreferences()
            },
            PaletteAction(title: "Edit Config File", subtitle: "config.toml", symbolName: "doc.badge.gearshape") { [weak self] in
                self?.openConfigFile()
            }
        ]

        commandPalette?.show(relativeTo: window, actions: actions)
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
        guard let activeTab = tabs[safe: activeTabIndex] else { return }

        let editorPane =
            activeTab.panes.first { $0.editorViewController?.isEditorFocused == true } ??
            activeTab.activePane.flatMap { $0.paneType == .editor ? $0 : nil } ??
            currentPaneSplitController?.activePane.flatMap { $0.paneType == .editor ? $0 : nil }

        guard let pane = editorPane,
              let editor = pane.editorViewController else {
            print("💾 No active editor pane to save")
            return
        }

        if editor.saveFile() {
            pane.updateTitleForEditor(fileName: editor.fileName)
            activeTab.isDirty = activeTab.panes.contains { $0.editorViewController?.isModified == true }
            activeTab.updateTitleFromActivePane()
            updateTabBar()
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
        if handleKeyDown(event) {
            return
        }

        super.keyDown(with: event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let command = keyboardCommandRouter.command(for: event, tabCount: tabs.count) else {
            return false
        }

        performKeyboardCommand(command)
        return true
    }

    private func performKeyboardCommand(_ command: KeyboardCommand) {
        switch command {
        case .cycleTabs(let forward):
            cycleTabs(forward: forward)
        case .showPanel(let panel):
            togglePanel(panel)
        case .closeCurrentPane:
            closeCurrentPane()
        case .splitPane(let direction):
            currentPaneSplitController?.splitPane(direction: direction)
        case .newTab:
            createNewTab()
        case .jumpToPrompt(let previous):
            guard let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController else { return }
            if previous {
                terminal.scrollToPreviousPrompt()
            } else {
                terminal.scrollToNextPrompt()
            }
        case .commandPalette:
            showCommandPalette()
        case .findInTerminal:
            tabs[safe: activeTabIndex]?.activePane?.terminalViewController?.showFindBar()
        case .toggleHiddenFiles:
            // Keep the keyboard toggle and the preferences setting in sync.
            if config.editor == nil {
                config.editor = EditorConfig()
            }
            let show = !(config.editor?.showHiddenFiles ?? false)
            config.editor?.showHiddenFiles = show
            sidebarContainerView.setShowHiddenFiles(show)
            config.save()
        case .closeTab:
            closeTab(index: activeTabIndex)
        case .saveFile:
            saveCurrentFile()
        case .toggleSidebar:
            toggleSidebar()
        case .quickOpen:
            showQuickOpen()
        case .preferences:
            showPreferences()
        case .splitWithBrowser:
            splitWithBrowser()
        case .focusPane(let forward):
            forward ? currentPaneSplitController?.focusNextPane() : currentPaneSplitController?.focusPreviousPane()
        case .selectTab(let index):
            switchToTab(index: index)
        }
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
        if currentPaneSplitController?.closeActivePane() != true {
            window?.performClose(nil)
        }
    }

    func toggleSidebar() {
        sidebarContainerView.toggleVisibility()
        updateSidebarLayout()
    }

    private func togglePanel(_ panel: SidebarPanel) {
        if sidebarContainerView.visible && sidebarContainerView.currentPanel == panel {
            sidebarContainerView.setVisible(false)
            updateSidebarLayout()
        } else {
            showPanel(panel)
        }
    }

    func showPanel(_ panel: SidebarPanel) {
        sidebarContainerView.showPanel(panel)
        activityBarView.selectPanel(panel)

        if sidebarContainerView.isHidden {
            sidebarContainerView.setVisible(true)
            updateSidebarLayout()
        }

        // Re-push the active pane's directory so a freshly opened panel
        // reflects the current terminal, not whatever it last saw.
        syncSidebarToActiveTab()
    }

    func splitWithBrowser() {
        print("🌐 MainWindowController: splitWithBrowser called")
        currentPaneSplitController?.splitWithBrowser(direction: .horizontal)
    }

    func showKeyboardShortcuts() {
        // Show keyboard shortcuts help
        // For now, this is a placeholder - could show a panel with shortcuts
        print("⌨️ Keyboard shortcuts requested")
    }

    private func updateSidebarLayout() {
        sidebarWidthConstraint.constant = sidebarContainerView.visible ? 240 : 0
        window?.contentView?.layoutSubtreeIfNeeded()
    }

}

// MARK: - IPCServerDelegate
extension MainWindowController: IPCServerDelegate {
    func ipcServer(_ server: IPCServer, didReceiveCommand command: IPCCommandType) -> IPCResponse {
        switch command {
        case .ping:
            return IPCResponse(ok: true)

        case .newTab(let cwd):
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
                tabs[activeTabIndex].agentState = .ready
                updateTabBar()

                // Notification: Bounce dock icon once
                NSApp.requestUserAttention(.informationalRequest) // Bounce dock icon once
            }
            return IPCResponse(ok: true)

        case .agentBusy:
            // Mark the active tab as agent busy
            if activeTabIndex < tabs.count {
                tabs[activeTabIndex].agentState = .working
                updateTabBar()
            }
            return IPCResponse(ok: true)

        case .agentDone:
            // Mark the active tab as done
            if activeTabIndex < tabs.count {
                tabs[activeTabIndex].agentState = .done
                updateTabBar()

                NSApp.requestUserAttention(.informationalRequest)
            }
            return IPCResponse(ok: true)

        case .agentIdle:
            // Mark the active tab as agent idle
            if activeTabIndex < tabs.count {
                tabs[activeTabIndex].agentState = .idle
                updateTabBar()
            }
            return IPCResponse(ok: true)
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
