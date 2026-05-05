import Cocoa

class EditorViewController: NSViewController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var lineNumberRuler: LineNumberRulerView!
    private var syntaxHighlighter: SyntaxHighlighter!
    private var currentURL: URL?

    var isModified: Bool = false {
        didSet {
            updateTitle()

            // Notify about modified state change
            NotificationCenter.default.post(
                name: NSNotification.Name("EditorModifiedStateChanged"),
                object: self,
                userInfo: ["isModified": isModified]
            )
        }
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTextView()
    }

    private func setupTextView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(hex: "#1e1e2e") ?? .textBackgroundColor
        textView.textColor = NSColor(hex: "#cdd6f4") ?? .textColor
        textView.insertionPointColor = NSColor(hex: "#f5e0dc") ?? .textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Enable line numbers (simplified)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        // Add line number ruler
        lineNumberRuler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Initialize syntax highlighter
        syntaxHighlighter = SyntaxHighlighter(textView: textView)

        // Add text change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    @objc private func textDidChange() {
        isModified = true
        // Trigger syntax highlighting after a small delay to avoid performance issues
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSyntaxHighlighting), object: nil)
        perform(#selector(updateSyntaxHighlighting), with: nil, afterDelay: 0.1)
    }

    @objc private func updateSyntaxHighlighting() {
        syntaxHighlighter.highlightSyntax()
    }

    func openFile(_ url: URL) {
        // Check file size limit
        if Limits.isFileTooLarge(path: url.path) {
            showError("File is too large to open (max \(Limits.maxFileSize / 1024 / 1024)MB)")
            return
        }

        // Check if binary file
        if Limits.isBinaryFile(path: url.path) {
            showError("Cannot open binary file")
            return
        }

        do {
            let content = try String(contentsOf: url)
            textView.string = content
            currentURL = url
            isModified = false
            updateTitle()

            // Update syntax highlighter with file extension
            if let highlighter = syntaxHighlighter {
                highlighter.fileExtension = url.pathExtension.lowercased()
                highlighter.highlightSyntax()
            }
        } catch {
            showError("Failed to open file: \\(error.localizedDescription)")
        }
    }

    func saveFile() -> Bool {
        guard let url = currentURL else {
            return saveAsFile()
        }

        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            isModified = false
            return true
        } catch {
            showError("Failed to save file: \\(error.localizedDescription)")
            return false
        }
    }

    func saveAsFile() -> Bool {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        if let url = currentURL {
            savePanel.directoryURL = url.deletingLastPathComponent()
            savePanel.nameFieldStringValue = url.lastPathComponent
        }

        guard savePanel.runModal() == .OK,
              let url = savePanel.url else {
            return false
        }

        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            currentURL = url
            isModified = false
            updateTitle()
            return true
        } catch {
            showError("Failed to save file: \\(error.localizedDescription)")
            return false
        }
    }

    private func updateTitle() {
        let filename = currentURL?.lastPathComponent ?? "Untitled"
        let prefix = isModified ? "● " : ""
        view.window?.title = "\(prefix)\(filename) - Sidekick"
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    var fileName: String {
        return currentURL?.lastPathComponent ?? "Untitled"
    }

    var filePath: String? {
        return currentURL?.path
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}