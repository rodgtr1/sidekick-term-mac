import Cocoa
import SwiftTerm

// MARK: - Catppuccin Mocha Theme
struct CatppuccinMocha {
    // Base colors
    static let rosewater = NSColor(hex: "#f5e0dc")!
    static let flamingo = NSColor(hex: "#f2cdcd")!
    static let pink = NSColor(hex: "#f5c2e7")!
    static let mauve = NSColor(hex: "#cba6f7")!
    static let red = NSColor(hex: "#f38ba8")!
    static let maroon = NSColor(hex: "#eba0ac")!
    static let peach = NSColor(hex: "#fab387")!
    static let yellow = NSColor(hex: "#f9e2af")!
    static let green = NSColor(hex: "#a6e3a1")!
    static let teal = NSColor(hex: "#94e2d5")!
    static let sky = NSColor(hex: "#89dceb")!
    static let sapphire = NSColor(hex: "#74c7ec")!
    static let blue = NSColor(hex: "#89b4fa")!
    static let lavender = NSColor(hex: "#b4befe")!

    // Text colors
    static let text = NSColor(hex: "#cdd6f4")!
    static let subtext1 = NSColor(hex: "#bac2de")!
    static let subtext0 = NSColor(hex: "#a6adc8")!
    static let overlay2 = NSColor(hex: "#9399b2")!
    static let overlay1 = NSColor(hex: "#7f849c")!
    static let overlay0 = NSColor(hex: "#6c7086")!
    static let surface2 = NSColor(hex: "#585b70")!
    static let surface1 = NSColor(hex: "#45475a")!
    static let surface0 = NSColor(hex: "#313244")!

    // Base surfaces
    static let base = NSColor(hex: "#1e1e2e")!
    static let mantle = NSColor(hex: "#181825")!
    static let crust = NSColor(hex: "#11111b")!
}

// MARK: - App Theme
struct AppTheme {
    // Window backgrounds
    static let windowBackground = CatppuccinMocha.base
    static let sidebarBackground = CatppuccinMocha.mantle
    static let headerBackground = CatppuccinMocha.crust

    // Text colors
    static let primaryText = CatppuccinMocha.text
    static let secondaryText = CatppuccinMocha.subtext0
    static let mutedText = CatppuccinMocha.overlay0

    // UI elements
    static let accent = CatppuccinMocha.blue
    static let success = CatppuccinMocha.green
    static let warning = CatppuccinMocha.yellow
    static let error = CatppuccinMocha.red

    // Interactive elements
    static let buttonBackground = CatppuccinMocha.surface0
    static let buttonBackgroundHover = CatppuccinMocha.surface1
    static let selection = CatppuccinMocha.surface1

    // Borders and dividers
    static let border = CatppuccinMocha.surface2
    static let divider = CatppuccinMocha.surface1
}

// MARK: - Terminal Color Palette
struct ColorPalette {
    static let catppuccinMocha: [SwiftTerm.Color] = [
        SwiftTerm.Color(hex: "#45475a"), // black
        SwiftTerm.Color(hex: "#f38ba8"), // red
        SwiftTerm.Color(hex: "#a6e3a1"), // green
        SwiftTerm.Color(hex: "#f9e2af"), // yellow
        SwiftTerm.Color(hex: "#89b4fa"), // blue
        SwiftTerm.Color(hex: "#f5c2e7"), // magenta
        SwiftTerm.Color(hex: "#94e2d5"), // cyan
        SwiftTerm.Color(hex: "#bac2de"), // white
        SwiftTerm.Color(hex: "#585b70"), // bright black
        SwiftTerm.Color(hex: "#f38ba8"), // bright red
        SwiftTerm.Color(hex: "#a6e3a1"), // bright green
        SwiftTerm.Color(hex: "#f9e2af"), // bright yellow
        SwiftTerm.Color(hex: "#89b4fa"), // bright blue
        SwiftTerm.Color(hex: "#f5c2e7"), // bright magenta
        SwiftTerm.Color(hex: "#94e2d5"), // bright cyan
        SwiftTerm.Color(hex: "#a6adc8")  // bright white
    ]
}

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