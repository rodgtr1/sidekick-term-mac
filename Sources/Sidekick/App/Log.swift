import Foundation
import os

/// Lightweight app logger. Writes to the unified logging system (visible in
/// Console.app, filter by subsystem `com.sidekick.terminal`) and appends to a
/// plain-text file you can `tail`:
///
///     tail -f ~/Library/Logs/Sidekick/Sidekick.log
///
/// Use this instead of `print()` so messages survive when the packaged `.app`
/// is launched (stdout is discarded there).
///
/// `nonisolated`: the logger is called from every thread (background git work,
/// the IPC accept loop, PTY callbacks), so it must not inherit the module's
/// default main-actor isolation. All state here is immutable and the file write
/// is funnelled through a private serial queue.
nonisolated enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    private static let subsystem = "com.sidekick.terminal"
    private static let osLog = os.Logger(subsystem: subsystem, category: "app")

    /// ~/Library/Logs/Sidekick/Sidekick.log
    static let fileURL: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sidekick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Sidekick.log")
    }()

    private static let queue = DispatchQueue(label: "\(subsystem).log")

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ message: @autoclosure () -> String, category: String = "app") {
        write(.debug, message(), category: category)
    }

    static func info(_ message: @autoclosure () -> String, category: String = "app") {
        write(.info, message(), category: category)
    }

    static func error(_ message: @autoclosure () -> String, category: String = "app") {
        write(.error, message(), category: category)
    }

    private static func write(_ level: Level, _ message: String, category: String) {
        switch level {
        case .debug: osLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: osLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: osLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
