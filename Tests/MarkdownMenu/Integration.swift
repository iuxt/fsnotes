import Cocoa

@main struct MarkdownMenuTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func main() {
        _ = NSApplication.shared
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        editor.isEditable = true
        editor.allowsUndo = true
        func load(_ text: String, selection: NSRange) {
            editor.string = text
            editor.setSelectedRange(selection)
            editor.undoManager?.removeAllActions()
        }
        func heading(_ level: Int) {
            let item = NSMenuItem()
            item.identifier = NSUserInterfaceItemIdentifier("format.h\(level)")
            editor.headerMenu(item)
        }
        let action = NSMenuItem()
        load("中文 😀", selection: NSRange(location: 0, length: 5))
        let menu = editor.makeMarkdownContextMenu()!
        expect(editor.selectedRange() == NSRange(location: 0, length: 5), "opening the menu preserves the selection")
        let actionable = menu.items.flatMap { $0.submenu?.items ?? [$0] }.filter { $0.action != nil }
        expect(actionable.count == 17, "formatting, paragraph, six heading levels, code and lists are available")
        expect(actionable.allSatisfy { $0.target === editor && editor.responds(to: $0.action!) }, "actions target this editor")
        expect(editor.makeMarkdownContextMenu()!.items.count == menu.items.count, "reopening does not duplicate menu items")
        editor.isEditable = false
        expect(editor.makeMarkdownContextMenu() == nil, "read-only editors offer no formatting")
        editor.isEditable = true
        editor.note?.markdown = false
        expect(editor.makeMarkdownContextMenu() == nil, "plain-text notes offer no Markdown formatting")
        editor.note?.markdown = true

        load("# C# 😀\r\nsecond\r\n\r\nlast", selection: NSRange(location: 0, length: 17))
        heading(3)
        expect(editor.string == "### C# 😀\r\n### second\r\n\r\nlast", "multi-line headings preserve content, blank lines and CRLF")
        let once = editor.string
        heading(3)
        expect(editor.string == once, "setting a heading level is idempotent")
        heading(0)
        expect(editor.string == "C# 😀\r\nsecond\r\n\r\nlast", "paragraph removes only heading prefixes")
        for level in 1...6 {
            load("中文 😀 #tag", selection: NSRange(location: 3, length: 0))
            heading(level)
            expect(editor.string == String(repeating: "#", count: level) + " 中文 😀 #tag", "heading level \(level)")
            expect(editor.selectedRange().location == 4 + level, "heading preserves the caret relative to Unicode content")
        }
        load("", selection: NSRange(location: 0, length: 0))
        heading(2)
        expect(editor.string == "## " && editor.selectedRange().location == 3, "heading at an empty caret")
        load("# 中文 😀", selection: NSRange(location: 2, length: 5))
        editor.undoManager?.beginUndoGrouping()
        heading(4)
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.undo()
        expect(editor.string == "# 中文 😀", "heading change can be undone in one step")
        editor.undoManager?.redo()
        expect(editor.string == "#### 中文 😀", "heading change supports redo")

        load("😀before 中文 after", selection: ("😀before 中文 after" as NSString).range(of: "中文"))
        editor.undoManager?.beginUndoGrouping()
        editor.insertCodeBlock(action)
        editor.undoManager?.endUndoGrouping()
        expect(editor.string == "😀before \n```\n中文\n```\n after", "mid-paragraph selection gets standalone code fences")
        expect((editor.string as NSString).substring(with: editor.selectedRange()) == "中文", "code block retains the selected content")
        editor.undoManager?.undo()
        expect(editor.string == "😀before 中文 after", "code block can be undone in one step")
        load("😀", selection: NSRange(location: 2, length: 0))
        editor.insertCodeBlock(action)
        expect(editor.string == "😀\n```\n\n```\n" && editor.selectedRange().location == 7, "empty block caret is inside, even after a surrogate pair")
        load("```swift\nlet x = 1\n```", selection: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertCodeBlock(action)
        expect(editor.string.hasPrefix("````\n```swift\n") && editor.string.hasSuffix("```\n````\n"), "embedded fences remain literal")
        load("`中文 😀`", selection: NSRange(location: 0, length: 7))
        editor.insertCodeSpan(action)
        expect(editor.string == "`` `中文 😀` ``", "edge backticks are padded within longer inline delimiters")
        expect((editor.string as NSString).substring(with: editor.selectedRange()) == "`中文 😀`", "inline code preserves Unicode selection")
        load(" 中文 ", selection: NSRange(location: 0, length: 4))
        editor.insertCodeSpan(action)
        expect(editor.string == "`  中文  `", "inline code preserves surrounding spaces")
        load("", selection: NSRange(location: 0, length: 0))
        editor.insertCodeSpan(action)
        expect(editor.string == "``" && editor.selectedRange().location == 1, "empty inline code places the caret between delimiters")
        print("Markdown menu integration: \(checks) checks passed")
    }
}
