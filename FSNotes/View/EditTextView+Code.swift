import Cocoa

extension EditTextView {
    func updateCodeCopyButtons() {
        guard note?.isMarkdown() == true, let manager = layoutManager as? LayoutManager,
              let container = textContainer else {
            removeCodeCopyButtons()
            return
        }
        let blocks = manager.markdownPresentation.codeBlocks
        let starts = Set(blocks.map { $0.range.location })
        for (start, button) in codeCopyButtons where !starts.contains(start) {
            button.removeFromSuperview()
            codeCopyButtons.removeValue(forKey: start)
        }
        for block in blocks {
            let start = block.range.location
            let button: InlineCodeCopyButton
            if let existing = codeCopyButtons[start] {
                button = existing
            } else {
                button = InlineCodeCopyButton(frame: .zero)
                button.tag = start
                button.target = self
                button.action = #selector(copyCodeBlock(_:))
                codeCopyButtons[start] = button
                addSubview(button)
            }
            manager.ensureLayout(forCharacterRange: NSRange(location: start, length: 1))
            let glyph = manager.glyphIndexForCharacter(at: start)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let size = MarkdownEditorStyle.codeCopyButtonSize
            button.frame = NSRect(x: textContainerOrigin.x + container.size.width - container.lineFragmentPadding - size - 6,
                                  y: textContainerOrigin.y + line.minY + (line.height - size) / 2,
                                  width: size, height: size)
            button.isHidden = isPreviewEnabled()
        }
    }

    func removeCodeCopyButtons() {
        for button in codeCopyButtons.values { button.removeFromSuperview() }
        codeCopyButtons.removeAll()
    }

    /// Read the current parse so a click immediately after typing copies the new text.
    @discardableResult
    func copyCodeBlock(at start: Int, to pasteboard: NSPasteboard) -> Bool {
        guard note?.isMarkdown() == true, let manager = layoutManager as? LayoutManager else { return false }
        manager.refreshInlineMarkdown()
        guard let block = manager.markdownPresentation.codeBlocks.first(where: { $0.range.location == start }) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(block.content, forType: .string)
    }

    @objc func copyCodeBlock(_ sender: InlineCodeCopyButton) {
        if copyCodeBlock(at: sender.tag, to: .general) { sender.showCopied() }
    }
}

final class InlineCodeCopyButton: NSButton {
    private var feedbackTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleProportionallyDown
        setAccessibilityIdentifier("code-copy")
        showCopyIcon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { feedbackTimer?.invalidate() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func showCopied() {
        feedbackTimer?.invalidate()
        image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        toolTip = NSLocalizedString("Copied", comment: "Code block copy confirmation")
        setAccessibilityLabel(toolTip)
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.showCopyIcon()
        }
    }

    private func showCopyIcon() {
        image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        toolTip = NSLocalizedString("Copy code", comment: "Code block copy button")
        setAccessibilityLabel(toolTip)
    }
}
