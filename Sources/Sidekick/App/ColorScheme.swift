import Cocoa
import SwiftTerm

// MARK: - App Theme (chrome roles)
//
// These are the higher-level chrome roles used across the sidebar, panels and
// preferences. They read from the active theme's palette, so switching themes
// repaints everything that pulls colors through AppTheme.
enum AppTheme {
    private static var p: ResolvedPalette { Theme.shared.palette }

    // Window backgrounds
    static var windowBackground: NSColor { p.base }
    static var sidebarBackground: NSColor { p.mantle }
    static var headerBackground: NSColor { p.crust }

    // Text colors
    static var primaryText: NSColor { p.text }
    static var secondaryText: NSColor { p.subtext0 }
    static var mutedText: NSColor { p.overlay0 }
    static var dimText: NSColor { p.overlay2 }

    // UI elements
    static var accent: NSColor { p.blue }
    static var success: NSColor { p.green }
    static var warning: NSColor { p.yellow }
    static var error: NSColor { p.red }
    static var peach: NSColor { p.peach }
    static var cursor: NSColor { p.rosewater }

    // Interactive elements
    static var buttonBackground: NSColor { p.surface0 }
    static var buttonBackgroundHover: NSColor { p.surface1 }
    static var selection: NSColor { p.surface1 }

    // Borders and dividers
    static var border: NSColor { p.surface2 }
    static var divider: NSColor { p.surface1 }
}

// MARK: - SwiftTerm Color hex helper

extension SwiftTerm.Color {
    convenience init(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") {
            hexString = String(hexString.dropFirst())
        }

        let hexInt = Int(hexString, radix: 16) ?? 0
        let red = UInt16((hexInt >> 16) & 0xFF) * 257
        let green = UInt16((hexInt >> 8) & 0xFF) * 257
        let blue = UInt16(hexInt & 0xFF) * 257

        self.init(red: red, green: green, blue: blue)
    }
}
