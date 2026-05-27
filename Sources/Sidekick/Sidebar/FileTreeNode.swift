import Foundation
import Cocoa
import UniformTypeIdentifiers

class FileTreeNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool

    var children: [FileTreeNode] = []
    var isExpanded: Bool = false
    var isLoaded: Bool = false
    var hasCheckedForChildren: Bool = false

    weak var parent: FileTreeNode?

    var icon: NSImage? {
        if isDirectory {
            return isExpanded ?
                NSImage(systemSymbolName: "folder.open", accessibilityDescription: "Open folder") :
                NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        } else {
            if #available(macOS 12.0, *) {
                let contentType = UTType(filenameExtension: url.pathExtension) ?? .data
                return NSWorkspace.shared.icon(for: contentType)
            } else {
                return NSWorkspace.shared.icon(forFileType: url.pathExtension)
            }
        }
    }

    var isGitIgnored: Bool = false

    init(url: URL, parent: FileTreeNode? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.parent = parent

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = exists && isDir.boolValue

        // Check if hidden (starts with .)
        self.isHidden = name.hasPrefix(".")

        // For directories, we'll lazy load children
        if isDirectory {
            self.isLoaded = false
            // Quick check if directory has any content to show disclosure triangle
            self.hasCheckedForChildren = false
        } else {
            self.isLoaded = true
            self.hasCheckedForChildren = true
        }
    }

    /// Quick synchronous check if directory has any children (for showing disclosure triangle)
    func hasChildren(showHidden: Bool = false) -> Bool {
        guard isDirectory else { return false }

        if isLoaded {
            return !children.isEmpty
        }

        // Avoid synchronous directory scans on the main thread while AppKit asks
        // whether rows are expandable. The actual children load on expansion.
        return true
    }

    func loadChildren(showHidden: Bool = false, gitIgnoreChecker: GitIgnoreChecker? = nil, completion: (() -> Void)? = nil) {
        guard isDirectory && !isLoaded else {
            completion?()
            return
        }

        // Mark as checked since we're loading now
        hasCheckedForChildren = true

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsPackageDescendants]
            )

            var newChildren: [FileTreeNode] = []

            for childURL in contents.sorted(by: { url1, url2 in
                // Directories first, then alphabetical
                let isDir1 = (try? url1.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let isDir2 = (try? url2.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir1 && !isDir2 { return true }
                if !isDir1 && isDir2 { return false }
                return url1.lastPathComponent.localizedCaseInsensitiveCompare(url2.lastPathComponent) == .orderedAscending
            }) {
                let child = FileTreeNode(url: childURL, parent: self)

                // Skip hidden files if not showing hidden
                if child.isHidden && !showHidden {
                    continue
                }

                // Check git ignore status
                if let checker = gitIgnoreChecker {
                    child.isGitIgnored = checker.isIgnored(path: childURL.path)
                    if child.isGitIgnored && !showHidden {
                        continue
                    }
                }

                newChildren.append(child)
            }

            self.children = newChildren
            self.isLoaded = true
            completion?()

        } catch {
            print("Error loading directory contents: \(error)")
            self.isLoaded = true
            completion?()
        }
    }

    func expand(showHidden: Bool = false, gitIgnoreChecker: GitIgnoreChecker? = nil, completion: (() -> Void)? = nil) {
        guard isDirectory else {
            completion?()
            return
        }

        if !isLoaded {
            loadChildren(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker, completion: completion)
        } else {
            completion?()
        }

        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    func toggle(showHidden: Bool = false, gitIgnoreChecker: GitIgnoreChecker? = nil, completion: (() -> Void)? = nil) {
        if isExpanded {
            collapse()
            completion?()
        } else {
            expand(showHidden: showHidden, gitIgnoreChecker: gitIgnoreChecker, completion: completion)
        }
    }

    var path: String {
        return url.path
    }

    var relativePath: String? {
        guard let parent = parent else { return nil }
        if let parentPath = parent.relativePath {
            return parentPath + "/" + name
        } else {
            return name
        }
    }
}
