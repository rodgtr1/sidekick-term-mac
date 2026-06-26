import Foundation
import Cocoa
import CoreServices

nonisolated enum GitFileStatus: String, CaseIterable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
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
        case .unmerged: return "Conflict"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .unmodified: return ""
        }
    }

    // Reads the (main-actor) theme palette, so it stays main-isolated even
    // though the rest of the enum is nonisolated for background construction.
    @MainActor var color: NSColor {
        switch self {
        case .modified: return AppTheme.peach
        case .added: return AppTheme.success
        case .deleted: return AppTheme.error
        case .renamed: return AppTheme.accent
        case .copied: return AppTheme.accent
        case .unmerged: return AppTheme.warning
        case .untracked: return AppTheme.primaryText
        case .ignored: return AppTheme.mutedText
        case .unmodified: return AppTheme.primaryText
        }
    }
}

nonisolated struct GitFileItem: Sendable {
    let path: String
    let filename: String
    let stagedStatus: GitFileStatus
    let unstagedStatus: GitFileStatus
    let isStaged: Bool
    let isConflicted: Bool
    let isDirectory: Bool

    init(path: String, stagedChar: Character, unstagedChar: Character) {
        self.path = path
        self.filename = URL(fileURLWithPath: path).lastPathComponent
        self.stagedStatus = GitFileStatus(rawValue: String(stagedChar)) ?? .unmodified
        self.unstagedStatus = GitFileStatus(rawValue: String(unstagedChar)) ?? .unmodified
        self.isConflicted = GitStatusEntry(path: path, stagedStatus: stagedChar, unstagedStatus: unstagedChar).isConflicted
        // A conflicted file isn't "staged" in any useful sense; the action
        // that makes sense for it is Stage, which marks it resolved.
        self.isStaged = !isConflicted && stagedChar != " " && stagedChar != "?"
        self.isDirectory = false // We'll enhance this later if needed
    }

    var displayStatus: GitFileStatus {
        if isConflicted {
            return .unmerged
        }
        if stagedStatus != .unmodified {
            return stagedStatus
        }
        return unstagedStatus
    }
}

class GitStatusModel: ObservableObject {
    @Published var files: [GitFileItem] = []
    @Published var currentBranch: String = ""
    @Published var aheadCount: Int = 0
    @Published var behindCount: Int = 0
    @Published var isClean: Bool = true
    @Published var commitMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?

    private var _repositoryPath: String = ""
    // Fallback poll for changes FSEvents can't see (e.g. edits over NFS).
    private let fallbackRefreshInterval: TimeInterval = 30.0
    private let refreshDebounce: TimeInterval = 0.3
    // Set on the main actor; torn down in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    nonisolated(unsafe) private var pendingRefresh: DispatchWorkItem?
    private let gitService: GitService
    private var refreshGeneration: Int = 0

    init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    var repositoryPath: String {
        return _repositoryPath
    }

    // Tear down the timer and FSEvents stream directly: the resource handles are
    // nonisolated(unsafe) so this nonisolated deinit can reach them without
    // hopping to the main actor (which a deinit can't await).
    deinit {
        refreshTimer?.invalidate()
        pendingRefresh?.cancel()
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

    func setRepositoryPath(_ path: String) {
        guard let repositoryRoot = gitService.repositoryRoot(from: path) else {
            stopAutoRefresh()
            refreshGeneration += 1
            _repositoryPath = ""
            currentBranch = ""
            aheadCount = 0
            behindCount = 0
            files = []
            isClean = true
            isLoading = false
            error = nil
            return
        }

        _repositoryPath = repositoryRoot
        refreshStatus(force: true)
        startAutoRefresh()
        startWatchingRepository(repositoryRoot)
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
            let counts = self.getAheadBehindCounts(repositoryRoot: repositoryPath)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.refreshGeneration == generation,
                          self._repositoryPath == repositoryPath else { return }

                    self.currentBranch = branch
                    self.aheadCount = counts.ahead
                    self.behindCount = counts.behind
                    self.files = statusItems
                    self.isClean = statusItems.isEmpty
                    self.isLoading = false
                }
            }
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: fallbackRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        stopWatchingRepository()
    }

    // MARK: - File system watching

    private func startWatchingRepository(_ repositoryRoot: String) {
        stopWatchingRepository()

        // The stream is dispatched to the main queue (below), so the callback
        // already runs on the main actor — assert that to reach the model.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let model = Unmanaged<GitStatusModel>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { model.scheduleDebouncedRefresh() }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [repositoryRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else {
            Log.error("GitStatusModel: Failed to create FSEvents stream for \(repositoryRoot)", category: "git")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatchingRepository() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func scheduleDebouncedRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDebounce, execute: work)
    }

    // These run on the background queue from refreshStatus. They touch only the
    // Sendable `gitService` (an immutable let) and their arguments, so they're
    // nonisolated; results are folded back into @Published state on the main
    // actor by the caller.
    private nonisolated func getCurrentBranch(repositoryRoot: String) -> String {
        do {
            return try gitService.currentBranch(repositoryRoot: repositoryRoot)
        } catch {
            return "unknown"
        }
    }

    private nonisolated func getAheadBehindCounts(repositoryRoot: String) -> (ahead: Int, behind: Int) {
        ((try? gitService.aheadBehindCounts(repositoryRoot: repositoryRoot)) ?? nil) ?? (ahead: 0, behind: 0)
    }

    private nonisolated func getGitStatus(repositoryRoot: String) -> [GitFileItem] {
        do {
            return try gitService.status(repositoryRoot: repositoryRoot)
                .map { GitFileItem(path: $0.path, stagedChar: $0.stagedStatus, unstagedChar: $0.unstagedStatus) }
                .sorted { $0.filename < $1.filename }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.error = "Failed to get git status: \(message)" }
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

    func commit(message: String, completion: @escaping @MainActor (Bool, String?) -> Void) {
        guard !message.isEmpty else {
            completion(false, "Commit message cannot be empty")
            return
        }

        executeGitCommand(["commit", "-m", message]) { [weak self] success in
            if success {
                self?.commitMessage = ""
                self?.refreshStatus()
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
            let fullPath = _repositoryPath + "/" + file.path
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try FileManager.default.removeItem(atPath: fullPath)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.refreshStatus() }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.error = "Failed to remove file: \(message)" }
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

    func pull(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["pull"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus()
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to pull changes")
            }
        }
    }

    func push(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["push"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus()
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to push changes")
            }
        }
    }

    func fetch(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["fetch"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus()
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to fetch changes")
            }
        }
    }

    private func executeGitCommand(_ arguments: [String], completion: @escaping @MainActor (Bool) -> Void) {
        let service = gitService
        let repoPath = _repositoryPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(success) }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.error = "Failed to execute git command: \(message)"
                        completion(false)
                    }
                }
            }
        }
    }

    private func executeGitCommandWithOutput(_ arguments: [String], completion: @escaping @MainActor (Bool, String?, String?) -> Void) {
        let service = gitService
        let repoPath = _repositoryPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded

                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(success, result.stdout, result.stderr) }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.error = "Failed to execute git command: \(message)"
                        completion(false, nil, message)
                    }
                }
            }
        }
    }
}
