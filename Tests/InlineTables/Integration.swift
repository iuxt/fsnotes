import Cocoa

private var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func flushEvents() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

@main struct Integration {
    static func main() {
        _ = NSApplication.shared
        let source = "Before 😀\n\n| 名字 | Value |\n| :-- | --: |\n| 中文 | **bold** |\n| A\\|B | `code` |\n\nAfter\n"
        let table = MarkdownTable.parse(source)[0]
        expect(table.rows.count == 3, "delimiter isn't a displayed row")
        expect(table.alignments == [.left, .right], "column alignments")
        expect(table.rows[2].cells[0].text == "A\\|B", "escaped pipe")
        expect((source as NSString).substring(with: table.rows[1].cells[0].range) == "中文", "UTF-16 ranges")
        expect(MarkdownTable.parse("```md\n" + source + "```\n").isEmpty, "fenced code excluded")
        expect(MarkdownTable.parse("~~~\n" + source).isEmpty, "unclosed fence excluded")
        expect(MarkdownTable.parse("    | A | B |\n    | - | - |\n").isEmpty, "indented code excluded")
        expect(MarkdownTable.parse("A | B\n--- | ---\n1 | 2").count == 1, "optional outer pipes")
        expect(MarkdownTable.parse("| A | B |\n| --- |\n").isEmpty, "matching delimiters")
        expect(MarkdownTable.parse("| A |\n| ::--: |\n").isEmpty, "invalid alignment marker")
        expect(MarkdownTable.parse("| A | B |\r\n| - | - |\r\n| C | D |\r\n").count == 1, "CRLF")
        var document = MarkdownTableDocument(table)
        document.insertRow(at: 0)
        expect(document.rows[0] == ["名字", "Value"] && document.rows[1] == ["", ""], "inserting rows preserves header")
        document.insertColumn(at: 1)
        expect(document.rows.allSatisfy { $0.count == 3 }, "new column in every row")
        document.setCell(row: 1, column: 1, text: "  文本 | test\nnext ")
        expect(MarkdownTable.parse(document.markdown)[0].alignments.count == 3, "typed pipes don't split columns")
        expect(MarkdownTableDocument.editingText(document.rows[1][1]) == "  文本 | test\nnext ", "spaces and newlines round trip")
        document.removeColumn(at: 1)
        document.removeRow(at: 1)
        expect(document.rows == MarkdownTableDocument(table).rows, "delete row and column")
        expect(document.moveRow(from: 1, to: 3) == 2 && document.rows[2][0] == "中文", "move row down")
        expect(document.moveRow(from: 2, to: 1) == 1 && document.rows[1][0] == "中文", "move row up")
        expect(document.moveRow(from: 0, to: 3) == nil, "header stays fixed")
        let columnTable = MarkdownTable.parse("| A | B | C |\n| :--- | :---: | ---: |\n| a | b | c |\n| d |\n")[0]
        var columns = MarkdownTableDocument(columnTable)
        expect(columns.moveColumn(from: 0, to: 3) == 2, "first column moves to last boundary")
        expect(columns.rows == [["B", "C", "A"], ["b", "c", "a"], ["", "", "d"]], "column move preserves header, body and missing cells")
        expect(columns.alignments == [.center, .right, .left], "alignment follows moved column")
        expect(columns.moveColumn(from: 2, to: 0) == 0 && columns.rows == MarkdownTableDocument(columnTable).rows, "last column moves back to first")
        let beforeNoOp = columns.markdown
        expect(columns.moveColumn(from: 1, to: 2) == 1 && columns.markdown == beforeNoOp, "adjacent boundary does not change column order")
        expect(columns.moveColumn(from: -1, to: 0) == nil && columns.markdown == beforeNoOp, "invalid column leaves document unchanged")
        let single = MarkdownTable.parse("| A |\n| - |\n")[0]
        var oneColumn = MarkdownTableDocument(single)
        oneColumn.removeColumn(at: 0)
        expect(oneColumn.alignments.count == 1, "last column remains")

        let storage = NSTextStorage(string: source, attributes: [.font: UserDefaultsManagement.noteFont])
        let snapshot = NSAttributedString(attributedString: storage)
        let manager = LayoutManager()
        manager.delegate = manager
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        editor.isEditable = true
        editor.allowsUndo = true
        editor.processor = TextStorageProcessor()
        editor.processor.editor = editor
        manager.processor = editor.processor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        window.contentView = scroll
        editor.refreshInlineTables()
        editor.updateTableEditors()
        let view = editor.tableEditorViews[table.range.location]!
        if ProcessInfo.processInfo.environment["FSNOTES_TABLE_DEMO"] == "1" {
            window.title = "FSNotes Table Editor Check"
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }
        let rect = manager.inlineTableRect(table, in: container)
        expect(rect.width <= 400, "table fits editor")
        let afterIndex = (source as NSString).range(of: "After").location
        let afterRect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: afterIndex), effectiveRange: nil)
        expect(afterRect.minY >= rect.maxY, "following text stays below table")
        expect(afterRect.minY < rect.maxY + 75, "source lines do not add empty space")
        editor.setSelectedRange(NSRange(location: table.rows[1].cells[0].range.location, length: 0))
        expect(manager.inlineTables.count == 1, "caret stays in rendered table")
        expect(storage.isEqual(to: snapshot), "rendering preserves source and attributes")
        view.beginEditing(row: 1, column: 0)
        expect(window.firstResponder === view.cellEditor, "native cell editor receives focus")
        let field = view.cellEditor!
        let beforeSwitch = editor.string
        let beforeSwitchScroll = scroll.contentView.bounds.origin
        view.beginEditing(row: 1, column: 1)
        expect(view.cellEditor === field && field.string == "**bold**", "switching cells reuses native input and reveals only active source")
        expect(scroll.contentView.bounds.origin == beforeSwitchScroll, "switching visible cells preserves scroll position")
        view.beginEditing(row: 0, column: 0)
        expect(NSFontManager.shared.traits(of: field.font!).contains(.boldFontMask), "header input keeps header typography")
        view.beginEditing(row: 1, column: 0)
        expect(!NSFontManager.shared.traits(of: field.font!).contains(.boldFontMask), "leaving header restores body typography")
        expect(!field.drawsBackground && editor.string == beforeSwitch, "focus transitions preserve table surface and source")
        field.insertText("直接 | 编辑", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        expect(manager.inlineTables.count == 1 && view.cellEditor === field, "typing keeps table and cell editor")
        expect(view.table.rows[1].cells[0].text == "直接 \\| 编辑", "cell edit serializes escaped Markdown")
        expect(editor.string.hasPrefix("Before 😀\n\n") && editor.string.hasSuffix("\nAfter\n"), "surrounding text preserved")
        editor.breakUndoCoalescing()
        flushEvents()
        let undoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "z",
                                        charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        expect(field.performKeyEquivalent(with: undoEvent), "cell Command Z uses note undo")
        expect(editor.string == source && field.string == "中文", "cell undo restores source and visible text")
        let redoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "z",
                                        charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        expect(field.performKeyEquivalent(with: redoEvent), "cell redo shortcut")
        expect(field.string == "直接 | 编辑", "redo updates cell text")
        field.insertText(" ", replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
        flushEvents()
        expect(field.string.hasSuffix(" "), "typing trailing space is preserved")
        editor.breakUndoCoalescing()
        flushEvents()
        let beforeRowInsert = editor.string
        view.rowInsertButton.tag = 2
        view.rowInsertButton.performClick(nil)
        expect(view.table.rows.count == 4 && view.editingCell?.row == 2, "row + inserts and focuses row")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeRowInsert, "row insertion undo restores Markdown")
        editor.tableUndoManager!.redo()
        editor.updateTableEditors()
        expect(view.table.rows.count == 4, "row insertion redo")
        flushEvents()
        view.columnInsertButton.tag = 1
        view.columnInsertButton.performClick(nil)
        expect(view.table.alignments.count == 3 && view.table.rows.allSatisfy { $0.cells.count == 3 }, "column + updates every row")
        expect(view.editingCell?.row == 0 && view.editingCell?.column == 1, "new column header receives focus")
        view.beginEditing(row: 1, column: 2)
        expect(view.cellEditor!.alignment == .right, "editing preserves column alignment")
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + 10,
            y: InlineTableLayout.top + view.tableLayout.size.height))
        expect(!view.rowInsertButton.isHidden && view.rowInsertButton.tag == view.table.rows.count, "bottom border exposes row +")
        view.rowInsertButton.performClick(nil)
        expect(view.table.rows.count == 5 && view.editingCell?.row == 4, "bottom border + appends row")
        let lastField = view.cellEditor!
        expect(view.textView(lastField, doCommandBy: NSSelectorFromString("insertTab:")), "Tab handled")
        expect(view.editingCell?.row == 4 && view.editingCell?.column == 1, "Tab navigates columns")
        expect(view.textView(view.cellEditor!, doCommandBy: NSSelectorFromString("insertBacktab:")), "Shift Tab handled")
        expect(view.editingCell?.column == 0, "Shift Tab navigates back")
        expect(view.textView(view.cellEditor!, doCommandBy: NSSelectorFromString("insertNewline:")), "Enter handled")
        expect(view.table.rows.count == 5 && view.cellEditor == nil && window.firstResponder === editor, "Enter at last row enters body without adding a row")
        expect(editor.selectedRange().location == NSMaxRange(view.table.range) + 1, "Enter places caret after blank separator below table")
        view.beginEditing(row: 1, column: 0)
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + 10,
            y: InlineTableLayout.top + view.tableLayout.heights[0]))
        expect(!view.rowInsertButton.isHidden && view.rowInsertButton.tag == 1, "horizontal separator exposes row +")
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.widths[0], y: 10))
        expect(!view.columnInsertButton.isHidden && view.columnInsertButton.tag == 1, "column edge exposes column +")
        expect(!view.bottomColumnInsertButton.isHidden && view.bottomColumnInsertButton.tag == 1, "column + also appears below grid")
        view.updateHover(at: NSPoint(x: 8, y: InlineTableLayout.top + view.tableLayout.heights[0]))
        expect(!view.leftRowInsertButton.isHidden && !view.rowInsertButton.isHidden, "both row + buttons reachable from left gutter")
        expect(view.leftRowInsertButton.tag == 1, "left row + inserts at hovered separator")
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.widths[0],
                                    y: InlineTableLayout.top + view.tableLayout.size.height + 12))
        expect(!view.columnInsertButton.isHidden && !view.bottomColumnInsertButton.isHidden, "both column + buttons reachable from bottom gutter")
        let gridOrigin = NSPoint(x: InlineTableLayout.side, y: InlineTableLayout.top)
        expect(view.cursor(at: NSPoint(x: gridOrigin.x + view.tableLayout.widths[0], y: gridOrigin.y + 12)) == .arrow, "vertical divider uses arrow")
        expect(view.cursor(at: NSPoint(x: gridOrigin.x + 15, y: gridOrigin.y + view.tableLayout.heights[0])) == .arrow, "horizontal divider uses arrow")
        expect(view.cursor(at: NSPoint(x: gridOrigin.x + 15, y: gridOrigin.y + 15)) == .iBeam, "cell interior keeps I-beam")
        expect(view.cursor(at: NSPoint(x: 8, y: gridOrigin.y + 15)) == .arrow, "row controls use arrow")
        expect(view.cursor(at: NSPoint(x: gridOrigin.x + 15, y: gridOrigin.y + view.tableLayout.size.height + 12)) == .arrow, "column controls use arrow")
        let dividerEvent = NSEvent.mouseEvent(with: .mouseMoved,
            location: view.convert(NSPoint(x: gridOrigin.x + view.tableLayout.widths[0], y: gridOrigin.y + 12), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
        editor.mouseMoved(with: dividerEvent)
        expect(NSCursor.current == .arrow, "document mouse tracking preserves divider arrow")
        NSCursor.iBeam.set()
        view.cursorUpdate(with: dividerEvent)
        expect(NSCursor.current == .arrow, "native cursor tracking overrides I-beam on divider")
        view.selectRow(1)
        let movingText = view.table.rows[1].cells[0].text
        let origin = NSPoint(x: 8, y: InlineTableLayout.top + view.tableLayout.heights[0] + 8)
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, at: origin))
        let rowHandlePoint = NSPoint(x: 10, y: InlineTableLayout.top + view.tableLayout.heights[0] + view.tableLayout.heights[1] / 2)
        view.updateHover(at: rowHandlePoint)
        expect(view.cursor(at: rowHandlePoint) == .openHand && NSCursor.current == .openHand, "row handle uses open hand on hover")
        let destination = NSPoint(x: 8, y: InlineTableLayout.top + view.tableLayout.size.height - 2)
        view.mouseDragged(with: event(.leftMouseDragged, at: destination))
        view.mouseUp(with: event(.leftMouseUp, at: destination))
        expect(view.table.rows.last!.cells[0].text == movingText, "dragging handle reorders row")
        expect(view.selectedRow == view.table.rows.count - 1, "moved row remains selected")
        expect(view.table.rows[0].cells[0].text == "名字", "dragging preserves header")
        let menu = view.menu(for: event(.rightMouseDown, at: origin))!
        expect(menu.items.contains { $0.title == "Delete row" }, "context menu includes delete")
        flushEvents()
        let beforeColumnDelete = editor.string
        let deleteColumn = menu.items.first { $0.title == "Delete column" }!
        expect(NSApp.sendAction(deleteColumn.action!, to: deleteColumn.target, from: deleteColumn), "column delete menu executes")
        expect(view.table.alignments.count == 2, "column delete removes cells and delimiter")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeColumnDelete, "column delete undo")
        view.selectRow(1)
        let rowCount = view.table.rows.count
        let deleteEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                                          charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        expect(editor.handleTableKeyDown(deleteEvent), "selected row Delete handled")
        expect(view.table.rows.count == rowCount - 1, "selected row Delete removes row")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(view.table.rows.count == rowCount, "selected row deletion undo")
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.widths[0] + view.tableLayout.widths[1] / 2, y: 10))
        let topHandle = view.columnHandleButtons[2]
        expect(!topHandle.isHidden && topHandle.toolTip == "Select or drag column 2", "top column handle exposes drag tooltip")
        topHandle.performClick(nil)
        flushEvents()
        expect(view.selectedColumn == 1 && view.selectedRow == nil && view.cellEditor == nil, "column handle selects whole column and exits cell editing")
        expect(window.firstResponder === editor, "column selection routes keys to document")
        expect(editor.hasTableSelection, "column selection hides document insertion point")
        let bottomHandle = view.columnHandleButtons[1]
        bottomHandle.performClick(nil)
        expect(view.selectedColumn == 0, "bottom handle selects column too")
        flushEvents()
        let beforeColumnMove = editor.string
        let originalColumns = MarkdownTableDocument(view.table)
        let firstTopHandle = view.columnHandleButtons[0]
        let firstHandlePoint = NSPoint(x: firstTopHandle.frame.midX, y: firstTopHandle.frame.midY)
        view.updateHover(at: firstHandlePoint)
        expect(view.cursor(at: firstHandlePoint) == .openHand && NSCursor.current == .openHand, "top column handle uses open hand on hover")
        expect(view.hitTest(view.convert(firstHandlePoint, to: view.superview)) === firstTopHandle, "mouse hit testing reaches column handle")
        firstTopHandle.mouseDown(with: event(.leftMouseDown, at: firstHandlePoint))
        let lastColumnPoint = NSPoint(x: InlineTableLayout.side + view.tableLayout.size.width + 10, y: firstHandlePoint.y)
        firstTopHandle.mouseDragged(with: event(.leftMouseDragged, at: lastColumnPoint))
        expect(view.cursor(at: lastColumnPoint) == .closedHand && NSCursor.current == .closedHand, "column drag uses closed hand")
        firstTopHandle.mouseUp(with: event(.leftMouseUp, at: lastColumnPoint))
        let movedColumns = MarkdownTableDocument(view.table)
        expect(movedColumns.rows == originalColumns.rows.map { Array($0.dropFirst()) + [$0[0]] }, "top handle moves every row including header")
        expect(movedColumns.alignments == Array(originalColumns.alignments.dropFirst()) + [originalColumns.alignments[0]], "column drag carries alignment")
        expect(view.selectedColumn == view.table.alignments.count - 1 && editor.hasTableSelection, "moved column remains selected")
        expect(editor.selectedRange().location == view.table.rows[0].cells.last!.range.location, "caret follows moved column")
        expect(editor.string.hasPrefix("Before 😀\n\n") && editor.string.hasSuffix("\nAfter\n"), "column dragging preserves surrounding text")
        flushEvents()
        let afterColumnMove = editor.string
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeColumnMove, "column drag undo restores source")
        editor.tableUndoManager!.redo()
        editor.updateTableEditors()
        expect(editor.string == afterColumnMove, "column drag redo restores moved source")
        flushEvents()
        let lastBottomHandle = view.columnHandleButtons.last!
        let bottomHandlePoint = NSPoint(x: lastBottomHandle.frame.midX, y: lastBottomHandle.frame.midY)
        view.updateHover(at: bottomHandlePoint)
        expect(view.cursor(at: bottomHandlePoint) == .openHand, "bottom column handle uses open hand")
        lastBottomHandle.mouseDown(with: event(.leftMouseDown, at: bottomHandlePoint))
        let firstColumnPoint = NSPoint(x: InlineTableLayout.side - 10, y: bottomHandlePoint.y)
        lastBottomHandle.mouseDragged(with: event(.leftMouseDragged, at: firstColumnPoint))
        lastBottomHandle.mouseUp(with: event(.leftMouseUp, at: firstColumnPoint))
        expect(editor.string == beforeColumnMove && view.selectedColumn == 0, "bottom handle moves column back to first without leaving table")
        let clickHandle = view.columnHandleButtons[2]
        let clickPoint = NSPoint(x: clickHandle.frame.midX, y: clickHandle.frame.midY)
        clickHandle.mouseDown(with: event(.leftMouseDown, at: clickPoint))
        let tinyMove = NSPoint(x: clickPoint.x + 1, y: clickPoint.y)
        clickHandle.mouseDragged(with: event(.leftMouseDragged, at: tinyMove))
        clickHandle.mouseUp(with: event(.leftMouseUp, at: tinyMove))
        expect(editor.string == beforeColumnMove && view.selectedColumn == 1, "click with tiny motion selects column without reordering")
        flushEvents()
        view.selectColumn(0)
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        expect(editor.handleTableKeyDown(key(124)) && view.selectedColumn == 1, "Right switches selected column")
        expect(editor.handleTableKeyDown(key(123)) && view.selectedColumn == 0, "Left switches selected column")
        view.selectRow(1)
        expect(view.selectedColumn == nil && view.selectedRow == 1, "row selection clears column selection")
        view.beginEditing(row: 1, column: 0)
        view.selectColumn(1)
        expect(view.cellEditor == nil, "column selection closes active cell")
        let beforeSelectedColumnDelete = editor.string
        let columnCount = view.table.alignments.count
        expect(editor.handleTableKeyDown(deleteEvent), "selected column Delete handled")
        expect(view.table.alignments.count == columnCount - 1 && view.table.rows.allSatisfy { $0.cells.count == columnCount - 1 }, "selected column Delete removes every cell and delimiter")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeSelectedColumnDelete, "selected column deletion undo restores table")
        view.selectColumn(1)
        expect(editor.handleTableKeyDown(key(53)) && view.selectedColumn == nil, "Escape clears whole column selection")
        view.selectColumn(0)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        expect(view.selectedColumn == nil && !editor.hasTableSelection, "moving document caret clears table selection")
        view.updateHover(at: NSPoint(x: 8, y: InlineTableLayout.top + view.tableLayout.heights[0]))
        let beforeLeftInsert = editor.string
        view.leftRowInsertButton.performClick(nil)
        expect(view.table.rows.count == rowCount + 1 && view.editingCell?.row == 1, "left + inserts row and focuses new cell")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeLeftInsert, "left + insertion undo")
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.size.width,
            y: InlineTableLayout.top + view.tableLayout.size.height + 12))
        let beforeBottomInsert = editor.string
        view.bottomColumnInsertButton.performClick(nil)
        expect(view.table.alignments.count == columnCount + 1 && view.editingCell?.column == columnCount, "bottom + inserts last column and focuses header")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == beforeBottomInsert, "bottom + insertion undo")
        let bottomGridY = InlineTableLayout.top + view.tableLayout.size.height
        view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.size.width, y: bottomGridY + 12))
        expect(view.bottomColumnInsertButton.frame.minY >= bottomGridY && view.bottomColumnInsertButton.frame.maxY <= view.bounds.maxY, "bottom column control fits in compact gutter")
        if let output = ProcessInfo.processInfo.environment["FSNOTES_TABLE_PREVIEW"] {
            view.beginEditing(row: 1, column: 0)
            view.updateHover(at: NSPoint(x: InlineTableLayout.side + view.tableLayout.widths[0] / 2,
                y: InlineTableLayout.top + view.tableLayout.heights[0] + view.tableLayout.heights[1] / 2))
            RunLoop.current.run(until: Date().addingTimeInterval(MarkdownEditorStyle.transitionDuration + 0.02))
            editor.frame.size.height = manager.usedRect(for: container).height + 30
            if let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
            }
        }
        view.finishEditing(returnToEditor: false)
        _ = editor.changeTable(view, action: "Add rows") { document in
            for _ in 0..<24 { document.insertRow(at: document.rows.count) }
        }
        editor.frame.size.height = manager.usedRect(for: container).height + 30
        view.beginEditing(row: 1, column: 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        let scrollOrigin = scroll.contentView.bounds.origin
        let scrollField = view.cellEditor!
        scrollField.insertText("x", replacementRange: NSRange(location: (scrollField.string as NSString).length, length: 0))
        expect(abs(scroll.contentView.bounds.origin.y - scrollOrigin.y) < 1, "cell edits do not jump to table end")
        expect(!editor.isScrollPositionSaverLocked, "scroll saving lock restored after edits")
        let fixedWidths = view.tableLayout.widths
        let previousHeight = view.tableLayout.heights[1]
        scrollField.insertText(String(repeating: "较长的单元格内容 ", count: 18), replacementRange: NSRange(location: 0, length: (scrollField.string as NSString).length))
        expect(view.tableLayout.widths == fixedWidths, "long input wraps without shifting column widths")
        expect(view.tableLayout.heights[1] > previousHeight && view.cellEditor === scrollField, "long input grows row while keeping native input")
        expect(scrollField.frame.height >= view.tableLayout.heights[1] - InlineTableLayout.padding * 2 - 1, "growing row keeps input fully visible")
        view.finishEditing(returnToEditor: false)
        view.beginEditing(row: 1, column: 1)
        expect(view.cellEditor === scrollField && !scrollField.isHidden, "reentering table reuses native input")
        view.finishEditing(returnToEditor: false)
        container.containerSize.width = 220
        editor.updateTableEditors()
        expect(manager.inlineTableRect(view.table, in: container).width <= 220, "resize fits table")
        editor.removeTableEditors()
        expect(view.superview == nil && window.firstResponder !== field, "closing editors removes cell focus")
        for ending in ["", "\n", "\r\n"] {
            let tableSource = "| A | B |\n| --- | --- |\n| C | D |" + ending
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: tableSource)
            editor.refreshInlineTables()
            editor.updateTableEditors()
            let endView = editor.tableEditorViews[0]!
            endView.beginEditing(row: 1, column: 0)
            expect(endView.textView(endView.cellEditor!, doCommandBy: NSSelectorFromString("insertNewline:")), "last-row Enter handled at EOF")
            flushEvents()
            expect(window.firstResponder === editor && endView.cellEditor == nil, "EOF paragraph keeps document focus after pending updates")
            expect(editor.string == tableSource + (ending.isEmpty ? "\n\n" : "\n"), "EOF exit creates an empty paragraph")
            expect(editor.selectedRange().location == (editor.string as NSString).length, "EOF exit places caret after blank separator")
            editor.insertText("正文 | text", replacementRange: editor.selectedRange())
            editor.insertNewline(nil)
            editor.insertText("第二行", replacementRange: editor.selectedRange())
            flushEvents()
            expect(manager.inlineTables.count == 1 && manager.inlineTables[0].rows.count == 2, "body containing pipes remains outside table")
            expect(editor.string.replacingOccurrences(of: "\r\n", with: "\n").hasSuffix("\n\n正文 | text\n第二行"), "body below table accepts typing and newlines")
        }
        let tableAtEnd = "| A |\n| --- |\n| B |"
        func resetEndTable() -> InlineTableEditorView {
            editor.removeTableEditors()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: tableAtEnd)
            editor.refreshInlineTables()
            editor.updateTableEditors()
            return editor.tableEditorViews[0]!
        }
        func click(_ target: NSView, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: target.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            target.mouseDown(with: event)
        }
        let gutterView = resetEndTable()
        gutterView.beginEditing(row: 1, column: 0)
        click(gutterView, NSPoint(x: InlineTableLayout.side + 15,
            y: InlineTableLayout.top + gutterView.tableLayout.size.height + 12))
        flushEvents()
        expect(editor.string == tableAtEnd + "\n\n" && window.firstResponder === editor, "clicking bottom gutter creates body paragraph")
        editor.leaveTable(gutterView)
        expect(editor.string == tableAtEnd + "\n\n", "repeated table exit reuses empty paragraph")
        let belowView = resetEndTable()
        belowView.beginEditing(row: 1, column: 0)
        click(editor, NSPoint(x: 30, y: belowView.frame.maxY + 20))
        flushEvents()
        expect(editor.string == tableAtEnd + "\n\n" && window.firstResponder === editor, "clicking below final table creates body paragraph")
        let caretView = resetEndTable()
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        flushEvents()
        expect(caretView.cellEditor == nil, "EOF caret does not reenter table")
        expect(editor.handleTableKeyDown(key(36)), "Return at EOF leaves table")
        expect(editor.string == tableAtEnd + "\n\n" && editor.selectedRange().location == (editor.string as NSString).length, "EOF Return creates body paragraph")
        flushEvents()
        editor.tableUndoManager!.undo()
        editor.updateTableEditors()
        expect(editor.string == tableAtEnd, "undo restores table without added paragraph")
        editor.tableUndoManager!.redo()
        editor.updateTableEditors()
        expect(editor.string == tableAtEnd + "\n\n", "redo restores body paragraph")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "Other note")
        editor.updateTableEditors()
        expect(manager.inlineTables.isEmpty && editor.tableEditorViews.isEmpty, "switching notes clears table views")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        editor.note!.markdown = false
        editor.refreshInlineTables()
        editor.updateTableEditors()
        expect(manager.inlineTables.isEmpty && editor.tableEditorViews.isEmpty, "plain text stays unrendered")
        editor.note!.markdown = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTable(rows: 3, columns: 6, replacementRange: editor.selectedRange())
        flushEvents()
        editor.updateTableEditors()
        let newTableView = editor.tableEditorViews[0]!
        expect(newTableView.table.rows.count == 3 && newTableView.table.alignments.count == 6,
               "size picker insertion renders the requested rows and columns")
        expect(newTableView.editingCell?.row == 0 && newTableView.editingCell?.column == 0 &&
               window.firstResponder === newTableView.cellEditor, "size picker insertion focuses the first native cell editor")
        newTableView.cellEditor!.string = "新表格"
        newTableView.cellEditor!.didChangeText()
        newTableView.finishEditing(returnToEditor: false)
        expect(MarkdownTable.parse(editor.string)[0].rows[0].cells[0].text == "新表格",
               "typing immediately after size picker insertion updates the Markdown header")
        print("Inline table integration: \(checks) checks passed")
    }
}
