import Cocoa
import SwiftTerm

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