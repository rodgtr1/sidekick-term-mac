import Cocoa

class DiffViewController: NSViewController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var hunkButtons: [HunkButton] = []

    private var filePath: String?
    private var diffContent: String = ""
    private var hunks: [DiffHunk] = []
    private var isInteractiveMode: Bool = false
    private let gitService = GitService()

    struct DiffHunk {
        let range: NSRange
        let header: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let content: String
    }

    struct DiffColors {
        static var background: NSColor { AppTheme.windowBackground }
        static var text: NSColor { AppTheme.primaryText }
        static var added: NSColor { AppTheme.success }
        static var removed: NSColor { AppTheme.error }
        static var context: NSColor { AppTheme.mutedText }
        static var hunkHeader: NSColor { AppTheme.accent }
        static var fileHeader: NSColor { AppTheme.warning }
    }

    override func loadView() {
        view = NSView()
        // Call setup immediately after creating view
        setupTextView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // setupTextView is now called in loadView
    }

    private func setupTextView() {
        Log.debug("📝 DiffViewController: setupTextView called", category: "editor")

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        // Create text container and layout manager
        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let layoutManager = DiffLineBackgroundLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = DiffColors.background
        textView.textColor = DiffColors.text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.autoresizingMask = [.width]

        // Configure for scrolling
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView

        // No line-number ruler: the inline diff rendering carries its own
        // gutter with the new file's line numbers.

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        Log.debug("📝 DiffViewController: setupTextView complete, view bounds: \(view.bounds)", category: "editor")
    }

    func showDiff(for filePath: String, isInteractive: Bool = false) {
        Log.debug("📝 DiffViewController: showDiff called for: \(filePath)", category: "editor")
        self.filePath = filePath
        self.isInteractiveMode = isInteractive

        loadGitDiff(for: filePath) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let diffContent):
                    Log.debug("📝 DiffViewController: Loaded diff content (\(diffContent.count) chars)", category: "editor")
                    self?.displayDiff(diffContent)
                case .failure(let error):
                    Log.error("❌ DiffViewController: Failed to load diff: \(error.localizedDescription)", category: "diff")
                    self?.showError("Failed to load diff: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGitDiff(for filePath: String, completion: @escaping (Result<String, Error>) -> Void) {
        Log.debug("📝 loadGitDiff: filePath = \(filePath)", category: "editor")

        DispatchQueue.global(qos: .userInitiated).async { [gitService] in
            let gitRoot = gitService.repositoryRoot(from: filePath) ?? URL(fileURLWithPath: filePath).deletingLastPathComponent().path
            Log.debug("📝 loadGitDiff: gitRoot = \(gitRoot)", category: "editor")

            let workspace = WorkspaceContext(workingDirectory: gitRoot, repositoryRoot: gitRoot)
            let relativePath = workspace.relativePath(for: filePath)
            Log.debug("📝 loadGitDiff: relativePath = \(relativePath)", category: "editor")

            do {
                let diff = try gitService.diff(relativePath: relativePath, repositoryRoot: gitRoot)
                Log.debug("📝 loadGitDiff: git diff output length = \(diff.count)", category: "editor")
                completion(.success(diff))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func displayDiff(_ content: String) {
        Log.debug("📝 DiffViewController: displayDiff called with \(content.count) chars", category: "editor")
        diffContent = content
        parseHunks()

        guard let textStorage = textView.textStorage else {
            Log.error("❌ DiffViewController: textStorage is nil!", category: "diff")
            return
        }

        textStorage.setAttributedString(NSAttributedString())

        if content.trimmingCharacters(in: .whitespacesAndNewlines) == "No changes" {
            let noChangesText = NSAttributedString(string: "No changes", attributes: [
                .foregroundColor: DiffColors.context,
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            ])
            textStorage.append(noChangesText)
            return
        }

        let ext = (filePath as NSString?)?.pathExtension.lowercased() ?? ""
        textStorage.append(InlineDiffRenderer.render(content, fileExtension: ext))

        Log.debug("📝 DiffViewController: Final textStorage length: \(textStorage.length)", category: "editor")
        Log.debug("📝 DiffViewController: textView bounds: \(textView.bounds)", category: "editor")
        Log.debug("📝 DiffViewController: textView isHidden: \(textView.isHidden)", category: "editor")
        Log.debug("📝 DiffViewController: scrollView bounds: \(scrollView.bounds)", category: "editor")

        if isInteractiveMode {
            addHunkButtons()
        }

        // Force a layout update
        textView.setNeedsDisplay(textView.bounds)
        scrollView.setNeedsDisplay(scrollView.bounds)
    }

    private func parseHunks() {
        hunks.removeAll()
        let lines = diffContent.components(separatedBy: .newlines)
        var currentHunkStart = -1
        var currentHunkContent = ""

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("@@") {
                // Save previous hunk if exists
                if currentHunkStart != -1 {
                    let range = NSRange(location: currentHunkStart, length: index - currentHunkStart)
                    if let hunk = parseHunkHeader(currentHunkContent, range: range) {
                        hunks.append(hunk)
                    }
                }

                // Start new hunk
                currentHunkStart = index
                currentHunkContent = line
            } else if currentHunkStart != -1 {
                currentHunkContent += "\n" + line
            }
        }

        // Save last hunk
        if currentHunkStart != -1 {
            let range = NSRange(location: currentHunkStart, length: lines.count - currentHunkStart)
            if let hunk = parseHunkHeader(currentHunkContent, range: range) {
                hunks.append(hunk)
            }
        }
    }

    private func parseHunkHeader(_ content: String, range: NSRange) -> DiffHunk? {
        let lines = content.components(separatedBy: .newlines)
        guard let header = lines.first, header.hasPrefix("@@") else { return nil }

        // Parse @@ -oldStart,oldCount +newStart,newCount @@
        let pattern = #"@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let headerRange = NSRange(location: 0, length: header.count)

        if let match = regex?.firstMatch(in: header, range: headerRange) {
            let oldStart = Int(String(header[Range(match.range(at: 1), in: header)!])) ?? 0
            let oldCount = match.range(at: 2).location != NSNotFound ?
                Int(String(header[Range(match.range(at: 2), in: header)!])) ?? 1 : 1
            let newStart = Int(String(header[Range(match.range(at: 3), in: header)!])) ?? 0
            let newCount = match.range(at: 4).location != NSNotFound ?
                Int(String(header[Range(match.range(at: 4), in: header)!])) ?? 1 : 1

            return DiffHunk(
                range: range,
                header: header,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                content: content
            )
        }

        return nil
    }

    private func addHunkButtons() {
        // Remove existing buttons
        hunkButtons.forEach { $0.removeFromSuperview() }
        hunkButtons.removeAll()

        for (index, hunk) in hunks.enumerated() {
            let acceptButton = HunkButton(title: "Accept", hunkIndex: index, action: .accept)
            let rejectButton = HunkButton(title: "Reject", hunkIndex: index, action: .reject)

            acceptButton.target = self
            acceptButton.action = #selector(hunkButtonClicked(_:))
            rejectButton.target = self
            rejectButton.action = #selector(hunkButtonClicked(_:))

            // Position buttons near the hunk
            let lineHeight: CGFloat = 16
            let yPosition = CGFloat(hunk.range.location) * lineHeight

            acceptButton.frame = NSRect(x: view.bounds.width - 120, y: yPosition, width: 50, height: 20)
            rejectButton.frame = NSRect(x: view.bounds.width - 60, y: yPosition, width: 50, height: 20)

            view.addSubview(acceptButton)
            view.addSubview(rejectButton)

            hunkButtons.append(acceptButton)
            hunkButtons.append(rejectButton)
        }
    }

    @objc private func hunkButtonClicked(_ sender: HunkButton) {
        guard sender.hunkIndex < hunks.count else { return }

        let hunk = hunks[sender.hunkIndex]

        switch sender.hunkAction {
        case .accept:
            acceptHunk(hunk)
        case .reject:
            rejectHunk(hunk)
        }
    }

    private func acceptHunk(_ hunk: DiffHunk) {
        // Apply the hunk to the working directory
        guard let filePath = filePath else { return }

        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["apply", "--cached"]
        task.currentDirectoryPath = URL(fileURLWithPath: filePath).deletingLastPathComponent().path

        let pipe = Pipe()
        task.standardInput = pipe

        do {
            try task.run()
            pipe.fileHandleForWriting.write(hunk.content.data(using: .utf8) ?? Data())
            pipe.fileHandleForWriting.closeFile()
            task.waitUntilExit()

            // Refresh the diff view
            showDiff(for: filePath, isInteractive: isInteractiveMode)
        } catch {
            showError("Failed to accept hunk: \(error.localizedDescription)")
        }
    }

    private func rejectHunk(_ hunk: DiffHunk) {
        // This would revert the hunk in the working directory
        // For now, we'll just remove it from the display
        showError("Reject hunk functionality not yet implemented")
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Diff Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - HunkButton

class HunkButton: NSButton {
    enum HunkAction {
        case accept
        case reject
    }

    let hunkIndex: Int
    let hunkAction: HunkAction

    init(title: String, hunkIndex: Int, action: HunkAction) {
        self.hunkIndex = hunkIndex
        self.hunkAction = action
        super.init(frame: .zero)

        self.title = title
        self.bezelStyle = .rounded
        self.font = NSFont.systemFont(ofSize: 10)

        switch action {
        case .accept:
            self.contentTintColor = AppTheme.success
        case .reject:
            self.contentTintColor = AppTheme.error
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
