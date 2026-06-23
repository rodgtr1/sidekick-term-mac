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
    private static let sidebarWidthDefaultsKey = "sidebarWidth"
    private var config: Config = Config.load()
    private var titlebarBackgroundView: TitlebarBackgroundView!
    private var tabBarSpacerView: TitlebarBackgroundView!
    private var tabBarView: TabBarView!
    private var activityBarView: ActivityBarView!
    private var sidebarContainerView: SidebarContainerView!
    private var mainContentView: NSView!
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarResizeHandle: SidebarResizeHandle!
    private var sidebarPreferredWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: MainWindowController.sidebarWidthDefaultsKey)
        return saved > 0 ? CGFloat(saved) : 240
    }()
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
    private let configWatcher = ConfigWatcher()
    private var sessionSaveTimer: Timer?
    /// Last session state written, to skip identical autosave writes.
    private var lastSavedSession: SessionState?
    /// Pending hook diff approvals, shown one sheet at a time.
    private var diffApprovalQueue: [(path: String, old: String, new: String, completion: (Bool) -> Void)] = []
    private var activeDiffApproval: DiffApprovalPanel?

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

        setupConfigWatcher()
        setupSessionPersistence()
    }

    private func setupConfigWatcher() {
        configWatcher.onChange = { [weak self] in
            guard let self = self else { return }
            print("🔄 Config file changed on disk, reloading")
            let newConfig = Config.load()
            Theme.shared.loadFromConfig(newConfig)
            self.applyRuntimeConfig(newConfig)
        }
        configWatcher.start()
    }

    private func setupSessionPersistence() {
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.saveSession()
        }

        if let window = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    @objc private func windowWillClose() {
        saveSession()

        // Don't strand hook processes blocked on approval: reject anything
        // pending so their IPC responses are sent and sockets closed.
        activeDiffApproval?.cancel()
        activeDiffApproval = nil
        drainDiffApprovalQueue()
    }

    private func drainDiffApprovalQueue() {
        let pending = diffApprovalQueue
        diffApprovalQueue.removeAll()
        for request in pending {
            request.completion(false)
        }
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

        // Create initial tab(s) after all views are set up
        if config.behavior.restoreSession, let session = SessionStore.load() {
            restoreSession(session)
        } else {
            createNewTab()
        }
    }

    // MARK: - Session save/restore

    func saveSession() {
        guard !tabs.isEmpty else { return }

        let tabStates: [SessionTabState] = tabs.map { tab in
            let panes: [SessionPaneState] = tab.panes.compactMap { pane in
                switch pane.paneType {
                case .terminal:
                    return SessionPaneState(
                        type: "terminal",
                        cwd: pane.resolvedWorkingDirectory(),
                        url: nil
                    )
                case .browser:
                    return SessionPaneState(
                        type: "browser",
                        cwd: nil,
                        url: pane.browserViewController?.pageURL?.absoluteString
                    )
                case .editor, .diff, .uncommittedChanges:
                    // Transient views; don't recreate them on relaunch.
                    return nil
                }
            }
            return SessionTabState(
                panes: panes,
                activePaneIndex: min(tab.activePaneIndex, max(panes.count - 1, 0)),
                customTitle: tab.customTitle
            )
        }

        let state = SessionState(tabs: tabStates, activeTabIndex: activeTabIndex)
        guard state != lastSavedSession else { return }
        lastSavedSession = state
        SessionStore.save(state)
    }

    private func restoreSession(_ session: SessionState) {
        let restorable = session.tabs.filter { !$0.panes.isEmpty }
        guard !restorable.isEmpty else {
            createNewTab()
            return
        }

        print("📦 Restoring session with \(restorable.count) tab(s)")
        for tabState in restorable.prefix(Limits.maxTabs) {
            restoreTab(from: tabState)
        }

        let targetIndex = min(max(0, session.activeTabIndex), tabs.count - 1)
        if targetIndex != activeTabIndex {
            switchToTab(index: targetIndex)
        }
        // Point the sidebar at the restored tab's directory right away.
        syncSidebarToActiveTab()
    }

    private func restoreTab(from state: SessionTabState) {
        let tab = TabModel()
        tab.panes.removeAll()
        tab.customTitle = state.customTitle

        for paneState in state.panes.prefix(Limits.maxPanesPerTab) {
            let pane = PaneModel()
            if paneState.type == "browser" {
                pane.createBrowserViewController(initialURL: paneState.url.flatMap { URL(string: $0) })
            } else {
                pane.createTerminalViewController(config: config, initialDirectory: paneState.cwd)
            }
            tab.panes.append(pane)
        }
        tab.activePaneIndex = min(max(0, state.activePaneIndex), tab.panes.count - 1)
        tab.updateTitleFromActivePane()

        installTab(tab)
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
        sidebarContainerView.setShowTeleportHosts(config.hosts?.showTeleport ?? false)
        sidebarContainerView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarContainerView)

        sidebarResizeHandle = SidebarResizeHandle()
        sidebarResizeHandle.isHidden = true
        sidebarResizeHandle.onDrag = { [weak self] delta in
            self?.resizeSidebar(by: delta)
        }
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(sidebarResizeHandle)
    }

    private func setupMainContent() {
        mainContentView = NSView()
        mainContentView.wantsLayer = true
        // Keep main content transparent so blur shows through terminal
        mainContentView.layer?.backgroundColor = NSColor.clear.cgColor
        mainContentView.layer?.isOpaque = false
        mainContentView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(mainContentView)
        if let sidebarResizeHandle {
            window?.contentView?.addSubview(sidebarResizeHandle, positioned: .above, relativeTo: mainContentView)
        }
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

            sidebarResizeHandle.topAnchor.constraint(equalTo: sidebarContainerView.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: sidebarContainerView.bottomAnchor),
            sidebarResizeHandle.centerXAnchor.constraint(equalTo: sidebarContainerView.trailingAnchor),
            sidebarResizeHandle.widthAnchor.constraint(equalToConstant: 8),

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
        configureWindowBackgroundEffect()
        // Repaint open terminals so a theme switch (or an Auto light/dark flip)
        // applies live rather than only to newly opened panes.
        for tab in tabs {
            for pane in tab.panes {
                pane.terminalViewController?.applyConfig(config)
                pane.editorViewController?.applyConfig(config)
            }
        }
    }

    func applyRuntimeConfig(_ newConfig: Config) {
        config = newConfig
        window?.alphaValue = 1.0
        configureWindowBackgroundEffect()
        activityBarView?.topInset = CGFloat(newConfig.window.padding)
        sidebarContainerView?.setShowHiddenFiles(newConfig.editor?.showHiddenFiles ?? false)
        sidebarContainerView?.setShowTeleportHosts(newConfig.hosts?.showTeleport ?? false)

        for tab in tabs {
            for pane in tab.panes {
                pane.terminalViewController?.applyConfig(newConfig)
                pane.editorViewController?.applyConfig(newConfig)
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
            window.backgroundColor = AppTheme.windowBackground
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
        openURLInBrowserPane(url)
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
        postUserNotification(
            title: status.succeeded ? "Command finished" : "Command failed",
            body: "\(tabTitle) — \(status.summary)",
            playSound: !status.succeeded
        )
    }

    private func postUserNotification(title: String, body: String, playSound: Bool) {
        // UNUserNotificationCenter requires a real bundle; skip when running
        // the bare debug binary.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = playSound ? .default : nil
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    @objc private func paneAgentStateChanged(_ notification: Notification) {
        guard let pane = notification.object as? PaneModel,
              notification.userInfo?["agentState"] is AgentState else { return }

        if let tab = tabs.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
            // PaneModel has already stored the new state. Aggregate all panes
            // so an idle sibling cannot mask one that is working or blocked.
            tab.updateAgentStateFromPanes()
            applyAgentState(tab.agentState, to: tab)
        }
    }

    /// Single path for agent state changes regardless of how they arrived
    /// (OSC termprop from the shell vs the IPC socket): updates the tab dot,
    /// the activity-bar badge, and alerts the user when input is needed.
    private func applyAgentState(_ state: AgentState, to tab: TabModel) {
        tab.agentState = state
        updateTabBar()
        refreshAgentsBadge()

        if state == .ready || state == .done {
            NSApp.requestUserAttention(.informationalRequest)
            if !NSApp.isActive {
                postUserNotification(
                    title: state == .ready ? "Agent waiting for input" : "Agent finished",
                    body: tab.title,
                    playSound: state == .ready
                )
            }
        }
    }

    /// Updates the activity-bar badge with the number of tabs whose agent is
    /// waiting for input.
    private func refreshAgentsBadge() {
        let waiting = tabs.filter { $0.agentState == .ready }.count
        activityBarView.updateAgentsBadge(count: waiting)
    }

    func createNewTab(workingDirectory: String? = nil) {
        let startDirectory = workingDirectory ?? currentWorkingDirectoryForNewTerminal()

        let tab = TabModel()
        if let firstPane = tab.panes.first {
            firstPane.createTerminalViewController(config: config, initialDirectory: startDirectory)
        }

        installTab(tab)
    }

    /// Shared plumbing for adding a fully-built tab: hides the current tab,
    /// appends and activates the new one, and installs its split controller
    /// into the main content view. Used by new-tab, session restore, and
    /// single-pane (diff/changes) tabs so they can't drift apart.
    private func installTab(_ tab: TabModel) {
        if let currentController = currentPaneSplitController {
            currentController.view.isHidden = true
        }
        if let activeTab = tabs[safe: activeTabIndex] {
            activeTab.isActive = false
        }

        tab.isActive = true
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
    }

    private func updateTabBar() {
        tabBarView.updateTabs(tabs, activeIndex: activeTabIndex)
    }

    private func syncSidebarToActiveTab() {
        guard let directory = currentSidebarDirectoryForActiveTab() else { return }
        sidebarContainerView.updateFileTree(path: directory)

        // Keep the file tree pointed at whatever the active tab is editing:
        // expand to and highlight that file, or clear the selection otherwise.
        if let editorPath = activeEditorFilePath() {
            sidebarContainerView.revealFile(URL(fileURLWithPath: editorPath))
        } else {
            sidebarContainerView.clearFileSelection()
        }
    }

    private func activeEditorFilePath() -> String? {
        guard let activeTab = tabs[safe: activeTabIndex] else { return nil }
        let editorPane =
            activeTab.activePane.flatMap { $0.paneType == .editor ? $0 : nil } ??
            activeTab.panes.first(where: { $0.paneType == .editor })
        return editorPane?.editorViewController?.filePath
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

    /// After a tab's view is unhidden, its editors need to regenerate their
    /// glyph layout — NSTextView leaves them blank otherwise. Deferred to the
    /// next runloop so the view has its restored frame before we lay out.
    private func refreshEditorsOnShow(for tab: TabModel) {
        DispatchQueue.main.async {
            for pane in tab.panes {
                pane.editorViewController?.refreshLayout()
            }
        }
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
            refreshEditorsOnShow(for: newTab)
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
            refreshEditorsOnShow(for: newTab)
        }

        updateTabBar()
        syncSidebarToActiveTab()
        refreshAgentsBadge()
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

    func tabBar(_ tabBar: TabBarView, didMoveTab fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < tabs.count,
              toIndex >= 0, toIndex < tabs.count else {
            updateTabBar()
            return
        }

        let activeTab = tabs[safe: activeTabIndex]
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)

        if let activeTab = activeTab, let newActiveIndex = tabs.firstIndex(where: { $0.id == activeTab.id }) {
            activeTabIndex = newActiveIndex
        }
        updateTabBar()
    }

    func tabBar(_ tabBar: TabBarView, didRenameTab index: Int, to title: String?) {
        guard let tab = tabs[safe: index] else { return }
        tab.customTitle = title
        updateTabBar()
    }
}

extension MainWindowController: PaneSplitControllerDelegate {
    func paneSplitController(_ controller: PaneSplitController, didAddPane pane: PaneModel, at index: Int) {
        guard let tab = tabs.first(where: { tabSplitControllers[$0.id] === controller }) else { return }

        if !tab.panes.contains(where: { $0.id == pane.id }) {
            tab.panes.append(pane)
        }
        updateTabBar()
    }

    func paneSplitController(_ controller: PaneSplitController, didActivatePane pane: PaneModel, at index: Int) {
        guard let tabIndex = tabs.firstIndex(where: { tabSplitControllers[$0.id] === controller }) else { return }
        let tab = tabs[tabIndex]

        tab.activePaneIndex = index
        if tabIndex != activeTabIndex {
            switchToTab(index: tabIndex)
        }
        if let directory = pane.resolvedWorkingDirectory() {
            sidebarContainerView.updateFileTree(path: directory)
        }
    }

    func paneSplitController(_ controller: PaneSplitController, didClosePane pane: PaneModel, at index: Int) {
        guard let tab = tabs.first(where: { tabSplitControllers[$0.id] === controller }) else { return }

        if index < tab.panes.count, tab.panes[index].id == pane.id {
            tab.panes.remove(at: index)
        } else if let paneIndex = tab.panes.firstIndex(of: pane) {
            tab.panes.remove(at: paneIndex)
        }

        if tab.activePaneIndex >= tab.panes.count {
            tab.activePaneIndex = max(tab.panes.count - 1, 0)
        } else if tab.activePaneIndex > index {
            tab.activePaneIndex -= 1
        }

        tab.updateTitleFromActivePane()
        tab.updateAgentStateFromPanes()
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

    private func openURLInBrowserPane(_ url: URL) {
        if let browserPane = tabs[safe: activeTabIndex]?.panes.first(where: { $0.paneType == .browser }),
           let browserVC = browserPane.browserViewController {
            browserVC.navigate(to: url)
            return
        }
        currentPaneSplitController?.splitWithBrowser(direction: .horizontal, initialURL: url)
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
        syncSidebarToActiveTab()
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
        let tab = TabModel()
        tab.panes = [pane]
        tab.activePaneIndex = 0
        tab.updateTitleFromActivePane()

        installTab(tab)
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
            PaletteAction(title: "Toggle Sidebar", subtitle: "⌘B", symbolName: "sidebar.left") { [weak self] in
                self?.toggleSidebar()
            },
            PaletteAction(title: "Toggle Hidden Files", subtitle: "⇧⌘.", symbolName: "eye.slash") { [weak self] in
                self?.sidebarContainerView.toggleHiddenFiles()
            },
            PaletteAction(title: "Zoom In", subtitle: "⌘=", symbolName: "plus.magnifyingglass") {
                FontZoom.shared.zoomIn()
            },
            PaletteAction(title: "Zoom Out", subtitle: "⌘-", symbolName: "minus.magnifyingglass") {
                FontZoom.shared.zoomOut()
            },
            PaletteAction(title: "Reset Zoom", subtitle: "⌘0", symbolName: "1.magnifyingglass") {
                FontZoom.shared.reset()
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

    /// Sends the command to the active tab's first terminal pane and returns
    /// that pane, so callers can track which pane ran the command.
    @discardableResult
    private func runCommandInActiveTerminal(_ command: String) -> PaneModel? {
        guard let activeTab = tabs[safe: activeTabIndex],
              let terminalPane = activeTab.panes.first(where: { $0.terminalViewController != nil }),
              let terminalVC = terminalPane.terminalViewController else {
            print("❌ No terminal pane found in active tab!")
            return nil
        }

        terminalVC.send(text: command + "\n")
        return terminalPane
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
        // When the GUI file editor has focus, let it own a few shortcuts that
        // otherwise route to panes/terminal: ⌘F (find bar), ⌘] / ⌘[ (indent /
        // outdent). The terminal and nvim are not CodeTextViews, so they keep
        // the default pane behavior.
        if window?.firstResponder is CodeTextView {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command,
               event.keyCode == 3 || event.keyCode == 30 || event.keyCode == 33 {
                return false
            }
        }

        guard let command = keyboardCommandRouter.command(for: event, tabCount: tabs.count) else {
            return false
        }

        // Cmd+V only intercepts when the pasteboard holds an image (pasted
        // as a temp PNG path); otherwise fall through to normal paste.
        if command == .pasteIntoTerminal {
            return pasteImageAsTempFileIfPossible()
        }

        performKeyboardCommand(command)
        return true
    }

    /// When the clipboard holds an image (and no plain text), write it to a
    /// temp PNG and type the quoted path into the focused terminal — handy
    /// for handing screenshots to CLI agents. Returns true when handled.
    private func pasteImageAsTempFileIfPossible() -> Bool {
        // Only intercept when keyboard focus is really on the terminal;
        // otherwise Cmd+V belongs to the editor/find bar/sidebar field.
        guard let terminal = tabs[safe: activeTabIndex]?.activePane?.terminalViewController,
              terminal.isTerminalFocused,
              !terminal.isCommandRunning else {
            return false
        }

        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return false
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        let url: URL
        do {
            url = try ImagePasteStore.store(png: png)
        } catch {
            print("📋 Failed to write pasted image: \(error)")
            return false
        }

        terminal.send(text: "'\(url.path)'")
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
        case .zoomIn:
            FontZoom.shared.zoomIn()
        case .zoomOut:
            FontZoom.shared.zoomOut()
        case .zoomReset:
            FontZoom.shared.reset()
        case .pasteIntoTerminal:
            break // handled in handleKeyDown
        case .focusAgentAttention:
            jumpToNextAttentionTab()
        }
    }

    /// Cmd+Shift+J: cycles through tabs whose agent wants attention, most
    /// urgent state first — needs-input tabs, then finished ones, then
    /// working ones. Repeated presses walk all tabs in that state.
    private func jumpToNextAttentionTab() {
        for state in [AgentState.ready, .done, .working] {
            let candidates = tabs.indices.filter { tabs[$0].agentState == state }
            guard !candidates.isEmpty else { continue }
            let next = candidates.first(where: { $0 > activeTabIndex }) ?? candidates[0]
            if next != activeTabIndex {
                switchToTab(index: next)
            }
            return
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
        sidebarWidthConstraint.constant = sidebarContainerView.visible ? sidebarPreferredWidth : 0
        sidebarResizeHandle.isHidden = !sidebarContainerView.visible
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func resizeSidebar(by delta: CGFloat) {
        guard sidebarContainerView.visible, let contentWidth = window?.contentView?.bounds.width else { return }

        let maximumWidth = max(180, min(600, contentWidth - 48 - 240))
        sidebarPreferredWidth = min(maximumWidth, max(180, sidebarPreferredWidth + delta))
        sidebarWidthConstraint.constant = sidebarPreferredWidth
        UserDefaults.standard.set(Double(sidebarPreferredWidth), forKey: Self.sidebarWidthDefaultsKey)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

}

private final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}

// MARK: - Automation

private extension MainWindowController {
    func automationPane(id: UUID) -> (tab: TabModel, pane: PaneModel, controller: PaneSplitController)? {
        for tab in tabs {
            guard let pane = tab.panes.first(where: { $0.id == id }),
                  let controller = tabSplitControllers[tab.id] else { continue }
            return (tab, pane, controller)
        }
        return nil
    }

    func automationPaneInfo(tab: TabModel, pane: PaneModel, controller: PaneSplitController) -> IPCPaneInfo {
        let type: String
        switch pane.paneType {
        case .terminal: type = "terminal"
        case .editor: type = "editor"
        case .diff: type = "diff"
        case .uncommittedChanges: type = "uncommitted_changes"
        case .browser: type = "browser"
        }
        let pid = pane.terminalViewController?.shellProcessID ?? 0
        return IPCPaneInfo(
            paneID: pane.id.uuidString.lowercased(),
            tabID: tab.id.uuidString.lowercased(),
            type: type,
            cwd: pane.resolvedWorkingDirectory(),
            focused: controller.activePaneID == pane.id && tab.id == tabs[safe: activeTabIndex]?.id,
            agentStatus: pane.agentState.rawValue,
            processID: pid > 0 ? Int32(pid) : nil
        )
    }

    func allAutomationPaneInfo() -> [IPCPaneInfo] {
        tabs.flatMap { tab -> [IPCPaneInfo] in
            guard let controller = tabSplitControllers[tab.id] else { return [] }
            return tab.panes.map { automationPaneInfo(tab: tab, pane: $0, controller: controller) }
        }
    }

    func waitForAutomationCondition(
        timeoutMS: Int,
        condition: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        if condition() {
            completion(true)
            return
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if condition() {
                timer?.invalidate()
                completion(true)
            } else if Date() >= deadline {
                timer?.invalidate()
                completion(false)
            }
        }
    }
}

// MARK: - IPCServerDelegate
extension MainWindowController: IPCServerDelegate {
    func ipcServer(
        _ server: IPCServer,
        didReceiveCommand command: IPCCommandType,
        completion: @escaping (IPCResponse) -> Void
    ) {
        switch command {
        case .ping:
            completion(IPCResponse(ok: true))

        case .newTab(let cwd):
            createNewTab(workingDirectory: cwd)
            completion(IPCResponse(ok: true))

        case .showDiff(let path, let old, let new):
            if old.isEmpty && new.isEmpty {
                // `sidekick-ctl open-diff <file>`: just view the file.
                openFileInEditor(URL(fileURLWithPath: path))
                completion(IPCResponse(ok: true))
            } else {
                // Hook approval: hold the response until the user decides.
                enqueueDiffApproval(path: path, old: old, new: new) { accepted in
                    completion(IPCResponse(ok: true, accepted: accepted))
                }
            }

        case .agentReady:
            setActiveTabAgentState(.ready)
            completion(IPCResponse(ok: true))

        case .agentBusy:
            setActiveTabAgentState(.working)
            completion(IPCResponse(ok: true))

        case .agentDone:
            setActiveTabAgentState(.done)
            completion(IPCResponse(ok: true))

        case .agentIdle:
            setActiveTabAgentState(.idle)
            completion(IPCResponse(ok: true))

        case .paneList:
            completion(IPCResponse(result: IPCResult(panes: allAutomationPaneInfo())))

        case .paneCurrent(let requestedPaneID):
            let context: (tab: TabModel, pane: PaneModel, controller: PaneSplitController)?
            if let requestedPaneID {
                context = automationPane(id: requestedPaneID)
            } else if let tab = tabs[safe: activeTabIndex],
                      let pane = tab.activePane,
                      let controller = tabSplitControllers[tab.id] {
                context = (tab, pane, controller)
            } else {
                context = nil
            }
            guard let context else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            completion(IPCResponse(result: IPCResult(
                pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
            )))

        case .paneSplit(let paneID, let direction, let cwd, let command, let focus):
            guard let context = automationPane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            guard let pane = context.controller.splitPane(
                direction: direction,
                targetPaneID: paneID,
                initialDirectory: cwd,
                command: command,
                focus: focus
            ) else {
                completion(IPCResponse(ok: false, error: "Unable to split pane (the tab may be at its pane limit)"))
                return
            }
            completion(IPCResponse(result: IPCResult(
                pane: automationPaneInfo(tab: context.tab, pane: pane, controller: context.controller)
            )))

        case .paneFocus(let paneID):
            guard let context = automationPane(id: paneID), context.controller.focusPane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            completion(IPCResponse(result: IPCResult(
                pane: automationPaneInfo(tab: context.tab, pane: context.pane, controller: context.controller)
            )))

        case .paneClose(let paneID):
            guard let context = automationPane(id: paneID), context.controller.closePane(id: paneID) else {
                completion(IPCResponse(ok: false, error: "Pane not found or cannot close the last pane"))
                return
            }
            completion(IPCResponse())

        case .paneSendText(let paneID, let text):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            terminal.send(text: text)
            completion(IPCResponse())

        case .paneSendKey(let paneID, let key):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            guard terminal.send(key: key) else {
                completion(IPCResponse(ok: false, error: "Unsupported key: \(key)"))
                return
            }
            completion(IPCResponse())

        case .paneRead(let paneID, let source, let lines):
            guard let terminal = automationPane(id: paneID)?.pane.terminalViewController else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            let text = source == "recent"
                ? terminal.recentOutputText(lineLimit: lines)
                : terminal.visibleScreenText(lineLimit: lines)
            completion(IPCResponse(result: IPCResult(text: text)))

        case .waitAgentStatus(let paneID, let status, let timeoutMS):
            guard automationPane(id: paneID) != nil else {
                completion(IPCResponse(ok: false, error: "Pane not found"))
                return
            }
            waitForAutomationCondition(timeoutMS: timeoutMS, condition: { [weak self] in
                self?.automationPane(id: paneID)?.pane.agentState == status
            }) { matched in
                completion(IPCResponse(result: IPCResult(matched: matched)))
            }

        case .waitOutput(let paneID, let match, let timeoutMS):
            guard automationPane(id: paneID)?.pane.terminalViewController != nil else {
                completion(IPCResponse(ok: false, error: "Terminal pane not found"))
                return
            }
            waitForAutomationCondition(timeoutMS: timeoutMS, condition: { [weak self] in
                guard let terminal = self?.automationPane(id: paneID)?.pane.terminalViewController else { return false }
                return terminal.recentOutputText().contains(match) || terminal.visibleScreenText().contains(match)
            }) { matched in
                completion(IPCResponse(result: IPCResult(matched: matched)))
            }
        }
    }

    private func setActiveTabAgentState(_ state: AgentState) {
        guard let tab = tabs[safe: activeTabIndex] else { return }
        applyAgentState(state, to: tab)
    }

    // MARK: - Hook diff approval

    private func enqueueDiffApproval(
        path: String,
        old: String,
        new: String,
        completion: @escaping (Bool) -> Void
    ) {
        diffApprovalQueue.append((path: path, old: old, new: new, completion: completion))
        presentNextDiffApprovalIfIdle()
    }

    private func presentNextDiffApprovalIfIdle() {
        guard activeDiffApproval == nil, !diffApprovalQueue.isEmpty else { return }

        // No window to attach a sheet to: reject rather than leave the hook
        // blocked and the queue wedged.
        guard let window = window, window.isVisible else {
            drainDiffApprovalQueue()
            return
        }

        let request = diffApprovalQueue.removeFirst()
        let panel = DiffApprovalPanel()
        activeDiffApproval = panel
        panel.show(relativeTo: window, path: request.path, old: request.old, new: request.new) { [weak self] accepted in
            request.completion(accepted)
            self?.activeDiffApproval = nil
            self?.presentNextDiffApprovalIfIdle()
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
