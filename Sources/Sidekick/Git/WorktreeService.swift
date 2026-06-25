import Foundation

/// Creates (or reuses) git worktrees so `sidekick-ctl pane split --worktree
/// <branch>` can open a pane on an isolated checkout. Parallel coding agents
/// can then fan out without clobbering each other's working tree — the workflow
/// the bundled SKILL.md already asks agents to do by hand.
struct WorktreeService {
    enum WorktreeError: Error, Equatable {
        case notAGitRepository
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
        var currentPath: String?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                if ref == "refs/heads/\(branch)" {
                    return currentPath
                }
            } else if line.isEmpty {
                currentPath = nil
            }
        }
        return nil
    }

    private static func sanitize(_ branch: String) -> String {
        branch.map { $0 == "/" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }
}
