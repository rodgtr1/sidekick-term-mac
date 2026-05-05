import Cocoa

class SyntaxHighlighter {
    private let textView: NSTextView
    private let colorScheme: SyntaxColorScheme
    var fileExtension: String = ""

    struct SyntaxColorScheme {
        let text: NSColor
        let background: NSColor
        let comment: NSColor
        let keyword: NSColor
        let string: NSColor
        let number: NSColor
        let function: NSColor
        let type: NSColor

        static let catppuccinMocha = SyntaxColorScheme(
            text: NSColor(hex: "#cdd6f4") ?? .textColor,
            background: NSColor(hex: "#1e1e2e") ?? .textBackgroundColor,
            comment: NSColor(hex: "#6c7086") ?? .secondaryLabelColor,
            keyword: NSColor(hex: "#cba6fa") ?? .systemPurple,
            string: NSColor(hex: "#a6e3a1") ?? .systemGreen,
            number: NSColor(hex: "#fab387") ?? .systemOrange,
            function: NSColor(hex: "#89b4fa") ?? .systemBlue,
            type: NSColor(hex: "#f9e2af") ?? .systemYellow
        )
    }

    init(textView: NSTextView, colorScheme: SyntaxColorScheme = .catppuccinMocha) {
        self.textView = textView
        self.colorScheme = colorScheme
    }

    func highlightSyntax() {
        guard let textStorage = textView.textStorage else { return }

        let text = textStorage.string
        let range = NSRange(location: 0, length: text.count)

        // Reset to base text color
        textStorage.removeAttribute(.foregroundColor, range: range)
        textStorage.addAttribute(.foregroundColor, value: colorScheme.text, range: range)

        // Detect file type from extension
        let fileExtension = getFileExtension()

        switch fileExtension {
        case "swift":
            highlightSwift(text: text, textStorage: textStorage, range: range)
        case "js", "ts", "jsx", "tsx":
            highlightJavaScript(text: text, textStorage: textStorage, range: range)
        case "py":
            highlightPython(text: text, textStorage: textStorage, range: range)
        case "rs":
            highlightRust(text: text, textStorage: textStorage, range: range)
        case "go":
            highlightGo(text: text, textStorage: textStorage, range: range)
        case "c", "cpp", "cc", "cxx", "h", "hpp":
            highlightC(text: text, textStorage: textStorage, range: range)
        case "java":
            highlightJava(text: text, textStorage: textStorage, range: range)
        case "html", "htm":
            highlightHTML(text: text, textStorage: textStorage, range: range)
        case "css":
            highlightCSS(text: text, textStorage: textStorage, range: range)
        case "json":
            highlightJSON(text: text, textStorage: textStorage, range: range)
        case "md", "markdown":
            highlightMarkdown(text: text, textStorage: textStorage, range: range)
        default:
            highlightGeneric(text: text, textStorage: textStorage, range: range)
        }
    }

    private func getFileExtension() -> String {
        return fileExtension
    }

    private func highlightSwift(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "return", "import", "private", "public", "internal", "fileprivate", "static", "final", "override", "mutating", "nonmutating", "convenience", "required", "optional", "weak", "strong", "unowned", "lazy", "dynamic", "inout", "throws", "rethrows", "try", "catch", "defer", "guard", "where", "associatedtype", "typealias", "self", "Self", "super", "nil", "true", "false", "init", "deinit", "subscript", "operator", "precedencegroup", "infix", "prefix", "postfix", "left", "right", "none", "assignment", "higherThan", "lowerThan", "as", "is", "in", "some", "any"
        ]

        let types = [
            "Int", "Float", "Double", "String", "Bool", "Array", "Dictionary", "Set", "Optional", "Result", "NSString", "NSArray", "NSDictionary", "NSSet", "NSNumber", "NSData", "NSDate", "NSURL", "NSError", "NSObject", "UIView", "UIViewController", "NSView", "NSViewController"
        ]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightJavaScript(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "var", "let", "const", "function", "class", "extends", "import", "export", "from", "default", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return", "try", "catch", "finally", "throw", "new", "delete", "typeof", "instanceof", "in", "of", "this", "super", "static", "async", "await", "yield", "true", "false", "null", "undefined"
        ]

