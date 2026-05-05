import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 App launching...")

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Ensure window is visible and in front
        if let window = mainWindowController?.window {
            NSLog("✅ Window exists: \(window)")
            window.makeKeyAndOrderFront(nil)
            window.center()
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSLog("✅ Window visibility calls completed")
        } else {
            NSLog("❌ Window is nil!")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}