import Foundation

class GitIgnoreChecker {
    private let rootPath: String
    private var ignoredFiles: Set<String> = []
    private var isLoaded = false
    private var isLoading = false
    private let queue = DispatchQueue(label: "com.sidekick.gitignore", qos: .userInitiated)

    var onLoadComplete: (() -> Void)?

    init(rootPath: String) {
        self.rootPath = rootPath
        // Don't load synchronously in init - start async load
        startLoadingIgnoredFiles()
    }

    func isIgnored(path: String) -> Bool {
        // Return false if not loaded yet - we'll refresh the UI when loading completes
        guard isLoaded else { return false }

        // Convert to relative path from root
        let relativePath = path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count + 1))
            : path

        return ignoredFiles.contains(relativePath)
    }

    private func startLoadingIgnoredFiles() {
        guard !isLoading && !isLoaded else { return }
        isLoading = true

        queue.async { [weak self] in
            guard let self = self else { return }
            self.loadIgnoredFiles()
        }
    }

    private func loadIgnoredFiles() {
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

            if task.terminationStatus == 0 {
                if let output = String(data: data, encoding: .utf8) {
                    ignoredFiles = Set(output.split(separator: "\n").map { String($0) })
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoaded = true
                self.isLoading = false
                self.onLoadComplete?()
            }
        } catch {
            // Git not available or not a git repo, ignore silently
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoaded = true
                self.isLoading = false
            }
        }
    }
}