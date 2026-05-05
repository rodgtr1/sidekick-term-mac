import Foundation
import Cocoa

class TabModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "Terminal"
    @Published var isActive: Bool = false
    @Published var isDirty: Bool = false
    @Published var isAgentReady: Bool = false // Indicator that Claude agent is ready
    @Published var panes: [PaneModel] = []
    @Published var activePaneIndex: Int = 0

    var rootSplitView: NSSplitView?

    init() {
        // Create initial pane
        let initialPane = PaneModel()
        panes.append(initialPane)
        activePaneIndex = 0
    }

    var activePane: PaneModel? {
        guard activePaneIndex >= 0 && activePaneIndex < panes.count else { return nil }
        return panes[activePaneIndex]
    }

    func addPane(_ pane: PaneModel, splitDirection: SplitDirection = .horizontal) {
        panes.append(pane)
        activePaneIndex = panes.count - 1
        rebuildSplitView(splitDirection: splitDirection)
    }

    func removePane(at index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        panes.remove(at: index)

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        }

        rebuildSplitView()
    }

    func setActivePane(index: Int) {
        guard index >= 0 && index < panes.count else { return }
        activePaneIndex = index

        // Update focus for all panes
        for (i, pane) in panes.enumerated() {
            pane.isFocused = (i == index)
        }

        // Update tab title from active pane
        updateTitleFromActivePane()
    }

    func updateTitleFromActivePane() {
        guard let activePane = activePane else { return }

        // Use the active pane's title (which includes directory and git branch)
        if !activePane.title.isEmpty {
            title = activePane.title
        } else {
            title = "Terminal"
        }
    }

    private func rebuildSplitView(splitDirection: SplitDirection = .horizontal) {
        // This will be called when the split layout needs to be rebuilt
        // Implementation will be handled by the view controller
    }
}

enum SplitDirection {
    case horizontal // Split left/right
    case vertical   // Split top/bottom
}