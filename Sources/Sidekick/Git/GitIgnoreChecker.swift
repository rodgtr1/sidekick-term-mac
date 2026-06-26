import Foundation

class GitIgnoreChecker {
    private let rootPath: String
    // Written on the main actor after the git load completes, read by isIgnored
    // on the file-tree background queue. Both accesses go through `stateLock`,
    // so the nonisolated(unsafe) opt-out is backed by real synchronization
    // (assigning a Set across threads without it is a data race / UB).
    private let stateLock = NSLock()
    private nonisolated(unsafe) var ignoredFiles: Set<String> = []
    private nonisolated(unsafe) var isLoaded = false
    private var isLoading = false
    private let queue = DispatchQueue(label: "com.sidekick.gitignore", qos: .userInitiated)

    var onLoadComplete: (() -> Void)?

    init(rootPath: String) {
        self.rootPath = rootPath
        // Don't load synchronously in init - start async load
        startLoadingIgnoredFiles()
    }

    nonisolated func isIgnored(path: String) -> Bool {
        // Convert to relative path from root
        let relativePath = path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count + 1))
            : path

        stateLock.lock()
        defer { stateLock.unlock() }
        // Return false if not loaded yet - we'll refresh the UI when loading completes
        guard isLoaded else { return false }
        return ignoredFiles.contains(relativePath)
    }

    private func startLoadingIgnoredFiles() {
        stateLock.lock()
        let alreadyLoaded = isLoaded
        stateLock.unlock()
        guard !isLoading && !alreadyLoaded else { return }
        isLoading = true

        // The git invocation runs off-main and touches no instance state; the
        // result is folded back in on the main actor, so this MainActor class
        // never mutates from two threads.
        let root = rootPath
        queue.async {
            let loaded = Self.loadIgnoredFiles(rootPath: root)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.stateLock.withLock {
                    if let loaded = loaded {
                        self.ignoredFiles = loaded
                    }
                    self.isLoaded = true
                }
                self.isLoading = false
                self.onLoadComplete?()
            }
        }
    }

    /// Runs `git ls-files` for ignored entries off the main actor. Returns the
    /// relative paths, or nil when git is unavailable / the dir isn't a repo.
    private nonisolated static func loadIgnoredFiles(rootPath: String) -> Set<String>? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", rootPath, "ls-files", "--ignored", "--exclude-standard", "--others"]
        task.currentDirectoryURL = URL(fileURLWithPath: rootPath)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Silence errors

        do {
            try task.run()
            // Drain stdout before waiting: large repos exceed the 64KB pipe
            // buffer, and git blocks on write until someone reads — waiting
            // first deadlocks both processes forever.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            return Set(output.split(separator: "\n").map { String($0) })
        } catch {
            // Git not available or not a git repo, ignore silently
            return nil
        }
    }
}