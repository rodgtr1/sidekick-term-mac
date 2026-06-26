import Foundation

/// One entry from `git worktree list --porcelain`. A pure value type so the
/// Worktrees panel and tests can reason over it without shelling out.
struct GitWorktree: Equatable {
    /// Absolute checkout path.
    let path: String
    /// Short branch name (`feature/x`), or nil when detached or bare.
    let branch: String?
    /// HEAD commit sha, when reported.
    let head: String?
    let isDetached: Bool
    let isLocked: Bool
    let isBare: Bool
}

/// Creates (or reuses) git worktrees so `sidekick-ctl pane split --worktree
/// <branch>` can open a pane on an isolated checkout. Parallel coding agents
/// can then fan out without clobbering each other's working tree — the workflow
/// the bundled SKILL.md already asks agents to do by hand.
struct WorktreeService {
    enum WorktreeError: Error, Equatable {
        case notAGitRepository
        case noWorktreeForBranch(String)
        case gitFailed(String)
    }

    private let git: GitService

    init(git: GitService = GitService()) {
        self.git = git
    }

    /// Ensures a worktree for `branch` exists for the repository containing
    /// `directory`, and returns its absolute path. Idempotent: a branch that
    /// already has a worktree returns that worktree rather than failing, so a
    /// supervisor can re-issue the same split safely.
    func ensureWorktree(forBranch branch: String, directory: String) throws -> String {
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        // Reuse an existing worktree for this branch if there is one.
        let listing = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        if listing.succeeded,
           let existing = Self.worktreePath(forBranch: branch, inPorcelain: listing.stdout) {
            return existing
        }

        let path = Self.worktreePath(forBranch: branch, repoRoot: repoRoot)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // `-b` creates the branch; if it already exists (just without a
        // worktree), check it out into the new worktree instead.
        let exists = try git.run(
            repositoryRoot: repoRoot,
            arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]
        ).succeeded
        let arguments = exists
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path]

        let result = try git.run(repositoryRoot: repoRoot, arguments: arguments)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree add failed" : message)
        }
        return path
    }

    /// Removes the worktree registered for `branch` in the repo containing
    /// `directory`, and returns the path it removed. Refuses a dirty or locked
    /// worktree unless `force` is set, so a teardown can't silently discard an
    /// agent's uncommitted work. A branch with no worktree throws
    /// `noWorktreeForBranch` rather than failing opaquely.
    func removeWorktree(forBranch branch: String, directory: String, force: Bool = false) throws -> String {
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        let listing = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard listing.succeeded,
              let path = Self.worktreePath(forBranch: branch, inPorcelain: listing.stdout) else {
            throw WorktreeError.noWorktreeForBranch(branch)
        }

        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path)

        let result = try git.run(repositoryRoot: repoRoot, arguments: arguments)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree remove failed" : message)
        }
        return path
    }

    /// Prunes stale worktree admin entries — bookkeeping for worktrees whose
    /// directories were deleted by hand — and returns git's summary (empty when
    /// there was nothing to prune).
    func pruneWorktrees(directory: String) throws -> String {
        guard let repoRoot = git.repositoryRoot(from: directory) else {
            throw WorktreeError.notAGitRepository
        }

        let result = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "prune", "-v"])
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(message.isEmpty ? "git worktree prune failed" : message)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every worktree registered for the repository containing `directory`, in
    /// git's own order (the primary checkout first). Returns an empty list when
    /// the directory isn't in a git repo or git fails, so the panel can render an
    /// empty state rather than throwing for the common "not a repo" case.
    func listWorktrees(repoRoot: String) throws -> [GitWorktree] {
        let result = try git.run(repositoryRoot: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard result.succeeded else { return [] }
        return Self.parseWorktrees(porcelain: result.stdout)
    }

    /// Parses `git worktree list --porcelain` into records. Each record is a run
    /// of `key value` lines (`worktree`, `HEAD`, `branch`, `detached`, `bare`,
    /// `locked`) terminated by a blank line.
    static func parseWorktrees(porcelain output: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var path: String?
        var branch: String?
        var head: String?
        var isDetached = false
        var isLocked = false
        var isBare = false

        func flush() {
            if let path {
                worktrees.append(GitWorktree(
                    path: path, branch: branch, head: head,
                    isDetached: isDetached, isLocked: isLocked, isBare: isBare
                ))
            }
            path = nil; branch = nil; head = nil
            isDetached = false; isLocked = false; isBare = false
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                flush()   // start of a new record; emit the previous one
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                isDetached = true
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
            } else if line.isEmpty {
                flush()
            }
        }
        flush()   // last record may not be followed by a blank line
        return worktrees
    }

    /// Path for a new worktree: a sibling `<repo>.worktrees/<branch>` directory,
    /// keeping checkouts out of the main tree while staying easy to find. Branch
    /// separators become dashes so `feature/x` is one directory, not nested.
    static func worktreePath(forBranch branch: String, repoRoot: String) -> String {
        let repoURL = URL(fileURLWithPath: repoRoot)
        let container = repoURL.deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent).worktrees")
        return container.appendingPathComponent(sanitize(branch)).path
    }

    /// Finds the worktree registered for `branch` in `git worktree list
    /// --porcelain` output, or nil if the branch has no worktree.
    static func worktreePath(forBranch branch: String, inPorcelain output: String) -> String? {
        parseWorktrees(porcelain: output).first { $0.branch == branch }?.path
    }

    private static func sanitize(_ branch: String) -> String {
        branch.map { $0 == "/" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }
}
