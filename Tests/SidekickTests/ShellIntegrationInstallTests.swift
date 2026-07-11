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
}
