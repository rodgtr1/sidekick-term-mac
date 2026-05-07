import Cocoa

enum ThemeType: String, Codable {
    case system = "system"
    case catppuccin = "catppuccin"
}

protocol ThemeColors {
    // UI Elements
    var windowBackground: NSColor { get }
    var controlBackground: NSColor { get }
    var textBackground: NSColor { get }

    // Text
    var primaryText: NSColor { get }
    var secondaryText: NSColor { get }
    var labelText: NSColor { get }

    // Accents
    var accent: NSColor { get }
    var border: NSColor { get }
    var separator: NSColor { get }

    // Tab colors
    var activeTabBackground: NSColor { get }
    var inactiveTabBackground: NSColor { get }
    var activeTabText: NSColor { get }
    var inactiveTabText: NSColor { get }
    var activeTabBorder: NSColor { get }

    // Terminal
    var terminalBackground: NSColor { get }
    var terminalForeground: NSColor { get }
    var terminalCursor: NSColor { get }

    // Syntax/Status
    var green: NSColor { get }
    var red: NSColor { get }
    var yellow: NSColor { get }
    var blue: NSColor { get }
}

// System theme uses native macOS colors
struct SystemTheme: ThemeColors {
    var windowBackground: NSColor { .windowBackgroundColor }
    var controlBackground: NSColor { .controlBackgroundColor }
    var textBackground: NSColor { .textBackgroundColor }

    var primaryText: NSColor { .labelColor }
    var secondaryText: NSColor { .secondaryLabelColor }
    var labelText: NSColor { .labelColor }

    var accent: NSColor { .controlAccentColor }
    var border: NSColor { .separatorColor }
    var separator: NSColor { .separatorColor }

    var activeTabBackground: NSColor { .controlBackgroundColor }
    var inactiveTabBackground: NSColor { .unemphasizedSelectedContentBackgroundColor }
    var activeTabText: NSColor { .controlTextColor }
    var inactiveTabText: NSColor { .secondaryLabelColor }
    var activeTabBorder: NSColor { .controlAccentColor }

    var terminalBackground: NSColor { .textBackgroundColor }
    var terminalForeground: NSColor { .textColor }
    var terminalCursor: NSColor { .controlAccentColor }

    var green: NSColor { .systemGreen }
    var red: NSColor { .systemRed }
    var yellow: NSColor { .systemYellow }
    var blue: NSColor { .systemBlue }
}

// Catppuccin theme uses custom colors
struct CatppuccinTheme: ThemeColors {
    var windowBackground: NSColor { CatppuccinMocha.mantle }
    var controlBackground: NSColor { CatppuccinMocha.crust }
    var textBackground: NSColor { CatppuccinMocha.base }

    var primaryText: NSColor { CatppuccinMocha.text }
    var secondaryText: NSColor { CatppuccinMocha.overlay0 }
    var labelText: NSColor { CatppuccinMocha.text }

    var accent: NSColor { CatppuccinMocha.blue }
    var border: NSColor { CatppuccinMocha.surface1 }
    var separator: NSColor { CatppuccinMocha.surface1 }

    var activeTabBackground: NSColor { CatppuccinMocha.surface0 }
    var inactiveTabBackground: NSColor { CatppuccinMocha.crust }
    var activeTabText: NSColor { CatppuccinMocha.text }
    var inactiveTabText: NSColor { CatppuccinMocha.overlay0 }
    var activeTabBorder: NSColor { CatppuccinMocha.blue }

    var terminalBackground: NSColor { CatppuccinMocha.base }
    var terminalForeground: NSColor { CatppuccinMocha.text }
    var terminalCursor: NSColor { CatppuccinMocha.rosewater }

    var green: NSColor { CatppuccinMocha.green }
    var red: NSColor { CatppuccinMocha.red }
    var yellow: NSColor { CatppuccinMocha.yellow }
    var blue: NSColor { CatppuccinMocha.blue }
}

class Theme {
    static let shared = Theme()

    private(set) var current: ThemeColors
    private(set) var type: ThemeType

    private init() {
        // Default to system theme
        self.type = .system
        self.current = SystemTheme()
    }

    func setTheme(_ type: ThemeType) {
        self.type = type

        switch type {
        case .system:
            self.current = SystemTheme()
        case .catppuccin:
            self.current = CatppuccinTheme()
        }

        // Post notification to update UI
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    func loadFromConfig(_ config: Config) {
        switch config.theme.name {
        case "catppuccin", "catppuccin-mocha":
            setTheme(.catppuccin)
        case "system":
            setTheme(.system)
        default:
            setTheme(.catppuccin)
        }
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("themeDidChange")
}
