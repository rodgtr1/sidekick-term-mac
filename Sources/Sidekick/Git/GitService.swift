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

    /// Unmerged entry from a conflicted merge/rebase/cherry-pick:
    /// UU, AU, UA, DU, UD, AA or DD in porcelain output.
    var isConflicted: Bool {
        stagedStatus == "U" || unstagedStatus == "U"
            || (stagedStatus == "A" && unstagedStatus == "A")
            || (stagedStatus == "D" && unstagedStatus == "D")
    }
}

/// One-glance dirtiness of a working tree, for the Worktrees panel. `conflicted`
/// counts files in a merge-conflict state; `changed` counts every other
/// modified/untracked file. `clean` means no entries at all.
struct WorktreeStatusSummary: Equatable {
    let changed: Int
    let conflicted: Int

    var clean: Bool { changed == 0 && conflicted == 0 }

    static let empty = WorktreeStatusSummary(changed: 0, conflicted: 0)

    /// Derives the summary from porcelain status entries: conflicted files are
    /// counted separately, everything else rolls into `changed`.
    init(entries: [GitStatusEntry]) {
        var changed = 0
        var conflicted = 0
        for entry in entries {
            if entry.isConflicted { conflicted += 1 } else { changed += 1 }
        }
        self.changed = changed
        self.conflicted = conflicted
    }

