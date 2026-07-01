import Foundation
import Cocoa

class PaneModel: Identifiable, Hashable {
    let id = UUID()
    var isFocused: Bool = false
    var title: String = ""
    var currentDirectory: String = ""
    var gitBranch: String?
    var agentState: AgentState = .idle
    var agentStateChangedAt = Date()

    static func == (lhs: PaneModel, rhs: PaneModel) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var terminalViewController: TerminalViewController?
    var editorViewController: EditorViewController?
    var diffViewController: DiffViewController?
    var uncommittedChangesViewController: UncommittedChangesViewController?
    var view: NSView?
    var paneType: PaneType = .terminal
    // Set on the main actor; read once in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var editorDirtyStateObserver: NSObjectProtocol?

    enum PaneType {
        case terminal
        case editor
        case diff
        case uncommittedChanges
    }

    init() {
        self.isFocused = false
    }

    func createTerminalViewController(
        config: Config,
        initialDirectory: String? = nil,
        command: [String]? = nil
    ) {
        let terminalVC = TerminalViewController(
            config: config,
            initialDirectory: initialDirectory,
            paneID: id,
            command: command
        )
        terminalVC.delegate = self
        self.terminalViewController = terminalVC
        self.view = terminalVC.view
        self.paneType = .terminal

        // Set up observers for title updates
        setupTitleObserver()
    }

    func createEditorViewController(for url: URL) {
        Log.debug("🪟 PaneModel creating editor for: \(url.path)", category: "panes")
        let editorVC = EditorViewController()
        self.editorViewController = editorVC
        self.currentDirectory = url.deletingLastPathComponent().path

        // Ensure view is loaded by accessing it
        Log.debug("🪟 Accessing editor view...", category: "panes")
        _ = editorVC.view

        self.view = editorVC.view
        self.paneType = .editor
        Log.debug("🪟 Editor view set, view size: \(editorVC.view.bounds)", category: "panes")

        // Open the file
        Log.debug("🪟 Opening file in editor...", category: "panes")
        editorVC.openFile(url)

        // Update title based on filename
        updateTitleForEditor(fileName: editorVC.fileName)

        // Observe editor dirty state changes
        observeEditorDirtyState(editorVC)
        Log.debug("🪟 Editor pane setup complete", category: "panes")
    }

    private func observeEditorDirtyState(_ editorVC: EditorViewController) {
        if let existingObserver = editorDirtyStateObserver {
            NotificationCenter.default.removeObserver(existingObserver)
        }
        editorDirtyStateObserver = NotificationCenter.default.addObserver(
            forName: .editorModifiedStateChanged,
            object: editorVC,
            queue: .main
        ) { [weak self] notification in
            if let isModified = notification.userInfo?["isModified"] as? Bool {
                // Notify the tab about dirty state change
                NotificationCenter.default.post(
                    name: .paneDirtyStateChanged,
                    object: self,
                    userInfo: ["isDirty": isModified]
                )
            }
        }
    }

    func createDiffViewController(for filePath: String) {
        let diffVC = DiffViewController()
        self.diffViewController = diffVC
        self.currentDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path

        // Ensure view is loaded by accessing it
        _ = diffVC.view

        self.view = diffVC.view
        self.paneType = .diff

        // Show the diff
        diffVC.showDiff(for: filePath)

        // Update title based on filename
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        updateTitleForDiff(fileName: fileName)
    }

    func createUncommittedChangesViewController(
        repositoryPath: String,
        focusedFilePath: String? = nil,
        onOpenFile: ((String) -> Void)? = nil
    ) {
        let changesVC = UncommittedChangesViewController(
            repositoryPath: repositoryPath,
            focusedFilePath: focusedFilePath
        )
        changesVC.onOpenFile = onOpenFile
        self.uncommittedChangesViewController = changesVC
        self.currentDirectory = repositoryPath

        _ = changesVC.view

        self.view = changesVC.view
        self.paneType = .uncommittedChanges
        self.title = "Uncommitted Changes"
    }

    func updateTitleForEditor(fileName: String) {
        title = fileName
    }

    func updateTitleForDiff(fileName: String) {
        title = "Diff: \(fileName)"
    }

    private func setupTitleObserver() {
        // This could be enhanced to observe the terminal's title changes
        // For now, we'll update the title manually
    }

    func updateTitle(directory: String, branch: String?) {
        let dirName = URL(fileURLWithPath: directory).lastPathComponent

        if let branch = branch, !branch.isEmpty {
            title = "\(dirName) (\(branch))"
        } else {
            title = dirName
        }

        currentDirectory = directory
        gitBranch = branch

        // Notify that the pane title has changed
        NotificationCenter.default.post(
            name: .paneTitleChanged,
            object: self,
            userInfo: ["title": title]
        )
    }

    func resolvedWorkingDirectory() -> String? {
        if !currentDirectory.isEmpty {
            return currentDirectory
        }

        if let directory = terminalViewController?.getCurrentWorkingDirectory(),
           !directory.isEmpty,
           directory != "~" {
            return directory
        }

        return nil
    }

    /// End-of-life teardown: kills the terminal pane's shell. Called from the
    /// tab controller's close paths rather than deinit, which is nonisolated
    /// and can't touch the main-actor view controller.
    func shutdown() {
        terminalViewController?.terminateProcess()
    }

    func focus() {
        isFocused = true

        switch paneType {
        case .terminal:
            terminalViewController?.focusTerminal()
        case .editor:
            editorViewController?.focusEditor()
        case .diff:
            if let textView = diffViewController?.view.subviews.first(where: { $0 is NSScrollView })?.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
                diffViewController?.view.window?.makeFirstResponder(textView)
            }
        case .uncommittedChanges:
            uncommittedChangesViewController?.view.window?.makeFirstResponder(uncommittedChangesViewController?.view)
        }
    }

    func unfocus() {
        isFocused = false
    }

    deinit {
        if let observer = editorDirtyStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        terminalViewController = nil
        editorViewController = nil
        diffViewController = nil
        uncommittedChangesViewController = nil
        view = nil
    }
}

extension PaneModel: TerminalViewControllerDelegate {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?) {
        updateTitle(directory: directory, branch: branch)

        // Notify about CWD change
        NotificationCenter.default.post(
            name: .terminalCWDChanged,
            object: self,
            userInfo: ["directory": directory, "branch": branch as Any]
        )
    }

    func terminalDidDetectAgentState(_ terminal: TerminalViewController, state: AgentState) {
        if agentState != state {
            agentState = state
            agentStateChangedAt = Date()
        }
        NotificationCenter.default.post(
            name: .paneAgentStateChanged,
            object: self,
            userInfo: ["agentState": state]
        )
    }

    func terminalRequestsOpenFile(_ terminal: TerminalViewController, path: String, line: Int?) {
        var userInfo: [String: Any] = ["path": path]
        if let line = line {
            userInfo["line"] = line
        }
        NotificationCenter.default.post(
            name: .paneOpenFileRequested,
            object: self,
            userInfo: userInfo
        )
    }

    func terminalRequestsOpenURL(_ terminal: TerminalViewController, url: URL) {
        NotificationCenter.default.post(
            name: .paneOpenURLRequested,
            object: self,
            userInfo: ["url": url]
        )
    }

    func terminalDidUpdateCommandStatus(_ terminal: TerminalViewController, status: TerminalCommandStatus?) {
        var userInfo: [String: Any] = [:]
        if let status = status {
            userInfo["status"] = status
        }
        NotificationCenter.default.post(
            name: .paneCommandStatusChanged,
            object: self,
            userInfo: userInfo
        )
    }
}
