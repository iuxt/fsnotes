import Cocoa

private var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}

private final class RecordingLayoutManager: LayoutManager {
    var invalidatedRanges: [NSRange] = []
    override func invalidateGlyphs(forCharacterRange range: NSRange, changeInLength delta: Int,
                                   actualCharacterRange actual: NSRangePointer?) {
        invalidatedRanges.append(range)
        super.invalidateGlyphs(forCharacterRange: range, changeInLength: delta, actualCharacterRange: actual)
    }
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
        let codeCases: [(String, String)] = [
            ("```swift\nlet value = \"中文 😀\"\n```\n", "let value = \"中文 😀\"\n"),
            ("~~~~text\na ``` fence\n\n  indented\n~~~~\n", "a ``` fence\n\n  indented\n"),
            ("    one\n    two\n", "one\ntwo\n"),
            ("> ```js\n> console.log(1)\n> ```\n", "console.log(1)\n"),
            ("- ```sh\n  echo hi\n  ```\n", "echo hi\n"),
            ("```\r\none\r\ntwo\r\n```\r\n", "one\ntwo\n"),
            ("```\n```\n", ""),
            ("```python\nprint(1)", "print(1)\n")
        ]
        for (markdown, content) in codeCases {
            expect(MarkdownPresentation.parse(markdown).codeBlocks.map { $0.content } == [content],
                   "copy payload excludes fences, language and enclosing Markdown: " + markdown)
        }
        expect(MarkdownPresentation.parse("`inline code`\n").codeBlocks.isEmpty, "inline code has no block copy button")

