import Cocoa
import SwiftTerm
// UserNotifications isn't Sendable-audited for strict concurrency yet, so import
// it @preconcurrency to downgrade its cross-actor Sendable diagnostics (e.g.
// capturing UNUserNotificationCenter in the authorization completion handler).
@preconcurrency import UserNotifications
import SidekickTelemetryCore

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
    /// Owns the tab/pane tree, the per-tab split controllers, the tab lifecycle,
    /// and session save/restore. MWC reads it through the forwarders below and
    /// drives it for create/switch/close.
    private var tabController: TabController!
    private var tabs: [TabModel] { tabController.tabs }
    private var activeTabIndex: Int { tabController.activeTabIndex }
    private var currentPaneSplitController: PaneSplitController? { tabController.currentSplitController }
    private var quickOpenPanel: QuickOpenPanel?
    private var preferencesWindowController: PreferencesWindowController?
    fileprivate var commandPalette: CommandPalettePanel?
    // Set on the main actor; removed in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var keyEventMonitor: Any?
    nonisolated(unsafe) private var clickEventMonitor: Any?
    private let keyboardCommandRouter = KeyboardCommandRouter()
    private let configWatcher = ConfigWatcher()
    private var sessionSaveTimer: Timer?
    /// Owns IPC command translation and the hook diff-approval queue.
    private var automationCoordinator: AutomationCoordinator!
    /// Per-session "auto-approve agent edits" toggle (menu-driven). Layered on
    /// top of the `[approval]` config mode; resets on relaunch.
    private var sessionAutoApproveEdits = false

    convenience init() {
        Log.debug("🏗️ Creating MainWindowController...", category: "app")

        let config = Config.load()
        Theme.shared.loadFromConfig(config)
        Log.debug("✅ Config loaded", category: "app")

        let window = MainWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        Log.debug("✅ NSWindow created", category: "app")

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
        Log.debug("✅ Window configured", category: "app")

        self.init(window: window)
        self.config = config
        self.tabController = TabController(host: self)
        Log.debug("✅ WindowController initialized", category: "app")

        setupUI()
        Log.debug("✅ UI setup completed", category: "app")

        setupIPC()
        Log.debug("✅ IPC server started", category: "app")

        setupConfigWatcher()
        setupSessionPersistence()
        syncAgentAutoApprove()
    }

    /// Reflects the effective auto-approve preference into each installed agent's
    /// own permission system so agents launched in panes stop prompting. Per-agent
    /// and best-effort — only affects future launches, so failures are logged, not
    /// surfaced. Called at launch (which also reverts a stale value left by last
    /// session's menu toggle) and whenever the state changes.
    private func syncAgentAutoApprove() {
        let mode = effectiveApprovalMode
        do {
            try AgentIntegrationInstaller.syncClaudeAutoApprove(
                desiredMode: AgentIntegrationInstaller.claudeMode(forApprovalMode: mode)
            )
        } catch {
            Log.debug("Failed to sync Claude auto-approve setting: \(error)", category: "app")
        }
        do {
            try AgentIntegrationInstaller.syncCodexAutoApprove(forMode: mode)
        } catch {
            Log.debug("Failed to sync Codex auto-approve setting: \(error)", category: "app")
        }
    }

    /// Effective Sidekick approval level ("ask"/"auto"/"bypass"): the persistent
    /// `[approval]` mode, but the per-session ⇧⌘A toggle forces at least "auto"
    /// and never downgrades a configured "bypass".
    private var effectiveApprovalMode: String {
        let configMode = (config.approval?.mode ?? "ask").lowercased()
        if configMode == "bypass" { return "bypass" }
        if sessionAutoApproveEdits { return "auto" }
        return configMode == "auto" ? "auto" : "ask"
    }

    private func setupConfigWatcher() {
        configWatcher.onChange = { [weak self] in
            guard let self = self else { return }
            Log.debug("🔄 Config file changed on disk, reloading", category: "app")
            let newConfig = Config.load()
            Theme.shared.loadFromConfig(newConfig)
            self.applyRuntimeConfig(newConfig)
        }
        configWatcher.start()
    }

    private func setupSessionPersistence() {
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }

        if let window = window {
            // Become the window delegate so windowShouldClose can veto a close
            // that would kill running agents (see the NSWindowDelegate extension).
            window.delegate = self
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    /// Panes whose agent is actively running or waiting on the user — the
    /// states whose work is lost by quitting. Drives the close confirmation.
    private var busyAgentPaneCount: Int {
        tabs.reduce(0) { count, tab in
            count + tab.panes.filter { $0.agentState == .working || $0.agentState == .ready }.count
        }
    }

    /// Returns true when it is safe to close/quit: nothing is busy, or the user
    /// confirmed via the alert. Returns false to abort the close. Called from
    /// both windowShouldClose (close button) and applicationShouldTerminate (⌘Q).
    func confirmCloseWithBusyAgents() -> Bool {
        let busy = busyAgentPaneCount
        guard busy > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = busy == 1 ? "An agent is still working" : "\(busy) agents are still working"
        alert.informativeText = "Quitting Sidekick will end "
            + (busy == 1 ? "this session" : "these sessions")
            + " and any running commands. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func windowWillClose() {
        saveSession()

        // Don't strand hook processes blocked on approval: let the coordinator
        // cancel the visible sheet and resolve the queue.
        automationCoordinator?.prepareForWindowClose()
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
        tabController.restoreOrCreateInitialTab()
    }

    // MARK: - Session save/restore

    /// Forwards to the tab controller, which owns the tab/pane tree. Called from
    /// the autosave timer and windowWillClose.
    func saveSession() {
        tabController.saveSession()
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

        syncAgentAutoApprove()
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

        // A single window-wide click monitor, routed only to the active tab's
        // split controller. Previously every tab's controller installed its own
        // monitor, so a click was hit-tested against hidden tabs too and could
        // yank focus to whichever tab's panes happened to overlap the point.
        clickEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            self.currentPaneSplitController?.activatePane(containing: event)
            return event
        }
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let clickEventMonitor {
            NSEvent.removeMonitor(clickEventMonitor)
        }
    }

    private func setupCWDTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalCWDChanged(_:)),
            name: .terminalCWDChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneDirtyStateChanged(_:)),
            name: .paneDirtyStateChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneTitleChanged(_:)),
            name: .paneTitleChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneCommandStatusChanged(_:)),
            name: .paneCommandStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenURLRequested(_:)),
            name: .paneOpenURLRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneOpenFileRequested(_:)),
            name: .paneOpenFileRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneAgentStateChanged(_:)),
            name: .paneAgentStateChanged,
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
        NSWorkspace.shared.open(url)
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
    func refreshAgentsBadge() {
        let waiting = tabs.filter { $0.agentState == .ready }.count
        activityBarView.updateAgentsBadge(count: waiting)
    }

    /// Forwards to the tab controller. Public entry point used by the menu,
    /// command palette, keyboard router, and AppDelegate.
    func createNewTab(workingDirectory: String? = nil, command: [String]? = nil) {
        tabController.createNewTab(workingDirectory: workingDirectory, command: command)
    }

    private func updateTabBar() {
        tabBarView.updateTabs(tabs, activeIndex: activeTabIndex)
    }

    func syncSidebarToActiveTab() {
        // Keep the agents panel's highlighted row on the active tab's agent.
        sidebarContainerView.refreshAgents()

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

    private func switchToTab(index: Int) {
        tabController.switchToTab(index: index)
    }

    private func closeTab(index: Int) {
        tabController.closeTab(index: index)
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
        tabController.moveTab(from: fromIndex, to: toIndex)
    }

    func tabBar(_ tabBar: TabBarView, didRenameTab index: Int, to title: String?) {
        guard let tab = tabs[safe: index] else { return }
        tab.customTitle = title
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

    // MARK: Worktrees panel

    func sidebarContainerActiveRepoRoot(_ container: SidebarContainerView) -> String? {
        guard let cwd = tabController.currentWorkingDirectoryForNewTerminal() else { return nil }
        return GitService().repositoryRoot(from: cwd)
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestOpenWorktree path: String) {
        // Focus an existing pane in that checkout if there is one; else open a
        // fresh terminal there.
        if let index = tabs.firstIndex(where: { tab in
            tab.panes.contains { Self.path($0.resolvedWorkingDirectory(), isWithin: path) }
        }) {
            switchToTab(index: index)
        } else {
            createNewTab(workingDirectory: path)
        }
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestCreateWorktree branch: String, agent: WorktreeAgent) {
        guard let repoRoot = sidebarContainerActiveRepoRoot(container) else {
            presentWorktreeError("Worktrees need a pane inside a git repository.")
            return
        }
        // Creating the worktree shells out to git (checks out files); do it off
        // the main thread, then open the pane on the resulting directory.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().ensureWorktree(forBranch: branch, directory: repoRoot) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let path):
                    self.createNewTab(workingDirectory: path, command: agent.argv)
                    self.sidebarContainerView.refreshWorktrees()
                case .failure(let error):
                    self.presentWorktreeError(Self.worktreeErrorMessage(error))
                }
            }
        }
    }

    func sidebarContainer(_ container: SidebarContainerView, didRequestRemoveWorktree branch: String, force: Bool) {
        guard let repoRoot = sidebarContainerActiveRepoRoot(container) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WorktreeService().removeWorktree(forBranch: branch, directory: repoRoot, force: force) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    self.presentWorktreeError(Self.worktreeErrorMessage(error))
                }
                self.sidebarContainerView.refreshWorktrees()
            }
        }
    }

    /// True when `candidate` is the worktree `path` or lives inside it.
    private static func path(_ candidate: String?, isWithin path: String) -> Bool {
        guard let candidate else { return false }
        let base = URL(fileURLWithPath: path).standardizedFileURL.path
        let other = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return other == base || other.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func presentWorktreeError(_ message: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Worktree"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func worktreeErrorMessage(_ error: Error) -> String {
        switch error {
        case WorktreeService.WorktreeError.notAGitRepository:
            return "Not a git repository — worktree commands need a directory inside one."
        case WorktreeService.WorktreeError.noWorktreeForBranch(let branch):
            return "No worktree registered for branch '\(branch)'."
        case WorktreeService.WorktreeError.gitFailed(let message):
            return "git worktree failed: \(message)"
        default:
            return "Worktree operation failed: \(error.localizedDescription)"
        }
    }

    func sidebarContainer(_ container: SidebarContainerView, didOpenFile url: URL) {
        Log.debug("📂 Sidebar requested to open file: \(url.path)", category: "app")

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
        currentTab.addPane(editorPane)
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

        tabController.installTab(tab)
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

        Log.debug("📝 Opening config file with command: \(command)", category: "app")

        // Make sure window is focused
        window?.makeKeyAndOrderFront(nil)

        // Send command to terminal
        runCommandInActiveTerminal(command)
    }

    func closeCurrentTab() {
        tabController.closeCurrentTab()
    }

    func saveCurrentFile() {
        guard let activeTab = tabs[safe: activeTabIndex] else { return }

        let editorPane =
            activeTab.panes.first { $0.editorViewController?.isEditorFocused == true } ??
            activeTab.activePane.flatMap { $0.paneType == .editor ? $0 : nil } ??
            currentPaneSplitController?.activePane.flatMap { $0.paneType == .editor ? $0 : nil }

        guard let pane = editorPane,
              let editor = pane.editorViewController else {
            Log.debug("💾 No active editor pane to save", category: "app")
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
            Log.error("❌ No terminal pane found in active tab!", category: "app")
            return nil
        }

        terminalVC.send(text: command + "\n")
        return terminalPane
    }

    private func setupIPC() {
        automationCoordinator = AutomationCoordinator(host: self)
        IPCServer.shared.delegate = automationCoordinator
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
            Log.debug("📋 Failed to write pasted image: \(error)", category: "app")
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

    func showKeyboardShortcuts() {
        // Show keyboard shortcuts help
        // For now, this is a placeholder - could show a panel with shortcuts
        Log.debug("⌨️ Keyboard shortcuts requested", category: "app")
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

// MARK: - NSWindowDelegate
extension MainWindowController: NSWindowDelegate {
    /// Veto a close-button close while agents are working, so the window (and
    /// its PTYs) aren't torn down without a heads-up. ⌘Q is guarded separately
    /// in AppDelegate.applicationShouldTerminate.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseWithBusyAgents()
    }
}

// MARK: - TabHost
extension MainWindowController: TabHost {
    var tabContentView: NSView { mainContentView }
    var tabConfig: Config { config }

    func reloadTabBar() {
        updateTabBar()
    }

    func updateSidebarDirectory(_ path: String) {
        sidebarContainerView.updateFileTree(path: path)
    }
    // syncSidebarToActiveTab() and refreshAgentsBadge() are defined on the
    // class above and satisfy the rest of TabHost.
}

// MARK: - AutomationHost
extension MainWindowController: AutomationHost {
    var automationTabs: [TabModel] { tabs }
    var activeAutomationTabID: UUID? { tabs[safe: activeTabIndex]?.id }
    var automationWindow: NSWindow? { window }

    /// Effective auto-approve: the session toggle OR the config mode.
    var shouldAutoApproveEdits: Bool {
        sessionAutoApproveEdits || (config.approval?.autoApprove ?? false)
    }

    /// The active approval config (defaults when the section is absent), used
    /// for the auto_allow / always_ask glob rules.
    var approvalConfig: ApprovalConfig {
        config.approval ?? ApprovalConfig()
    }

    /// Effective telemetry rate card: `[telemetry]` overrides merged over the
    /// built-in defaults.
    var telemetryRates: [String: TelemetryRate] {
        config.telemetry?.resolvedRates() ?? TelemetryRates.defaults
    }

    /// Flips the per-session auto-approve toggle. Menu-driven. Writes Claude
    /// Code's permission mode so the change reaches agents launched afterward;
    /// the next relaunch re-syncs from the persistent `[approval]` mode.
    func toggleAutoApproveEdits() {
        sessionAutoApproveEdits.toggle()
        syncAgentAutoApprove()
    }

    func automationSplitController(forTab tabID: UUID) -> PaneSplitController? {
        tabController.splitController(forTab: tabID)
    }

    func automationCreateNewTab(workingDirectory: String?) {
        createNewTab(workingDirectory: workingDirectory)
    }

    func automationOpenFile(_ url: URL) {
        openFileInEditor(url)
    }

    func automationSetActiveTabAgentState(_ state: AgentState) {
        guard let tab = tabs[safe: activeTabIndex] else { return }
        applyAgentState(state, to: tab)
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
