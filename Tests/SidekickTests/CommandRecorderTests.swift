import XCTest
@testable import Sidekick

final class CommandRecorderTests: XCTestCase {
    func testCapturesCommandRecordWithCleanedOutput() {
        var recorder = CommandRecorder()
        XCTAssertFalse(recorder.isCommandInFlight)

        let start = Date(timeIntervalSince1970: 100)
        recorder.commandStarted(command: "ls -la", at: start)
        XCTAssertTrue(recorder.isCommandInFlight)

        recorder.appendOutput("\u{001B}[32mfile.txt\u{001B}[0m\n")
        let status = recorder.commandFinished(exitCode: 0, at: start.addingTimeInterval(1.5))

        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(status.duration ?? -1, 1.5, accuracy: 0.001)
        XCTAssertFalse(recorder.isCommandInFlight)

        let record = recorder.recentRecords().last
        XCTAssertEqual(record?.command, "ls -la")
        XCTAssertEqual(record?.exitCode, 0)
        // ANSI stripped and whitespace trimmed at finalize.
        XCTAssertEqual(record?.output, "file.txt")
    }

    func testOSCSequencesStrippedFromRecordOutput() {
        var recorder = CommandRecorder()
        recorder.commandStarted(command: "pwd")
        recorder.appendOutput("\u{001B}]7;file:///tmp\u{001B}\\/tmp\n")
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output, "/tmp")
    }

    func testFinishWithoutStartYieldsStatusButNoRecord() {
        var recorder = CommandRecorder()
        let status = recorder.commandFinished(exitCode: 2)
        XCTAssertEqual(status.exitCode, 2)
        XCTAssertNil(status.duration)
        XCTAssertTrue(recorder.recentRecords().isEmpty)
    }

    func testOutputOutsideCommandWindowIsIgnored() {
        var recorder = CommandRecorder()
        recorder.appendOutput("prompt noise before the command")
        recorder.commandStarted(command: "true")
        _ = recorder.commandFinished(exitCode: 0)
        XCTAssertEqual(recorder.recentRecords().last?.output, "")
    }

    func testRecordsCappedAndLimitApplied() {
        var recorder = CommandRecorder()
        for i in 0..<105 {
            recorder.commandStarted(command: "cmd\(i)")
            _ = recorder.commandFinished(exitCode: 0)
        }
        XCTAssertEqual(recorder.recentRecords().count, 100)
        XCTAssertEqual(recorder.recentRecords().first?.command, "cmd5")
        XCTAssertEqual(recorder.recentRecords(limit: 2).map(\.command), ["cmd103", "cmd104"])
        // A nil/zero limit means everything.
        XCTAssertEqual(recorder.recentRecords(limit: 0).count, 100)
    }

    func testStatusSummaryFormatting() {
        XCTAssertEqual(TerminalCommandStatus(exitCode: 0, duration: nil).summary, "✓ exit 0")
        XCTAssertEqual(TerminalCommandStatus(exitCode: 1, duration: 2.34).summary, "✗ exit 1 · 2.3s")
        XCTAssertEqual(TerminalCommandStatus(exitCode: 0, duration: 90).summary, "✓ exit 0 · 1m 30s")
    }
}
