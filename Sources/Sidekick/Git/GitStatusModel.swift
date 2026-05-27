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
    private let gitService: GitService
    private var refreshGeneration: Int = 0

    init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    var repositoryPath: String {
        return _repositoryPath
    }

    deinit {
        stopAutoRefresh()
    }

    func setRepositoryPath(_ path: String) {
        guard let repositoryRoot = gitService.repositoryRoot(from: path) else {
            stopAutoRefresh()
            refreshGeneration += 1
            _repositoryPath = ""
            currentBranch = ""
            files = []
            isClean = true
            isLoading = false
            error = nil
            return
        }

        _repositoryPath = repositoryRoot
        refreshStatus(force: true)
        startAutoRefresh()
    }

    func refreshStatus(force: Bool = false) {
        guard !_repositoryPath.isEmpty else { return }
        guard force || !isLoading else { return }

        isLoading = true
        error = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        let repositoryPath = _repositoryPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let branch = self.getCurrentBranch(repositoryRoot: repositoryPath)
            let statusItems = self.getGitStatus(repositoryRoot: repositoryPath)

            DispatchQueue.main.async {
                guard self.refreshGeneration == generation,
                      self._repositoryPath == repositoryPath else { return }

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

    private func getCurrentBranch(repositoryRoot: String) -> String {
        do {
            return try gitService.currentBranch(repositoryRoot: repositoryRoot)
        } catch {
            return "unknown"
        }
    }

    private func getGitStatus(repositoryRoot: String) -> [GitFileItem] {
        do {
            return try gitService.status(repositoryRoot: repositoryRoot)
                .map { GitFileItem(path: $0.path, stagedChar: $0.stagedStatus, unstagedChar: $0.unstagedStatus) }
                .sorted { $0.filename < $1.filename }
        } catch {
            DispatchQueue.main.async {
                self.error = "Failed to get git status: \(error.localizedDescription)"
            }
        }

        return []
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
        var command: [String]

        // Handle different file states
        if file.unstagedStatus == .untracked {
            // For untracked files, just remove them
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let fullPath = self._repositoryPath + "/" + file.path
                do {
                    try FileManager.default.removeItem(atPath: fullPath)
                    DispatchQueue.main.async {
                        self.refreshStatus()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.error = "Failed to remove file: \(error.localizedDescription)"
                    }
                }
            }
            return
        } else if file.isStaged {
            // For staged files, restore from HEAD (discards both staged and unstaged changes)
            command = ["checkout", "HEAD", "--", file.path]
        } else {
            // For unstaged files, restore from index (discards unstaged changes only)
            command = ["checkout", "--", file.path]
        }

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
            do {
                let result = try self.gitService.run(repositoryRoot: self._repositoryPath, arguments: arguments)
                let success = result.succeeded
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
            do {
                let result = try self.gitService.run(repositoryRoot: self._repositoryPath, arguments: arguments)
                let success = result.succeeded

                DispatchQueue.main.async {
                    completion(success, result.stdout, result.stderr)
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
