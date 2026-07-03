import Cocoa

class PreferencesWindowController: NSWindowController {
    private var config: Config
    private weak var mainWindowController: MainWindowController?

    // UI Elements
    private var contentView: NSView!
    private var tabView: NSTabView!
    private var themeObserver: ThemeObserver?

    // General Tab
    private var opacitySlider: NSSlider!
    private var opacityLabel: NSTextField!
    private var blurCheckbox: NSButton!
    private var restoreSessionCheckbox: NSButton!
    private var rawConfigButton: NSButton!

    // Terminal Tab
    private var fontFamilyPopup: NSPopUpButton!
    private var fontSizeSlider: NSSlider!
    private var fontSizeLabel: NSTextField!
    private var boldIsBrightCheckbox: NSButton!
    private var paddingSlider: NSSlider!
    private var paddingLabel: NSTextField!
    private var shellIntegrationStatusLabel: NSTextField!
    private var shellIntegrationButton: NSButton!

    // Appearance Tab
    private var themePopup: NSPopUpButton!

    // Editor Tab
    private var fileOpenModePopup: NSPopUpButton!
    private var editorFontFamilyPopup: NSPopUpButton!
    private var editorFontSizeSlider: NSSlider!
    private var editorFontSizeLabel: NSTextField!
    private var wordWrapCheckbox: NSButton!
    private var showHiddenFilesCheckbox: NSButton!
    private var agentStatusLabels: [AgentIntegrationInstaller.AgentID: NSTextField] = [:]
    private var agentInstallButtons: [AgentIntegrationInstaller.AgentID: NSButton] = [:]

