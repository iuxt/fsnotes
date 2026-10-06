import Cocoa

final class TableCellTextView: NSTextView {
    weak var tableView: InlineTableEditorView?
    override var undoManager: UndoManager? { tableView?.owner?.tableUndoManager }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let tableMenu = tableView?.menu(for: event) {
            menu.addItem(.separator())
            let item = menu.addItem(withTitle: NSLocalizedString("Table", comment: "Table menu"), action: nil, keyEquivalent: "")
            item.submenu = tableMenu
        }
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            let undo = undoManager
            if event.modifierFlags.contains(.shift) { undo?.redo() } else { undo?.undo() }
            tableView?.owner?.updateTableEditors()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Native cell editing and table controls share the table's TextKit geometry.
final class InlineTableEditorView: NSView, NSTextViewDelegate {
    weak var owner: EditTextView?
    weak var note: Note?
    private(set) var table: MarkdownTable
    private(set) var tableLayout: InlineTableLayout
    private(set) var editingCell: (row: Int, column: Int)?
    private(set) var cellEditor: TableCellTextView?
    private(set) var selectedRow: Int?
    private(set) var selectedColumn: Int?
    private var hoveredRow: Int?
    private var hoveredColumn: Int?
    private var hoveredRowBoundary: Int?
    private var hoveredColumnBoundary: Int?
    private var pointerInside = false
    private var draggingRow: Int?
    private var dragStart: NSPoint?
    private var dropBoundary: Int?
    private var contextCell = (row: 0, column: 0)
    private var isUpdatingCell = false
    private var tracking: NSTrackingArea?
    let rowInsertButton = NSButton()
    let leftRowInsertButton = NSButton()
    let columnInsertButton = NSButton()
    let bottomColumnInsertButton = NSButton()
    private(set) var columnHandleButtons: [NSButton] = []
    let appendRowButton = NSButton()

    override var isFlipped: Bool { true }
    private var gridRect: NSRect {
        NSRect(x: InlineTableLayout.side, y: InlineTableLayout.top,
               width: tableLayout.size.width, height: tableLayout.size.height)
    }

