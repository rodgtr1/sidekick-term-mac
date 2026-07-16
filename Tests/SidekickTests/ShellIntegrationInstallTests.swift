import XCTest
@testable import Sidekick

/// R2/2: installing shell integration appends one line to ~/.zshrc. An existing
/// zshrc that can't be read as UTF-8 must make the install throw — never be
/// treated as empty content, which would replace the user's file with only the
/// Sidekick stanza.
@MainActor
final class ShellIntegrationInstallTests: XCTestCase {
    private let fm = FileManager.default
    private let sourceLineNeedle = "shell-integration/sidekick.zsh"

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("sk-zshrc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runWrapperScenario(shell: String, suffix: String, script: String) throws -> [String] {
        let directory = try makeTempDir()
        defer { try? fm.removeItem(at: directory) }
        let integration = directory.appendingPathComponent("sidekick.\(suffix)")
        let mode = directory.appendingPathComponent("approval-mode")
        let bin = directory.appendingPathComponent("bin")
        let codex = bin.appendingPathComponent("codex")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try script.write(to: integration, atomically: true, encoding: .utf8)
        try "ask\n".write(to: mode, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'CODEX'
        for arg in "$@"; do printf ' <%s>' "$arg"; done
        printf '\n'
        """.write(to: codex, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let command = """
        source '\(integration.path)'
        codex before
        printf 'review\\n' > '\(mode.path)'
        codex after
        printf 'not-a-mode\\n' > '\(mode.path)'
        codex invalid
        codex -a=never override
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM_PROGRAM"] = ShellIntegration.termProgram
        environment["SIDEKICK_APPROVAL_MODE"] = "ask"
        environment["SIDEKICK_APPROVAL_MODE_FILE"] = mode.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment.removeValue(forKey: "SIDEKICK_SHELL_INTEGRATION_ACTIVE")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "\(suffix) scenario failed: \(error)")
        return output.split(separator: "\n").map(String.init).filter { $0.contains("CODEX") }
    }

    func testInstallAppendsAndPreservesExistingContent() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zshrc = dir.appendingPathComponent(".zshrc")
        let original = "export EDITOR=vim\nalias ll='ls -la'\n"
        try original.write(to: zshrc, atomically: true, encoding: .utf8)

        XCTAssertFalse(ShellIntegration.isInstalledInZshrc(at: zshrc))
        XCTAssertTrue(try ShellIntegration.installInZshrc(at: zshrc))

        let updated = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(updated.hasPrefix(original), "The user's existing zshrc must survive intact")
        XCTAssertTrue(updated.contains(sourceLineNeedle))
        XCTAssertTrue(ShellIntegration.isInstalledInZshrc(at: zshrc))
    }

    func testInstallIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zshrc = dir.appendingPathComponent(".zshrc")
        try "export EDITOR=vim\n".write(to: zshrc, atomically: true, encoding: .utf8)

        XCTAssertTrue(try ShellIntegration.installInZshrc(at: zshrc))
        let afterFirst = try String(contentsOf: zshrc, encoding: .utf8)

        XCTAssertFalse(try ShellIntegration.installInZshrc(at: zshrc), "Already present")
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), afterFirst)
    }

    func testInstallCreatesZshrcWhenAbsent() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zshrc = dir.appendingPathComponent(".zshrc")

        XCTAssertFalse(ShellIntegration.isInstalledInZshrc(at: zshrc))
        XCTAssertTrue(try ShellIntegration.installInZshrc(at: zshrc))
        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains(sourceLineNeedle))
    }

    func testUnreadableZshrcThrowsAndIsLeftUntouched() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        let zshrc = dir.appendingPathComponent(".zshrc")
        // Not decodable as UTF-8 (lone continuation bytes / a stray 0xFF).
        let garbage = Data([0xFF, 0xFE, 0x80, 0x81, 0x0A, 0xC3, 0x28])
        try garbage.write(to: zshrc)

        // A read failure must not read as "not installed, so overwrite".
        XCTAssertFalse(ShellIntegration.isInstalledInZshrc(at: zshrc))
        XCTAssertThrowsError(try ShellIntegration.installInZshrc(at: zshrc),
                             "An existing but unreadable zshrc must fail the install")
        XCTAssertEqual(try Data(contentsOf: zshrc), garbage,
                       "The user's zshrc must be byte-for-byte untouched")
    }

    func testAgentWrappersResolveLiveProviderNeutralMode() {
        for script in [ShellIntegration.zshScript, ShellIntegration.bashScript] {
            XCTAssertTrue(script.contains("SIDEKICK_APPROVAL_MODE_FILE"))
            XCTAssertTrue(script.contains("--sandbox read-only --ask-for-approval on-request"))
            XCTAssertTrue(script.contains("approvals_reviewer=auto_review"))
            XCTAssertTrue(script.contains("--permission-mode auto"))
            XCTAssertTrue(script.contains("--sandbox danger-full-access --ask-for-approval never"))
        }
    }

    func testGeneratedShellScriptsParse() throws {
        for (shell, suffix, script) in [
            ("/bin/zsh", "zsh", ShellIntegration.zshScript),
            ("/bin/bash", "bash", ShellIntegration.bashScript)
        ] {
            let url = fm.temporaryDirectory
                .appendingPathComponent("sidekick-shell-\(UUID().uuidString).\(suffix)")
            defer { try? fm.removeItem(at: url) }
            try script.write(to: url, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-n", url.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(suffix) integration must parse")
        }
    }

    func testAgentWrappersRereadModeFailClosedAndHonorShortOverrides() throws {
        for (shell, suffix, script) in [
            ("/bin/zsh", "zsh", ShellIntegration.zshScript),
            ("/bin/bash", "bash", ShellIntegration.bashScript)
        ] {
            let lines = try runWrapperScenario(shell: shell, suffix: suffix, script: script)
            XCTAssertEqual(lines.count, 4, "\(suffix) should invoke the stub four times")
            XCTAssertTrue(lines[0].contains("<--sandbox> <read-only>"), "\(suffix) ask must fail closed")
            XCTAssertTrue(lines[0].hasSuffix("<before>"))
            XCTAssertTrue(lines[1].contains("<approvals_reviewer=auto_review>"), "\(suffix) must reread review")
            XCTAssertTrue(lines[1].hasSuffix("<after>"))
            XCTAssertTrue(lines[2].contains("<--sandbox> <read-only>"), "\(suffix) invalid mode must fail closed")
            XCTAssertEqual(lines[3], "CODEX <-a=never> <override>", "\(suffix) explicit short override must win")
        }
    }
}
