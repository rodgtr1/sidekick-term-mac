import Foundation

/// A lock-guarded `Data` holder so a background pipe-drain closure can publish
/// its result without mutating a captured `var` (rejected by strict concurrency).
private nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock(); defer { lock.unlock() }
        data = newValue
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

nonisolated struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool {
        terminationStatus == 0
    }
}

nonisolated enum ProcessRunnerError: Error {
    case executableNotFound(String)
}

nonisolated protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?
    ) throws -> ProcessResult
}

nonisolated extension ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        try run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }
}

// Stateless and called from background git/worktree work, so it opts out of the
// module's default main-actor isolation and is safely Sendable.
nonisolated final class ProcessRunner: ProcessRunning {
    static let shared = ProcessRunner()

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        task.currentDirectoryURL = currentDirectoryURL
        task.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        // The two pipes are drained on separate background queues to avoid the
        // 64KB pipe-buffer deadlock, so each closure writes into its own
        // reference-typed box rather than mutating a captured `var` (which strict
        // concurrency rejects even though `readGroup.wait()` orders the reads).
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readGroup = DispatchGroup()

        try task.run()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        task.waitUntilExit()
        readGroup.wait()

        return ProcessResult(
            terminationStatus: task.terminationStatus,
            stdout: String(data: outputBox.value, encoding: .utf8) ?? "",
            stderr: String(data: errorBox.value, encoding: .utf8) ?? ""
        )
    }

    static func executableURL(named executableName: String, commonPaths: [String] = []) -> URL? {
        let fileManager = FileManager.default

        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let path = String(directory) + "/" + executableName
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }
}
