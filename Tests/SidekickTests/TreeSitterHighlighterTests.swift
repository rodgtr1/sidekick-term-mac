import XCTest
@testable import Sidekick

@MainActor
final class TreeSitterHighlighterTests: XCTestCase {
    func testSupportedExtensions() {
        for ext in ["swift", "SWIFT", "go", "rs", "js", "jsx", "ts", "tsx", "md", "mdx", "py"] {
            XCTAssertTrue(TreeSitterHighlighter.canHighlight(ext: ext), "expected \(ext) supported")
        }
        XCTAssertFalse(TreeSitterHighlighter.canHighlight(ext: "txt"))
    }

    /// Each grammar's embedded query must compile against its linked grammar
    /// (ABI match) and classify real source — otherwise that language silently
    /// degrades to the regex fallback.
    func testEachGrammarQueryCompilesAndClassifies() {
        let samples: [(ext: String, src: String)] = [
            ("go", "package main\nfunc main() { x := 42 }\n"),
            ("py", "def f(x):\n    return 42  # comment\n"),
            ("rs", "fn main() { let x = 42; }\n"),
            ("ts", "const x: number = 42\nfunction f(): string { return \"s\" }\n"),
            ("tsx", "const e = <div className=\"a\">{42}</div>\n"),
            ("js", "const x = 42\nfunction f() { return \"s\" }\n"),
        ]
        for sample in samples {
            guard let kinds = TreeSitterHighlighter._captureKinds(in: sample.src, ext: sample.ext) else {
                XCTFail("\(sample.ext): query failed to compile against the grammar")
                continue
            }
            // `keyword` is universal proof the query compiled against the grammar
            // and classified tokens. We don't assert specific literal captures —
            // grammars differ (e.g. Rust tags integer literals @constant.builtin,
            // not @number) — only that real, multi-class highlighting happens.
            XCTAssertTrue(kinds.contains("keyword"), "\(sample.ext): expected keyword, got \(kinds)")
            XCTAssertGreaterThanOrEqual(kinds.count, 2, "\(sample.ext): expected multi-class highlighting, got \(kinds)")
        }
    }

    /// Confirms the embedded highlights query compiles against the linked Swift
    /// grammar (ABI match) and classifies real tokens — the runtime risk that
    /// `try? Query(...)` would otherwise swallow into a silent regex fallback.
    func testSwiftQueryCompilesAndClassifiesTokens() {
        let source = """
        // a comment
        func greet(_ name: String) -> Int {
            let count = 42
            return count
        }
        """
        guard let kinds = TreeSitterHighlighter._captureKinds(in: source, ext: "swift") else {
            return XCTFail("Swift query failed to compile against the grammar")
        }
        XCTAssertTrue(kinds.contains("keyword"), "expected keyword captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("comment"), "expected comment captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("number"), "expected number captures, got \(kinds)")
        XCTAssertTrue(kinds.contains("type"), "expected type captures, got \(kinds)")
    }

    /// Markdown uses the @text.* capture family (no @keyword), so it's checked
    /// separately: a heading + code span must classify as text captures.
    func testMarkdownBlockClassifies() {
        let source = "# Heading\n\nSome `code` and a para.\n"
        guard let kinds = TreeSitterHighlighter._captureKinds(in: source, ext: "md") else {
            return XCTFail("markdown query failed to compile against the grammar")
        }
        XCTAssertTrue(kinds.contains("text"), "expected @text.* captures, got \(kinds)")
    }

    func testUnsupportedLanguageReturnsNil() {
        XCTAssertNil(TreeSitterHighlighter._captureKinds(in: "x = 1", ext: "rb"))
    }

    /// The query is restricted to the edited range's UTF-8 byte span. A multibyte
    /// character on an earlier line makes UTF-8 byte offsets diverge from UTF-16,
    /// so this proves the byte-range conversion is correct: the `func` keyword in
    /// the dirty range must still be colored as a keyword.
    func testSubRangeHighlightingWithMultibytePrefix() {
        let source = "let café = \"☕\"\nfunc greet() {}\n"
        let ns = source as NSString
        let storage = NSTextStorage(string: source)
        let scheme = SyntaxHighlighter.SyntaxColorScheme(
            text: .black, background: .white, comment: .gray, keyword: .red,
            string: .green, number: .blue, function: .purple, type: .orange
        )
        let dirty = ns.paragraphRange(for: ns.range(of: "func greet() {}"))

        storage.beginEditing()
        let ok = TreeSitterHighlighter.highlight(
            textStorage: storage, fullText: ns, range: dirty, ext: "swift", scheme: scheme
        )
        storage.endEditing()

        XCTAssertTrue(ok)
        let funcLoc = ns.range(of: "func").location
        let color = storage.attribute(.foregroundColor, at: funcLoc, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .red, "keyword in the dirty range should be highlighted")
    }
}