        let storage = NSTextStorage(string: source, attributes: [.font: UserDefaultsManagement.noteFont])
        plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
            font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: .labelColor)
        let snapshot = NSAttributedString(attributedString: storage)
        let boldFont = storage.attribute(.font, at: range("粗体").location, effectiveRange: nil) as! NSFont
        expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "bold presentation style")
        expect((storage.attribute(.font, at: range("标题").location, effectiveRange: nil) as! NSFont).pointSize == UserDefaultsManagement.noteFont.pointSize * MarkdownEditorStyle.headingScales[0], "heading size")
        expect(storage.attribute(.link, at: range("reference").location, effectiveRange: nil) as? String == "https://example.com", "reference links stay clickable")
        let manager = RecordingLayoutManager()
        manager.delegate = manager
        let container = NSTextContainer(containerSize: NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 1100), textContainer: container)
        editor.isEditable = true
        editor.allowsUndo = true
        editor.processor = TextStorageProcessor()
        editor.processor.editor = editor
        manager.processor = editor.processor
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        editor.setSelectedRange(NSRange(location: range("Last line").location, length: 0))
        window.makeFirstResponder(editor)
        editor.refreshInlineTables()
        manager.ensureLayout(for: container)
        editor.updateCodeCopyButtons()
        expect(editor.codeCopyButtons.count == 2, "each code block has a native copy button")
        let firstCode = plan.codeBlocks[0]
        let copyButton = editor.codeCopyButtons[firstCode.range.location]!
        expect(copyButton.superview === editor && !copyButton.isHidden, "copy button is visible in the editor")
        expect(copyButton.target === editor && copyButton.action == #selector(EditTextView.copyCodeBlock(_:)), "copy button invokes the clipboard action")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fsnotes-code-copy-tests"))
        defer { pasteboard.releaseGlobally() }
        let originalSelection = editor.selectedRange()
        expect(editor.copyCodeBlock(at: firstCode.range.location, to: pasteboard), "copy writes to the clipboard")
        expect(pasteboard.string(forType: .string) == "let value = \"**literal**\"\n", "clipboard contains only literal code")
        expect(editor.selectedRange() == originalSelection && storage.isEqual(to: snapshot), "copy preserves selection and note source")
        let initialButtonFrame = copyButton.frame
        container.size.width = 360
        editor.updateCodeCopyButtons()
        expect(copyButton.frame.minX == initialButtonFrame.minX - 100, "copy button follows container resizing")
        container.size.width = 460
        editor.updateCodeCopyButtons()
        editor.previewEnabled = true
        editor.updateCodeCopyButtons()
        expect(editor.codeCopyButtons.values.allSatisfy { $0.isHidden }, "web preview hides native copy buttons")
        editor.previewEnabled = false
        editor.updateCodeCopyButtons()
        let literalRange = range("**literal**")
        storage.replaceCharacters(in: literalRange, with: "updated")
        expect(editor.copyCodeBlock(at: firstCode.range.location, to: pasteboard), "copy reads a block immediately after an edit")
        expect(pasteboard.string(forType: .string) == "let value = \"updated\"\n", "copy uses the latest code content")
        storage.setAttributedString(snapshot)
        editor.refreshInlineTables()
        editor.updateCodeCopyButtons()
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
        editor.updateCodeCopyButtons()
        expect(editor.codeCopyButtons.isEmpty && copyButton.superview == nil, "plain text removes native code buttons")
        expect(manager.hiddenMarkdownCharacters.isEmpty && manager.markdownDecorations.isEmpty, "plain text has no rendering")
        editor.note!.markdown = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "**unfinished")
        editor.refreshInlineTables()
        editor.updateCodeCopyButtons()
        expect(editor.codeCopyButtons.isEmpty, "switching to a note without code leaves no copy buttons")
        expect(!editor.copyCodeBlock(at: firstCode.range.location, to: pasteboard), "stale code locations do not overwrite the clipboard")
        expect(manager.hiddenMarkdownCharacters.isEmpty, "incomplete syntax stays editable")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "**finished**\n")
        expect(manager.hiddenMarkdownCharacters.contains(0), "typing closing syntax updates display plan")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        expect(manager.hiddenMarkdownCharacters.isEmpty, "empty note clears hidden glyphs")

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("fsnotes-inline-image-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.83, green: 0.9, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 800, height: 400).fill()
        NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 80, y: -150, width: 800, height: 400)).fill()
        NSGraphicsContext.restoreGraphicsState()
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
        expect(manager.markdownDecorations[0] != nil && manager.hiddenMarkdownCharacters.contains(0), "image caret keeps preview")
        let imageElement = manager.markdownPresentation.elements.first!
        expect([0, NSMaxRange(imageElement.range)].contains(editor.selectedRange().location), "caret snaps outside image source")
        func followingImageLine() -> NSRect {
            manager.ensureLayout(for: container)
            let index = (editor.string as NSString).range(of: "After image").location
            return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        expect(followingImageLine() == following, "entering image keeps following text position")
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        expect(editor.selectedRange() == imageElement.range, "partial image selection expands to entire object")
        expect(followingImageLine() == following, "selecting image keeps following text position")
        window.makeFirstResponder(nil)
        editor.refreshInlineTables()
        expect(followingImageLine() == following, "losing focus keeps image layout")
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.moveRight(nil)
        expect(editor.selectedRange().location == NSMaxRange(imageElement.range), "right arrow skips hidden image source")
        editor.moveLeft(nil)
        expect(editor.selectedRange().location == 0, "left arrow skips hidden image source")
        editor.textContainerInset = NSSize(width: 13, height: 17)
        let imageRect = manager.inlineImageRect(imageElement, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let center = NSPoint(x: imageRect.midX, y: imageRect.midY)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(center, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        expect(editor.handleImageClick(event), "image click handled before native text selection")
        expect(editor.selectedRange() == imageElement.range, "single click selects image")
        expect(editor.inlineImage(at: NSPoint(x: imageRect.maxX + 8, y: imageRect.midY)) == nil, "hit testing excludes surrounding whitespace")
        expect(editor.string == imageSource, "navigation and clicks preserve source")
        expect(followingImageLine() == following, "clicking image keeps following text position")
        let menu = editor.makeImageContextMenu(for: event)!
        expect(menu.items.count == 3 && menu.items.allSatisfy { $0.isEnabled }, "image menu exposes open, edit and delete")
        let popover = NSPopover()
        let panel = InlineImagePropertiesController(owner: editor, image: imageElement, popover: popover)
        _ = panel.view
        if let output = ProcessInfo.processInfo.environment["FSNOTES_IMAGE_PREVIEW"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                let panelWindow = NSWindow(contentRect: panel.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
                panelWindow.appearance = window.appearance
                panelWindow.contentView = panel.view
                panelWindow.orderFront(nil)
                panel.view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                for (stage, view) in [("selected", editor as NSView), ("properties", panel.view)] {
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: image)
                        let composite = NSImage(size: view.bounds.size)
                        composite.lockFocus()
                        (name == "light" ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)).setFill()
                        NSRect(origin: .zero, size: view.bounds.size).fill()
                        let foreground = NSImage(size: view.bounds.size)
                        foreground.addRepresentation(image)
                        foreground.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero,
                                        operation: .sourceOver, fraction: 1)
                        composite.unlockFocus()
                        let rendered = NSBitmapImageRep(data: composite.tiffRepresentation!)!
                        try! rendered.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(stage + "-" + name + ".png"))
                    }
                }
                panelWindow.orderOut(nil)
                panelWindow.contentView = nil
            }
        }
        panel.altField.stringValue = "更新 [说明] 😀"
        panel.save(nil)
        expect(editor.string.contains("![更新 \\[说明\\] 😀]"), "properties edit escapes brackets and preserves Unicode")
        expect(manager.markdownDecorations[0] != nil && followingImageLine() == following, "saving description preserves image and document height")
        editor.undoManager?.undo()
        expect(editor.string == imageSource, "properties change can be undone")
        let cancelled = InlineImagePropertiesController(owner: editor, image: imageElement, popover: popover)
        _ = cancelled.view
        cancelled.altField.stringValue = "discarded"
        cancelled.cancel(nil)
        expect(editor.string == imageSource, "cancelling image edit preserves source")
        let stale = InlineImagePropertiesController(owner: editor, image: imageElement, popover: popover)
        _ = stale.view
        stale.altField.stringValue = "wrong note"
        let initialNote = editor.note
        editor.note = Note()
        stale.save(nil)
        expect(editor.string == imageSource, "properties panel cannot edit another note")
        editor.note = initialNote
        let serialized = MarkdownPresentation.imageSource(altText: "changed", destination: "/tmp/a b(1).png",
            original: "![old](old.png \"tooltip\")", originalAltText: "old")
        let serializedPlan = MarkdownPresentation.parse(serialized)
        expect(serializedPlan.elements.first?.decoration == .image(destination: "/tmp/a b(1).png", title: "changed"), "image properties support spaces and balanced parentheses in paths")
        expect(serialized.contains("\"tooltip\""), "image properties preserve optional title")
        editor.undoManager?.removeAllActions()
        func deleteEvent(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        editor.setSelectedRange(NSRange(location: NSMaxRange(imageElement.range), length: 0))
        expect(editor.handleImageKeyDown(deleteEvent(51)), "backspace at image end deletes whole image")
        expect(editor.string == "\nAfter image\n", "backspace leaves no broken Markdown")
        editor.undoManager?.undo()
        expect(editor.string == imageSource && manager.markdownDecorations[0] != nil, "undo restores image source and preview")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        expect(editor.handleImageKeyDown(deleteEvent(117)), "forward delete at image start deletes whole image")
        editor.undoManager?.undo()
        expect(editor.string == imageSource, "forward deletion can be undone")
        editor.setSelectedRange(imageElement.range)
        editor.deleteSelectedImage(nil)
        expect(editor.string == "\nAfter image\n", "image menu deletion removes entire syntax")
        editor.undoManager?.undo()
        expect(editor.string == imageSource, "menu deletion can be undone")
        editor.note!.markdown = false
        editor.refreshInlineTables()
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        expect(editor.selectedRange().location == 3 && manager.markdownDecorations.isEmpty, "plain text keeps raw image syntax editable")
        editor.note!.markdown = true
        editor.refreshInlineTables()
        editor.setSelectedRange(NSRange(location: afterImage, length: 0))
        expect(manager.markdownDecorations[0] != nil, "leaving image retains preview")
        window.makeFirstResponder(nil)
        let taskSource = "- [x] complete\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: taskSource)
        let taskPlan = MarkdownPresentation.parse(taskSource)
        taskPlan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
            font: UserDefaultsManagement.noteFont, codeFont: UserDefaultsManagement.noteFont,
            textColor: .labelColor)
        expect(manager.markdownDecorations[0] == .text("☑"), "checked task preview")
        expect(storage.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) as? Int == 1, "checked tasks retain completed styling")

        // A long note must keep its parse and distant glyphs across caret/attribute changes.
        let longSource = "First **bold** 中文😀\n\n" + String(repeating: "Unchanged paragraph.\n\n", count: 3000) + "**tail**\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: longSource)
        editor.refreshInlineTables()
        let parseCount = manager.markdownParseCount
        _ = MarkdownPresentation.presentation(for: storage)
        _ = manager.presentation(for: storage.string)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: 5))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        expect(manager.markdownParseCount == parseCount, "caret and attribute updates reuse the document parse")
        manager.invalidatedRanges.removeAll()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀")
        expect(manager.markdownParseCount == parseCount + 1, "one source edit parses exactly once across all consumers")
        expect(!manager.invalidatedRanges.isEmpty && manager.invalidatedRanges.allSatisfy { NSMaxRange($0) < 100 },
               "local insertion never invalidates distant glyphs")
        let expectedHidden = manager.markdownPresentation.elements.reduce(into: IndexSet()) { indexes, element in
            for range in element.hidden { indexes.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        expect(manager.hiddenMarkdownCharacters == expectedHidden, "Unicode insertion shifts hidden syntax in unchanged suffix")
        manager.invalidatedRanges.removeAll()
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        expect(manager.hiddenMarkdownCharacters.contains((longSource as NSString).range(of: "**tail**").location),
               "Unicode deletion restores suffix syntax positions")
        expect(manager.invalidatedRanges.allSatisfy { NSMaxRange($0) < 100 }, "local deletion keeps distant layout valid")

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
