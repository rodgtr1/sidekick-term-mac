import Cocoa

@main
class MinimalSidekick: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 Sidekick NoTerm launching...")

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidekick (No Terminal)"
        window.backgroundColor = .systemBlue
        window.makeKeyAndOrderFront(nil)
        window.center()

        let label = NSTextField(labelWithString: "Sidekick - SwiftTerm Removed")
        label.frame = NSRect(x: 200, y: 300, width: 400, height: 30)
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.font = NSFont.systemFont(ofSize: 18)
        label.alignment = .center
        window.contentView?.addSubview(label)

        let subtitle = NSTextField(labelWithString: "Testing without SwiftTerm dependency")
        subtitle.frame = NSRect(x: 200, y: 250, width: 400, height: 20)
        subtitle.backgroundColor = .clear
        subtitle.isBordered = false
        subtitle.isEditable = false
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.alignment = .center
        subtitle.textColor = .white
        window.contentView?.addSubview(subtitle)

        NSLog("✅ Window created and shown successfully")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}