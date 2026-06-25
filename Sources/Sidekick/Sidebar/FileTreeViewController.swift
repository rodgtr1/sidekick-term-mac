import Cocoa
import CoreServices

private let fileTreeEventCallback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
    guard let clientInfo = clientInfo else { return }
    let controller = Unmanaged<FileTreeViewController>.fromOpaque(clientInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.scheduleRefreshFromFileEvent()
    }
}

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
    private var eventStream: FSEventStreamRef?
    private var refreshWorkItem: DispatchWorkItem?
    private var lastRefreshFromFileEvent: Date?
    /// Expanded folders remembered per project root, so switching tabs and
    /// coming back restores the tree instead of collapsing it.
    private var expandedPathsByRoot: [String: Set<String>] = [:]
    /// A file we want to expand-to and select once the tree is loaded.
    private var pendingRevealURL: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
    }

    private var themeObserver: ThemeObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupOutlineView()
        themeObserver = ThemeObserver { [weak self] in self?.applyThemeColors() }
        showHidden = Config.load().editor?.showHiddenFiles ?? false
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
        setupContextMenu()
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

    private func applyThemeColors() {
        view.layer?.backgroundColor = AppTheme.sidebarBackground.cgColor
        scrollView?.backgroundColor = AppTheme.sidebarBackground
        scrollView?.contentView.backgroundColor = AppTheme.sidebarBackground
        outlineView?.backgroundColor = AppTheme.sidebarBackground
        outlineView?.reloadData()
    }

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
    }

    func loadFileTree(for path: String, force: Bool = false) {
        Log.debug("🌳 loadFileTree called with path: \(path)", category: "sidebar")

        let workspace = WorkspaceResolver.context(for: path)
        let displayPath = workspace.displayRoot
        Log.debug("🌳 displayPath: \(displayPath), gitRoot: \(workspace.repositoryRoot ?? "none")", category: "sidebar")
        let pathChanged = displayPath != currentPath

        guard force || pathChanged else {
            Log.debug("🌳 Skipping - already loaded: \(displayPath)", category: "sidebar")
            return
        }

        // Remember the outgoing project's expanded folders so returning to it
        // restores them instead of collapsing everything.
        if pathChanged, !currentPath.isEmpty {
            expandedPathsByRoot[currentPath] = expandedDirectoryPaths()
        }

        // Restore expansion: the live set on a forced refresh, otherwise the
        // saved set for the project we're switching to.
        let expandedPaths = force ? expandedDirectoryPaths() : (expandedPathsByRoot[displayPath] ?? [])

        currentPath = displayPath
        if pathChanged {
            startWatching(path: displayPath)
        }
        let url = URL(fileURLWithPath: displayPath)
        Log.debug("🌳 Creating root node for: \(url.path)", category: "sidebar")

        // Check if this is a git repository
        let gitPath = url.appendingPathComponent(".git").path
        if FileManager.default.fileExists(atPath: gitPath) {
            gitIgnoreChecker = GitIgnoreChecker(rootPath: displayPath)
            // Reload tree when git ignore data finishes loading
            gitIgnoreChecker?.onLoadComplete = { [weak self] in
                guard let self = self else { return }
                Log.debug("🔄 GitIgnore data loaded, refreshing tree", category: "sidebar")
                let expandedPaths = self.expandedDirectoryPaths()
                // Reload the root node to apply git ignore filtering
                self.rootNode?.isLoaded = false
                guard let rootNode = self.rootNode else { return }
                let showHidden = self.showHidden
                let gitIgnoreChecker = self.gitIgnoreChecker
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak rootNode] in
                    rootNode?.loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker) {
                        if let rootNode {
                            self?.loadExpandedDescendants(
                                from: rootNode,
                                expandedPaths: expandedPaths,
                                showHidden: showHidden,
                                gitIgnoreChecker: gitIgnoreChecker
                            )
                        }
                        DispatchQueue.main.async {
                            guard let self = self,
                                  let rootNode = rootNode,
                                  self.rootNode === rootNode else { return }
                            self.outlineView.reloadData()
                            self.expandLoadedItems(from: rootNode)
                            self.attemptRevealPending()
                        }
                    }
                }
            }
        } else {
            gitIgnoreChecker = nil
        }

        rootNode = FileTreeNode(url: url)
        // Load the root's children synchronously so they're available immediately
        rootNode?.isExpanded = true
        guard let rootNodeToLoad = rootNode else { return }
        let currentShowHidden = showHidden
        let currentGitIgnoreChecker = gitIgnoreChecker
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak rootNodeToLoad] in
            rootNodeToLoad?.loadChildren(showHidden: currentShowHidden, gitIgnoreChecker: currentGitIgnoreChecker) {
                if let rootNodeToLoad = rootNodeToLoad {
                    self?.loadExpandedDescendants(
                        from: rootNodeToLoad,
                        expandedPaths: expandedPaths,
                        showHidden: currentShowHidden,
                        gitIgnoreChecker: currentGitIgnoreChecker
                    )
                }

                DispatchQueue.main.async {
                    guard let self = self, self.rootNode === rootNodeToLoad else { return }
                    Log.debug("📁 Root node loaded with \(self.rootNode?.children.count ?? 0) children", category: "sidebar")
                    self.outlineView.reloadData()
                    if let rootNode = self.rootNode {
                        self.expandLoadedItems(from: rootNode)
                    }
                    self.attemptRevealPending()
                }
            }
        }
    }

    func toggleHiddenFiles() {
        setShowHidden(!showHidden)
    }

    func setShowHidden(_ show: Bool) {
        guard show != showHidden else { return }
        showHidden = show
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath, force: true)
        }
    }

    func refresh() {
        if let rootPath = rootNode?.url.path {
            loadFileTree(for: rootPath, force: true)
        }
    }

    // MARK: - Reveal / select a file

    /// Expand the folders leading to `url` and select it. If the tree is still
    /// loading the request is remembered and retried once it finishes.
    func revealFile(_ url: URL) {
        pendingRevealURL = url.standardizedFileURL
        attemptRevealPending()
    }

    /// Clear any selection (e.g. the active tab is no longer an editor).
    func clearSelection() {
        pendingRevealURL = nil
        outlineView?.deselectAll(nil)
    }

    private func attemptRevealPending() {
        guard isViewLoaded,
              let target = pendingRevealURL,
              let rootNode = rootNode,
              rootNode.isLoaded else { return }

        let targetPath = target.path
        let rootPath = rootNode.url.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            // File lives outside the current tree; nothing to reveal.
            pendingRevealURL = nil
            return
        }

        revealStep(target: target, in: rootNode)
    }

    private func revealStep(target: URL, in node: FileTreeNode) {
        let targetPath = target.path
        guard let child = node.children.first(where: { child in
            let childPath = child.url.standardizedFileURL.path
            return targetPath == childPath || targetPath.hasPrefix(childPath + "/")
        }) else {
            // Not present (likely hidden or gitignored); give up quietly.
            pendingRevealURL = nil
            return
        }

        if child.url.standardizedFileURL.path == targetPath {
            outlineView.expandItem(node)
            let row = outlineView.row(forItem: child)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
            pendingRevealURL = nil
            return
        }

        // `child` is an ancestor directory of the target: expand, then descend.
        if child.isLoaded {
            child.isExpanded = true
            outlineView.expandItem(child)
            revealStep(target: target, in: child)
        } else {
            let showHidden = self.showHidden
            let gitIgnoreChecker = self.gitIgnoreChecker
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak child] in
                child?.loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker) {
                    DispatchQueue.main.async {
                        guard let self = self, let child = child,
                              self.pendingRevealURL == target else { return }
                        child.isExpanded = true
                        self.outlineView.reloadItem(child, reloadChildren: true)
                        self.outlineView.expandItem(child)
                        self.revealStep(target: target, in: child)
                    }
                }
            }
        }
    }

    private func startWatching(path: String) {
        stopWatching()

        guard shouldWatchPath(path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileTreeEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            Log.error("⚠️ Failed to watch file tree path: \(path)", category: "filetree")
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func expandedDirectoryPaths() -> Set<String> {
        guard let rootNode = rootNode else { return [] }

        var paths = Set<String>()
        collectExpandedDirectoryPaths(from: rootNode, into: &paths)
        return paths
    }

    private func collectExpandedDirectoryPaths(from node: FileTreeNode, into paths: inout Set<String>) {
        guard node.isDirectory else { return }

        if node === rootNode || outlineView.isItemExpanded(node) || node.isExpanded {
            paths.insert(node.url.path)
        }

        for child in node.children {
            collectExpandedDirectoryPaths(from: child, into: &paths)
        }
    }

    private func loadExpandedDescendants(
        from node: FileTreeNode,
        expandedPaths: Set<String>,
        showHidden: Bool,
        gitIgnoreChecker: GitIgnoreChecker?
    ) {
        guard node.isDirectory else { return }

        for child in node.children where child.isDirectory && expandedPaths.contains(child.url.path) {
            child.isExpanded = true
            child.loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker)
            loadExpandedDescendants(
                from: child,
                expandedPaths: expandedPaths,
                showHidden: showHidden,
                gitIgnoreChecker: gitIgnoreChecker
            )
        }
    }

    private func expandLoadedItems(from node: FileTreeNode) {
        guard node.isDirectory else { return }

        if node === rootNode || node.isExpanded {
            outlineView.expandItem(node)
        }

        for child in node.children {
            expandLoadedItems(from: child)
        }
    }

    fileprivate func scheduleRefreshFromFileEvent() {
        let now = Date()
        if let lastRefreshFromFileEvent,
           now.timeIntervalSince(lastRefreshFromFileEvent) < 2.0 {
            return
        }
        lastRefreshFromFileEvent = now
        refreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }

        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func shouldWatchPath(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return standardizedPath != homePath && standardizedPath != "/"
    }

    deinit {
        stopWatching()
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

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension FileTreeViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }

        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let openInFinderItem = NSMenuItem(
            title: "Open in Finder",
            action: #selector(openInFinder(_:)),
            keyEquivalent: ""
        )
        openInFinderItem.target = self
        openInFinderItem.representedObject = node.url
        menu.addItem(openInFinderItem)
    }
}

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            let count = rootNode != nil ? 1 : 0
            Log.debug("📊 numberOfChildrenOfItem(nil) = \(count)", category: "sidebar")
            return count
        }

        guard let node = item as? FileTreeNode else { return 0 }

        // Return children count only if loaded
        // Loading happens in shouldExpandItem delegate method
        let count = node.isLoaded ? node.children.count : 0
        Log.debug("📊 numberOfChildrenOfItem(\(node.name)) = \(count), isLoaded: \(node.isLoaded), isExpanded: \(node.isExpanded)", category: "sidebar")
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

        // Style based on file state: hidden and gitignored entries render
        // dimmed (name and icon) so they're distinguishable at a glance.
        if node.isGitIgnored {
            view?.textField?.textColor = AppTheme.mutedText // Dimmed for ignored files
            view?.imageView?.alphaValue = 0.4
        } else if node.isHidden {
            view?.textField?.textColor = AppTheme.dimText // Slightly dimmed for hidden files
            view?.imageView?.alphaValue = 0.55
        } else {
            view?.textField?.textColor = AppTheme.primaryText // Normal text color
            view?.imageView?.alphaValue = 1.0
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
            let currentShowHidden = showHidden
            let currentGitIgnoreChecker = gitIgnoreChecker
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
                node?.loadChildren(showHidden: currentShowHidden, gitIgnoreChecker: currentGitIgnoreChecker) {
                    DispatchQueue.main.async {
                        guard let self = self, let node = node else { return }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                        self.outlineView.expandItem(node)
                    }
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
