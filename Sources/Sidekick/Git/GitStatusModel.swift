import Foundation
import Cocoa

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
        // git porcelain reports an untracked *directory* with a trailing slash
        // (e.g. "build/"). Discarding such an entry removes the whole subtree, so
        // the UI must warn accordingly rather than treating it as a single file.
        self.isDirectory = path.hasSuffix("/")
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

class GitStatusModel {
    /// Fired on the main actor after a batch of state changes settles (a status
    /// refresh, a repository switch, or a commit clearing the message). The git
    /// panel reads the properties below and repaints. A plain callback rather
    /// than Combine `@Published`, matching the app's dominant model→view idiom
    /// (`RepositoryWatcher.onChange`, `ConfigWatcher.onChange`). Set before use.
    var onChange: (() -> Void)?

    var files: [GitFileItem] = []
    var currentBranch: String = ""
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var isClean: Bool = true
    var commitMessage: String = ""
    var isLoading: Bool = false
    var error: String?

    private var _repositoryPath: String = ""
    // Fallback poll for changes FSEvents can't see (e.g. edits over NFS).
    private let fallbackRefreshInterval: TimeInterval = 30.0
    // How long to keep ignoring watcher events after an app-owned git mutation
    // finishes, so the mutation's own FSEvents (delivered up to the stream's
    // latency late) don't trigger a redundant refresh on top of the explicit one.
    private let watcherSettleDelay: TimeInterval = 0.6
    // Set on the main actor; torn down in the nonisolated deinit at end-of-life.
    nonisolated(unsafe) private var refreshTimer: Timer?
    // The app's shared FSEvents change detector — see RepositoryWatcher.
    private let watcher = RepositoryWatcher()
    private let gitService: GitService
    private var refreshGeneration: Int = 0
    // Coalesce overlapping refreshes: while a background git query is running, a
    // new request just sets `refreshAgainWhenDone` instead of spawning another
    // set of `git status`/`rev-list` processes whose results the generation guard
    // would only throw away. The trailing request runs once the current finishes.
    private var refreshInFlight = false
    private var refreshAgainWhenDone = false
    // Number of in-flight git mutations the app itself started. While > 0 (and
    // for a short settle window after), watcher-driven refreshes are suppressed:
    // those operations refresh explicitly when they finish, so reacting to their
    // `.git` writes is redundant work that lands on the main thread mid-typing.
    private var pendingMutationCount: Int = 0
    private var watcherSuppressed: Bool = false
    private var unsuppressWork: DispatchWorkItem?

    init(gitService: GitService = GitService()) {
        self.gitService = gitService
        // App-owned mutations (stage/commit/checkout/…) refresh themselves when
        // they complete; ignore the `.git` churn they generate in the meantime.
        watcher.onChange = { [weak self] in
            guard let self, !self.watcherSuppressed else { return }
            self.refreshStatus()
        }
    }

    var repositoryPath: String {
        return _repositoryPath
    }

    /// Notify the observing panel that the published state above changed. Called
    /// on the main actor at the end of each batch update.
    private func notifyChanged() {
        onChange?()
    }

    // Tear down the fallback timer directly: it's nonisolated(unsafe) so this
    // nonisolated deinit can reach it without hopping to the main actor (which a
    // deinit can't await). The FSEvents stream is owned by `watcher`, whose own
    // deinit stops it when this model releases its last reference.
    deinit {
        refreshTimer?.invalidate()
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
            notifyChanged()
            return
        }

