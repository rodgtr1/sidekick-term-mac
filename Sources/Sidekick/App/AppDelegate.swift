import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App launching...")

        // Set activation policy to regular app
        NSApp.setActivationPolicy(.regular)
        print("✅ Activation policy set")

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
}