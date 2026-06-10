import Cocoa

final class UncommittedChangesViewController: NSViewController {
    var onOpenFile: ((String) -> Void)?

    private var repositoryPath: String
    private var focusedFilePath: String?
    private let gitService: GitService
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!

    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 10
        static let headerHeight: CGFloat = 44
        static let diffLineHeight: CGFloat = 19
        static let maxDiffHeight: CGFloat = 900
    }

    init(repositoryPath: String, focusedFilePath: String? = nil, gitService: GitService = GitService()) {
        self.repositoryPath = repositoryPath
        self.focusedFilePath = focusedFilePath
        self.gitService = gitService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = DiffViewController.DiffColors.background.cgColor
        setupScrollView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadChanges()
    }

    func reload(focusedFilePath: String?) {
        self.focusedFilePath = focusedFilePath
        loadChanges()
    }

    private func setupScrollView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DiffViewController.DiffColors.background
        view.addSubview(scrollView)

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = Metrics.sectionSpacing
        stackView.edgeInsets = NSEdgeInsets(
            top: Metrics.horizontalPadding,
            left: Metrics.horizontalPadding,
            bottom: Metrics.horizontalPadding,
            right: Metrics.horizontalPadding
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = DiffViewController.DiffColors.background.cgColor
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: stackView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),

            stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor)
        ])
    }

    private func loadChanges() {
        showLoading()

        DispatchQueue.global(qos: .userInitiated).async { [repositoryPath, gitService] in
            do {
                // Keep a stable alphabetical order; the focused file is
                // scrolled into view rather than reordered to the top.
                let entries = try gitService.status(repositoryRoot: repositoryPath)
                    .sorted { lhs, rhs in
                        URL(fileURLWithPath: lhs.path).lastPathComponent < URL(fileURLWithPath: rhs.path).lastPathComponent
                    }

                let diffs = try gitService.diffsByPath(for: entries, repositoryRoot: repositoryPath)
                let sections = entries.map { entry in
                    ChangeSection(
                        relativePath: entry.path,
                        diff: diffs[entry.path] ?? "No changes"
                    )
                }

                DispatchQueue.main.async { [weak self] in
                    self?.display(sections)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.showMessage("Failed to load uncommitted changes: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showLoading() {
        clearStack()
        showMessage("Loading changes...")
    }

    private func showMessage(_ message: String) {
        clearStack()
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = DiffViewController.DiffColors.context
        label.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(label)
    }

    private func display(_ sections: [ChangeSection]) {
        clearStack()

        guard !sections.isEmpty else {
            showMessage("No changes")
            return
        }

        for section in sections {
            stackView.addArrangedSubview(makeSectionView(section))
        }

        if let focusedFilePath {
            // Frames are only valid after layout, so scroll on the next
            // runloop pass once the stack view has sized its sections.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToFocusedFile(focusedFilePath)
            }
        }
    }

    private func clearStack() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeSectionView(_ section: ChangeSection) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: "#1e1e2e")?.cgColor
        container.layer?.borderColor = NSColor(hex: "#313244")?.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        container.identifier = NSUserInterfaceItemIdentifier(section.absolutePath(repositoryPath: repositoryPath))

        let header = makeHeaderView(section)
        let renderedDiff = InlineDiffRenderer.render(section.diff)
        let diffView = makeDiffColumn(text: renderedDiff)

        container.addSubview(header)
        container.addSubview(diffView)

        let lineCount = max(1, renderedDiff.string.filter { $0 == "\n" }.count + 1)
        let diffHeight = min(CGFloat(lineCount) * Metrics.diffLineHeight + 14, Metrics.maxDiffHeight)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            diffView.topAnchor.constraint(equalTo: header.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            diffView.heightAnchor.constraint(equalToConstant: diffHeight)
        ])

        return container
    }

    private func makeHeaderView(_ section: ChangeSection) -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(hex: "#181825")?.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let fileName = NSTextField(labelWithString: URL(fileURLWithPath: section.relativePath).lastPathComponent)
        fileName.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        fileName.textColor = DiffViewController.DiffColors.fileHeader
        fileName.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: URL(fileURLWithPath: section.relativePath).deletingLastPathComponent().path)
        path.font = NSFont.systemFont(ofSize: 12)
        path.textColor = DiffViewController.DiffColors.context
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open File", target: self, action: #selector(openFileClicked(_:)))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.identifier = NSUserInterfaceItemIdentifier(section.absolutePath(repositoryPath: repositoryPath))
        openButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(fileName)
        header.addSubview(path)
        header.addSubview(openButton)

        NSLayoutConstraint.activate([
            fileName.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            fileName.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            path.leadingAnchor.constraint(equalTo: fileName.trailingAnchor, constant: 8),
            path.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -12),

            openButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 78)
        ])

        return header
    }

    private func makeDiffColumn(text: NSAttributedString) -> NSTextView {
        let textView = NSTextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = DiffViewController.DiffColors.background
        textView.textColor = DiffViewController.DiffColors.text
        textView.textContainerInset = NSSize(width: 12, height: 7)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(text)
        return textView
    }

    @objc private func openFileClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpenFile?(path)
    }

    private func scrollToFocusedFile(_ filePath: String) {
        guard let sectionView = stackView.arrangedSubviews.first(where: { $0.identifier?.rawValue == filePath }),
              let documentView = scrollView.documentView else { return }

        view.layoutSubtreeIfNeeded()

        // Align the section's top edge with the top of the viewport,
        // accounting for the document view's coordinate orientation.
        let sectionFrame = sectionView.convert(sectionView.bounds, to: documentView)
        let clipHeight = scrollView.contentView.bounds.height
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = max(0, sectionFrame.minY - Metrics.sectionSpacing)
        } else {
            targetY = max(0, sectionFrame.maxY - clipHeight + Metrics.sectionSpacing)
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

}

private struct ChangeSection {
    let relativePath: String
    let diff: String

    func absolutePath(repositoryPath: String) -> String {
        URL(fileURLWithPath: repositoryPath).appendingPathComponent(relativePath).path
    }
}
