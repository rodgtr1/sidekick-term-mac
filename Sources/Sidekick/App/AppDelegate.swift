import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App launching...")

        // Set activation policy to regular app
        NSApp.setActivationPolicy(.regular)
        print("✅ Activation policy set")

        setupMenuBar()
        print("✅ Menu bar setup completed")

        mainWindowController = MainWindowController()
        print("✅ MainWindowController created")

        mainWindowController?.showWindow(nil)
        print("✅ showWindow called")

        // Ensure window is visible and in front
        if let window = mainWindowController?.window {
            print("✅ Window exists: \(window)")
            window.makeKeyAndOrderFront(nil)
            window.center()
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            print("✅ Window visibility calls completed")
        } else {
            print("❌ Window is nil!")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        // About Sidekick
        let aboutItem = NSMenuItem(title: "About Sidekick", action: nil, keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        // Edit Config File (Command+,)
        let editConfigItem = NSMenuItem(title: "Edit Config File...", action: #selector(AppDelegate.editConfigFile), keyEquivalent: ",")
        editConfigItem.target = self
        appMenu.addItem(editConfigItem)

        appMenu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Sidekick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        // New Tab
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)

        // Close Tab
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)

        fileMenu.addItem(NSMenuItem.separator())

        // Save
        let saveItem = NSMenuItem(title: "Save", action: #selector(save), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        mainMenu.addItem(fileMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        // Copy
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)

        // Paste
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)

        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // Toggle Sidebar
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Quick Open
        let quickOpenItem = NSMenuItem(title: "Quick Open...", action: #selector(quickOpen), keyEquivalent: "p")
        quickOpenItem.target = self
        viewMenu.addItem(quickOpenItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Activity Bar Panels
        let filesItem = NSMenuItem(title: "Show Files", action: #selector(showFilesPanel), keyEquivalent: "e")
        filesItem.keyEquivalentModifierMask = [.command, .shift]
        filesItem.target = self
        viewMenu.addItem(filesItem)

        let gitItem = NSMenuItem(title: "Show Git", action: #selector(showGitPanel), keyEquivalent: "g")
        gitItem.keyEquivalentModifierMask = [.command, .shift]
        gitItem.target = self
        viewMenu.addItem(gitItem)

        let searchItem = NSMenuItem(title: "Show Search", action: #selector(showSearchPanel), keyEquivalent: "f")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        searchItem.target = self
        viewMenu.addItem(searchItem)

        let runItem = NSMenuItem(title: "Show Run", action: #selector(showRunPanel), keyEquivalent: "r")
        runItem.keyEquivalentModifierMask = [.command, .shift]
        runItem.target = self
        viewMenu.addItem(runItem)

        // Split with Browser (Cmd+Shift+O)
        let splitBrowserItem = NSMenuItem(title: "Split with Browser", action: #selector(splitWithBrowser), keyEquivalent: "o")
        splitBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        splitBrowserItem.target = self
        viewMenu.addItem(splitBrowserItem)

        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        // Minimize
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimizeItem)

        // Close
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeItem)

        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newTab() {
        mainWindowController?.createNewTab()
    }

    @objc private func closeTab() {
        mainWindowController?.closeCurrentTab()
    }

    @objc private func save() {
        mainWindowController?.saveCurrentFile()
    }

    @objc private func toggleSidebar() {
        mainWindowController?.toggleSidebar()
    }

    @objc private func quickOpen() {
        mainWindowController?.showQuickOpen()
    }

    @objc private func editConfigFile() {
        print("⌨️ editConfigFile action called")
        mainWindowController?.openConfigFile()
    }

    @objc private func showFilesPanel() {
        mainWindowController?.showPanel(.files)
    }

    @objc private func showGitPanel() {
        mainWindowController?.showPanel(.git)
    }

    @objc private func showSearchPanel() {
        mainWindowController?.showPanel(.search)
    }

    @objc private func showRunPanel() {
        mainWindowController?.showPanel(.run)
    }

    @objc private func splitWithBrowser() {
        print("🌐 AppDelegate: Split with Browser action called")
        mainWindowController?.splitWithBrowser()
    }
}