import Foundation

/// Snapshot of the open tabs/panes, persisted across launches.
nonisolated struct SessionPaneState: Codable, Equatable, Sendable {
    let type: String // "terminal"
    let cwd: String?
    let url: String?
}

nonisolated struct SessionTabState: Codable, Equatable, Sendable {
    let panes: [SessionPaneState]
    let activePaneIndex: Int
    let customTitle: String?
}

nonisolated struct SessionState: Codable, Equatable, Sendable {
    let tabs: [SessionTabState]
    let activeTabIndex: Int
}

enum SessionStore {
    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sidekick/session.json")
    }

    static func save(_ state: SessionState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("failed to save session: \(error)", category: "session")
        }
    }

    static func load() -> SessionState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              !state.tabs.isEmpty else {
            return nil
        }
        return state
    }
}