    // Approvals Tab
    private var approvalModePopup: NSPopUpButton!
    private var autoAllowField: NSTextField!
    private var alwaysAskField: NSTextField!
    private var worktreeAutoApproveCheckbox: NSButton!

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

        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
    }

    /// Re-theme the Preferences window itself when the theme changes (e.g. the
    /// user picks a theme from the Appearance tab while this window is open).
    private func applyThemeColors() {
        window?.backgroundColor = AppTheme.windowBackground
        contentView?.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        for item in tabView.tabViewItems {
            item.view?.wantsLayer = true
            item.view?.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        }
        // Default every label to primary, then restore the secondary value labels.
        recolorLabels(in: contentView, color: AppTheme.primaryText)
        [opacityLabel, fontSizeLabel, editorFontSizeLabel, shellIntegrationStatusLabel].forEach {
            $0?.textColor = AppTheme.secondaryText
        }
        agentStatusLabels.values.forEach { $0.textColor = AppTheme.secondaryText }
    }

    private func recolorLabels(in view: NSView?, color: NSColor) {
        guard let view else { return }
        for sub in view.subviews {
            if let label = sub as? NSTextField, !label.isEditable, !label.drawsBackground {
                label.textColor = color
            }
            recolorLabels(in: sub, color: color)
        }
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
        setupApprovalsTab()
        setupAppearanceTab()
        layoutViews()
    }

    private func setupTabView() {
        tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
    }

    /// A themed, layer-backed container for one preference pane.
    private func makePaneView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.windowBackground.cgColor
        return view
    }

    /// Wrap a built pane view in a tab and append it. Call order here (in
    /// setupUI) is the visible tab order.
    private func addTab(_ view: NSView, identifier: String, label: String) {
        let item = NSTabViewItem(identifier: identifier)
        item.label = label
        item.view = view
        tabView.addTabViewItem(item)
    }

    /// The right-aligned monospaced value label paired with a slider.
    private static func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.alignment = .right
        return label
    }

    /// A secondary wrapping help/status label. `preferredWidth` opts into the
    /// low horizontal compression resistance the wide help blurbs need.
    private static func wrappingLabel(_ text: String, fontSize: CGFloat, maxLines: Int, preferredWidth: CGFloat? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.textColor = AppTheme.secondaryText
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = maxLines
        if let preferredWidth {
            label.preferredMaxLayoutWidth = preferredWidth
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return label
    }

    private func setupGeneralTab() {
        let generalView = makePaneView()
        let form = PreferencesFormBuilder(container: generalView)

        opacitySlider = NSSlider()
        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.numberOfTickMarks = 8
        opacitySlider.allowsTickMarkValuesOnly = false
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))

        opacityLabel = Self.valueLabel("100%")

        blurCheckbox = NSButton(checkboxWithTitle: "Enable background blur", target: self, action: #selector(blurCheckboxChanged(_:)))
        blurCheckbox.font = NSFont.systemFont(ofSize: 13)

        restoreSessionCheckbox = NSButton(
            checkboxWithTitle: "Reopen previous tabs on launch (off starts with one tab at ~/)",
            target: self,
            action: #selector(restoreSessionChanged(_:))
        )
        restoreSessionCheckbox.font = NSFont.systemFont(ofSize: 13)

        rawConfigButton = NSButton(title: "View/Edit Raw Config...", target: self, action: #selector(rawConfigButtonClicked(_:)))
        rawConfigButton.bezelStyle = .rounded

        form.fieldLabel("Window Opacity:", gapAbove: 30)
        form.sliderRow(opacitySlider, valueLabel: opacityLabel, gapAbove: 10)
        form.checkbox(blurCheckbox, gapAbove: 20)
        form.checkbox(restoreSessionCheckbox, gapAbove: 12)
        form.fieldLabel("Raw Config File:", gapAbove: 30)
        form.leadingControl(rawConfigButton, gapAbove: 10)

        addTab(generalView, identifier: "general", label: "General")
    }

    private func setupTerminalTab() {
        let terminalView = makePaneView()
        let form = PreferencesFormBuilder(container: terminalView)

        fontFamilyPopup = NSPopUpButton()
        fontFamilyPopup.addItems(withTitles: terminalFontFamilies())
        fontFamilyPopup.target = self
        fontFamilyPopup.action = #selector(fontFamilyChanged(_:))

        fontSizeSlider = NSSlider()
        fontSizeSlider.minValue = 8
        fontSizeSlider.maxValue = 24
        fontSizeSlider.numberOfTickMarks = 17
        fontSizeSlider.allowsTickMarkValuesOnly = true
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(fontSizeSliderChanged(_:))

        fontSizeLabel = Self.valueLabel("13pt")

        boldIsBrightCheckbox = NSButton(
            checkboxWithTitle: "Use bright colors for bold text",
            target: self,
            action: #selector(boldIsBrightChanged(_:))
        )
        boldIsBrightCheckbox.font = NSFont.systemFont(ofSize: 13)

        paddingSlider = NSSlider()
        paddingSlider.minValue = 0
        paddingSlider.maxValue = 24
        paddingSlider.numberOfTickMarks = 13
        paddingSlider.allowsTickMarkValuesOnly = true
        paddingSlider.target = self
        paddingSlider.action = #selector(paddingSliderChanged(_:))

        paddingLabel = Self.valueLabel("8px")

        shellIntegrationStatusLabel = Self.wrappingLabel("", fontSize: 12, maxLines: 3)

        shellIntegrationButton = NSButton(
            title: "Install for zsh…",
            target: self,
            action: #selector(installShellIntegrationClicked(_:))
        )
        shellIntegrationButton.bezelStyle = .rounded

        form.fieldLabel("Font Family:", gapAbove: 30)
        form.leadingControl(fontFamilyPopup, gapAbove: 10, width: 200)
        form.fieldLabel("Font Size:", gapAbove: 30)
        form.sliderRow(fontSizeSlider, valueLabel: fontSizeLabel, gapAbove: 10)
        form.checkbox(boldIsBrightCheckbox, gapAbove: 24)
        form.fieldLabel("Content Padding:", gapAbove: 24)
        form.sliderRow(paddingSlider, valueLabel: paddingLabel, gapAbove: 10)
        form.fieldLabel("Shell Integration:", gapAbove: 30)
        form.fullWidth(shellIntegrationStatusLabel, gapAbove: 6)
        form.leadingControl(shellIntegrationButton, gapAbove: 10)

        addTab(terminalView, identifier: "terminal", label: "Terminal")
    }

    private func setupAgentsTab() {
        let agentsView = makePaneView()
        let form = PreferencesFormBuilder(container: agentsView)

        let blurbLabel = Self.wrappingLabel(
            "Wire up agent CLIs to report Working / Needs input / Done to the agents panel. Detected from each tool's config directory; safe to re-run.",
            fontSize: 12,
            maxLines: 3
        )
        form.fullWidth(blurbLabel, gapAbove: 20)

        for (index, agent) in AgentIntegrationInstaller.AgentID.allCases.enumerated() {
            let statusLabel = Self.wrappingLabel("", fontSize: 12, maxLines: 2)

            let installButton = NSButton(
                title: "Install",
                target: self,
                action: #selector(installAgentIntegrationClicked(_:))
            )
            installButton.bezelStyle = .rounded
            installButton.tag = index

            form.agentRow(name: agent.displayName, statusLabel: statusLabel, button: installButton, gapAbove: 22)

            agentStatusLabels[agent] = statusLabel
            agentInstallButtons[agent] = installButton
        }

        updateAgentIntegrationStatuses()

        addTab(agentsView, identifier: "agents", label: "Agents")
    }

    private func setupApprovalsTab() {
        let approvalsView = makePaneView()
        let form = PreferencesFormBuilder(container: approvalsView)

        approvalModePopup = NSPopUpButton()
        approvalModePopup.addItems(withTitles: [
            "Ask before every edit",
            "Auto-approve edits",
            "Auto-approve everything (no prompts)"
        ])
        approvalModePopup.target = self
        approvalModePopup.action = #selector(approvalModeChanged(_:))

        let modeHelp = Self.wrappingLabel(
            "Edits are applied without prompting; risky commands still ask. \"Everything\" skips all prompts. Applies to new agents — toggle per session with ⇧⌘A.",
            fontSize: 11,
            maxLines: 6,
            preferredWidth: 420
        )

        autoAllowField = NSTextField()
        autoAllowField.placeholderString = "Sources/**, docs/**"
        autoAllowField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        autoAllowField.target = self
        autoAllowField.action = #selector(autoAllowChanged(_:))

        let autoAllowHelp = Self.wrappingLabel(
            "Approved silently in ask mode. Ignored when auto-approving everything.",
            fontSize: 11,
            maxLines: 2,
            preferredWidth: 420
        )

        alwaysAskField = NSTextField()
        alwaysAskField.placeholderString = ".env, **/secrets/**, *.pem"
        alwaysAskField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        alwaysAskField.target = self
        alwaysAskField.action = #selector(alwaysAskChanged(_:))

        let alwaysAskHelp = Self.wrappingLabel(
            "Always prompts, even when auto-approving. Highest precedence — use for secrets.",
            fontSize: 11,
            maxLines: 2,
            preferredWidth: 420
        )

        worktreeAutoApproveCheckbox = NSButton(
            checkboxWithTitle: "Auto-approve edits inside registered worktrees",
            target: self,
            action: #selector(worktreeAutoApproveChanged(_:))
        )
        worktreeAutoApproveCheckbox.font = NSFont.systemFont(ofSize: 13)

        let worktreeAutoApproveHelp = Self.wrappingLabel(
            "When a pane sits in a git worktree, edits inside that worktree apply without prompting. Paths outside it — the main checkout, other worktrees — still ask, and Always Ask rules still win.",
            fontSize: 11,
            maxLines: 4,
            preferredWidth: 420
        )

        form.fieldLabel("Agent Edits:", gapAbove: 30)
        form.leadingControl(approvalModePopup, gapAbove: 10, width: 220)
        form.fullWidth(modeHelp, gapAbove: 6)
        form.fieldLabel("Always Allow (comma-separated globs):", gapAbove: 22)
        form.fullWidth(autoAllowField, gapAbove: 8)
        form.fullWidth(autoAllowHelp, gapAbove: 6)
        form.fieldLabel("Always Ask (comma-separated globs):", gapAbove: 22)
        form.fullWidth(alwaysAskField, gapAbove: 8)
        form.fullWidth(alwaysAskHelp, gapAbove: 6)
        form.checkbox(worktreeAutoApproveCheckbox, gapAbove: 22)
        form.fullWidth(worktreeAutoApproveHelp, gapAbove: 6)

        addTab(approvalsView, identifier: "approvals", label: "Approvals")
    }

    // Theme picker model: every available theme, then an "Auto" entry that
    // follows the macOS light/dark setting. Index aligns with themeMenuTitles.
    private var themeSelectionNames: [String] {
        Theme.shared.available.map { $0.name } + [Theme.autoSelection]
    }

    private var themeMenuTitles: [String] {
        Theme.shared.available.map { def in
            def.displayName + (def.appearance == .light ? " (Light)" : " (Dark)")
        } + ["Auto (Follow System)"]
    }

    private func setupAppearanceTab() {
        let appearanceView = makePaneView()
        let form = PreferencesFormBuilder(container: appearanceView)

        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: themeMenuTitles)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))

        form.fieldLabel("Color Theme:", gapAbove: 30)
        form.leadingControl(themePopup, gapAbove: 10, width: 200)

        addTab(appearanceView, identifier: "appearance", label: "Appearance")
    }

    private func setupEditorTab() {
        let editorView = makePaneView()
        let form = PreferencesFormBuilder(container: editorView)

        fileOpenModePopup = NSPopUpButton()
        fileOpenModePopup.addItems(withTitles: ["Terminal Editor", "Built-in Editor"])
        fileOpenModePopup.target = self
        fileOpenModePopup.action = #selector(fileOpenModeChanged(_:))

        editorFontFamilyPopup = NSPopUpButton()
        editorFontFamilyPopup.addItem(withTitle: Self.systemDefaultFontTitle)
        editorFontFamilyPopup.addItems(withTitles: terminalFontFamilies())
        editorFontFamilyPopup.target = self
        editorFontFamilyPopup.action = #selector(editorFontFamilyChanged(_:))

        editorFontSizeSlider = NSSlider()
        editorFontSizeSlider.minValue = 8
        editorFontSizeSlider.maxValue = 32
        editorFontSizeSlider.numberOfTickMarks = 25
        editorFontSizeSlider.allowsTickMarkValuesOnly = true
        editorFontSizeSlider.target = self
        editorFontSizeSlider.action = #selector(editorFontSizeChanged(_:))

        editorFontSizeLabel = Self.valueLabel("13pt")

        wordWrapCheckbox = NSButton(checkboxWithTitle: "Wrap long lines", target: self, action: #selector(wordWrapChanged(_:)))
        wordWrapCheckbox.font = NSFont.systemFont(ofSize: 13)

        showHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: "Show hidden files in file tree (dimmed)",
            target: self,
            action: #selector(showHiddenFilesChanged(_:))
        )
        showHiddenFilesCheckbox.font = NSFont.systemFont(ofSize: 13)

        form.fieldLabel("File Tree Opens:", gapAbove: 30)
        form.leadingControl(fileOpenModePopup, gapAbove: 10, width: 200)
        form.fieldLabel("Font Family:", gapAbove: 24)
        form.leadingControl(editorFontFamilyPopup, gapAbove: 10, width: 200)
        form.fieldLabel("Text Size:", gapAbove: 24)
        form.sliderRow(editorFontSizeSlider, valueLabel: editorFontSizeLabel, gapAbove: 10)
        form.checkbox(wordWrapCheckbox, gapAbove: 24)
        form.checkbox(showHiddenFilesCheckbox, gapAbove: 12)

        addTab(editorView, identifier: "editor", label: "Editor")
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

        // Load session-restore setting
        restoreSessionCheckbox.state = config.behavior.restoreSession ? .on : .off

        // Load font family. If the configured font isn't in the list, add it
        // so the popup always reflects what's actually in use.
        let currentFont = config.font.family
        if fontFamilyPopup.item(withTitle: currentFont) == nil {
            fontFamilyPopup.addItem(withTitle: currentFont)
        }
        fontFamilyPopup.selectItem(withTitle: currentFont)

        // Load font size
        fontSizeSlider.doubleValue = Double(config.font.size)
        updateFontSizeLabel()

        // Load bold-is-bright and padding
        boldIsBrightCheckbox.state = config.font.boldIsBright ? .on : .off
        paddingSlider.doubleValue = Double(config.window.padding)
        updatePaddingLabel()

        let editorConfig = config.editor ?? EditorConfig()
        fileOpenModePopup.selectItem(at: editorConfig.fileOpenMode == "builtin" ? 1 : 0)

        // Editor font family. Empty means system default; an unknown family is
        // added so the popup reflects what's actually configured.
        let editorFamily = editorConfig.fontFamily.trimmingCharacters(in: .whitespaces)
        if editorFamily.isEmpty {
            editorFontFamilyPopup.selectItem(withTitle: Self.systemDefaultFontTitle)
        } else {
            if editorFontFamilyPopup.item(withTitle: editorFamily) == nil {
                editorFontFamilyPopup.addItem(withTitle: editorFamily)
            }
            editorFontFamilyPopup.selectItem(withTitle: editorFamily)
        }

        editorFontSizeSlider.doubleValue = Double(editorConfig.fontSize)
        updateEditorFontSizeLabel()
        wordWrapCheckbox.state = editorConfig.wordWrap ? .on : .off
        showHiddenFilesCheckbox.state = editorConfig.showHiddenFiles ? .on : .off

        // Select the active theme (or "Auto") in the Appearance popup
        if let themeIndex = themeSelectionNames.firstIndex(of: config.theme.name) {
            themePopup.selectItem(at: themeIndex)
        } else {
            themePopup.selectItem(at: 0)
        }

        // Load approval settings (defaults when the section is absent).
        let approval = config.approval ?? ApprovalConfig()
        approvalModePopup.selectItem(at: Self.approvalModeIndex(approval.mode))
        autoAllowField.stringValue = approval.autoAllow.joined(separator: ", ")
        alwaysAskField.stringValue = approval.alwaysAsk.joined(separator: ", ")
        worktreeAutoApproveCheckbox.state = approval.worktreeAutoApprove ? .on : .off

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
        let opacity = sender.doubleValue
        mutateConfig { $0.window.opacity = opacity }
        updateOpacityLabel()
        applyOpacityChange()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let names = themeSelectionNames
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < names.count else { return }
        mutateConfig { $0.theme.name = names[index] }
        // Posts .themeDidChange, which every window observes to repaint live
        // (chrome + open terminals) and sets the matching NSApp appearance.
        Theme.shared.setSelection(names[index])
    }

    @objc private func blurCheckboxChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { $0.window.enableBlur = enabled }
        showRestartAlert()
    }

    @objc private func restoreSessionChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { $0.behavior.restoreSession = enabled }
    }

    /// Popup title meaning "no family configured — use the system mono font".
    private static let systemDefaultFontTitle = "System Default"

    /// Font families suitable for the terminal: every installed fixed-pitch
    /// family, plus families whose name marks them as coding/Nerd fonts (the
    /// non-"Mono" Nerd Font variants report a proportional trait but are still
    /// usable), plus a few common names. Sorted and de-duplicated.
    private func terminalFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        let fixedPitch = UInt(NSFontTraitMask.fixedPitchFontMask.rawValue)
        let nameHints = ["mono", "nerd", "code", "consol", "courier"]

        var families = Set<String>(["JetBrains Mono", "SF Mono", "Monaco", "Menlo"])

        for family in manager.availableFontFamilies {
            let lower = family.lowercased()
            if nameHints.contains(where: lower.contains) {
                families.insert(family)
                continue
            }
            if let members = manager.availableMembers(ofFontFamily: family),
               members.contains(where: { ($0.count > 3 ? ($0[3] as? UInt ?? 0) : 0) & fixedPitch != 0 }) {
                families.insert(family)
            }
        }

        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        if let selectedTitle = sender.selectedItem?.title {
            mutateConfig { $0.font.family = selectedTitle }
            applyFontChanges()
        }
    }

    @objc private func fontSizeSliderChanged(_ sender: NSSlider) {
        let size = Int(sender.doubleValue)
        mutateConfig { $0.font.size = size }
        updateFontSizeLabel()
        applyFontChanges()
    }

    @objc private func boldIsBrightChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { $0.font.boldIsBright = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func paddingSliderChanged(_ sender: NSSlider) {
        let padding = Int(sender.doubleValue)
        mutateConfig { $0.window.padding = padding }
        updatePaddingLabel()
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func fileOpenModeChanged(_ sender: NSPopUpButton) {
        let mode = sender.indexOfSelectedItem == 1 ? "builtin" : "terminal"
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fileOpenMode = mode }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func editorFontSizeChanged(_ sender: NSSlider) {
        let size = Int(sender.doubleValue)
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fontSize = size }
        updateEditorFontSizeLabel()
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func editorFontFamilyChanged(_ sender: NSPopUpButton) {
        let title = sender.selectedItem?.title ?? Self.systemDefaultFontTitle
        let family = (title == Self.systemDefaultFontTitle) ? "" : title
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.fontFamily = family }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.wordWrap = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func showHiddenFilesChanged(_ sender: NSButton) {
        let on = sender.state == .on
        mutateConfig { Self.ensuringEditor(&$0); $0.editor?.showHiddenFiles = on }
        mainWindowController?.applyRuntimeConfig(config)
    }

    /// Approval mode strings indexed to match the popup item order.
    private static let approvalModes = ["ask", "auto", "bypass"]

    private static func approvalModeIndex(_ mode: String) -> Int {
        approvalModes.firstIndex(of: mode.lowercased()) ?? 0
    }

    @objc private func approvalModeChanged(_ sender: NSPopUpButton) {
        let mode = Self.approvalModes[safe: sender.indexOfSelectedItem] ?? "ask"
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.mode = mode }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func autoAllowChanged(_ sender: NSTextField) {
        let globs = Self.parseGlobs(sender.stringValue)
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.autoAllow = globs }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func alwaysAskChanged(_ sender: NSTextField) {
        let globs = Self.parseGlobs(sender.stringValue)
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.alwaysAsk = globs }
        mainWindowController?.applyRuntimeConfig(config)
    }

    @objc private func worktreeAutoApproveChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        mutateConfig { Self.ensuringApproval(&$0); $0.approval?.worktreeAutoApprove = enabled }
        mainWindowController?.applyRuntimeConfig(config)
    }

    /// Split a comma-separated glob list into trimmed, non-empty patterns.
    private static func parseGlobs(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        // Every control already persists on change, so there's nothing pending to
        // flush; writing our snapshot here would clobber on-disk edits. Loading
        // just recreates a default when the file is missing, without overwriting
        // an existing (or broken) one, so "Edit raw config" always opens a file.
        _ = Config.load()
        mainWindowController?.openConfigFile()
    }

    /// Set once we've warned the user that on-disk config is broken, so a
    /// stream of control changes doesn't stack a modal per click.
    private var didWarnBrokenConfig = false

    /// Apply a single-field change on top of the *latest* on-disk config, then
    /// persist and refresh our snapshot. Re-reading before writing means each
    /// control only rewrites the field the user just touched — concurrent
    /// external edits (or a ConfigWatcher reload) to *other* fields survive
    /// instead of being clobbered by this window's stale whole-file snapshot
    /// (M4). If the on-disk file failed to parse, nothing is written and the
    /// running config is left as-is, so a broken config isn't overwritten with
    /// defaults (M3); the user is told once why the change didn't stick.
    private func mutateConfig(_ apply: (inout Config) -> Void) {
        var fresh = Config.load()
        guard !fresh.loadDidFail else {
            warnBrokenConfigOnce()
            return
        }
        apply(&fresh)
        config = fresh
        fresh.save()
    }

    private func warnBrokenConfigOnce() {
        guard !didWarnBrokenConfig else { return }
        didWarnBrokenConfig = true
        let alert = NSAlert()
        alert.messageText = "Couldn't save your change"
        alert.informativeText =
            "~/.config/sidekick/config.toml can't be parsed, so Sidekick won't overwrite it and lose your existing settings. Fix or remove that file (a backup is at config.toml.bak), then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func ensuringEditor(_ config: inout Config) {
        if config.editor == nil {
            config.editor = EditorConfig()
        }
    }

    private static func ensuringApproval(_ config: inout Config) {
        if config.approval == nil {
            config.approval = ApprovalConfig()
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

    private func updatePaddingLabel() {
        paddingLabel.stringValue = "\(Int(paddingSlider.doubleValue))px"
    }

    private func updateEditorFontSizeLabel() {
        editorFontSizeLabel.stringValue = "\(Int(editorFontSizeSlider.doubleValue))pt"
    }

    private func applyOpacityChange() {
        mainWindowController?.applyRuntimeConfig(config)
    }

    private func applyFontChanges() {
        // This would need to be implemented to update existing terminals
        // For now, changes will apply to new terminals
        Log.debug("Font changed to \(config.font.family) \(config.font.size)pt", category: "app")
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
        // Nothing to flush: every control persists its own field on change via
        // mutateConfig. Writing the whole snapshot here would clobber any
        // external edits made while this window was open (M4).
    }
}
