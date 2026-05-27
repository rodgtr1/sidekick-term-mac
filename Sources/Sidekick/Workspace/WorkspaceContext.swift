import Foundation

struct WorkspaceContext: Equatable {
    let workingDirectory: String
    let repositoryRoot: String?

    var displayRoot: String {
        repositoryRoot ?? workingDirectory
    }

    init(workingDirectory: String, repositoryRoot: String? = nil) {
        self.workingDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        self.repositoryRoot = repositoryRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    func relativePath(for absolutePath: String) -> String {
        let absolute = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let root = URL(fileURLWithPath: displayRoot).standardizedFileURL.path

        guard absolute == root || absolute.hasPrefix(root + "/") else {
            return absolute
        }

        if absolute == root {
            return URL(fileURLWithPath: absolute).lastPathComponent
        }

        return String(absolute.dropFirst(root.count + 1))
    }

    func absolutePath(forRepoPath path: String) -> String {
        let root = repositoryRoot ?? workingDirectory
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return URL(fileURLWithPath: root).appendingPathComponent(path).standardizedFileURL.path
    }
}

enum WorkspaceResolver {
    static func gitRoot(from path: String, runner: ProcessRunning = ProcessRunner.shared) -> String? {
        do {
            let result = try runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "rev-parse", "--show-toplevel"]
            )

            guard result.succeeded else { return nil }
            let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return root.isEmpty ? nil : URL(fileURLWithPath: root).standardizedFileURL.path
        } catch {
            return nil
        }
    }

    static func context(for path: String, runner: ProcessRunning = ProcessRunner.shared) -> WorkspaceContext {
        WorkspaceContext(
            workingDirectory: path,
            repositoryRoot: gitRoot(from: path, runner: runner)
        )
    }
}
