import Foundation
import Cocoa

class PaneModel: Identifiable, Hashable {
    let id = UUID()
    var isFocused: Bool = false
    var title: String = ""
    var currentDirectory: String = ""
    var gitBranch: String?

    static func == (lhs: PaneModel, rhs: PaneModel) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var terminalViewController: TerminalViewController?
    var editorViewController: EditorViewController?
    var diffViewController: DiffViewController?
    var browserViewController: BrowserPanelViewController?
    var view: NSView?
    var paneType: PaneType = .terminal

    enum PaneType {
        case terminal
        case editor
        case diff
        case browser
    }

    init() {
        self.isFocused = false
    }

    func createTerminalViewController(config: Config, initialDirectory: String? = nil) {
        let terminalVC = TerminalViewController(config: config, initialDirectory: initialDirectory)
        terminalVC.delegate = self
        self.terminalViewController = terminalVC
        self.view = terminalVC.view
        self.paneType = .terminal

        // Set up observers for title updates
        setupTitleObserver()
    }

    func createEditorViewController(for url: URL) {
        print("🪟 PaneModel creating editor for: \(url.path)")
        let editorVC = EditorViewController()
        self.editorViewController = editorVC

        // Ensure view is loaded by accessing it
        print("🪟 Accessing editor view...")
        _ = editorVC.view

        self.view = editorVC.view
        self.paneType = .editor
        print("🪟 Editor view set, view size: \(editorVC.view.bounds)")

        // Open the file
        print("🪟 Opening file in editor...")
        editorVC.openFile(url)

        // Update title based on filename
        updateTitleForEditor(fileName: editorVC.fileName)

        // Observe editor dirty state changes
        observeEditorDirtyState(editorVC)
        print("🪟 Editor pane setup complete")
    }

    private func observeEditorDirtyState(_ editorVC: EditorViewController) {
        // We'll need to add KVO for the isModified property in EditorViewController
        // For now, we'll set up a notification observer
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("EditorModifiedStateChanged"),
            object: editorVC,
            queue: .main
        ) { [weak self] notification in
            if let isModified = notification.userInfo?["isModified"] as? Bool {
                // Notify the tab about dirty state change
                NotificationCenter.default.post(
                    name: NSNotification.Name("PaneDirtyStateChanged"),
                    object: self,
                    userInfo: ["isDirty": isModified]
                )
            }
        }
    }

    func createDiffViewController(for filePath: String) {
        let diffVC = DiffViewController()
        self.diffViewController = diffVC

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

    func createBrowserViewController() {
        let browserVC = BrowserPanelViewController()
        self.browserViewController = browserVC

        // Ensure view is loaded by accessing it
        _ = browserVC.view

        self.view = browserVC.view
        self.paneType = .browser

        // Update title
        title = "Browser"
    }

    private func updateTitleForEditor(fileName: String) {
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
            name: NSNotification.Name("PaneTitleChanged"),
            object: self,
            userInfo: ["title": title]
        )
    }

    func focus() {
        isFocused = true

        switch paneType {
        case .terminal:
            terminalViewController?.focusTerminal()
        case .editor:
            if let textView = editorViewController?.view.subviews.first(where: { $0 is NSScrollView })?.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
                editorViewController?.view.window?.makeFirstResponder(textView)
            }
        case .diff:
            if let textView = diffViewController?.view.subviews.first(where: { $0 is NSScrollView })?.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
                diffViewController?.view.window?.makeFirstResponder(textView)
            }
        case .browser:
            // Focus on the browser view
            browserViewController?.view.window?.makeFirstResponder(browserViewController?.view)
        }
    }

    func unfocus() {
        isFocused = false
    }

    deinit {
        terminalViewController = nil
        editorViewController = nil
        diffViewController = nil
        browserViewController = nil
        view = nil
    }
}

extension PaneModel: TerminalViewControllerDelegate {
    func terminalDidUpdateTitle(_ terminal: TerminalViewController, directory: String, branch: String?) {
        updateTitle(directory: directory, branch: branch)

        // Notify about CWD change
        NotificationCenter.default.post(
            name: NSNotification.Name("TerminalCWDChanged"),
            object: nil,
            userInfo: ["directory": directory, "branch": branch as Any]
        )
    }

    func terminalDidDetectAgentState(_ terminal: TerminalViewController, state: AgentState) {
        NotificationCenter.default.post(
            name: NSNotification.Name("PaneAgentStateChanged"),
            object: self,
            userInfo: ["agentState": state]
        )
    }
}
