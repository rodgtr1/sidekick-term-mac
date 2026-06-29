import AppKit
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterGo
import TreeSitterRust
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterMarkdown
import TreeSitterPython

/// Grammar-accurate syntax highlighting via tree-sitter, replacing the regex
/// highlighter for the languages it supports. Currently wired for Swift; every
/// other extension falls back to the regex `SyntaxHighlighter` (so this is a
/// strict upgrade — nothing regresses for unsupported files).
///
/// Scoped to the document editor path. The parser+query are built once and
/// reused. Parsing is whole-document on each highlight pass (incremental tree
/// editing is a later optimization); the `maxHighlightLength` guard in the
/// caller bounds that cost.
enum TreeSitterHighlighter {
    /// Extensions handled by tree-sitter. Anything else → regex fallback.
    static func canHighlight(ext: String) -> Bool {
        languageAndQuery(for: ext.lowercased()) != nil
    }

    /// Applies grammar-accurate colors to `range` of `textStorage`. Returns
    /// false (so the caller runs the regex path) when the language is
    /// unsupported or parsing fails. The caller has already reset `range` to the
    /// base text color and opened a text-storage edit transaction.
    static func highlight(
        textStorage: NSTextStorage,
        fullText: NSString,
        range: NSRange,
        ext: String,
        scheme: SyntaxHighlighter.SyntaxColorScheme
    ) -> Bool {
        guard let (language, query) = languageAndQuery(for: ext.lowercased()) else { return false }

        let parser = Parser()
        do { try parser.setLanguage(language) } catch { return false }
        guard let tree = parser.parse(fullText as String), let root = tree.rootNode else { return false }

        // First-capture-wins per character, matching tree-sitter's convention
        // that earlier (more specific) query patterns take precedence — so a
        // keyword inside a string keeps the string color, etc.
        var colored = IndexSet()
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures {
                guard let color = color(forCapture: capture.nameComponents, scheme: scheme) else { continue }
                let nodeRange = NSIntersectionRange(capture.node.range, range)
                guard nodeRange.length > 0 else { continue }
                let positions = IndexSet(integersIn: nodeRange.location..<(nodeRange.location + nodeRange.length))
                let fresh = positions.subtracting(colored)
                guard !fresh.isEmpty else { continue }
                for run in fresh.rangeView {
                    textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(run))
                }
                colored.formUnion(positions)
            }
        }
        return true
    }

    // MARK: - Capture → color mapping

    /// Maps a tree-sitter capture name (nvim-treesitter convention) onto the
    /// theme's syntax palette. Keys mostly on the leading component; Markdown's
    /// `@text.*` family needs the second component too. Unmapped captures
    /// (operators, punctuation, plain variables) stay the base text color.
    private static func color(forCapture name: [String], scheme: SyntaxHighlighter.SyntaxColorScheme) -> NSColor? {
        switch name.first {
        case "keyword", "attribute", "label":
            return scheme.keyword
        case "string", "character", "escape":
            return scheme.string
        case "comment":
            return scheme.comment
        case "number", "boolean", "float":
            return scheme.number
        case "type", "constructor":
            return scheme.type
        case "function":
            return scheme.function
        case "constant":
            // `nil` / builtins read as keywords in the regex highlighter; keep that.
            return scheme.keyword
        case "text":
            // Markdown block captures: headings, code spans, links.
            switch name.dropFirst().first {
            case "title":              return scheme.keyword    // # Heading
            case "literal":            return scheme.function   // `code` / fenced
            case "uri", "reference":   return scheme.string     // links
            default:                   return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Language + query cache

    /// Maps a (lowercased) file extension to its grammar's `Language` and the
    /// raw highlight-query text. nil for unsupported extensions. TS/TSX use the
    /// combined JS-base + TS-additions query; JSX rides the JavaScript grammar.
    private static func languageAndQueryText(for ext: String) -> (Language, String)? {
        switch ext {
        case "swift":
            return (Language(language: tree_sitter_swift()), treeSitterSwiftHighlightsQuery)
        case "go":
            return (Language(language: tree_sitter_go()), tsQueryGo)
        case "py", "pyi":
            return (Language(language: tree_sitter_python()), tsQueryPython)
        case "rs":
            return (Language(language: tree_sitter_rust()), tsQueryRust)
        case "js", "jsx", "mjs", "cjs", "ts", "mts", "cts", "tsx":
            // All routed through the TSX grammar — a superset of JS/JSX/TS/TSX —
            // so the combined JS-base + TS-additions query compiles against it
            // and one path covers every flavor (no tree-sitter-javascript dep).
            return (Language(language: tree_sitter_tsx()), tsQueryTypeScript)
        case "md", "markdown", "mdx":
            // Block grammar only (headings, fenced code, lists, links). Inline
            // emphasis/links need the inline grammar via injections — see #21.
            return (Language(language: tree_sitter_markdown()), tsQueryMarkdown)
        default:
            return nil
        }
    }

    /// Memoized (Language, Query) per extension. Built lazily on first use and
    /// reused; main-actor isolated via the module default, so the cache is
    /// single-threaded. A query that won't compile against its grammar caches
    /// nothing and returns nil, so that language quietly falls back to regex.
    private static var cache: [String: (Language, Query)] = [:]

    private static func languageAndQuery(for ext: String) -> (Language, Query)? {
        if let hit = cache[ext] { return hit }
        guard let (language, text) = languageAndQueryText(for: ext),
              let query = try? Query(language: language, data: Data(text.utf8)) else {
            return nil
        }
        cache[ext] = (language, query)
        return (language, query)
    }

    // MARK: - Test hook

    /// Parses `source` for `ext` and returns the set of leading capture-name
    /// components produced (e.g. ["keyword", "string", "number"]), or nil if the
    /// language is unsupported / the query failed to compile. Lets a unit test
    /// confirm the embedded query compiles against the grammar (ABI match) and
    /// actually classifies tokens — without needing the running app.
    static func _captureKinds(in source: String, ext: String) -> Set<String>? {
        guard let (language, query) = languageAndQuery(for: ext.lowercased()) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil,
              let tree = parser.parse(source), let root = tree.rootNode else { return nil }
        var kinds = Set<String>()
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures {
                if let first = capture.nameComponents.first { kinds.insert(first) }
            }
        }
        return kinds
    }
}
