import Foundation
import Cocoa
import SidekickTelemetryCore

enum AgentState: String, Codable, CaseIterable {
    case idle       // No agent activity
    case working    // Agent is processing
    case ready      // Agent is ready for input (waiting for user)
    case done       // Agent finished the last run

    /// Higher values require more immediate attention. Used to aggregate
    /// per-pane state into the tab indicator without one idle pane masking a
    /// working or blocked sibling.
    var priority: Int {
        switch self {
        case .idle: return 0
        case .done: return 1
        case .working: return 2
        case .ready: return 3
        }
    }
}

class TabModel: Identifiable {
    let id = UUID()
    var title: String = "Terminal"
    var isActive: Bool = false
    var isDirty: Bool = false
    var agentState: AgentState = .idle {
        didSet {
            if agentState != oldValue {
                agentStateChangedAt = Date()
            }
        }
    }
    var agentStateChangedAt = Date()
    var panes: [PaneModel] = []
    var activePaneIndex: Int = 0

    /// User-assigned name from "Rename Tab"; overrides the automatic
    /// directory/branch title until cleared (set back to nil).
    var customTitle: String? {
        didSet { updateTitleFromActivePane() }
    }

    // Last finished command (from shell integration); nil while one runs
    var lastCommandFailed: Bool = false
    var lastCommandTooltip: String?

    /// Aggregated agent telemetry (model, token usage) for this tab's primary
    /// agent pane, set by AutomationCoordinator when the sidekick-telemetry hook
    /// reports. Read by the agents-panel dashboard.
    var telemetry: TranscriptUsage?

    // Backward compatibility
    var isAgentReady: Bool {
        return agentState == .ready
    }

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

    func addPane(_ pane: PaneModel) {
        panes.append(pane)
        activePaneIndex = panes.count - 1
    }

    func removePane(at index: Int) {
        guard index >= 0 && index < panes.count && panes.count > 1 else { return }

        panes.remove(at: index)

        // Adjust active pane index
        if activePaneIndex >= panes.count {
            activePaneIndex = panes.count - 1
        }
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
        if let customTitle = customTitle, !customTitle.isEmpty {
            title = customTitle
            return
        }

        guard let activePane = activePane else { return }

        // Use the active pane's title (which includes directory and git branch)
        if !activePane.title.isEmpty {
            title = activePane.title
        } else {
            title = "Terminal"
        }
    }

    func updateAgentStateFromPanes() {
        agentState = panes.map(\.agentState).max(by: { $0.priority < $1.priority }) ?? .idle
    }
}

enum SplitDirection {
    case horizontal // Split left/right
    case vertical   // Split top/bottom
}
