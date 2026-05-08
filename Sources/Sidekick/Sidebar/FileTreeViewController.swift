import Cocoa

protocol FileTreeDelegate: AnyObject {
    func fileTree(_ fileTree: FileTreeViewController, didSelectFile url: URL)
    func fileTree(_ fileTree: FileTreeViewController, didOpenFile url: URL)
}

class FileTreeViewController: NSViewController {
    weak var delegate: FileTreeDelegate?

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var rootNode: FileTreeNode?
    private var currentPath: String = ""
    private var showHidden: Bool = false
    private var gitIgnoreChecker: GitIgnoreChecker?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupOutlineView()
        // Start with home directory instead of root
        let initialPath = FileManager.default.homeDirectoryForCurrentUser.path
        loadFileTree(for: initialPath)
    }

    private func setupOutlineView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppTheme.sidebarBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = AppTheme.sidebarBackground

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.backgroundColor = AppTheme.sidebarBackground
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickAction(_:))
        outlineView.usesAlternatingRowBackgroundColors = false
        if #available(macOS 12.0, *) {
            outlineView.style = .plain
        }
        outlineView.selectionHighlightStyle = .regular

        // Create column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.title = "Files"
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func loadFileTree(for path: String) {
        print("🌳 loadFileTree called with path: \(path)")
        // Find git root if we're in a git project
        let gitRoot = findGitRoot(from: path)
        let displayPath = gitRoot ?? path
        print("🌳 displayPath: \(displayPath), gitRoot: \(gitRoot ?? "none")")

        guard displayPath != currentPath else {
            print("🌳 Skipping - already loaded: \(displayPath)")
            return
        }

        currentPath = displayPath
        let url = URL(fileURLWithPath: displayPath)
        print("🌳 Creating root node for: \(url.path)")

        // Check if this is a git repository
        let gitPath = url.appendingPathComponent(".git").path
        if FileManager.default.fileExists(atPath: gitPath) {
            gitIgnoreChecker = GitIgnoreChecker(rootPath: displayPath)
            // Reload tree when git ignore data finishes loading
            gitIgnoreChecker?.onLoadComplete = { [weak self] in
                guard let self = self else { return }
                print("🔄 GitIgnore data loaded, refreshing tree")
                // Reload the root node to apply git ignore filtering
                self.rootNode?.isLoaded = false
                self.rootNode?.loadChildren(showHidden: self.showHidden, gitIgnoreChecker: self.gitIgnoreChecker) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.outlineView.reloadData()
                        self.outlineView.expandItem(self.rootNode)
                    }
                }
            }
        } else {
            gitIgnoreChecker = nil
        }

        rootNode = FileTreeNode(url: url)
        // Load the root's children synchronously so they're available immediately
        rootNode?.isExpanded = true
        rootNode?.loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("📁 Root node loaded with \(self.rootNode?.children.count ?? 0) children")
                self.outlineView.reloadData()
                self.outlineView.expandItem(self.rootNode)
            }
        }
    }

    // Find the git repository root by walking up the directory tree
    private func findGitRoot(from path: String) -> String? {
        var currentURL = URL(fileURLWithPath: path)

        // Walk up the directory tree looking for .git
        while currentURL.path != "/" {
            let gitURL = currentURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) {
                return currentURL.path
            }
            currentURL = currentURL.deletingLastPathComponent()
        }

        return nil
    }

    func toggleHiddenFiles() {
        showHidden.toggle()
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath)
        }
    }

    func refresh() {
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath)
        }
    }

    @objc private func doubleClickAction(_ sender: Any) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }

        print("DoubleClick: \(node.name) - isDirectory: \(node.isDirectory) - path: \(node.url.path)")

        if node.isDirectory {
            // For directories, toggle expand/collapse
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            // Only open files, not directories
            delegate?.fileTree(self, didOpenFile: node.url)
        }
    }
}

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            let count = rootNode != nil ? 1 : 0
            print("📊 numberOfChildrenOfItem(nil) = \(count)")
            return count
        }

        guard let node = item as? FileTreeNode else { return 0 }

        // Return children count only if loaded
        // Loading happens in shouldExpandItem delegate method
        let count = node.isLoaded ? node.children.count : 0
        print("📊 numberOfChildrenOfItem(\(node.name)) = \(count), isLoaded: \(node.isLoaded), isExpanded: \(node.isExpanded)")
        return count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!
        }

        guard let node = item as? FileTreeNode else {
            return NSNull()
        }

        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.isDirectory && node.hasChildren(showHidden: showHidden)
    }
}

extension FileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return FileTreeRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        var view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if view == nil {
            view = NSTableCellView()
            view?.identifier = identifier

            let textField = NSTextField()
            textField.isEditable = false
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false

            view?.addSubview(imageView)
            view?.addSubview(textField)
            view?.textField = textField
            view?.imageView = imageView

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: view!.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
            ])
        }

        view?.textField?.stringValue = node.name
        view?.imageView?.image = node.icon

        // Style based on file state
        if node.isGitIgnored {
            view?.textField?.textColor = NSColor(hex: "#6c7086") // Dimmed for ignored files
        } else if node.isHidden {
            view?.textField?.textColor = NSColor(hex: "#9399b2") // Slightly dimmed for hidden files
        } else {
            view?.textField?.textColor = NSColor(hex: "#cdd6f4") // Normal text color
        }

        return view
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 22
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }

        print("Selection: \(node.name) - isDirectory: \(node.isDirectory)")

        // Only notify delegate about file selection, not directory selection
        if !node.isDirectory {
            delegate?.fileTree(self, didSelectFile: node.url)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }

        if node.isDirectory && !node.isLoaded {
            node.loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker) { [weak self, weak node] in
                guard let self = self, let node = node else { return }
                DispatchQueue.main.async {
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            }
        } else {
            // Item is already loaded, just reload to update icon
            DispatchQueue.main.async {
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        node.isExpanded = true
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        node.isExpanded = false

        // Reload the item to update its icon (from folder.open to folder)
        DispatchQueue.main.async {
            outlineView.reloadItem(node, reloadChildren: false)
        }

        return true
    }
}

private final class FileTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 0, dy: 1)
        AppTheme.selection.setFill()
        selectionRect.fill()
    }
}