    init(changed: Int, conflicted: Int) {
        self.changed = changed
        self.conflicted = conflicted
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

    /// Commits ahead of / behind the current branch's upstream.
    /// Returns nil when no upstream is configured (e.g. branch never pushed).
    func aheadBehindCounts(repositoryRoot: String) throws -> (ahead: Int, behind: Int)? {
        let result = try runGit(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            repositoryRoot: repositoryRoot,
            allowOptionalLocks: false
        )

        guard result.succeeded else { return nil }

        let parts = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else { return nil }

        return (ahead: ahead, behind: behind)
    }

    func status(repositoryRoot: String) throws -> [GitStatusEntry] {
        // --untracked-files=all lists each untracked file individually instead
        // of collapsing a fully-untracked directory into a single "?? dir/"
        // entry, so files like .claude/skills/.../SKILL.md show up the way they
        // do in Zed. (Nested git repos such as content/15.x still come back as
        // a single "?? content/15.x/" directory entry; git won't recurse them.)
        let result = try runGit(
            ["status", "--porcelain", "--untracked-files=all"],
            repositoryRoot: repositoryRoot,
            allowOptionalLocks: false
        )
        guard result.succeeded else { return [] }
        return Self.parseStatusOutput(result.stdout)
    }

    /// Dirty/clean/conflicted summary for a worktree, derived from the same
    /// porcelain status the file list uses. A worktree path is a valid
    /// repository root for `git status`, so the panel passes the checkout path
    /// straight in.
    func statusSummary(repositoryRoot: String) throws -> WorktreeStatusSummary {
        WorktreeStatusSummary(entries: try status(repositoryRoot: repositoryRoot))
    }

    func status(forRelativePath relativePath: String, repositoryRoot: String) throws -> GitStatusEntry? {
        let result = try runGit(
            ["status", "--porcelain", "--untracked-files=all", "--", relativePath],
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

        if entry.isConflicted {
            return conflictedFileDiff(relativePath: relativePath, repositoryRoot: repositoryRoot)
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

    /// Returns combined (staged + unstaged) diffs keyed by relative path,
    /// using two repo-wide git invocations instead of several per file.
    func diffsByPath(for entries: [GitStatusEntry], repositoryRoot: String) throws -> [String: String] {
        let stagedByPath = Self.splitDiffByFile(try gitOutput(["diff", "--cached"], repositoryRoot: repositoryRoot))
        let unstagedByPath = Self.splitDiffByFile(try gitOutput(["diff"], repositoryRoot: repositoryRoot))

        var combined: [String: String] = [:]
        for entry in entries {
            if entry.isUntracked {
                combined[entry.path] = (try? untrackedFileDiff(relativePath: entry.path, repositoryRoot: repositoryRoot)) ?? "No changes"
                continue
            }

            if entry.isConflicted {
                combined[entry.path] = conflictedFileDiff(relativePath: entry.path, repositoryRoot: repositoryRoot)
                continue
            }

            var output = stagedByPath[entry.path] ?? ""
            if let unstagedDiff = unstagedByPath[entry.path] {
                if !output.isEmpty {
                    output += "\n"
                }
                output += unstagedDiff
            }
            combined[entry.path] = output.isEmpty ? "No changes" : output
        }
        return combined
    }

    static func splitDiffByFile(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            if let path = currentPath, !currentLines.isEmpty {
                result[path, default: ""] += currentLines.joined(separator: "\n")
            }
            currentLines = []
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = parsePathFromDiffHeader(line)
            }
            // Unmerged paths emit a bare "* Unmerged path <file>" line with no
            // diff --git header; skip it so it doesn't get appended to the
            // previous file's diff.
            if line.hasPrefix("* Unmerged path ") {
                continue
            }
            if currentPath != nil {
                currentLines.append(line)
            }
        }
        flush()
        return result
    }

    static func parsePathFromDiffHeader(_ line: String) -> String? {
        // Quoted form: diff --git "a/pa th" "b/pa th"
        if let quotedRange = line.range(of: "\"b/", options: .backwards) {
            let tail = line[quotedRange.upperBound...]
            if let closingQuote = tail.lastIndex(of: "\"") {
                return String(tail[..<closingQuote])
            }
        }
        // Plain form: diff --git a/path b/path
        if let plainRange = line.range(of: " b/", options: .backwards) {
            return String(line[plainRange.upperBound...])
        }
        return nil
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
        // Rename/copy entries are "old -> new"; show the destination.
        let destination = rawPath.components(separatedBy: " -> ").last ?? rawPath

        return GitStatusEntry(
            path: unquoteGitPath(destination),
            stagedStatus: stagedStatus,
            unstagedStatus: unstagedStatus
        )
    }

    /// Git quotes paths containing special characters in C style:
    /// `"name \"x\".txt"` with `\t`, `\n`, `\\`, `\"` and `\ooo` octal
    /// escapes encoding UTF-8 bytes.
    static func unquoteGitPath(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }

        let inner = Array(raw.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < inner.count {
            let byte = inner[i]
            guard byte == UInt8(ascii: "\\"), i + 1 < inner.count else {
                bytes.append(byte)
                i += 1
                continue
            }

            let escape = inner[i + 1]
            switch escape {
            case UInt8(ascii: "t"):
                bytes.append(0x09)
                i += 2
            case UInt8(ascii: "n"):
                bytes.append(0x0A)
                i += 2
            case UInt8(ascii: "r"):
                bytes.append(0x0D)
                i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var digits = 0
                var j = i + 1
                while j < inner.count, digits < 3,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[j]) {
                    value = value * 8 + Int(inner[j] - UInt8(ascii: "0"))
                    j += 1
                    digits += 1
                }
                bytes.append(UInt8(value & 0xFF))
                i = j
            default:
                // Covers \" and \\ along with anything unrecognized.
                bytes.append(escape)
                i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
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

    /// Unmerged paths can't be diffed against the index (`git diff --cached`
    /// prints "* Unmerged path" and `git diff` emits combined-diff format),
    /// so show the working-tree contents, which carry the <<<<<<< / =======
    /// / >>>>>>> conflict markers the user needs to resolve.
    private func conflictedFileDiff(relativePath: String, repositoryRoot: String) -> String {
        let filePath = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(relativePath).path
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return "Conflicted: file not present in working tree"
        }
        return Self.conflictMarkerDiff(relativePath: relativePath, content: content)
    }

    static func conflictMarkerDiff(relativePath: String, content: String, contextLines: Int = 3) -> String {
        var lines = content.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }

        var diffOutput = "diff --git a/\(relativePath) b/\(relativePath)\n"
        diffOutput += "conflict\n"
        diffOutput += "--- a/\(relativePath)\n"
        diffOutput += "+++ b/\(relativePath)\n"

        // Only emit the regions around conflict markers (plus a few context
        // lines) instead of the whole file, so a conflict deep in a large file
        // isn't pushed past the diff view's height cap and hidden.
        let markerIndices = lines.indices.filter { index in
            let line = lines[index]
            return line.hasPrefix("<<<<<<<") || line.hasPrefix("|||||||")
                || line.hasPrefix("=======") || line.hasPrefix(">>>>>>>")
        }

        guard !markerIndices.isEmpty else {
            diffOutput += "@@ -1,\(lines.count) +1,\(lines.count) @@\n"
            for line in lines {
                diffOutput += " \(line)\n"
            }
            return diffOutput
        }

        var regions: [(start: Int, end: Int)] = []
        for index in markerIndices {
            let start = max(0, index - contextLines)
            let end = min(lines.count - 1, index + contextLines)
            if let last = regions.last, start <= last.end + 1 {
                regions[regions.count - 1].end = max(last.end, end)
            } else {
                regions.append((start, end))
            }
        }

        for region in regions {
            let count = region.end - region.start + 1
            diffOutput += "@@ -\(region.start + 1),\(count) +\(region.start + 1),\(count) @@\n"
            for index in region.start...region.end {
                diffOutput += " \(lines[index])\n"
            }
        }
        return diffOutput
    }

    private func untrackedFileDiff(relativePath: String, repositoryRoot: String) throws -> String {
        let trimmedPath = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        let filePath = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(trimmedPath).path

        // A fully-untracked directory (e.g. a nested git repo git won't recurse
        // into) arrives as a single "?? dir/" entry. There's no file to read, so
        // surface a note instead of throwing and falling back to a blank
        // "No changes" the user can't interpret.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            var diffOutput = "diff --git a/\(trimmedPath) b/\(trimmedPath)\n"
            diffOutput += "new file\n"
            diffOutput += "--- /dev/null\n"
            diffOutput += "+++ b/\(trimmedPath)\n"
            diffOutput += "@@ -0,0 +1,1 @@\n"
            diffOutput += "+(untracked directory — likely a nested repository; open it to view its contents)\n"
            return diffOutput
        }

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var diffOutput = "diff --git a/\(trimmedPath) b/\(trimmedPath)\n"
        diffOutput += "new file\n"
        diffOutput += "--- /dev/null\n"
        diffOutput += "+++ b/\(trimmedPath)\n"
        diffOutput += "@@ -0,0 +1,\(lines.count) @@\n"
        for line in lines {
            diffOutput += "+\(line)\n"
        }

        return diffOutput
    }
}
