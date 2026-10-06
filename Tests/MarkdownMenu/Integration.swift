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
        if ProcessInfo.processInfo.environment["FSNOTES_MENU_DEMO"] == "1" {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "FSNotes Table Menu Check"
            window.contentView = editor
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }
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

        let tableItem = menu.items.first { $0.identifier?.rawValue == "format.table" }!
        let picker = tableItem.submenu!.items[0].view as! TableSizePickerView
        let cells = picker.accessibilityChildren() as! [NSAccessibilityElement]
        expect(cells.count == 96 && cells.allSatisfy { $0.isAccessibilityEnabled() }, "every grid cell exposes an enabled size choice")
        expect(cells[29].accessibilityLabel() == "3 rows × 6 columns", "accessible cell labels match visible grid dimensions")
        func hover(_ row: Int, _ column: Int) {
            let rect = picker.cellRect(row: row - 1, column: column - 1)
            picker.updateSelection(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        hover(3, 6)
        expect(picker.selectedRows == 3 && picker.selectedColumns == 6, "hover selects the rectangular 3 by 6 area")
        expect(picker.selectionTitle == "3 rows × 6 columns", "hover label reports rows before columns")
        hover(8, 12)
        expect(picker.selectedRows == 8 && picker.selectedColumns == 12, "bottom-right cell selects the maximum size")
        hover(1, 1)
        expect(picker.selectedRows == 1 && picker.selectedColumns == 1, "moving back shrinks the selection")
        picker.updateSelection(at: NSPoint(x: -1, y: -1))
        expect(picker.selectedRows == 0 && picker.selectedColumns == 0, "leaving the grid clears the selection")
        expect(!picker.accessibilityPerformPress(), "clicking outside the grid does not insert")

        load("", selection: NSRange(location: 0, length: 0))
        let clickMenu = editor.makeMarkdownContextMenu()!
        let clickPicker = clickMenu.items.first { $0.identifier?.rawValue == "format.table" }!.submenu!.items[0].view as! TableSizePickerView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = clickPicker
        let cell = clickPicker.cellRect(row: 2, column: 5)
        let clickPoint = clickPicker.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: clickPoint, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)!
        }
        clickPicker.mouseMoved(with: mouse(.mouseMoved))
        expect(clickPicker.selectedRows == 3 && clickPicker.selectedColumns == 6, "native mouse coordinates update the picker")
        clickPicker.mouseDown(with: mouse(.leftMouseDown))
        clickPicker.mouseUp(with: mouse(.leftMouseUp))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let inserted = MarkdownTable.parse(editor.string)
        expect(inserted.count == 1 && inserted[0].rows.count == 3 && inserted[0].alignments.count == 6,
               "click inserts exactly the chosen visible rows and columns, excluding the Markdown delimiter")
        expect(editor.selectedRange() == inserted[0].rows[0].cells[0].range, "caret enters the first empty header cell")

        for (rows, columns) in [(1, 1), (8, 12)] {
            load("", selection: NSRange(location: 0, length: 0))
            editor.insertTable(rows: rows, columns: columns, replacementRange: editor.selectedRange())
            let table = MarkdownTable.parse(editor.string)[0]
            expect(table.rows.count == rows && table.alignments.count == columns, "minimum and maximum sizes produce valid tables")
        }
        let surrounding = "中文😀beforeafter"
        load(surrounding, selection: NSRange(location: 10, length: 0))
        editor.undoManager?.beginUndoGrouping()
        editor.insertTable(rows: 3, columns: 2, replacementRange: editor.selectedRange())
        editor.undoManager?.endUndoGrouping()
        expect(editor.string.hasPrefix("中文😀before\n\n| ") && editor.string.hasSuffix("\n\nafter"),
               "mid-paragraph insertion preserves Unicode text and separates the table")
        let withTable = editor.string
        editor.undoManager?.undo()
        expect(editor.string == surrounding, "inserting a table is one undo step")
        editor.undoManager?.redo()
        expect(editor.string == withTable, "table insertion supports redo")
        load("before\r\n\r\nafter", selection: NSRange(location: 10, length: 0))
        editor.insertTable(rows: 2, columns: 2, replacementRange: editor.selectedRange())
        expect(editor.string.hasPrefix("before\r\n\r\n| ") && editor.string.hasSuffix("\r\n\r\nafter"),
               "existing blank paragraphs and CRLF are preserved")
        expect(!editor.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF notes use CRLF table rows")
        let existingTable = editor.string
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertTable(rows: 1, columns: 1, replacementRange: editor.selectedRange())
        expect(MarkdownTable.parse(editor.string).count == 2, "a neighboring table remains a separate table")
        load("replace", selection: NSRange(location: 0, length: 7))
        editor.insertTable(rows: 1, columns: 1, replacementRange: editor.selectedRange())
        expect(!editor.string.contains("replace") && MarkdownTable.parse(editor.string).count == 1, "table replaces the current selection")
        load(existingTable, selection: NSRange(location: 0, length: 0))
        editor.insertTable(rows: 0, columns: 2, replacementRange: editor.selectedRange())
        editor.insertTable(rows: 2, columns: 13, replacementRange: editor.selectedRange())
        editor.insertTable(rows: 2, columns: 2, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.isEditable = false
        editor.insertTable(rows: 2, columns: 2, replacementRange: editor.selectedRange())
        expect(editor.string == existingTable, "invalid sizes, stale ranges and read-only notes cannot insert")
        editor.isEditable = true
        editor.note?.markdown = false
        editor.insertTable(rows: 2, columns: 2, replacementRange: editor.selectedRange())
        expect(editor.string == existingTable, "plain-text notes cannot insert Markdown tables")
        editor.note?.markdown = true
        load("original", selection: NSRange(location: 0, length: 0))
        let oldMenu = editor.makeMarkdownContextMenu()!
        let oldPicker = oldMenu.items.first { $0.identifier?.rawValue == "format.table" }!.submenu!.items[0].view as! TableSizePickerView
        editor.note = Note()
        oldPicker.updateSelection(at: NSPoint(x: 20, y: 50))
        expect(oldPicker.accessibilityPerformPress(), "picker can submit an active selection")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        expect(editor.string == "original", "a pending picker action cannot insert into another note")

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
