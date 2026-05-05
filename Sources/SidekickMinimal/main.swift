import Cocoa

@main
class MinimalApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Minimal app starting...")

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidekick Minimal"
        window.backgroundColor = .systemGreen
        window.makeKeyAndOrderFront(nil)
        window.center()

        let label = NSTextField(labelWithString: "Sidekick Minimal Test")
        label.frame = NSRect(x: 200, y: 200, width: 200, height: 30)
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.font = NSFont.systemFont(ofSize: 16)
        window.contentView?.addSubview(label)

        print("Window created and shown")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}