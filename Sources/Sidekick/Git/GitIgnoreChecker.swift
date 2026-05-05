import Foundation

class GitIgnoreChecker {
    private let rootPath: String
    private var ignoredFiles: Set<String> = []
    private var isLoaded = false

    init(rootPath: String) {
        self.rootPath = rootPath
        loadIgnoredFiles()
    }

    func isIgnored(path: String) -> Bool {
        if !isLoaded {
            loadIgnoredFiles()
        }

        // Convert to relative path from root
        let relativePath = path.hasPrefix(rootPath)
            ? String(path.dropFirst(rootPath.count + 1))
            : path

        return ignoredFiles.contains(relativePath)
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
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    ignoredFiles = Set(output.split(separator: "\n").map { String($0) })
                }
            }
            isLoaded = true
        } catch {
            // Git not available or not a git repo, ignore silently
            isLoaded = true
        }
    }
}