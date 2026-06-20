import Cocoa

class SyntaxHighlighter {
    private let textView: NSTextView
    private let colorScheme: SyntaxColorScheme
    var fileExtension: String = ""

    /// Files larger than this (UTF-16 units) are not highlighted at all.
    static let maxHighlightLength = 1_000_000

    /// Compiled regexes are cached per pattern; patterns are static per language.
    private var regexCache: [String: NSRegularExpression] = [:]

    struct SyntaxColorScheme {
        let text: NSColor
        let background: NSColor
        let comment: NSColor
        let keyword: NSColor
        let string: NSColor
        let number: NSColor
        let function: NSColor
        let type: NSColor

        /// Built from the active theme's palette, so syntax colors follow
        /// whichever theme is selected.
        static var current: SyntaxColorScheme {
            let p = Theme.shared.palette
            return SyntaxColorScheme(
                text: p.text,
                background: p.base,
                comment: p.overlay0,
                keyword: p.mauve,
                string: p.green,
                number: p.peach,
                function: p.blue,
                type: p.yellow
            )
        }
    }

    init(textView: NSTextView, colorScheme: SyntaxColorScheme = .current) {
        self.textView = textView
        self.colorScheme = colorScheme
    }

    /// Highlights the whole document.
    func highlightSyntax() {
        highlightSyntax(in: nil)
    }

    /// Highlights only the paragraphs overlapping `dirtyRange` (the whole
    /// document when nil), so edits don't re-scan the entire file.
    func highlightSyntax(in dirtyRange: NSRange?) {
        guard let textStorage = textView.textStorage else { return }
        guard textStorage.length <= Self.maxHighlightLength else { return }

        let nsText = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let range: NSRange
        if let dirtyRange = dirtyRange {
            let clamped = NSIntersectionRange(dirtyRange, fullRange)
            range = nsText.paragraphRange(for: clamped)
        } else {
            range = fullRange
        }
        guard range.length > 0 else { return }

        textStorage.beginEditing()
        defer { textStorage.endEditing() }

        // Reset to base text color
        textStorage.removeAttribute(.foregroundColor, range: range)
        textStorage.addAttribute(.foregroundColor, value: colorScheme.text, range: range)

        switch fileExtension {
        case "swift":
            highlightSwift(text: nsText, textStorage: textStorage, range: range)
        case "js", "ts", "jsx", "tsx":
            highlightJavaScript(text: nsText, textStorage: textStorage, range: range)
        case "py":
            highlightPython(text: nsText, textStorage: textStorage, range: range)
        case "rs":
            highlightRust(text: nsText, textStorage: textStorage, range: range)
        case "go":
            highlightGo(text: nsText, textStorage: textStorage, range: range)
        case "c", "cpp", "cc", "cxx", "h", "hpp":
            highlightC(text: nsText, textStorage: textStorage, range: range)
        case "java":
            highlightJava(text: nsText, textStorage: textStorage, range: range)
        case "html", "htm":
            highlightHTML(text: nsText, textStorage: textStorage, range: range)
        case "css":
            highlightCSS(text: nsText, textStorage: textStorage, range: range)
        case "json":
            highlightJSON(text: nsText, textStorage: textStorage, range: range)
        case "md", "markdown":
            highlightMarkdown(text: nsText, textStorage: textStorage, range: range)
        default:
            highlightGeneric(text: nsText, textStorage: textStorage, range: range)
        }
    }

    private func highlightSwift(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "return", "import", "private", "public", "internal", "fileprivate", "static", "final", "override", "mutating", "nonmutating", "convenience", "required", "optional", "weak", "strong", "unowned", "lazy", "dynamic", "inout", "throws", "rethrows", "try", "catch", "defer", "guard", "where", "associatedtype", "typealias", "self", "Self", "super", "nil", "true", "false", "init", "deinit", "subscript", "operator", "precedencegroup", "infix", "prefix", "postfix", "left", "right", "none", "assignment", "higherThan", "lowerThan", "as", "is", "in", "some", "any"
        ]

        let types = [
            "Int", "Float", "Double", "String", "Bool", "Array", "Dictionary", "Set", "Optional", "Result", "NSString", "NSArray", "NSDictionary", "NSSet", "NSNumber", "NSData", "NSDate", "NSURL", "NSError", "NSObject", "UIView", "UIViewController", "NSView", "NSViewController"
        ]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightJavaScript(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "var", "let", "const", "function", "class", "extends", "import", "export", "from", "default", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return", "try", "catch", "finally", "throw", "new", "delete", "typeof", "instanceof", "in", "of", "this", "super", "static", "async", "await", "yield", "true", "false", "null", "undefined"
        ]

