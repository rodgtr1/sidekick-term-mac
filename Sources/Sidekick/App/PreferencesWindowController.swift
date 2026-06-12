import Cocoa

class PreferencesWindowController: NSWindowController {
    private var config: Config
    private weak var mainWindowController: MainWindowController?

    // UI Elements
    private var contentView: NSView!
    private var tabView: NSTabView!

    // General Tab
    private var opacitySlider: NSSlider!
    private var opacityLabel: NSTextField!
    private var blurCheckbox: NSButton!
    private var showTeleportCheckbox: NSButton!
    private var rawConfigButton: NSButton!

    // Terminal Tab
    private var fontFamilyPopup: NSPopUpButton!
    private var fontSizeSlider: NSSlider!
    private var fontSizeLabel: NSTextField!
    private var shellIntegrationStatusLabel: NSTextField!
    private var shellIntegrationButton: NSButton!

    // Appearance Tab
    private var themePopup: NSPopUpButton!

    // Editor Tab
    private var fileOpenModePopup: NSPopUpButton!
    private var wordWrapCheckbox: NSButton!
    private var showHiddenFilesCheckbox: NSButton!
    private var agentStatusLabels: [AgentIntegrationInstaller.AgentID: NSTextField] = [:]
    private var agentInstallButtons: [AgentIntegrationInstaller.AgentID: NSButton] = [:]

    init(config: Config, mainWindowController: MainWindowController? = nil) {
        self.config = config
        self.mainWindowController = mainWindowController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
        setupUI()
        loadCurrentSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let window = window else { return }

        window.title = "Preferences"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        window.center()
        window.isMovableByWindowBackground = true
        window.backgroundColor = AppTheme.windowBackground
    }

    private func setupUI() {
        guard let window = window else { return }

        contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        window.contentView = contentView

        setupTabView()
        setupGeneralTab()
        setupTerminalTab()
        setupEditorTab()
        setupAgentsTab()
        setupAppearanceTab()
        layoutViews()
    }

    private func setupTabView() {
        tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
    }

    private func setupGeneralTab() {
        let generalView = NSView()
        generalView.wantsLayer = true
        generalView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        // Window opacity
        let opacityTitleLabel = NSTextField(labelWithString: "Window Opacity:")
        opacityTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        opacityTitleLabel.textColor = AppTheme.primaryText
        opacityTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        opacitySlider = NSSlider()
        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.numberOfTickMarks = 8
        opacitySlider.allowsTickMarkValuesOnly = false
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false

        opacityLabel = NSTextField(labelWithString: "100%")
        opacityLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = AppTheme.secondaryText
        opacityLabel.alignment = .right
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false

        // Background blur checkbox
        blurCheckbox = NSButton(checkboxWithTitle: "Enable background blur", target: self, action: #selector(blurCheckboxChanged(_:)))
        blurCheckbox.font = NSFont.systemFont(ofSize: 13)
        blurCheckbox.translatesAutoresizingMaskIntoConstraints = false

        showTeleportCheckbox = NSButton(
            checkboxWithTitle: "Show Teleport hosts (tsh) in Hosts panel",
            target: self,
            action: #selector(showTeleportChanged(_:))
        )
        showTeleportCheckbox.font = NSFont.systemFont(ofSize: 13)
        showTeleportCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let rawConfigLabel = NSTextField(labelWithString: "Raw Config File:")
        rawConfigLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        rawConfigLabel.textColor = AppTheme.primaryText
        rawConfigLabel.translatesAutoresizingMaskIntoConstraints = false

        rawConfigButton = NSButton(title: "View/Edit Raw Config...", target: self, action: #selector(rawConfigButtonClicked(_:)))
        rawConfigButton.bezelStyle = .rounded
        rawConfigButton.translatesAutoresizingMaskIntoConstraints = false

        generalView.addSubview(opacityTitleLabel)
        generalView.addSubview(opacitySlider)
        generalView.addSubview(opacityLabel)
        generalView.addSubview(blurCheckbox)
        generalView.addSubview(showTeleportCheckbox)
        generalView.addSubview(rawConfigLabel)
        generalView.addSubview(rawConfigButton)

        NSLayoutConstraint.activate([
            opacityTitleLabel.topAnchor.constraint(equalTo: generalView.topAnchor, constant: 30),
            opacityTitleLabel.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20),

            opacitySlider.topAnchor.constraint(equalTo: opacityTitleLabel.bottomAnchor, constant: 10),
            opacitySlider.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20),
            opacitySlider.trailingAnchor.constraint(equalTo: opacityLabel.leadingAnchor, constant: -10),

            opacityLabel.topAnchor.constraint(equalTo: opacitySlider.topAnchor),
            opacityLabel.trailingAnchor.constraint(equalTo: generalView.trailingAnchor, constant: -20),
            opacityLabel.widthAnchor.constraint(equalToConstant: 50),

            blurCheckbox.topAnchor.constraint(equalTo: opacitySlider.bottomAnchor, constant: 20),
            blurCheckbox.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20),

            showTeleportCheckbox.topAnchor.constraint(equalTo: blurCheckbox.bottomAnchor, constant: 12),
            showTeleportCheckbox.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20),

            rawConfigLabel.topAnchor.constraint(equalTo: showTeleportCheckbox.bottomAnchor, constant: 30),
            rawConfigLabel.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20),

