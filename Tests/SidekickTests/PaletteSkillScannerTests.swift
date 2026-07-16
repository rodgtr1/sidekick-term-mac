import XCTest
@testable import Sidekick

/// The palette's skill list is declared inside the skills themselves — a
/// `sidekick-palette: true` frontmatter line — so the scanner's job is to
/// include exactly what's tagged and nothing else, across the user and
/// workspace roots.
final class PaletteSkillScannerTests: XCTestCase {
    private var userRoot: URL!
    private var workspaceRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteSkillScannerTests-\(UUID().uuidString)")
        userRoot = base.appendingPathComponent("user-skills")
        workspaceRoot = base.appendingPathComponent("workspace-skills")
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: userRoot.deletingLastPathComponent())
    }

    private func install(_ skill: String, frontmatter: [String], in root: URL, body: String = "Body.") throws {
        let directory = root.appendingPathComponent(skill)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = (["---"] + frontmatter + ["---", "", body]).joined(separator: "\n")
        try contents.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func testTaggedSkillAppearsWithHumanizedTitle() throws {
        try install("stage-and-commit", frontmatter: [
            "name: stage-and-commit",
            "description: Stages and commits.",
            "sidekick-palette: true"
        ], in: userRoot)

        let skills = PaletteSkillScanner.scan(roots: [userRoot])
        XCTAssertEqual(skills, [PaletteSkill(name: "stage-and-commit", title: "Stage And Commit", submit: false)])
    }

    func testUntaggedSkillIsExcluded() throws {
        try install("newsletter", frontmatter: [
            "name: newsletter",
            "description: Writes the newsletter."
        ], in: userRoot)

        XCTAssertTrue(PaletteSkillScanner.scan(roots: [userRoot]).isEmpty)
    }

    func testSubmitAndLabelKeysAreHonored() throws {
        try install("stage-and-commit", frontmatter: [
            "name: stage-and-commit",
            "sidekick-palette: true",
            "sidekick-palette-submit: true",
            "sidekick-palette-label: Stage and Commit"
        ], in: userRoot)

        let skills = PaletteSkillScanner.scan(roots: [userRoot])
        XCTAssertEqual(skills, [PaletteSkill(name: "stage-and-commit", title: "Stage and Commit", submit: true)])
    }

    func testNameFallsBackToDirectoryName() throws {
        try install("second-opinion", frontmatter: [
            "description: No name key.",
            "sidekick-palette: true"
        ], in: userRoot)

        XCTAssertEqual(PaletteSkillScanner.scan(roots: [userRoot]).first?.name, "second-opinion")
    }

    func testLaterRootShadowsEarlierOnNameCollision() throws {
        try install("delegate", frontmatter: [
            "name: delegate",
            "sidekick-palette: true",
            "sidekick-palette-label: User Delegate"
        ], in: userRoot)
        try install("delegate", frontmatter: [
            "name: delegate",
            "sidekick-palette: true",
            "sidekick-palette-label: Workspace Delegate"
        ], in: workspaceRoot)

        let skills = PaletteSkillScanner.scan(roots: [userRoot, workspaceRoot])
        XCTAssertEqual(skills.map(\.title), ["Workspace Delegate"])
    }

    func testResultsAreSortedByTitle() throws {
        try install("second-opinion", frontmatter: ["sidekick-palette: true"], in: userRoot)
        try install("delegate", frontmatter: ["sidekick-palette: true"], in: userRoot)

        XCTAssertEqual(
            PaletteSkillScanner.scan(roots: [userRoot]).map(\.title),
            ["Delegate", "Second Opinion"]
        )
    }

    func testFileWithoutFrontmatterIsIgnored() throws {
        let directory = userRoot.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Just markdown, no fences.\nsidekick-palette: true".write(
            to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        XCTAssertTrue(PaletteSkillScanner.scan(roots: [userRoot]).isEmpty)
    }

    func testTagInBodyDoesNotCount() throws {
        try install("humanizer", frontmatter: [
            "name: humanizer"
        ], in: userRoot, body: "sidekick-palette: true")

        XCTAssertTrue(PaletteSkillScanner.scan(roots: [userRoot]).isEmpty)
    }

    func testMissingRootScansToEmpty() {
        let missing = userRoot.appendingPathComponent("does-not-exist")
        XCTAssertTrue(PaletteSkillScanner.scan(roots: [missing]).isEmpty)
    }
}
