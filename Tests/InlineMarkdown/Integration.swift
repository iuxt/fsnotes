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
        expect(element("Setext").hidden.map { text.substring(with: $0) } == ["======\n"], "setext underline and line break collapsed")
        expect(element("reference").hidden.map { text.substring(with: $0) } == ["[", "][id]"], "reference link label")
        let escaped = plan.elements.filter { $0.hidden.contains { text.substring(with: $0) == "\\" } }
        expect(escaped.count == 2, "escaped punctuation")
        let code = MarkdownPresentation.parse("`` a`b ``\n").elements[0]
        expect(code.hidden.map { ("`` a`b ``\n" as NSString).substring(with: $0) } == ["``", "``"], "multiple code backticks")
        let crlf = MarkdownPresentation.parse("# 中文 😀\r\n\r\n**bold**\r\n")
        expect(crlf.elements.count == 2, "CRLF and UTF-8 source mapping")

        let storage = NSTextStorage(string: source, attributes: [.font: UserDefaultsManagement.noteFont])
        plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
            font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: .labelColor, codeBackground: .quaternaryLabelColor, codeSpanBackground: .quaternaryLabelColor)
        let snapshot = NSAttributedString(attributedString: storage)
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
        expect(!manager.hiddenMarkdownCharacters.contains(range("```swift").location), "code caret reveals fence and language")
        expect(!manager.hiddenMarkdownCharacters.contains(range("```\n\n~~~").location), "code caret reveals closing fence")
        editor.setSelectedRange(range("**粗体** and *italic*"))
        expect(!manager.hiddenMarkdownCharacters.contains(boldRange.location) && !manager.hiddenMarkdownCharacters.contains(range("*italic*").location), "selection reveals intersected constructs")
        window.makeFirstResponder(nil)
        editor.refreshInlineTables()
        expect(manager.hiddenMarkdownCharacters.contains(boldRange.location), "inactive editor renders selected content")
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

        if let output = ProcessInfo.processInfo.environment["FSNOTES_MARKDOWN_PREVIEW"] {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: source)
            plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
                font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                textColor: .labelColor, codeBackground: .quaternaryLabelColor, codeSpanBackground: .quaternaryLabelColor)
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
