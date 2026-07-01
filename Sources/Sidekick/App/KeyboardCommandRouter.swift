import Cocoa

enum KeyboardCommand: Equatable {
    case cycleTabs(forward: Bool)
    case showPanel(SidebarPanel)
    case closeCurrentPane
    case splitPane(SplitDirection)
    case newTab
    case toggleHiddenFiles
    case closeTab
    case saveFile
    case toggleSidebar
    case quickOpen
    case preferences
    case focusPane(forward: Bool)
    case selectTab(Int)
    case jumpToPrompt(previous: Bool)
    case commandPalette
    case findInTerminal
    case zoomIn
    case zoomOut
    case zoomReset
    case pasteIntoTerminal
    case focusAgentAttention
}

extension KeyboardCommand {
    /// Human-readable shortcut for the command palette. Single source of truth so
    /// the palette's labels can't drift from the bindings in `command(for:…)`
    /// below. nil for commands the palette doesn't list (or that have no shortcut).
    var displayShortcut: String? {
        switch self {
        case .newTab: return "⌘T"
        case .closeTab: return "⌘W"
        case .closeCurrentPane: return "⇧⌘W"
        case .splitPane(.horizontal): return "⌘D"
        case .splitPane(.vertical): return "⇧⌘D"
        case .findInTerminal: return "⌘F"
        case .jumpToPrompt(let previous): return previous ? "⌘↑" : "⌘↓"
        case .quickOpen: return "⌘P"
        case .commandPalette: return "⇧⌘P"
        case .showPanel(.files): return "⇧⌘E"
        case .showPanel(.git): return "⇧⌘G"
        case .showPanel(.search): return "⇧⌘F"
        case .showPanel(.agents): return "⇧⌘A"
        case .showPanel(.hosts): return "⇧⌘H"
        case .toggleSidebar: return "⌘B"
        case .toggleHiddenFiles: return "⇧⌘."
        case .zoomIn: return "⌘="
        case .zoomOut: return "⌘-"
        case .zoomReset: return "⌘0"
        case .preferences: return "⌘,"
        case .saveFile: return "⌘S"
        case .cycleTabs(let forward): return forward ? "⌃Tab" : "⌃⇧Tab"
        case .focusPane(let forward): return forward ? "⌘]" : "⌘["
        case .pasteIntoTerminal: return "⌘V"
        case .focusAgentAttention: return "⇧⌘J"
        default: return nil
        }
    }
}

struct KeyboardCommandRouter {
    /// kVK_ANSI_1…9 → tab index 0…8.
    private static let digitKeyCodeToTabIndex: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8
    ]

    func command(for event: NSEvent, tabCount: Int) -> KeyboardCommand? {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        if modifiers.contains(.control) && keyCode == 48 {
            return .cycleTabs(forward: !modifiers.contains(.shift))
        }

        if modifiers.contains([.command, .shift]) {
            switch keyCode {
            case 14: return .showPanel(.files)
            case 5: return .showPanel(.git)
            case 3: return .showPanel(.search)
            case 0: return .showPanel(.agents)
            case 4: return .showPanel(.hosts)
            case 13: return .closeCurrentPane
            case 2: return .splitPane(.vertical)
            case 17: return .newTab
            case 47: return .toggleHiddenFiles
            case 35: return .commandPalette
            case 24: return .zoomIn // Cmd+Shift+= is Cmd+"+"
            case 38: return .focusAgentAttention // Cmd+Shift+J
            default: break
            }
        }

        if modifiers.contains(.command) && !modifiers.contains(.shift) {
            switch keyCode {
            case 17: return .newTab
            case 13: return .closeTab
            case 1: return .saveFile
            case 11: return .toggleSidebar
            case 35: return .quickOpen
            case 43: return .preferences
            case 2: return .splitPane(.horizontal)
            case 33: return .focusPane(forward: false)
            case 30: return .focusPane(forward: true)
            case 126: return .jumpToPrompt(previous: true)
            case 125: return .jumpToPrompt(previous: false)
            case 3: return .findInTerminal
            case 24: return .zoomIn   // Cmd+=
            case 27: return .zoomOut  // Cmd+-
            case 29: return .zoomReset // Cmd+0
            case 9: return .pasteIntoTerminal // Cmd+V (image-aware paste)
            default:
                // ANSI digit keycodes are not contiguous (5=23, 6=22, 7=26,
                // 8=28, 9=25), so map Cmd+1…9 explicitly.
                if let tabIndex = Self.digitKeyCodeToTabIndex[keyCode] {
                    return tabIndex < tabCount ? .selectTab(tabIndex) : nil
                }
            }
        }

        return nil
    }
}