    init(owner: EditTextView, table: MarkdownTable, layout: InlineTableLayout) {
        self.owner = owner
        self.note = owner.note
        self.table = table
        self.tableLayout = layout
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Table", comment: "Inline table"))
        for button in [rowInsertButton, leftRowInsertButton, columnInsertButton, bottomColumnInsertButton, appendRowButton] {
            button.title = "+"
            button.font = NSFont.systemFont(ofSize: 16, weight: .medium)
            button.bezelStyle = .smallSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.contentTintColor = .controlAccentColor
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        for button in [rowInsertButton, leftRowInsertButton] {
            button.action = #selector(insertRow(_:))
            button.toolTip = NSLocalizedString("Insert row here", comment: "Table control")
            button.setAccessibilityLabel(button.toolTip)
        }
        for button in [columnInsertButton, bottomColumnInsertButton] {
            button.action = #selector(insertColumn(_:))
            button.toolTip = NSLocalizedString("Insert column here", comment: "Table control")
            button.setAccessibilityLabel(button.toolTip)
        }
        appendRowButton.action = #selector(appendRow(_:))
        appendRowButton.toolTip = NSLocalizedString("Add row", comment: "Table control")
        appendRowButton.setAccessibilityLabel(appendRowButton.toolTip)
        toolTip = NSLocalizedString("Click a cell to edit. Drag the handle on the left to move a row.", comment: "Table control")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    func update(table: MarkdownTable, layout: InlineTableLayout) {
        self.table = table
        self.tableLayout = layout
        if let row = selectedRow, !table.rows.indices.contains(row) { selectedRow = nil }
        if let column = selectedColumn, !table.alignments.indices.contains(column) { selectedColumn = nil }
        if let cell = editingCell {
            if table.rows.indices.contains(cell.row), table.alignments.indices.contains(cell.column) {
                let text = editingText(row: cell.row, column: cell.column)
                if let editor = cellEditor, editor.string != text, !editor.hasMarkedText(), !isUpdatingCell {
                    let selection = editor.selectedRange()
                    editor.string = text
                    editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
                }
                positionCellEditor()
            } else { finishEditing(returnToEditor: true) }
        }
        updateControls()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func editingText(row: Int, column: Int) -> String {
        let cells = table.rows[row].cells
        return column < cells.count ? MarkdownTableDocument.editingText(cells[column].text) : ""
    }

    func beginEditing(row: Int, column: Int, event: NSEvent? = nil) {
        guard owner?.isEditable == true, table.rows.indices.contains(row), table.alignments.indices.contains(column) else { return }
        if editingCell?.row == row && editingCell?.column == column {
            if let event = event { cellEditor?.mouseDown(with: event) }
            return
        }
        finishEditing(returnToEditor: false)
        clearSelection()
        editingCell = (row, column)
        let editor = TableCellTextView(frame: .zero)
        editor.tableView = self
        editor.delegate = self
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = row == 0 ? NSFontManager.shared.convert(tableLayout.font, toHaveTrait: .boldFontMask) : tableLayout.font
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.drawsBackground = true
        editor.textContainerInset = NSSize(width: 0, height: 0)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        editor.string = editingText(row: row, column: column)
        let style = NSMutableParagraphStyle()
        switch table.alignments[column] {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        style.lineBreakMode = .byCharWrapping
        editor.defaultParagraphStyle = style
        editor.typingAttributes[.paragraphStyle] = style
        editor.setAccessibilityLabel(String(format: NSLocalizedString("Table row %d, column %d", comment: "Table cell"), row + 1, column + 1))
        addSubview(editor)
        cellEditor = editor
        positionCellEditor()
        owner?.breakUndoCoalescing()
        owner?.isApplyingTableChange = true
        let sourceRow = table.rows[row]
        let index = column < sourceRow.cells.count ? sourceRow.cells[column].range.location : sourceRow.range.location
        owner?.setSelectedRange(NSRange(location: index, length: 0))
        owner?.saveSelectedRange()
        owner?.isApplyingTableChange = false
        window?.makeFirstResponder(editor)
        _ = scrollToVisible(editor.frame)
        if let event = event { editor.mouseDown(with: event) }
        else { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        updateControls()
        needsDisplay = true
    }

    private func positionCellEditor() {
        guard let cell = editingCell, let editor = cellEditor else { return }
        let rect = tableLayout.cellRect(row: cell.row, column: cell.column)
            .offsetBy(dx: gridRect.minX, dy: gridRect.minY)
        editor.frame = NSRect(x: rect.minX + InlineTableLayout.padding, y: rect.minY + InlineTableLayout.padding,
                              width: max(1, rect.width - InlineTableLayout.padding * 2),
                              height: max(1, rect.height - InlineTableLayout.padding * 2))
        let alignment: NSTextAlignment
        switch table.alignments[cell.column] {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        if editor.alignment != alignment { editor.alignment = alignment }
        editor.textContainer?.containerSize = NSSize(width: max(1, editor.frame.width), height: CGFloat.greatestFiniteMagnitude)
    }

    func finishEditing(returnToEditor: Bool) {
        guard let editor = cellEditor else { return }
        cellEditor = nil
        editingCell = nil
        editor.delegate = nil
        if window?.firstResponder === editor {
            owner?.isApplyingTableChange = true
            window?.makeFirstResponder(returnToEditor ? owner : nil)
            owner?.isApplyingTableChange = false
        }
        editor.removeFromSuperview()
        owner?.breakUndoCoalescing()
        updateControls()
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = cellEditor, let cell = editingCell else { return }
        isUpdatingCell = true
        _ = owner?.changeTable(self) { $0.setCell(row: cell.row, column: cell.column, text: editor.string) }
        isUpdatingCell = false
        positionCellEditor()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Saving happens on each edit; ending input only removes the native cell editor.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window?.firstResponder !== self.cellEditor else { return }
            self.finishEditing(returnToEditor: false)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let cell = editingCell else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "insertTab:": navigate(row: cell.row, column: cell.column + 1); return true
        case "insertBacktab:": navigate(row: cell.row, column: cell.column - 1); return true
        case "insertNewline:": navigate(row: cell.row + 1, column: cell.column); return true
        case "cancelOperation:": owner?.leaveTable(self); return true
        case "moveLeft:" where textView.selectedRange().location == 0:
            navigate(row: cell.row, column: cell.column - 1); return true
        case "moveRight:" where NSMaxRange(textView.selectedRange()) == (textView.string as NSString).length:
            navigate(row: cell.row, column: cell.column + 1); return true
        default: return false
        }
    }

    func navigate(row: Int, column: Int) {
        var nextRow = row, nextColumn = column
        if nextColumn >= table.alignments.count { nextRow += 1; nextColumn = 0 }
        if nextColumn < 0 { nextRow -= 1; nextColumn = table.alignments.count - 1 }
        if nextRow < 0 { owner?.leaveTable(self); return }
        if nextRow >= table.rows.count {
            _ = owner?.changeTable(self, action: NSLocalizedString("Add table row", comment: "Undo action")) { $0.insertRow(at: $0.rows.count) }
        }
        beginEditing(row: min(nextRow, table.rows.count - 1), column: nextColumn)
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { pointerInside = true; updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hoveredRow = nil
        hoveredColumn = nil
        hoveredRowBoundary = nil
        hoveredColumnBoundary = nil
        updateControls()
        needsDisplay = true
    }

    func updateHover(at point: NSPoint) {
        pointerInside = bounds.contains(point)
        cursor(at: point).set()
        let local = NSPoint(x: point.x - gridRect.minX, y: point.y - gridRect.minY)
        hoveredRow = local.y >= 0 && local.y < gridRect.height ? tableLayout.cell(at: local).row : nil
        hoveredColumn = local.x >= 0 && local.x < gridRect.width ? tableLayout.cell(at: local).column : nil
        var y: CGFloat = 0
        hoveredRowBoundary = nil
        for boundary in 0...table.rows.count {
            if boundary >= 1, abs(local.y - y) <= 7, point.x >= bounds.minX, point.x <= bounds.maxX {
                hoveredRowBoundary = boundary
                break
            }
            if boundary < tableLayout.heights.count { y += tableLayout.heights[boundary] }
        }
        var x: CGFloat = 0
        hoveredColumnBoundary = nil
        for boundary in 0...table.alignments.count {
            if abs(local.x - x) <= 7, point.y >= bounds.minY, point.y <= gridRect.maxY + 23 {
                hoveredColumnBoundary = boundary
                break
            }
            if boundary < tableLayout.widths.count { x += tableLayout.widths[boundary] }
        }
        updateControls()
        needsDisplay = true
    }

    /// Borders and control gutters are click targets, while cell interiors accept text.
    func cursor(at point: NSPoint) -> NSCursor {
        guard gridRect.contains(point) else { return .arrow }
        var x = gridRect.minX
        for width in tableLayout.widths + [0] {
            if abs(point.x - x) <= 7 { return .arrow }
            x += width
        }
        var y = gridRect.minY
        for height in tableLayout.heights + [0] {
            if abs(point.y - y) <= 7 { return .arrow }
            y += height
        }
        return .iBeam
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func resetCursorRects() {
        // Separate rectangles keep the enclosing NSTextView's I-beam off the controls.
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: gridRect.minY), cursor: .arrow)
        addCursorRect(NSRect(x: 0, y: gridRect.maxY, width: bounds.width, height: bounds.maxY - gridRect.maxY), cursor: .arrow)
        addCursorRect(NSRect(x: 0, y: gridRect.minY, width: gridRect.minX, height: gridRect.height), cursor: .arrow)
        addCursorRect(NSRect(x: gridRect.maxX, y: gridRect.minY, width: bounds.maxX - gridRect.maxX, height: gridRect.height), cursor: .arrow)
        var x = gridRect.minX
        for width in tableLayout.widths + [0] {
            addCursorRect(NSRect(x: x - 7, y: gridRect.minY, width: 14, height: gridRect.height), cursor: .arrow)
            x += width
        }
        var y = gridRect.minY
        for height in tableLayout.heights + [0] {
            addCursorRect(NSRect(x: gridRect.minX, y: y - 7, width: gridRect.width, height: 14), cursor: .arrow)
            y += height
        }
        for row in table.rows.indices {
            for column in table.alignments.indices {
                let rect = tableLayout.cellRect(row: row, column: column)
                    .offsetBy(dx: gridRect.minX, dy: gridRect.minY).insetBy(dx: 7, dy: 7)
                if rect.width > 0 && rect.height > 0 { addCursorRect(rect, cursor: .iBeam) }
            }
        }
    }

    private func updateControls() {
        let enabled = owner?.isEditable == true
        for button in [rowInsertButton, leftRowInsertButton] {
            if let boundary = hoveredRowBoundary, enabled {
                button.tag = boundary
                button.frame = NSRect(x: button === rowInsertButton ? gridRect.maxX + 2 : 2,
                    y: gridRect.minY + tableLayout.heights.prefix(boundary).reduce(0, +) - 10, width: 20, height: 20)
                button.isHidden = false
            } else { button.isHidden = true }
        }
        for button in [columnInsertButton, bottomColumnInsertButton] {
            if let boundary = hoveredColumnBoundary, enabled {
                button.tag = boundary
                let x = gridRect.minX + tableLayout.widths.prefix(boundary).reduce(0, +)
                button.frame = NSRect(x: x - 10, y: button === columnInsertButton ? 0 : gridRect.maxY + 3, width: 20, height: 20)
                button.isHidden = false
            } else { button.isHidden = true }
        }
        if columnHandleButtons.count != table.alignments.count * 2 {
            columnHandleButtons.forEach { $0.removeFromSuperview() }
            columnHandleButtons = []
            for column in table.alignments.indices {
                for _ in 0..<2 {
                    let button = NSButton(title: "⠿", target: self, action: #selector(selectColumnFromHandle(_:)))
                    button.tag = column
                    button.isBordered = false
                    button.font = NSFont.systemFont(ofSize: 15)
                    button.contentTintColor = .secondaryLabelColor
                    button.toolTip = String(format: NSLocalizedString("Select column %d", comment: "Table control"), column + 1)
                    button.setAccessibilityLabel(button.toolTip)
                    columnHandleButtons.append(button)
                    addSubview(button)
                }
            }
        }
        for (index, button) in columnHandleButtons.enumerated() {
            let column = button.tag
            let x = gridRect.minX + tableLayout.widths.prefix(column).reduce(0, +) + tableLayout.widths[column] / 2
            button.frame = NSRect(x: x - 10, y: index.isMultiple(of: 2) ? 0 : gridRect.maxY + 3, width: 20, height: 20)
            button.isHidden = !enabled || (column != selectedColumn && (!pointerInside || column != hoveredColumn))
            button.contentTintColor = column == selectedColumn ? .controlAccentColor : .secondaryLabelColor
        }
        appendRowButton.frame = NSRect(x: gridRect.midX - 10, y: gridRect.maxY + 27, width: 20, height: 20)
        appendRowButton.isHidden = !enabled || (!pointerInside && editingCell == nil && selectedRow == nil && selectedColumn == nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let column = selectedColumn, tableLayout.widths.indices.contains(column) {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSRect(x: gridRect.minX + tableLayout.widths.prefix(column).reduce(0, +), y: gridRect.minY,
                   width: tableLayout.widths[column], height: gridRect.height).fill()
        }
        if let row = selectedRow, tableLayout.heights.indices.contains(row) {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSRect(x: gridRect.minX, y: gridRect.minY + tableLayout.heights.prefix(row).reduce(0, +),
                   width: gridRect.width, height: tableLayout.heights[row]).fill()
        }
        if let cell = editingCell {
            let rect = tableLayout.cellRect(row: cell.row, column: cell.column).offsetBy(dx: gridRect.minX, dy: gridRect.minY)
            NSColor.textBackgroundColor.setFill()
            rect.insetBy(dx: 1, dy: 1).fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.stroke()
        }
        for row in table.rows.indices where row == hoveredRow || row == selectedRow || row == draggingRow {
            let y = gridRect.minY + tableLayout.heights.prefix(row).reduce(0, +) + tableLayout.heights[row] / 2
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor]
            ("⠿" as NSString).draw(at: NSPoint(x: 5, y: y - 10), withAttributes: attrs)
        }
        NSColor.controlAccentColor.setStroke()
        if let boundary = dropBoundary ?? hoveredRowBoundary {
            let y = gridRect.minY + tableLayout.heights.prefix(boundary).reduce(0, +)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: gridRect.minX, y: y))
            path.line(to: NSPoint(x: gridRect.maxX, y: y))
            path.lineWidth = dropBoundary == nil ? 1.5 : 3
            path.stroke()
        }
        if let boundary = hoveredColumnBoundary, draggingRow == nil {
            let x = gridRect.minX + tableLayout.widths.prefix(boundary).reduce(0, +)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: gridRect.minY))
            path.line(to: NSPoint(x: x, y: gridRect.maxY))
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard owner?.isEditable == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: point.x - gridRect.minX, y: point.y - gridRect.minY)
        guard local.y >= 0, local.y < gridRect.height else { return }
        let cell = tableLayout.cell(at: local)
        if point.x < gridRect.minX || (selectedRow == cell.row && event.clickCount == 1) {
            selectRow(cell.row)
            dragStart = point
            return
        }
        if gridRect.contains(point) { beginEditing(row: cell.row, column: cell.column, event: event) }
    }

    func selectRow(_ row: Int) {
        finishEditing(returnToEditor: false)
        selectedRow = row
        selectedColumn = nil
        owner?.isApplyingTableChange = true
        window?.makeFirstResponder(owner)
        owner?.setSelectedRange(NSRange(location: table.rows[row].range.location, length: 0))
        owner?.isApplyingTableChange = false
        updateControls()
        needsDisplay = true
    }

    func clearSelection() {
        selectedRow = nil
        selectedColumn = nil
        dragStart = nil
        draggingRow = nil
        dropBoundary = nil
        updateControls()
        needsDisplay = true
    }

    func selectColumn(_ column: Int) {
        guard owner?.isEditable == true, table.alignments.indices.contains(column) else { return }
        finishEditing(returnToEditor: false)
        clearSelection()
        selectedColumn = column
        owner?.isApplyingTableChange = true
        window?.makeFirstResponder(owner)
        let header = table.rows[0]
        let index = column < header.cells.count ? header.cells[column].range.location : header.range.location
        owner?.setSelectedRange(NSRange(location: index, length: 0))
        owner?.isApplyingTableChange = false
        updateControls()
        needsDisplay = true
    }

    @objc private func selectColumnFromHandle(_ sender: NSButton) { selectColumn(sender.tag) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let row = selectedRow, row > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard draggingRow != nil || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        draggingRow = row
        dropBoundary = rowBoundary(at: point.y)
        _ = autoscroll(with: event)
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    func rowBoundary(at y: CGFloat) -> Int {
        var edge = gridRect.minY + tableLayout.heights[0]
        for row in 1..<table.rows.count {
            if y < edge + tableLayout.heights[row] / 2 { return row }
            edge += tableLayout.heights[row]
        }
        return table.rows.count
    }

    override func mouseUp(with event: NSEvent) {
        if let source = draggingRow, let target = dropBoundary {
            moveRow(from: source, to: target)
        }
        draggingRow = nil
        dragStart = nil
        dropBoundary = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    func moveRow(from source: Int, to target: Int) {
        var moved: Int?
        _ = owner?.changeTable(self, action: NSLocalizedString("Move table row", comment: "Undo action")) {
            moved = $0.moveRow(from: source, to: target)
        }
        selectedRow = moved
        updateControls()
    }

    @objc func insertRow(_ sender: NSButton) {
        let row = min(max(1, sender.tag), table.rows.count)
        _ = owner?.changeTable(self, action: NSLocalizedString("Add table row", comment: "Undo action")) { $0.insertRow(at: row) }
        hoveredRowBoundary = nil
        beginEditing(row: row, column: 0)
    }

    @objc func appendRow(_ sender: NSButton) {
        sender.tag = table.rows.count
        insertRow(sender)
    }

    @objc func insertColumn(_ sender: NSButton) {
        let column = min(max(0, sender.tag), table.alignments.count)
        _ = owner?.changeTable(self, action: NSLocalizedString("Add table column", comment: "Undo action")) { $0.insertColumn(at: column) }
        hoveredColumnBoundary = nil
        beginEditing(row: 0, column: column)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard owner?.isEditable == true else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        contextCell = tableLayout.cell(at: NSPoint(x: point.x - gridRect.minX, y: point.y - gridRect.minY))
        let menu = NSMenu()
        for (title, action, tag) in [
            ("Insert row above", #selector(menuInsertRow(_:)), max(1, contextCell.row)),
            ("Insert row below", #selector(menuInsertRow(_:)), contextCell.row + 1),
            ("Insert column left", #selector(menuInsertColumn(_:)), contextCell.column),
            ("Insert column right", #selector(menuInsertColumn(_:)), contextCell.column + 1)
        ] {
            let item = menu.addItem(withTitle: NSLocalizedString(title, comment: "Table menu"), action: action, keyEquivalent: "")
            item.target = self; item.tag = tag
        }
        menu.addItem(.separator())
        for (index, title) in ["Align left", "Align center", "Align right"].enumerated() {
            let item = menu.addItem(withTitle: NSLocalizedString(title, comment: "Table menu"), action: #selector(alignColumn(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        menu.addItem(.separator())
        let row = menu.addItem(withTitle: NSLocalizedString("Delete row", comment: "Table menu"), action: #selector(deleteRow(_:)), keyEquivalent: "")
        row.target = self; row.isEnabled = contextCell.row > 0
        let column = menu.addItem(withTitle: NSLocalizedString("Delete column", comment: "Table menu"), action: #selector(deleteColumn(_:)), keyEquivalent: "")
        column.target = self; column.isEnabled = table.alignments.count > 1
        menu.autoenablesItems = false
        return menu
    }

    @objc private func menuInsertRow(_ item: NSMenuItem) { rowInsertButton.tag = item.tag; insertRow(rowInsertButton) }
    @objc private func menuInsertColumn(_ item: NSMenuItem) { columnInsertButton.tag = item.tag; insertColumn(columnInsertButton) }
    @objc private func alignColumn(_ item: NSMenuItem) {
        _ = owner?.changeTable(self, action: NSLocalizedString("Align table column", comment: "Undo action")) {
            $0.alignments[contextCell.column] = [.left, .center, .right][item.tag]
        }
    }
    @objc private func deleteRow(_ item: NSMenuItem) {
        finishEditing(returnToEditor: true)
        _ = owner?.changeTable(self, action: NSLocalizedString("Delete table row", comment: "Undo action")) { $0.removeRow(at: contextCell.row) }
    }
    @objc private func deleteColumn(_ item: NSMenuItem) {
        finishEditing(returnToEditor: true)
        _ = owner?.changeTable(self, action: NSLocalizedString("Delete table column", comment: "Undo action")) { $0.removeColumn(at: contextCell.column) }
    }
}
