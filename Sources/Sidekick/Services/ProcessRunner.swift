import Foundation

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

        var outputData = Data()
        var errorData = Data()
        let readGroup = DispatchGroup()

        try task.run()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        task.waitUntilExit()
        readGroup.wait()

        return ProcessResult(
            terminationStatus: task.terminationStatus,
            stdout: String(data: outputData, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
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
