import Foundation

class CWDDetector {
    static func getCWD(for pid: pid_t) -> String? {
        // Use lsof to get the current working directory
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-p", "\(pid)", "-d", "cwd", "-Fn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Parse lsof output - look for line starting with 'n' which contains the path
            for line in output.split(separator: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst())
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}