        let types = ["Array", "Object", "String", "Number", "Boolean", "Function", "Date", "RegExp", "Error", "Promise", "Map", "Set", "WeakMap", "WeakSet"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightPython(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "and", "or", "not", "is", "in", "True", "False", "None", "pass", "del", "assert"
        ]

        let types = ["int", "float", "str", "bool", "list", "dict", "tuple", "set", "frozenset", "bytes", "bytearray"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .hash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightRust(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "mod", "pub", "use", "if", "else", "match", "for", "while", "loop", "break", "continue", "return", "where", "move", "ref", "self", "Self", "super", "crate", "true", "false", "unsafe", "async", "await"
        ]

        let types = ["i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32", "f64", "bool", "char", "str", "String", "Vec", "HashMap", "Result", "Option", "Box", "Rc", "Arc"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightGo(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "package", "import", "func", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return", "go", "defer", "select", "chan", "map", "make", "new", "append", "len", "cap", "copy", "delete", "close", "true", "false", "nil"
        ]

        let types = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "complex64", "complex128", "bool", "byte", "rune", "string", "error"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightC(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary", "true", "false"
        ]

        let types = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "size_t", "ssize_t", "ptrdiff_t", "wchar_t"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightJava(text: String, textStorage: NSTextStorage, range: NSRange) {
        let keywords = [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null"
        ]

        let types = ["String", "Integer", "Double", "Float", "Boolean", "Character", "Byte", "Short", "Long", "Object", "Class", "Array", "List", "Map", "Set", "Collection"]

        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
        highlightKeywords(types, in: text, textStorage: textStorage, color: colorScheme.type)
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    private func highlightHTML(text: String, textStorage: NSTextStorage, range: NSRange) {
        // HTML tags
        let tagPattern = "<[^>]+>"
        highlightPattern(tagPattern, in: text, textStorage: textStorage, color: colorScheme.keyword)

        // HTML comments
        let commentPattern = "<!--[\\s\\S]*?-->"
        highlightPattern(commentPattern, in: text, textStorage: textStorage, color: colorScheme.comment)

        // Attribute values
        let attributePattern = "\"[^\"]*\""
        highlightPattern(attributePattern, in: text, textStorage: textStorage, color: colorScheme.string)
    }

    private func highlightCSS(text: String, textStorage: NSTextStorage, range: NSRange) {
        // CSS properties
        let propertyPattern = "\\b[a-z-]+(?=\\s*:)"
        highlightPattern(propertyPattern, in: text, textStorage: textStorage, color: colorScheme.keyword)

        // CSS values
        let valuePattern = "(?<=:)\\s*[^;]+"
        highlightPattern(valuePattern, in: text, textStorage: textStorage, color: colorScheme.string)

        // CSS comments
        let commentPattern = "/\\*[\\s\\S]*?\\*/"
        highlightPattern(commentPattern, in: text, textStorage: textStorage, color: colorScheme.comment)
    }

    private func highlightJSON(text: String, textStorage: NSTextStorage, range: NSRange) {
        // JSON strings
        let stringPattern = "\"([^\"\\\\]|\\\\.)*\""
        highlightPattern(stringPattern, in: text, textStorage: textStorage, color: colorScheme.string)

        // JSON numbers
        highlightNumbers(in: text, textStorage: textStorage)

        // JSON booleans and null
        let keywords = ["true", "false", "null"]
        highlightKeywords(keywords, in: text, textStorage: textStorage, color: colorScheme.keyword)
    }

    private func highlightMarkdown(text: String, textStorage: NSTextStorage, range: NSRange) {
        // Headers
        let headerPattern = "^#{1,6}\\s+.*$"
        highlightPattern(headerPattern, in: text, textStorage: textStorage, color: colorScheme.keyword)

        // Code blocks
        let codeBlockPattern = "`[^`]+`|```[\\s\\S]*?```"
        highlightPattern(codeBlockPattern, in: text, textStorage: textStorage, color: colorScheme.function)

        // Links
        let linkPattern = "\\[([^\\]]+)\\]\\([^)]+\\)"
        highlightPattern(linkPattern, in: text, textStorage: textStorage, color: colorScheme.string)
    }

    private func highlightGeneric(text: String, textStorage: NSTextStorage, range: NSRange) {
        // Generic highlighting for unknown file types
        highlightComments(in: text, textStorage: textStorage, commentStyle: .slashSlash)
        highlightStrings(in: text, textStorage: textStorage)
        highlightNumbers(in: text, textStorage: textStorage)
    }

    // MARK: - Helper Methods

    private enum CommentStyle {
        case slashSlash
        case hash
        case slashStar
    }

    private func highlightKeywords(_ keywords: [String], in text: String, textStorage: NSTextStorage, color: NSColor) {
        for keyword in keywords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            highlightPattern(pattern, in: text, textStorage: textStorage, color: color)
        }
    }

    private func highlightComments(in text: String, textStorage: NSTextStorage, commentStyle: CommentStyle) {
        let pattern: String
        switch commentStyle {
        case .slashSlash:
            pattern = "//.*$"
        case .hash:
            pattern = "#.*$"
        case .slashStar:
            pattern = "/\\*[\\s\\S]*?\\*/"
        }

        highlightPattern(pattern, in: text, textStorage: textStorage, color: colorScheme.comment)
    }

    private func highlightStrings(in text: String, textStorage: NSTextStorage) {
        // Double quoted strings
        let doubleQuotePattern = "\"([^\"\\\\]|\\\\.)*\""
        highlightPattern(doubleQuotePattern, in: text, textStorage: textStorage, color: colorScheme.string)

        // Single quoted strings
        let singleQuotePattern = "'([^'\\\\]|\\\\.)*'"
        highlightPattern(singleQuotePattern, in: text, textStorage: textStorage, color: colorScheme.string)
    }

    private func highlightNumbers(in text: String, textStorage: NSTextStorage) {
        // Integer and floating point numbers
        let numberPattern = "\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b"
        highlightPattern(numberPattern, in: text, textStorage: textStorage, color: colorScheme.number)
    }

    private func highlightPattern(_ pattern: String, in text: String, textStorage: NSTextStorage, color: NSColor) {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            let range = NSRange(location: 0, length: text.count)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                textStorage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        } catch {
            // Silently ignore regex errors
        }
    }
}