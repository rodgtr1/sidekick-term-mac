import Cocoa

class DiffViewController: NSViewController {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var lineNumberRuler: LineNumberRulerView!
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
        static let background = NSColor(hex: "#1e1e2e") ?? .textBackgroundColor
        static let text = NSColor(hex: "#cdd6f4") ?? .textColor
        static let added = NSColor(hex: "#a6e3a1") ?? .systemGreen
        static let removed = NSColor(hex: "#f38ba8") ?? .systemRed
        static let context = NSColor(hex: "#6c7086") ?? .secondaryLabelColor
        static let hunkHeader = NSColor(hex: "#89b4fa") ?? .systemBlue
        static let fileHeader = NSColor(hex: "#f9e2af") ?? .systemYellow
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
        print("📝 DiffViewController: setupTextView called")

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

        let layoutManager = NSLayoutManager()
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

        print("📝 DiffViewController: setupTextView complete, view bounds: \(view.bounds)")
    }

    func showDiff(for filePath: String, isInteractive: Bool = false) {
        print("📝 DiffViewController: showDiff called for: \(filePath)")
        self.filePath = filePath
        self.isInteractiveMode = isInteractive

        loadGitDiff(for: filePath) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let diffContent):
                    print("📝 DiffViewController: Loaded diff content (\(diffContent.count) chars)")
                    self?.displayDiff(diffContent)
                case .failure(let error):
                    print("❌ DiffViewController: Failed to load diff: \(error.localizedDescription)")
                    self?.showError("Failed to load diff: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGitDiff(for filePath: String, completion: @escaping (Result<String, Error>) -> Void) {
        print("📝 loadGitDiff: filePath = \(filePath)")

        DispatchQueue.global(qos: .userInitiated).async { [gitService] in
            let gitRoot = gitService.repositoryRoot(from: filePath) ?? URL(fileURLWithPath: filePath).deletingLastPathComponent().path
            print("📝 loadGitDiff: gitRoot = \(gitRoot)")

            let workspace = WorkspaceContext(workingDirectory: gitRoot, repositoryRoot: gitRoot)
            let relativePath = workspace.relativePath(for: filePath)
            print("📝 loadGitDiff: relativePath = \(relativePath)")

            do {
                let diff = try gitService.diff(relativePath: relativePath, repositoryRoot: gitRoot)
                print("📝 loadGitDiff: git diff output length = \(diff.count)")
                completion(.success(diff))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func displayDiff(_ content: String) {
        print("📝 DiffViewController: displayDiff called with \(content.count) chars")
        diffContent = content
        parseHunks()

        guard let textStorage = textView.textStorage else {
            print("❌ DiffViewController: textStorage is nil!")
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

        let lines = content.components(separatedBy: .newlines)

        print("📝 DiffViewController: Processing \(lines.count) lines")

        for (index, line) in lines.enumerated() {
            let attributedLine = formatDiffLine(line)
            textStorage.append(attributedLine)

            // Add newline except for the last line
            if index < lines.count - 1 {
                let newline = NSAttributedString(string: "\n", attributes: [
                    .foregroundColor: DiffColors.text,
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                ])
                textStorage.append(newline)
            }
        }

        print("📝 DiffViewController: Final textStorage length: \(textStorage.length)")
        print("📝 DiffViewController: textView bounds: \(textView.bounds)")
        print("📝 DiffViewController: textView isHidden: \(textView.isHidden)")
        print("📝 DiffViewController: scrollView bounds: \(scrollView.bounds)")

        if isInteractiveMode {
            addHunkButtons()
        }

        // Force a layout update
        textView.setNeedsDisplay(textView.bounds)
        scrollView.setNeedsDisplay(scrollView.bounds)
    }

    private func formatDiffLine(_ line: String) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ]

        var attributes = baseAttributes

        if line.hasPrefix("+++") || line.hasPrefix("---") {
            // File headers
            attributes[.foregroundColor] = DiffColors.fileHeader
        } else if line.hasPrefix("@@") {
            // Hunk headers
            attributes[.foregroundColor] = DiffColors.hunkHeader
        } else if line.hasPrefix("+") {
            // Added lines
            attributes[.foregroundColor] = DiffColors.added
            attributes[.backgroundColor] = NSColor(hex: "#a6e3a1")?.withAlphaComponent(0.1)
        } else if line.hasPrefix("-") {
            // Removed lines
            attributes[.foregroundColor] = DiffColors.removed
            attributes[.backgroundColor] = NSColor(hex: "#f38ba8")?.withAlphaComponent(0.1)
        } else if line.hasPrefix("index") || line.hasPrefix("diff --git") {
            // Git metadata
            attributes[.foregroundColor] = DiffColors.context
        } else {
            // Context lines
            attributes[.foregroundColor] = DiffColors.text
        }

        return NSAttributedString(string: line, attributes: attributes)
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
            self.contentTintColor = NSColor(hex: "#a6e3a1")
        case .reject:
            self.contentTintColor = NSColor(hex: "#f38ba8")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
