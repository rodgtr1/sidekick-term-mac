import Cocoa

class EditorViewController: NSViewController {
    private var textView: CodeTextView!
    private var scrollView: NSScrollView!
    private var lineNumberRuler: LineNumberRulerView!
    private var syntaxHighlighter: SyntaxHighlighter!
    private var currentURL: URL?
    private var activeSearchTerm: String?
    private var pendingHighlightRange: NSRange?
    private var isProgrammaticLoad = false

    var isModified: Bool = false {
        didSet {
            updateTitle()

            // Notify about modified state change
            NotificationCenter.default.post(
                name: .editorModifiedStateChanged,
                object: self,
                userInfo: ["isModified": isModified]
            )
        }
    }

    var isEditorFocused: Bool {
        return textView.window?.firstResponder === textView
    }

    override func loadView() {
        Log.debug("📝 EditorViewController loadView() called", category: "editor")
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Log.debug("📝 EditorViewController viewDidLoad() called", category: "editor")
        setupTextView()
    }

    private func setupTextView() {
        Log.debug("📝 EditorViewController setupTextView() called", category: "editor")

        // Load config
        let config = Config.load()

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        textStorage.delegate = self

        textView = CodeTextView(frame: scrollView.contentView.bounds, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Self.editorFont(for: config.editor ?? EditorConfig())
        textView.backgroundColor = AppTheme.windowBackground
        textView.textColor = AppTheme.primaryText
        textView.insertionPointColor = AppTheme.cursor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        // Breathing room on the sides so wrapped text doesn't slide under the
        // scroller (and isn't jammed against the line-number ruler).
        textView.textContainerInset = NSSize(width: 10, height: 6)

        // Configure word wrap based on config (default to true if not set)
        textView.isVerticallyResizable = true
        let wordWrap = config.editor?.wordWrap ?? true
        if wordWrap {
            // Word wrap enabled: text wraps to view width
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Word wrap disabled: allow horizontal scrolling
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView

        // Add line number ruler
        lineNumberRuler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        lineNumberRuler.attach(to: textView)
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

    /// The editor font: the configured family if set and installed,
    /// otherwise the system monospaced font.
    static func editorFont(for editorConfig: EditorConfig) -> NSFont {
        let size = CGFloat(editorConfig.fontSize)
        let family = editorConfig.fontFamily.trimmingCharacters(in: .whitespaces)
        if !family.isEmpty {
            if let font = NSFont(name: family, size: size) {
                return font
            }
            Log.error("Editor font '\(family)' not found; falling back to system mono", category: "editor")
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func applyConfig(_ config: Config) {
        guard isViewLoaded else { return }

        let editorConfig = config.editor ?? EditorConfig()
        let font = Self.editorFont(for: editorConfig)
        Log.debug("applyConfig: font=\(font.fontName) size=\(editorConfig.fontSize) wrap=\(editorConfig.wordWrap)", category: "editor")
        textView.font = font

        textView.isHorizontallyResizable = !editorConfig.wordWrap
        textView.textContainer?.widthTracksTextView = editorConfig.wordWrap
        textView.textContainer?.containerSize = NSSize(
            width: editorConfig.wordWrap ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        // Re-apply theme colors live (applyConfig is invoked on theme change).
        textView.backgroundColor = AppTheme.windowBackground
        textView.textColor = AppTheme.primaryText
        textView.insertionPointColor = AppTheme.cursor
        let ext = syntaxHighlighter?.fileExtension ?? ""
        syntaxHighlighter = SyntaxHighlighter(textView: textView)
        syntaxHighlighter.fileExtension = ext
        syntaxHighlighter.highlightSyntax()

        refreshLayout()
    }

    /// Force the text view to regenerate glyph layout and redraw. NSTextView
    /// drops its laid-out glyphs when its enclosing view is hidden (tab switch)
    /// or when the font changes, and doesn't always regenerate them on its own —
    /// which leaves the editor looking empty. Call this when the editor becomes
    /// visible again or after a font change.
    func refreshLayout() {
        guard isViewLoaded,
              let textView = textView,
              let scrollView = scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // When word wrap is on, the container width tracks the text view width
        // but only recomputes on a resize. A font change resets the width to 0,
        // so without this every line wraps to zero width and the text vanishes
        // until the window is resized. Restore it to the visible width here.
        if textContainer.widthTracksTextView {
            let visibleWidth = scrollView.contentView.bounds.width
            if visibleWidth > 0 {
                textContainer.containerSize = NSSize(
                    width: visibleWidth - 2 * textView.textContainerInset.width - 2 * textContainer.lineFragmentPadding,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }

        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: textContainer)
        textView.needsLayout = true
        textView.needsDisplay = true
        lineNumberRuler?.needsDisplay = true
    }

    @objc private func textDidChange() {
        isModified = true
        // Trigger syntax highlighting after a small delay to avoid performance issues
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateSyntaxHighlighting), object: nil)
        perform(#selector(updateSyntaxHighlighting), with: nil, afterDelay: 0.3)
    }

    @objc private func updateSyntaxHighlighting() {
        // Only re-highlight the paragraphs that actually changed since the
        // last pass, not the whole document.
        let dirtyRange = pendingHighlightRange
        pendingHighlightRange = nil
        syntaxHighlighter.highlightSyntax(in: dirtyRange)
        applySearchHighlights(in: dirtyRange)
    }

    func openFile(_ url: URL) {
        Log.debug("📝 EditorViewController openFile() called with: \(url.path)", category: "editor")
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
            isProgrammaticLoad = true
            textView.string = content
            isProgrammaticLoad = false
            pendingHighlightRange = nil
            currentURL = url
            isModified = false
            updateTitle()

            // Pick the line-comment style for ⌘/ based on the file type.
            textView.commentPrefix = CodeTextView.commentPrefix(forExtension: url.pathExtension.lowercased())

            // Update syntax highlighter with file extension
            if let highlighter = syntaxHighlighter {
                highlighter.fileExtension = url.pathExtension.lowercased()
                highlighter.highlightSyntax()
                applySearchHighlights()
            }
        } catch {
            Log.error("Failed to open \(url.path): \(error.localizedDescription)", category: "editor")
            showError("Failed to open file: \(error.localizedDescription)")
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
            Log.error("Failed to save \(url.path): \(error.localizedDescription)", category: "editor")
            showError("Failed to save file: \(error.localizedDescription)")
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
            Log.error("Failed to save as \(url.path): \(error.localizedDescription)", category: "editor")
            showError("Failed to save file: \(error.localizedDescription)")
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

    func navigateToLine(_ line: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let textView = self.textView else { return }

            guard line > 0 else { return }

            // Walk lines in UTF-16 units so the offset matches what NSTextView
            // consumes; String.count (grapheme clusters) drifts on emoji/CJK and
            // would land the caret on the wrong line.
            let content = textView.string as NSString
            var location = 0
            var currentLine = 1
            while currentLine < line && location < content.length {
                let lineRange = content.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(lineRange)
                currentLine += 1
            }
            // The walk can run off the end and still satisfy currentLine ==
            // line: on a file without a trailing newline, line lastLine+1
            // "exists" as location == length. A real line starts where
            // lineRange says it does — for a phantom line past the end,
            // lineRange snaps back to the start of the actual last line.
            guard currentLine == line,
                  content.lineRange(for: NSRange(location: location, length: 0)).location == location
            else { return }

            // Set the selection to the beginning of the target line
            let range = NSRange(location: location, length: 0)
            textView.setSelectedRange(range)

            // Scroll to make the line visible
            textView.scrollRangeToVisible(range)

            // Focus the text view
            textView.window?.makeFirstResponder(textView)
        }
    }

    func highlightOccurrences(of searchTerm: String) {
        activeSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        applySearchHighlights()
    }

    private func applySearchHighlights(in dirtyRange: NSRange? = nil) {
        guard let textView,
              let textStorage = textView.textStorage else { return }

        let content = textView.string as NSString
        let fullRange = NSRange(location: 0, length: content.length)
        let scanRange: NSRange
        if let dirtyRange = dirtyRange {
            scanRange = content.paragraphRange(for: NSIntersectionRange(dirtyRange, fullRange))
        } else {
            scanRange = fullRange
        }
        textStorage.removeAttribute(.backgroundColor, range: scanRange)

        guard let searchTerm = activeSearchTerm,
              !searchTerm.isEmpty else { return }

        var searchRange = scanRange
        let highlightColor = AppTheme.warning.withAlphaComponent(0.35)

        while searchRange.length > 0 {
            let foundRange = content.range(
                of: searchTerm,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )

            guard foundRange.location != NSNotFound else { break }

            textStorage.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            guard nextLocation < NSMaxRange(scanRange) else { break }
            searchRange = NSRange(location: nextLocation, length: NSMaxRange(scanRange) - nextLocation)
        }
    }

    func focusEditor() {
        textView.window?.makeFirstResponder(textView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension EditorViewController: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isProgrammaticLoad else { return }
        if let pending = pendingHighlightRange {
            pendingHighlightRange = NSUnionRange(pending, editedRange)
        } else {
            pendingHighlightRange = editedRange
        }
    }
}
