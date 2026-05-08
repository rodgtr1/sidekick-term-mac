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

    // Terminal Tab
    private var fontFamilyPopup: NSPopUpButton!
    private var fontSizeSlider: NSSlider!
    private var fontSizeLabel: NSTextField!

    // Appearance Tab
    private var themePopup: NSPopUpButton!

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

        generalView.addSubview(opacityTitleLabel)
        generalView.addSubview(opacitySlider)
        generalView.addSubview(opacityLabel)
        generalView.addSubview(blurCheckbox)

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
            blurCheckbox.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: 20)
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

        terminalView.addSubview(fontFamilyLabel)
        terminalView.addSubview(fontFamilyPopup)
        terminalView.addSubview(fontSizeTitleLabel)
        terminalView.addSubview(fontSizeSlider)
        terminalView.addSubview(fontSizeLabel)

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
