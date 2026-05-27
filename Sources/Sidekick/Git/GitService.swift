import Foundation

struct GitStatusEntry: Equatable {
    let path: String
    let stagedStatus: Character
    let unstagedStatus: Character

    var isUntracked: Bool {
        stagedStatus == "?" && unstagedStatus == "?"
    }

    var hasStagedChanges: Bool {
        stagedStatus != " " && stagedStatus != "?"
    }

    var hasUnstagedChanges: Bool {
        unstagedStatus != " " && unstagedStatus != "?"
    }
}

final class GitService {
    private let runner: ProcessRunning

    init(runner: ProcessRunning = ProcessRunner.shared) {
        self.runner = runner
    }

    func repositoryRoot(from path: String) -> String? {
        WorkspaceResolver.gitRoot(from: path, runner: runner)
    }

    func currentBranch(repositoryRoot: String) throws -> String {
        let result = try runGit(
            ["symbolic-ref", "--short", "HEAD"],
            repositoryRoot: repositoryRoot,
            allowOptionalLocks: false
        )

        if result.succeeded {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let detached = try runGit(
            ["rev-parse", "--short", "HEAD"],
            repositoryRoot: repositoryRoot,
            allowOptionalLocks: false
        )

        if detached.succeeded {
            return "(\(detached.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))"
        }

        return "unknown"
    }

    func status(repositoryRoot: String) throws -> [GitStatusEntry] {
        let result = try runGit(["status", "--porcelain"], repositoryRoot: repositoryRoot, allowOptionalLocks: false)
        guard result.succeeded else { return [] }
        return Self.parseStatusOutput(result.stdout)
    }

    func status(forRelativePath relativePath: String, repositoryRoot: String) throws -> GitStatusEntry? {
        let result = try runGit(
            ["status", "--porcelain", "--", relativePath],
            repositoryRoot: repositoryRoot,
            allowOptionalLocks: false
        )

        guard result.succeeded else { return nil }
        return Self.parseStatusOutput(result.stdout).first
    }

    func diff(relativePath: String, repositoryRoot: String) throws -> String {
        guard let entry = try status(forRelativePath: relativePath, repositoryRoot: repositoryRoot) else {
            return "No changes"
        }

        if entry.isUntracked {
            return try untrackedFileDiff(relativePath: relativePath, repositoryRoot: repositoryRoot)
        }

        var output = ""
        if entry.hasStagedChanges {
            output += try gitOutput(["diff", "--cached", "--", relativePath], repositoryRoot: repositoryRoot)
        }

        if entry.hasUnstagedChanges {
            if !output.isEmpty {
                output += "\n"
            }
            output += try gitOutput(["diff", "--", relativePath], repositoryRoot: repositoryRoot)
        }

        return output.isEmpty ? "No changes" : output
    }

    func stage(path: String, repositoryRoot: String) throws -> Bool {
        try runGit(["add", path], repositoryRoot: repositoryRoot).succeeded
    }

    func unstage(path: String, repositoryRoot: String) throws -> Bool {
        try runGit(["reset", "HEAD", path], repositoryRoot: repositoryRoot).succeeded
    }

    func run(repositoryRoot: String, arguments: [String]) throws -> ProcessResult {
        try runGit(arguments, repositoryRoot: repositoryRoot)
    }

    static func parseStatusOutput(_ output: String) -> [GitStatusEntry] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseStatusLine(String($0)) }
    }

    static func parseStatusLine(_ line: String) -> GitStatusEntry? {
        guard line.count >= 4 else { return nil }

        let stagedStatus = line[line.startIndex]
        let unstagedStatus = line[line.index(after: line.startIndex)]
        let pathStart = line.index(line.startIndex, offsetBy: 3)
        let rawPath = String(line[pathStart...])
        let path = rawPath.components(separatedBy: " -> ").last ?? rawPath

        return GitStatusEntry(
            path: path,
            stagedStatus: stagedStatus,
            unstagedStatus: unstagedStatus
        )
    }

    private func gitOutput(_ arguments: [String], repositoryRoot: String) throws -> String {
        try runGit(arguments, repositoryRoot: repositoryRoot).stdout
    }

    private func runGit(
        _ arguments: [String],
        repositoryRoot: String,
        allowOptionalLocks: Bool = true
    ) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        if !allowOptionalLocks {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }

        return try runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repositoryRoot] + arguments,
            currentDirectoryURL: URL(fileURLWithPath: repositoryRoot),
            environment: environment
        )
    }

    private func untrackedFileDiff(relativePath: String, repositoryRoot: String) throws -> String {
        let filePath = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(relativePath).path
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var diffOutput = "diff --git a/\(relativePath) b/\(relativePath)\n"
        diffOutput += "new file\n"
        diffOutput += "--- /dev/null\n"
        diffOutput += "+++ b/\(relativePath)\n"
        diffOutput += "@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines {
            diffOutput += "+\(line)\n"
        }

        return diffOutput
    }
}