        _repositoryPath = repositoryRoot
        refreshStatus(force: true)
        startAutoRefresh()
        watcher.start(root: repositoryRoot)
    }

    func refreshStatus(force: Bool = false) {
        guard !_repositoryPath.isEmpty else { return }
        guard force || !isLoading else { return }

        // A query is already running — fold this request into a single trailing
        // refresh instead of launching a second, redundant set of git processes.
        if refreshInFlight {
            refreshAgainWhenDone = true
            return
        }

        refreshInFlight = true
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
                    self.refreshInFlight = false
                    defer {
                        // Service a request that arrived while this one was running.
                        if self.refreshAgainWhenDone {
                            self.refreshAgainWhenDone = false
                            self.refreshStatus(force: true)
                        }
                    }

                    guard self.refreshGeneration == generation,
                          self._repositoryPath == repositoryPath else { return }

                    self.currentBranch = branch
                    self.aheadCount = counts.ahead
                    self.behindCount = counts.behind
                    // nil means the status query failed — keep the prior file
                    // list rather than clearing to a false "clean" state.
                    if let statusItems {
                        self.files = statusItems
                        self.isClean = statusItems.isEmpty
                    }
                    self.isLoading = false
                    self.notifyChanged()
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
        watcher.stop()
    }

    // These run on the background queue from refreshStatus. They touch only the
    // Sendable `gitService` (an immutable let) and their arguments, so they're
    // nonisolated; results are folded back into the observable state on the
    // main actor by the caller.
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

    /// Returns nil on a git failure (distinct from an empty array, which means a
    /// genuinely clean tree) so the caller can keep the last-known file list
    /// instead of flashing the panel to "Working tree clean" on a transient error.
    private nonisolated func getGitStatus(repositoryRoot: String) -> [GitFileItem]? {
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

        return nil
    }

    // MARK: - Git Operations

    func stageFile(_ file: GitFileItem) {
        // `--` so a path beginning with "-" can't be parsed as a flag.
        executeGitCommand(["add", "--", file.path]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func unstageFile(_ file: GitFileItem) {
        executeGitCommand(["reset", "HEAD", "--", file.path]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func stageAllFiles() {
        executeGitCommand(["add", "."]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
            }
        }
    }

    func unstageAllFiles() {
        executeGitCommand(["reset", "HEAD"]) { [weak self] success in
            if success {
                self?.refreshStatus(force: true)
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
                self?.notifyChanged()
                self?.refreshStatus(force: true)
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
            // For untracked entries let git remove them. `git clean -fd` deletes
            // untracked files and directories but deliberately leaves nested git
            // repositories intact (removing those needs -ff) — unlike a blind
            // FileManager.removeItem, which would wipe a nested repo's contents
            // too. The trailing-slash path from porcelain works as a clean arg.
            executeGitCommand(["clean", "-fd", "--", file.path]) { [weak self] success in
                if success {
                    self?.refreshStatus(force: true)
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
                self?.refreshStatus(force: true)
            }
        }
    }

    func pull(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["pull"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to pull changes")
            }
        }
    }

    func push(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["push"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to push changes")
            }
        }
    }

    func fetch(completion: @escaping @MainActor (Bool, String?) -> Void) {
        executeGitCommandWithOutput(["fetch"]) { [weak self] success, output, errorOutput in
            if success {
                self?.refreshStatus(force: true)
                completion(true, output)
            } else {
                completion(false, errorOutput ?? "Failed to fetch changes")
            }
        }
    }

    private func executeGitCommand(_ arguments: [String], completion: @escaping @MainActor (Bool) -> Void) {
        let service = gitService
        let repoPath = _repositoryPath
        beginAppMutation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        completion(success)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
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
        beginAppMutation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.run(repositoryRoot: repoPath, arguments: arguments)
                let success = result.succeeded

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        completion(success, result.stdout, result.stderr)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.endAppMutation()
                        self?.error = "Failed to execute git command: \(message)"
                        completion(false, nil, message)
                    }
                }
            }
        }
    }

    // MARK: - App-owned mutation suppression

    private func beginAppMutation() {
        pendingMutationCount += 1
        watcherSuppressed = true
        unsuppressWork?.cancel()
        unsuppressWork = nil
    }

    private func endAppMutation() {
        pendingMutationCount = max(0, pendingMutationCount - 1)
        guard pendingMutationCount == 0 else { return }
        // Keep suppressing briefly so trailing FSEvents from the finished
        // mutation are swallowed; the caller's explicit refresh covers the update.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.watcherSuppressed = false }
        }
        unsuppressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + watcherSettleDelay, execute: work)
    }
}
