import Foundation
import Cocoa

class PaneModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var isFocused: Bool = false
    @Published var title: String = ""
    @Published var currentDirectory: String = ""
    @Published var gitBranch: String?

    var terminalViewController: TerminalViewController?
    var editorViewController: EditorViewController?
    var diffViewController: DiffViewController?
    var view: NSView?
    var paneType: PaneType = .terminal

    enum PaneType {
        case terminal
        case editor
        case diff
    }

    init() {
        self.isFocused = false
    }

    func createTerminalViewController(config: Config) {
        let terminalVC = TerminalViewController(config: config)
        terminalVC.delegate = self
        self.terminalViewController = terminalVC
        self.view = terminalVC.view
        self.paneType = .terminal

        // Set up observers for title updates
        setupTitleObserver()
    }

    func createEditorViewController(for url: URL) {
        let editorVC = EditorViewController()
        self.editorViewController = editorVC
        self.view = editorVC.view
        self.paneType = .editor

        // Open the file
        editorVC.openFile(url)

        // Update title based on filename
        updateTitleForEditor(fileName: editorVC.fileName)

        // Observe editor dirty state changes
        observeEditorDirtyState(editorVC)
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
        self.view = diffVC.view
        self.paneType = .diff

        // Show the diff
        diffVC.showDiff(for: filePath)

        // Update title based on filename
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        updateTitleForDiff(fileName: fileName)
    }

    private func updateTitleForEditor(fileName: String) {
        title = fileName
    }

    private func updateTitleForDiff(fileName: String) {
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
    }

    func focus() {
        isFocused = true

        switch paneType {
        case .terminal:
            terminalViewController?.view.window?.makeFirstResponder(terminalViewController?.view)
        case .editor:
            if let textView = editorViewController?.view.subviews.first(where: { $0 is NSScrollView })?.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
                editorViewController?.view.window?.makeFirstResponder(textView)
            }
        case .diff:
            if let textView = diffViewController?.view.subviews.first(where: { $0 is NSScrollView })?.subviews.first(where: { $0 is NSTextView }) as? NSTextView {
                diffViewController?.view.window?.makeFirstResponder(textView)
            }
        }
    }

    func unfocus() {
        isFocused = false
    }

    deinit {
        terminalViewController = nil
        editorViewController = nil
        diffViewController = nil
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
}