        let types = ["Array", "Object", "String", "Number", "Boolean", "Function", "Date", "RegExp", "Error", "Promise", "Map", "Set", "WeakMap", "WeakSet"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightPython(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "and", "or", "not", "is", "in", "True", "False", "None", "pass", "del", "assert"
        ]

        let types = ["int", "float", "str", "bool", "list", "dict", "tuple", "set", "frozenset", "bytes", "bytearray"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .hash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightRust(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "mod", "pub", "use", "if", "else", "match", "for", "while", "loop", "break", "continue", "return", "where", "move", "ref", "self", "Self", "super", "crate", "true", "false", "unsafe", "async", "await"
        ]

        let types = ["i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32", "f64", "bool", "char", "str", "String", "Vec", "HashMap", "Result", "Option", "Box", "Rc", "Arc"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightGo(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "package", "import", "func", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer", "select", "chan", "map", "make", "new", "append", "len", "cap", "copy", "delete", "close", "true", "false", "nil"
        ]

        let types = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "complex64", "complex128", "bool", "byte", "rune", "string", "error"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightC(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary", "true", "false"
        ]

        let types = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "size_t", "ssize_t", "ptrdiff_t", "wchar_t"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightJava(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null"
        ]

        let types = ["String", "Integer", "Double", "Float", "Boolean", "Character", "Byte", "Short", "Long", "Object", "Class", "Array", "List", "Map", "Set", "Collection"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, range: range, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    private func highlightHTML(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // HTML tags
        highlightPattern("<[^>]+>", in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)

        // HTML comments
        highlightPattern("<!--[\\s\\S]*?-->", in: text, textStorage: textStorage, range: range, color: colorScheme.comment)

        // Attribute values
        highlightPattern("\"[^\"]*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)
    }

    private func highlightCSS(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // CSS properties
        highlightPattern("\\b[a-z-]+(?=\\s*:)", in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)

        // CSS values
        highlightPattern("(?<=:)\\s*[^;]+", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // CSS comments
        highlightPattern("/\\*[\\s\\S]*?\\*/", in: text, textStorage: textStorage, range: range, color: colorScheme.comment)
    }

    private func highlightJSON(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // JSON strings
        highlightPattern("\"([^\"\\\\]|\\\\.)*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // JSON numbers
        highlightNumbers(in: text, textStorage: textStorage, range: range)

        // JSON booleans and null
        highlightKeywords(["true", "false", "null"], in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)
    }

    private func highlightMarkdown(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Headers
        highlightPattern("^#{1,6}\\s+.*$", in: text, textStorage: textStorage, range: range, color: colorScheme.keyword)

        // Code blocks
        highlightPattern("`[^`]+`|```[\\s\\S]*?```", in: text, textStorage: textStorage, range: range, color: colorScheme.function)

        // Links
        highlightPattern("\\[([^\\]]+)\\]\\([^)]+\\)", in: text, textStorage: textStorage, range: range, color: colorScheme.string)
    }

    private func highlightGeneric(text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Generic highlighting for unknown file types
        highlightComments(in: text, textStorage: textStorage, range: range, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage, range: range)
        highlightNumbers(in: text, textStorage: textStorage, range: range)
    }

    // MARK: - Helper Methods

    private enum CommentStyle {
        case slashSlash
        case hash
        case slashStar
    }

    private func highlightKeywords(_ keywords: [String], in text: NSString, textStorage: NSTextStorage, range: NSRange, color: NSColor) {
        // One alternation regex for the whole keyword set instead of one
        // regex pass per keyword.
        let escaped = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(?:\(escaped.joined(separator: "|")))\\b"
        highlightPattern(pattern, in: text, textStorage: textStorage, range: range, color: color)
    }

    private func highlightComments(in text: NSString, textStorage: NSTextStorage, range: NSRange, commentStyle: CommentStyle) {
        let pattern: String
        switch commentStyle {
        case .slashSlash:
            pattern = "//.*$"
        case .hash:
            pattern = "#.*$"
        case .slashStar:
            pattern = "/\\*[\\s\\S]*?\\*/"
        }

        highlightPattern(pattern, in: text, textStorage: textStorage, range: range, color: colorScheme.comment)
    }

    private func highlightStrings(in text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Double quoted strings
        highlightPattern("\"([^\"\\\\]|\\\\.)*\"", in: text, textStorage: textStorage, range: range, color: colorScheme.string)

        // Single quoted strings
        highlightPattern("'([^'\\\\]|\\\\.)*'", in: text, textStorage: textStorage, range: range, color: colorScheme.string)
    }

    private func highlightNumbers(in text: NSString, textStorage: NSTextStorage, range: NSRange) {
        // Integer and floating point numbers
        highlightPattern("\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", in: text, textStorage: textStorage, range: range, color: colorScheme.number)
    }

    private func highlightPattern(_ pattern: String, in text: NSString, textStorage: NSTextStorage, range: NSRange, color: NSColor) {
        guard let regex = cachedRegex(for: pattern) else { return }

        regex.enumerateMatches(in: text as String, options: [], range: range) { match, _, _ in
            if let match = match {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }

    private func cachedRegex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] {
            return cached
        }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        regexCache[pattern] = regex
        return regex
    }
}