            rawConfigButton.topAnchor.constraint(equalTo: rawConfigLabel.bottomAnchor, constant: 10),
            rawConfigButton.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20)
        ])

        let generalTabItem = NSTabViewItem(identifier: "general")
        generalTabItem.label = "General"
        generalTabItem.view = generalView
        tabView.addTabViewItem(generalTabItem)
    }

    private func setupTerminalTab() {
        let terminalView = NSView()
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        // Font family
        let fontFamilyLabel = NSTextField(labelWithString: "Font Family:")
        fontFamilyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fontFamilyLabel.textColor = AppTheme.primaryText
        fontFamilyLabel.translatesAutoresizingMaskIntoConstraints = false

        fontFamilyPopup = NSPopUpButton()
        fontFamilyPopup.addItems(withTitles: [
            "JetBrains Mono",
            "SF Mono",
            "Monaco",
            "Menlo",
            "Consolas",
            "Fira Code",
            "Source Code Pro"
        ])
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontFamilyChanged(_:))
        fontFamilyPopup.translatesAutoresizingMaskIntoConstraints = false

        // Font size
        let fontSizeTitleLabel = NSTextField(labelWithString: "Font Size:")
        fontSizeTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fontSizeTitleLabel.textColor = AppTheme.primaryText
        fontSizeTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        fontSizeSlider = NSSlider()
        fontSizeSlider.minValue = 8
        fontSizeSlider.maxValue = 24
        fontSizeSlider.numberOfTickMarks = 17
        fontSizeSlider.allowsTickMarkValuesOnly = true
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeSliderChanged(_:))
        fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false

        fontSizeLabel = NSTextField(labelWithString: "13pt")
        fontSizeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fontSizeLabel.textColor = AppTheme.secondaryText
        fontSizeLabel.alignment = .right
        fontSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        // Shell integration
        let shellIntegrationTitleLabel = NSTextField(labelWithString: "Shell Integration:")
        shellIntegrationTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        shellIntegrationTitleLabel.textColor = AppTheme.primaryText
        shellIntegrationTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        shellIntegrationStatusLabel = NSTextField(labelWithString: "")
        shellIntegrationStatusLabel.font = NSFont.systemFont(ofSize: 12)
        shellIntegrationStatusLabel.textColor = AppTheme.secondaryText
        shellIntegrationStatusLabel.lineBreakMode = .byWordWrapping
        shellIntegrationStatusLabel.maximumNumberOfLines = 3
        shellIntegrationStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        shellIntegrationButton = NSButton(
            title: "Install for zsh…",
            target: self,
            action: #selector(installShellIntegrationClicked(_:))
        )
        shellIntegrationButton.bezelStyle = .rounded
        shellIntegrationButton.translatesAutoresizingMaskIntoConstraints = false

        terminalView.addSubview(fontFamilyLabel)
        terminalView.addSubview(fontFamilyPopup)
        terminalView.addSubview(fontSizeTitleLabel)
        terminalView.addSubview(fontSizeSlider)
        terminalView.addSubview(fontSizeLabel)
        terminalView.addSubview(shellIntegrationTitleLabel)
        terminalView.addSubview(shellIntegrationStatusLabel)
        terminalView.addSubview(shellIntegrationButton)

        NSLayoutConstraint.activate([
            shellIntegrationTitleLabel.topAnchor.constraint(equalTo: fontSizeSlider.bottomAnchor, constant: 30),
            shellIntegrationTitleLabel.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),

            shellIntegrationStatusLabel.topAnchor.constraint(equalTo: shellIntegrationTitleLabel.bottomAnchor, constant: 6),
            shellIntegrationStatusLabel.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),
            shellIntegrationStatusLabel.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -20),

            shellIntegrationButton.topAnchor.constraint(equalTo: shellIntegrationStatusLabel.bottomAnchor, constant: 10),
            shellIntegrationButton.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),
        ])

        NSLayoutConstraint.activate([
            fontFamilyLabel.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 30),
            fontFamilyLabel.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),

            fontFamilyPopup.topAnchor.constraint(equalTo: fontFamilyLabel.bottomAnchor, constant: 10),
            fontFamilyPopup.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),
            fontFamilyPopup.widthAnchor.constraint(equalToConstant: 200),

            fontSizeTitleLabel.topAnchor.constraint(equalTo: fontFamilyPopup.bottomAnchor, constant: 30),
            fontSizeTitleLabel.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),

            fontSizeSlider.topAnchor.constraint(equalTo: fontSizeTitleLabel.bottomAnchor, constant: 10),
            fontSizeSlider.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 20),
            fontSizeSlider.trailingAnchor.constraint(equalTo: fontSizeLabel.leadingAnchor, constant: -10),

            fontSizeLabel.topAnchor.constraint(equalTo: fontSizeSlider.topAnchor),
            fontSizeLabel.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -20),
            fontSizeLabel.widthAnchor.constraint(equalToConstant: 50)
        ])

        let terminalTabItem = NSTabViewItem(identifier: "terminal")
        terminalTabItem.label = "Terminal"
        terminalTabItem.view = terminalView
        tabView.addTabViewItem(terminalTabItem)
    }

    private func setupAgentsTab() {
        let agentsView = NSView()
        agentsView.wantsLayer = true
        agentsView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        let blurbLabel = NSTextField(
            labelWithString: "Wire up agent CLIs to report Working / Needs input / Done to the agents panel. Detected from each tool's config directory; safe to re-run."
        )
        blurbLabel.font = NSFont.systemFont(ofSize: 12)
        blurbLabel.textColor = AppTheme.secondaryText
        blurbLabel.lineBreakMode = .byWordWrapping
        blurbLabel.maximumNumberOfLines = 3
        blurbLabel.translatesAutoresizingMaskIntoConstraints = false
        agentsView.addSubview(blurbLabel)

        NSLayoutConstraint.activate([
            blurbLabel.topAnchor.constraint(equalTo: agentsView.topAnchor, constant: 20),
            blurbLabel.leadingAnchor.constraint(equalTo: agentsView.leadingAnchor, constant: 20),
            blurbLabel.trailingAnchor.constraint(equalTo: agentsView.trailingAnchor, constant: -20)
        ])

        var previousAnchor = blurbLabel.bottomAnchor
        for (index, agent) in AgentIntegrationInstaller.AgentID.allCases.enumerated() {
            let nameLabel = NSTextField(labelWithString: agent.displayName)
            nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            nameLabel.textColor = AppTheme.primaryText
            nameLabel.translatesAutoresizingMaskIntoConstraints = false

            let statusLabel = NSTextField(labelWithString: "")
            statusLabel.font = NSFont.systemFont(ofSize: 12)
            statusLabel.textColor = AppTheme.secondaryText
            statusLabel.lineBreakMode = .byWordWrapping
            statusLabel.maximumNumberOfLines = 2
            statusLabel.translatesAutoresizingMaskIntoConstraints = false

            let installButton = NSButton(
                title: "Install",
                target: self,
                action: #selector(installAgentIntegrationClicked(_:))
            )
            installButton.bezelStyle = .rounded
            installButton.tag = index
            installButton.translatesAutoresizingMaskIntoConstraints = false

            agentsView.addSubview(nameLabel)
            agentsView.addSubview(statusLabel)
            agentsView.addSubview(installButton)

            NSLayoutConstraint.activate([
                nameLabel.topAnchor.constraint(equalTo: previousAnchor, constant: 22),
                nameLabel.leadingAnchor.constraint(equalTo: agentsView.leadingAnchor, constant: 20),

                installButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
                installButton.trailingAnchor.constraint(equalTo: agentsView.trailingAnchor, constant: -20),
                installButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

                statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
                statusLabel.leadingAnchor.constraint(equalTo: agentsView.leadingAnchor, constant: 20),
                statusLabel.trailingAnchor.constraint(equalTo: agentsView.trailingAnchor, constant: -20)
            ])

            agentStatusLabels[agent] = statusLabel
            agentInstallButtons[agent] = installButton
            previousAnchor = statusLabel.bottomAnchor
        }

        updateAgentIntegrationStatuses()

        let agentsTabItem = NSTabViewItem(identifier: "agents")
        agentsTabItem.label = "Agents"
        agentsTabItem.view = agentsView
        tabView.addTabViewItem(agentsTabItem)
    }

    private func setupAppearanceTab() {
        let appearanceView = NSView()
        appearanceView.wantsLayer = true
        appearanceView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        // Theme selection
        let themeLabel = NSTextField(labelWithString: "Color Theme:")
        themeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        themeLabel.textColor = AppTheme.primaryText
        themeLabel.translatesAutoresizingMaskIntoConstraints = false

        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ["Catppuccin Mocha"])
        themePopup.selectItem(at: 0)
        themePopup.isEnabled = false // Only one theme for now
        themePopup.translatesAutoresizingMaskIntoConstraints = false

        appearanceView.addSubview(themeLabel)
        appearanceView.addSubview(themePopup)

        NSLayoutConstraint.activate([
            themeLabel.topAnchor.constraint(equalTo: appearanceView.topAnchor, constant: 30),
            themeLabel.leadingAnchor.constraint(equalTo: appearanceView.leadingAnchor, constant: 20),

            themePopup.topAnchor.constraint(equalTo: themeLabel.bottomAnchor, constant: 10),
            themePopup.leadingAnchor.constraint(equalTo: appearanceView.leadingAnchor, constant: 20),
            themePopup.widthAnchor.constraint(equalToConstant: 200)
        ])

        let appearanceTabItem = NSTabViewItem(identifier: "appearance")
        appearanceTabItem.label = "Appearance"
        appearanceTabItem.view = appearanceView
        tabView.addTabViewItem(appearanceTabItem)
    }

    private func setupEditorTab() {
        let editorView = NSView()
        editorView.wantsLayer = true
        editorView.layer?.backgroundColor = AppTheme.windowBackground.cgColor

        let fileOpenModeLabel = NSTextField(labelWithString: "File Tree Opens:")
        fileOpenModeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        fileOpenModeLabel.textColor = AppTheme.primaryText
        fileOpenModeLabel.translatesAutoresizingMaskIntoConstraints = false

        fileOpenModePopup = NSPopUpButton()
        fileOpenModePopup.addItems(withTitles: ["Terminal Editor", "Built-in Editor"])
        fileOpenModePopup.target = self
        fileOpenModePopup.action = #selector(fileOpenModeChanged(_:))
        fileOpenModePopup.translatesAutoresizingMaskIntoConstraints = false

        wordWrapCheckbox = NSButton(checkboxWithTitle: "Wrap long lines", target: self, action: #selector(wordWrapChanged(_:)))
        wordWrapCheckbox.font = NSFont.systemFont(ofSize: 13)
        wordWrapCheckbox.translatesAutoresizingMaskIntoConstraints = false

        showHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: "Show hidden files in file tree (dimmed)",
            target: self,
            action: #selector(showHiddenFilesChanged(_:))
        )
        showHiddenFilesCheckbox.font = NSFont.systemFont(ofSize: 13)
        showHiddenFilesCheckbox.translatesAutoresizingMaskIntoConstraints = false

        editorView.addSubview(fileOpenModeLabel)
        editorView.addSubview(fileOpenModePopup)
        editorView.addSubview(wordWrapCheckbox)
        editorView.addSubview(showHiddenFilesCheckbox)

        NSLayoutConstraint.activate([
            fileOpenModeLabel.topAnchor.constraint(equalTo: editorView.topAnchor, constant: 30),
            fileOpenModeLabel.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 20),

            fileOpenModePopup.topAnchor.constraint(equalTo: fileOpenModeLabel.bottomAnchor, constant: 10),
            fileOpenModePopup.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 20),
            fileOpenModePopup.widthAnchor.constraint(equalToConstant: 200),

            wordWrapCheckbox.topAnchor.constraint(equalTo: fileOpenModePopup.bottomAnchor, constant: 24),
            wordWrapCheckbox.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 20),

            showHiddenFilesCheckbox.topAnchor.constraint(equalTo: wordWrapCheckbox.bottomAnchor, constant: 12),
            showHiddenFilesCheckbox.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 20)
        ])

        let editorTabItem = NSTabViewItem(identifier: "editor")
        editorTabItem.label = "Editor"
        editorTabItem.view = editorView
        tabView.addTabViewItem(editorTabItem)
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func loadCurrentSettings() {
        // Load opacity
        opacitySlider.doubleValue = config.window.opacity
        updateOpacityLabel()

        // Load blur setting
        blurCheckbox.state = config.window.enableBlur ? .on : .off

        // Load Teleport hosts setting
        showTeleportCheckbox.state = (config.hosts?.showTeleport ?? false) ? .on : .off

        // Load font family
        let currentFont = config.font.family
        for i in 0..<fontFamilyPopup.numberOfItems {
            if fontFamilyPopup.item(at: i)?.title == currentFont {
                fontFamilyPopup.selectItem(at: i)
                break
            }
        }

        // Load font size
        fontSizeSlider.doubleValue = Double(config.font.size)
        updateFontSizeLabel()

        let editorConfig = config.editor ?? EditorConfig()
        fileOpenModePopup.selectItem(at: editorConfig.fileOpenMode == "builtin" ? 1 : 0)
        wordWrapCheckbox.state = editorConfig.wordWrap ? .on : .off
        showHiddenFilesCheckbox.state = editorConfig.showHiddenFiles ? .on : .off

        updateShellIntegrationStatus()
    }

    private func updateShellIntegrationStatus() {
        if ShellIntegration.isInstalledInZshrc() {
            shellIntegrationStatusLabel.stringValue =
                "Installed in ~/.zshrc — prompt marks, exit-code indicators, and instant cwd tracking are active in new shells."
            shellIntegrationButton.isEnabled = false
            shellIntegrationButton.title = "Installed ✓"
        } else {
            shellIntegrationStatusLabel.stringValue =
                "Adds prompt navigation (⌘↑/⌘↓), failed-command indicators, and instant cwd tracking. Installs one line into ~/.zshrc."
            shellIntegrationButton.isEnabled = true
            shellIntegrationButton.title = "Install for zsh…"
        }
    }

    // MARK: - Actions

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        config.window.opacity = sender.doubleValue
        updateOpacityLabel()
        applyOpacityChange()
        config.save()
    }

    @objc private func blurCheckboxChanged(_ sender: NSButton) {
        config.window.enableBlur = sender.state == .on
        config.save()
        showRestartAlert()
    }

    @objc private func showTeleportChanged(_ sender: NSButton) {
        if config.hosts == nil {
            config.hosts = HostsConfig()
        }
        config.hosts?.showTeleport = sender.state == .on
        mainWindowController?.applyRuntimeConfig(config)
        config.save()
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        if let selectedTitle = sender.selectedItem?.title {
            config.font.family = selectedTitle
            applyFontChanges()
            config.save()
        }
    }

    @objc private func fontSizeSliderChanged(_ sender: NSSlider) {
        config.font.size = Int(sender.doubleValue)
        updateFontSizeLabel()
        applyFontChanges()
        config.save()
    }

    @objc private func fileOpenModeChanged(_ sender: NSPopUpButton) {
        ensureEditorConfig()
        config.editor?.fileOpenMode = sender.indexOfSelectedItem == 1 ? "builtin" : "terminal"
        mainWindowController?.applyRuntimeConfig(config)
        config.save()
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        ensureEditorConfig()
        config.editor?.wordWrap = sender.state == .on
        mainWindowController?.applyRuntimeConfig(config)
        config.save()
    }

    @objc private func showHiddenFilesChanged(_ sender: NSButton) {
        ensureEditorConfig()
        config.editor?.showHiddenFiles = sender.state == .on
        mainWindowController?.applyRuntimeConfig(config)
        config.save()
    }

    @objc private func installShellIntegrationClicked(_ sender: NSButton) {
        ShellIntegration.installScripts()

        let alert = NSAlert()
        do {
            let added = try ShellIntegration.installInZshrc()
            alert.messageText = added ? "Shell Integration Installed" : "Already Installed"
            alert.informativeText = added
                ? "Added one line to ~/.zshrc. Open a new tab (or run `source ~/.zshrc`) to activate it. For bash, source ~/.config/sidekick/shell-integration/sidekick.bash from your ~/.bashrc."
                : "~/.zshrc already sources the Sidekick shell integration."
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Installation Failed"
            alert.informativeText = "Could not modify ~/.zshrc: \(error.localizedDescription)"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateShellIntegrationStatus()
    }

    private func updateAgentIntegrationStatuses() {
        for agent in AgentIntegrationInstaller.AgentID.allCases {
            let status = AgentIntegrationInstaller.status(of: agent)
            agentStatusLabels[agent]?.stringValue = status.description

            let button = agentInstallButtons[agent]
            switch status {
            case .installed:
                button?.title = "Installed ✓"
                button?.isEnabled = false
            case .available:
                button?.title = "Install"
                button?.isEnabled = true
            case .notDetected, .helperMissing:
                button?.title = "Install"
                button?.isEnabled = false
            }
        }
    }

    @objc private func installAgentIntegrationClicked(_ sender: NSButton) {
        let agents = AgentIntegrationInstaller.AgentID.allCases
        guard sender.tag >= 0 && sender.tag < agents.count else { return }
        let agent = agents[sender.tag]

        let alert = NSAlert()
        do {
            try AgentIntegrationInstaller.install(agent)
            alert.messageText = "\(agent.displayName) Integration Installed"
            alert.informativeText = "Restart any running \(agent.displayName) sessions to pick up the change."
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Installation Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateAgentIntegrationStatuses()
    }

    @objc private func rawConfigButtonClicked(_ sender: NSButton) {
        config.save()
        mainWindowController?.openConfigFile()
    }

    private func ensureEditorConfig() {
        if config.editor == nil {
            config.editor = EditorConfig()
        }
    }

    private func updateOpacityLabel() {
        let percentage = Int(opacitySlider.doubleValue * 100)
        opacityLabel.stringValue = "\(percentage)%"
    }

    private func updateFontSizeLabel() {
        let size = Int(fontSizeSlider.doubleValue)
        fontSizeLabel.stringValue = "\(size)pt"
    }

    private func applyOpacityChange() {
        mainWindowController?.applyRuntimeConfig(config)
    }

    private func applyFontChanges() {
        // This would need to be implemented to update existing terminals
        // For now, changes will apply to new terminals
        print("Font changed to \(config.font.family) \(config.font.size)pt")
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Please restart Sidekick for the blur setting to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }
}

// MARK: - NSWindowDelegate
extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Save configuration when window closes
        config.save()
    }
}
