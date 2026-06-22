import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Log uncaught ObjC exceptions to the persistent log so production
        // crashes leave a trace (see ~/Library/Logs/Sidekick/Sidekick.log).
        NSSetUncaughtExceptionHandler { exception in
            Log.error("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n\(exception.callStackSymbols.joined(separator: "\n"))", category: "crash")
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNum = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.info("App launching (version \(version) build \(buildNum))", category: "app")

        // Set activation policy to regular app
        NSApp.setActivationPolicy(.regular)
        print("✅ Activation policy set")

        // Keep the on-disk shell integration scripts in sync with this build
        ShellIntegration.installScripts()

        // Clear out yesterday's pasted-image temp files
        DispatchQueue.global(qos: .utility).async {
            ImagePasteStore.pruneOldFiles()
        }

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

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveSession()
        IPCServer.shared.stop()
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

        // New Tab (no key equivalent - handled by event monitor in MainWindowController)
        let newTabItem = NSMenuItem(title: "New Terminal Tab", action: #selector(newTab), keyEquivalent: "")
        newTabItem.target = self
        fileMenu.addItem(newTabItem)

        // Close Pane (no key equivalent - handled by event monitor)
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePane), keyEquivalent: "")
        closePaneItem.target = self
        fileMenu.addItem(closePaneItem)

        fileMenu.addItem(NSMenuItem.separator())

        // Save (no key equivalent - handled by event monitor)
        let saveItem = NSMenuItem(title: "Save", action: #selector(save), keyEquivalent: "")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        mainMenu.addItem(fileMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        // Undo / Redo (validated against the first responder's undo manager —
        // active in the editor and any text field, inert elsewhere).
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        // Cut
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)

        // Copy
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)

        // Paste
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)

        editMenu.addItem(NSMenuItem.separator())

        // Select All
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)

        editMenu.addItem(NSMenuItem.separator())

        // Find submenu (drives the editor's built-in find bar; ⌘F is freed for
        // the editor via the first-responder check in MainWindowController).
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")

        let findItem = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        findMenu.addItem(findItem)

        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        findMenu.addItem(findNextItem)

        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.tag = NSTextFinder.Action.previousMatch.rawValue
        findMenu.addItem(findPrevItem)

        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        // Toggle Sidebar (no key equivalent - handled by event monitor)
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Quick Open (no key equivalent - handled by event monitor)
        let quickOpenItem = NSMenuItem(title: "Quick Open...", action: #selector(quickOpen), keyEquivalent: "")
        quickOpenItem.target = self
        viewMenu.addItem(quickOpenItem)

        viewMenu.addItem(NSMenuItem.separator())

        // Activity Bar Panels (no key equivalents - handled by event monitor)
        let filesItem = NSMenuItem(title: "Show Files", action: #selector(showFilesPanel), keyEquivalent: "")
        filesItem.target = self
        viewMenu.addItem(filesItem)

        let gitItem = NSMenuItem(title: "Show Git", action: #selector(showGitPanel), keyEquivalent: "")
        gitItem.target = self
        viewMenu.addItem(gitItem)

        let searchItem = NSMenuItem(title: "Show Search", action: #selector(showSearchPanel), keyEquivalent: "")
        searchItem.target = self
        viewMenu.addItem(searchItem)

        let runItem = NSMenuItem(title: "Show Run", action: #selector(showRunPanel), keyEquivalent: "")
        runItem.target = self
        viewMenu.addItem(runItem)

        // Split with Browser (no key equivalent - handled by event monitor)
        let splitBrowserItem = NSMenuItem(title: "Split with Browser", action: #selector(splitWithBrowser), keyEquivalent: "")
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

        // Close (no key equivalent - Cmd+W is handled by event monitor to close tabs)
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        windowMenu.addItem(closeItem)

        mainMenu.addItem(windowMenuItem)

        // Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu

        // Keyboard Shortcuts
        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts), keyEquivalent: "k")
        shortcutsItem.target = self
        helpMenu.addItem(shortcutsItem)

        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newTab() {
        mainWindowController?.createNewTab()
    }

    @objc private func closeTab() {
        mainWindowController?.closeCurrentTab()
    }

    @objc private func closePane() {
        // Close the active pane
        if let controller = mainWindowController {
            controller.perform(NSSelectorFromString("closeCurrentPane"))
        }
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

    @objc private func showKeyboardShortcuts() {
        mainWindowController?.showKeyboardShortcuts()
    }
}