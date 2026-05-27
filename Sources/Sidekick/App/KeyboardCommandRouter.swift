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
    case splitWithBrowser
    case focusPane(forward: Bool)
    case selectTab(Int)
}

struct KeyboardCommandRouter {
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
            case 15: return .showPanel(.run)
            case 13: return .closeCurrentPane
            case 2: return .splitPane(.horizontal)
            case 6: return .splitPane(.vertical)
            case 17: return .newTab
            case 31: return .splitWithBrowser
            case 47: return .toggleHiddenFiles
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
            case 18...26:
                let tabIndex = Int(keyCode) - 18
                return tabIndex < tabCount ? .selectTab(tabIndex) : nil
            default: break
            }
        }

        return nil
    }
}
