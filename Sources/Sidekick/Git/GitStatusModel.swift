import Foundation
import Cocoa

enum GitFileStatus: String, CaseIterable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case ignored = "!"
    case unmodified = " "

    var displayName: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .unmodified: return ""
        }
    }

    var color: NSColor {
        switch self {
        case .modified: return NSColor(hex: "#fab387") ?? .orange
        case .added: return NSColor(hex: "#a6e3a1") ?? .green
        case .deleted: return NSColor(hex: "#f38ba8") ?? .red
        case .renamed: return NSColor(hex: "#89b4fa") ?? .blue
        case .copied: return NSColor(hex: "#89b4fa") ?? .blue
        case .untracked: return NSColor(hex: "#cdd6f4") ?? .white
        case .ignored: return NSColor(hex: "#6c7086") ?? .gray
        case .unmodified: return NSColor(hex: "#cdd6f4") ?? .white
        }
    }
}

struct GitFileItem {
    let path: String
    let filename: String
    let stagedStatus: GitFileStatus
    let unstagedStatus: GitFileStatus
    let isStaged: Bool
    let isDirectory: Bool

    init(path: String, stagedChar: Character, unstagedChar: Character) {
        self.path = path
        self.filename = URL(fileURLWithPath: path).lastPathComponent
        self.stagedStatus = GitFileStatus(rawValue: String(stagedChar)) ?? .unmodified
        self.unstagedStatus = GitFileStatus(rawValue: String(unstagedChar)) ?? .unmodified
        self.isStaged = stagedChar != " " && stagedChar != "?"
        self.isDirectory = false // We'll enhance this later if needed
    }

    var displayStatus: GitFileStatus {
        if stagedStatus != .unmodified {
            return stagedStatus
        }
        return unstagedStatus
    }
}

class GitStatusModel: ObservableObject {
    @Published var files: [GitFileItem] = []
    @Published var currentBranch: String = ""
    @Published var isClean: Bool = true
    @Published var commitMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var _repositoryPath: String = ""
    private let refreshInterval: TimeInterval = 2.0
    private var refreshTimer: Timer?

    init() {}

    var repositoryPath: String {
        return _repositoryPath
    }

    deinit {
        stopAutoRefresh()
    }

    func setRepositoryPath(_ path: String) {
        guard path != _repositoryPath else { return }

        _repositoryPath = path
        refreshStatus()
        startAutoRefresh()
    }

    func refreshStatus() {
        guard !_repositoryPath.isEmpty else { return }

        isLoading = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let branch = self.getCurrentBranch()
            let statusItems = self.getGitStatus()

            DispatchQueue.main.async {
                self.currentBranch = branch
                self.files = statusItems
                self.isClean = statusItems.isEmpty
                self.isLoading = false
            }
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func getCurrentBranch() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", _repositoryPath, "symbolic-ref", "--short", "HEAD"]
        task.currentDirectoryURL = URL(fileURLWithPath: _repositoryPath)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Try detached HEAD
            return getDetachedHead()
        } catch {
            return "unknown"
        }
    }

    private func getDetachedHead() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", _repositoryPath, "rev-parse", "--short", "HEAD"]
        task.currentDirectoryURL = URL(fileURLWithPath: _repositoryPath)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return "(\(output.trimmingCharacters(in: .whitespacesAndNewlines)))"
                }
            }
        } catch {
            return "unknown"
        }

        return "unknown"
    }

    private func getGitStatus() -> [GitFileItem] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", _repositoryPath, "status", "--porcelain"]
        task.currentDirectoryURL = URL(fileURLWithPath: _repositoryPath)

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return parseGitStatusOutput(output)
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to get git status: \(error.localizedDescription)"
            }
        }

        return []
    }

    private func parseGitStatusOutput(_ output: String) -> [GitFileItem] {
        let lines = output.split(separator: "\n")
        var items: [GitFileItem] = []

        for line in lines {
            guard line.count >= 3 else { continue }

            let stagedChar = line[line.startIndex]
            let unstagedChar = line[line.index(line.startIndex, offsetBy: 1)]
            let path = String(line.dropFirst(3))

            let item = GitFileItem(path: path, stagedChar: stagedChar, unstagedChar: unstagedChar)
            items.append(item)
        }

        return items.sorted { $0.filename < $1.filename }
    }

    // MARK: - Git Operations

    func stageFile(_ file: GitFileItem) {
        executeGitCommand(["add", file.path]) { [weak self] success in
            if success {
                self?.refreshStatus()
            }
        }
    }

    func unstageFile(_ file: GitFileItem) {
        executeGitCommand(["reset", "HEAD", file.path]) { [weak self] success in
            if success {
                self?.refreshStatus()
            }
        }
    }

    func stageAllFiles() {
        executeGitCommand(["add", "."]) { [weak self] success in
            if success {
                self?.refreshStatus()
            }
        }
    }

    func unstageAllFiles() {
        executeGitCommand(["reset", "HEAD"]) { [weak self] success in
            if success {
                self?.refreshStatus()
            }
        }
    }

    func commit(message: String, completion: @escaping (Bool, String?) -> Void) {
        guard !message.isEmpty else {
            completion(false, "Commit message cannot be empty")
            return
        }

        executeGitCommand(["commit", "-m", message]) { success in
            if success {
                DispatchQueue.main.async {
                    self.commitMessage = ""
                    self.refreshStatus()
                }
                completion(true, nil)
            } else {
                completion(false, "Failed to commit changes")
            }
        }
    }

    func discardChanges(_ file: GitFileItem) {
        let command = file.isStaged ? ["checkout", "HEAD", "--", file.path] : ["checkout", "--", file.path]
        executeGitCommand(command) { [weak self] success in
            if success {
                self?.refreshStatus()
            }
        }
    }

    func pull(completion: @escaping (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["pull"]) { success, output, errorOutput in
            if success {
                DispatchQueue.main.async {
                    self.refreshStatus()
                }
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to pull changes")
            }
        }
    }

    func push(completion: @escaping (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["push"]) { success, output, errorOutput in
            if success {
                DispatchQueue.main.async {
                    self.refreshStatus()
                }
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to push changes")
            }
        }
    }

    func fetch(completion: @escaping (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["fetch"]) { success, output, errorOutput in
            if success {
                DispatchQueue.main.async {
                    self.refreshStatus()
                }
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to fetch changes")
            }
        }
    }

    private func executeGitCommand(_ arguments: [String], completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", self._repositoryPath] + arguments
            task.currentDirectoryURL = URL(fileURLWithPath: self._repositoryPath)

            task.standardOutput = Pipe()
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()

                let success = task.terminationStatus == 0
                DispatchQueue.main.async {
                    completion(success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "Failed to execute git command: \(error.localizedDescription)"
                    completion(false)
                }
            }
        }
    }

    private func executeGitCommandWithOutput(_ arguments: [String], completion: @escaping (Bool, String?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", self._repositoryPath] + arguments
            task.currentDirectoryURL = URL(fileURLWithPath: self._repositoryPath)

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe

            do {
                try task.run()
                task.waitUntilExit()

                let success = task.terminationStatus == 0

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let output = String(data: outputData, encoding: .utf8)
                let errorOutput = String(data: errorData, encoding: .utf8)

                DispatchQueue.main.async {
                    completion(success, output, errorOutput)
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "Failed to execute git command: \(error.localizedDescription)"
                    completion(false, nil, error.localizedDescription)
                }
            }
        }
    }
}