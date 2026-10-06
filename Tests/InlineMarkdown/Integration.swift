import Cocoa

private var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}

@main struct Integration {
    static func main() throws {
        _ = NSApplication.shared
        let source = """
        # 标题 😀

        **粗体** and *italic* and ~~removed~~ and `a*b`

        [嵌套 **链接**](https://example.com/a_(b) "title") and [[笔记]]

        - item
        - [ ] task
        1. numbered

        > 引用 **strong**

        ---

        ```swift
        let value = "**literal**"
        ```

        ~~~text
        # also literal
        ~~~

        Setext
        ======

        [reference][id]

        [id]: https://example.com

        Escaped \\*literal\\* and <https://example.com>

        Last line
        """
        let text = source as NSString
        let plan = MarkdownPresentation.parse(source)
        func range(_ value: String) -> NSRange { text.range(of: value) }
        func element(_ value: String) -> MarkdownPresentation.Element {
            let found = range(value)
            guard let element = plan.elements.first(where: { $0.range.location <= found.location && NSMaxRange($0.range) >= NSMaxRange(found) }) else { fatalError("No element for " + value) }
            return element
        }
        expect(element("粗体").hidden.map { text.substring(with: $0) } == ["**", "**"], "Unicode bold markers")
        expect(element("italic").hidden.map { text.substring(with: $0) } == ["*", "*"], "italic markers")
        expect(element("removed").hidden.map { text.substring(with: $0) } == ["~~", "~~"], "strike markers")
        expect(element("a*b").hidden.map { text.substring(with: $0) } == ["`", "`"], "literal code content and backticks")
        expect(element("嵌套").hidden.last.map { text.substring(with: $0) } == "](https://example.com/a_(b) \"title\")", "balanced link destination hidden")
        expect(element("笔记").hidden.map { text.substring(with: $0) } == ["[[", "]]"], "wiki links")
        expect(element("task").decoration == .text("☐"), "task checkbox")
        expect(element("numbered").decoration == .text("1."), "ordered list")
        expect(element("引用").decoration == .quote, "quote bar")
        expect(element("---").decoration == .rule, "horizontal rule")
        expect(!plan.elements.contains { $0.hidden.contains { NSIntersectionRange($0, range("**literal**")).length > 0 } }, "fenced code isn't Markdown")
        expect(!plan.elements.contains { $0.hidden.contains { NSIntersectionRange($0, range("# also literal")).length > 0 } }, "tilde code isn't a heading")
        expect(!plan.elements.contains { $0.hidden.contains { NSIntersectionRange($0, range("```swift")).length > 0 } }, "opening fence and language are always visible")
        expect(!plan.elements.contains { $0.hidden.contains { NSIntersectionRange($0, range("```\n\n~~~")).length > 0 } }, "closing and tilde fences are always visible")
        expect(element("Setext").hidden.map { text.substring(with: $0) } == ["======\n"], "setext underline and line break collapsed")
        expect(element("reference").hidden.map { text.substring(with: $0) } == ["[", "][id]"], "reference link label")
        let escaped = plan.elements.filter { $0.hidden.contains { text.substring(with: $0) == "\\" } }
        expect(escaped.count == 2, "escaped punctuation")
        let code = MarkdownPresentation.parse("`` a`b ``\n").elements[0]
        expect(code.hidden.map { ("`` a`b ``\n" as NSString).substring(with: $0) } == ["``", "``"], "multiple code backticks")
        let html = MarkdownPresentation.parse("<b>literal</b> &amp; &#x1F600;\n")
        expect(html.elements.filter { $0.decoration == nil }.count == 2, "HTML tags are hidden at rest")
        expect(html.elements.contains { $0.decoration == .literal("&") }, "HTML entities are decoded")
        expect(html.elements.contains { $0.decoration == .literal("😀") }, "numeric Unicode entities")
        let footnotes = MarkdownPresentation.parse("text[^1]\n\n[^1]: footnote\n")
        expect(footnotes.elements.contains { $0.decoration == .footnote("1") }, "footnote reference")
        expect(footnotes.elements.contains { $0.decoration == .text("1.") }, "footnote definition prefix")
        let numbers = MarkdownPresentation.parse("3. three\n1. four\n")
        expect(numbers.elements.map { $0.decoration } == [.text("3."), .text("4.")], "ordered list display follows list numbering")
        let formattedWiki = MarkdownPresentation.parse("[[**note**]]\n")
        expect(formattedWiki.elements.count == 2, "formatted wiki labels hide both kinds of syntax")
        let inlineWikiCode = MarkdownPresentation.parse("`[[literal]]`\n")
        expect(inlineWikiCode.elements.count == 1, "wiki syntax within inline code stays literal")
        let invalidDefinition = MarkdownPresentation.parse("paragraph\n[id]: https://example.com\n")
        expect(!invalidDefinition.elements.contains { $0.hidden.contains { $0.length > 4 } }, "ordinary paragraph content isn't mistaken for a definition")
        let indent = MarkdownPresentation.parse("    **literal**\n")
        expect(indent.elements.count == 1 && indent.elements[0].hidden[0].length == 4, "indented code hides indentation without styling literal markers")
        let crlf = MarkdownPresentation.parse("# 中文 😀\r\n\r\n**bold**\r\n")
        expect(crlf.elements.count == 2, "CRLF and UTF-8 source mapping")

        let storage = NSTextStorage(string: source, attributes: [.font: UserDefaultsManagement.noteFont])
        plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
            font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: .labelColor)
        let snapshot = NSAttributedString(attributedString: storage)
        let boldFont = storage.attribute(.font, at: range("粗体").location, effectiveRange: nil) as! NSFont
        expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "bold presentation style")
        expect((storage.attribute(.font, at: range("标题").location, effectiveRange: nil) as! NSFont).pointSize == UserDefaultsManagement.noteFont.pointSize * MarkdownEditorStyle.headingScales[0], "heading size")
        expect(storage.attribute(.link, at: range("reference").location, effectiveRange: nil) as? String == "https://example.com", "reference links stay clickable")
        let manager = LayoutManager()
        manager.delegate = manager
        let container = NSTextContainer(containerSize: NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 1100), textContainer: container)
        editor.processor = TextStorageProcessor()
        editor.processor.editor = editor
        manager.processor = editor.processor
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        editor.setSelectedRange(NSRange(location: range("Last line").location, length: 0))
        window.makeFirstResponder(editor)
        editor.refreshInlineTables()
        manager.ensureLayout(for: container)
        let openingFence = range("```swift").location
        let closingFence = range("```\n\n~~~").location
        func codeLine(at index: Int) -> NSRect {
            manager.ensureLayout(for: container)
            return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        let readingCodeLine = codeLine(at: openingFence)
        expect(!manager.hiddenMarkdownCharacters.contains(openingFence) && !manager.hiddenMarkdownCharacters.contains(closingFence), "reading code retains both fences")
        expect(manager.hiddenMarkdownCharacters.contains(range("**粗体**").location), "inactive bold is hidden")
        let boldRange = range("**粗体**")
        editor.setSelectedRange(NSRange(location: range("粗体").location, length: 0))
        expect(!manager.hiddenMarkdownCharacters.contains(boldRange.location), "caret reveals paired delimiters")
        expect(manager.hiddenMarkdownCharacters.contains(range("*italic*").location), "unrelated inline syntax stays rendered")
        editor.setSelectedRange(NSRange(location: NSMaxRange(boldRange), length: 0))
        expect(!manager.hiddenMarkdownCharacters.contains(boldRange.location), "caret at closing delimiter remains editable")
        editor.setSelectedRange(NSRange(location: range("Last line").location, length: 0))
        expect(manager.hiddenMarkdownCharacters.contains(boldRange.location), "leaving hides syntax again")
        let literal = range("let value")
        editor.setSelectedRange(NSRange(location: literal.location, length: 0))
        expect(!manager.hiddenMarkdownCharacters.contains(openingFence), "editing keeps the opening fence and language")
        expect(!manager.hiddenMarkdownCharacters.contains(closingFence), "editing keeps the closing fence")
        expect(codeLine(at: openingFence) == readingCodeLine, "entering code does not change its line position")
        let lastFenceGlyph = manager.glyphIndexForCharacter(at: closingFence + 2)
        let fenceRect = manager.lineFragmentUsedRect(forGlyphAt: lastFenceGlyph, effectiveRange: nil)
        let fencePoint = NSPoint(x: editor.textContainerOrigin.x + fenceRect.maxX + 2,
                                y: editor.textContainerOrigin.y + fenceRect.midY)
        expect(editor.characterIndexForInsertion(at: fencePoint) == closingFence + 3, "mouse insertion can reach the end of three backticks")
        editor.setSelectedRange(NSRange(location: range("Last line").location, length: 0))
        expect(codeLine(at: openingFence) == readingCodeLine, "leaving code does not collapse its fences")
        editor.setSelectedRange(range("**粗体** and *italic*"))
        expect(!manager.hiddenMarkdownCharacters.contains(boldRange.location) && !manager.hiddenMarkdownCharacters.contains(range("*italic*").location), "selection reveals intersected constructs")
        window.makeFirstResponder(nil)
        editor.refreshInlineTables()
        expect(manager.hiddenMarkdownCharacters.contains(boldRange.location), "inactive editor renders selected content")
        expect(!manager.hiddenMarkdownCharacters.contains(openingFence) && !manager.hiddenMarkdownCharacters.contains(closingFence), "unfocused preview retains code fences")
        expect(storage.isEqual(to: snapshot), "caret movement preserves source, attributes and undo")
        editor.note!.markdown = false
        editor.refreshInlineTables()
        expect(manager.hiddenMarkdownCharacters.isEmpty && manager.markdownDecorations.isEmpty, "plain text has no rendering")
        editor.note!.markdown = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "**unfinished")
        expect(manager.hiddenMarkdownCharacters.isEmpty, "incomplete syntax stays editable")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "**finished**\n")
        expect(manager.hiddenMarkdownCharacters.contains(0), "typing closing syntax updates display plan")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        expect(manager.hiddenMarkdownCharacters.isEmpty, "empty note clears hidden glyphs")

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("fsnotes-inline-image-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let imageSource = "![图片](" + imageURL.path + ")\nAfter image\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: imageSource)
        editor.refreshInlineTables()
        manager.ensureLayout(for: container)
        expect(manager.markdownDecorations[0] != nil && manager.hiddenMarkdownCharacters.contains(0), "image preview hides source")
        let imageSize = manager.markdownDecorationSize(manager.markdownDecorations[0]!, in: container)
        expect(imageSize.width <= 460 && abs(imageSize.width / imageSize.height - 2) < 0.01, "image fits width and preserves aspect ratio")
        let afterImage = (imageSource as NSString).range(of: "After image").location
        let following = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: afterImage), effectiveRange: nil)
        expect(following.minY >= imageSize.height, "image reserves height before following text")
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        expect(manager.markdownDecorations[0] == nil && !manager.hiddenMarkdownCharacters.contains(0), "image caret reveals editable alt text and path")
        editor.setSelectedRange(NSRange(location: afterImage, length: 0))
        expect(manager.markdownDecorations[0] != nil, "leaving image restores preview")
        window.makeFirstResponder(nil)
        let taskSource = "- [x] complete\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: taskSource)
        let taskPlan = MarkdownPresentation.parse(taskSource)
        taskPlan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
            font: UserDefaultsManagement.noteFont, codeFont: UserDefaultsManagement.noteFont,
            textColor: .labelColor)
        expect(manager.markdownDecorations[0] == .text("☑"), "checked task preview")
        expect(storage.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) as? Int == 1, "checked tasks retain completed styling")

        if let output = ProcessInfo.processInfo.environment["FSNOTES_MARKDOWN_PREVIEW"] {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
            plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
                font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                textColor: .labelColor)
            editor.refreshInlineTables()
            manager.ensureLayout(for: container)
            editor.frame.size.height = manager.usedRect(for: container).height + 30
            let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)!
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        print("Inline Markdown integration: \(checks) checks passed")
    }
}
