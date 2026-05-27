import Cocoa

class LineNumberRulerView: NSRulerView {
    private var textView: NSTextView?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        setup()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clientView = scrollView?.documentView
        ruleThickness = 50
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    func attach(to textView: NSTextView) {
        self.textView = textView
        clientView = textView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        if let textView = clientView as? NSTextView {
            self.textView = textView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange),
                name: NSText.didChangeNotification,
                object: textView
            )
        }
    }

    @objc private func textDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let textView = self.textView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        // Clear background
        let backgroundColor = NSColor(hex: "#181825") ?? NSColor.controlBackgroundColor
        backgroundColor.setFill()
        context.fill(bounds)

        // Draw separator line
        let separatorColor = NSColor(hex: "#313244") ?? NSColor.separatorColor
        separatorColor.setStroke()
        let separatorRect = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        context.stroke(separatorRect)

        let textString = textView.string as NSString
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Calculate line numbers for visible text
        var lineNumber = 1
        var charIndex = 0

        // Count lines before visible range
        while charIndex < characterRange.location {
            if textString.character(at: charIndex) == unichar(10) { // newline character
                lineNumber += 1
            }
            charIndex += 1
        }

        // Draw line numbers for visible lines
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let textColor = NSColor(hex: "#6c7086") ?? NSColor.secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        charIndex = characterRange.location

        while charIndex < NSMaxRange(characterRange) {
            let lineNumberString = "\(lineNumber)" as NSString
            let lineNumberSize = lineNumberString.size(withAttributes: attributes)

            let drawRect = NSRect(
                x: bounds.width - lineNumberSize.width - 8,
                y: lineRect.minY,
                width: lineNumberSize.width,
                height: lineNumberSize.height
            )

            lineNumberString.draw(in: drawRect, withAttributes: attributes)

            // Find next line
            let lineRange = textString.lineRange(for: NSRange(location: charIndex, length: 0))
            charIndex = NSMaxRange(lineRange)
            lineNumber += 1

            if charIndex < textString.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
        }
    }
}
