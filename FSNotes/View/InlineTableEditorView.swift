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

private final class TableFocusIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func drawTableHandle(at center: NSPoint, color: NSColor) {
    color.withAlphaComponent(0.7).setFill()
    for column in 0..<2 {
        for dot in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: center.x - 3 + CGFloat(column) * 4,
                                       y: center.y - 5 + CGFloat(dot) * 4,
                                       width: 2, height: 2)).fill()
        }
    }
}

private final class TableColumnHandleButton: NSButton {
    weak var tableView: InlineTableEditorView?

    override func draw(_ dirtyRect: NSRect) {
        drawTableHandle(at: NSPoint(x: bounds.midX, y: bounds.midY),
                        color: contentTintColor ?? .secondaryLabelColor)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { tableView?.beginColumnDrag(tag, with: event) }
    override func mouseDragged(with event: NSEvent) { tableView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { tableView?.mouseUp(with: event) }
}

/// One native renderer owns both the table surface and its reusable cell editor.
final class InlineTableEditorView: NSView, NSTextViewDelegate {
    weak var owner: EditTextView?
    weak var note: Note?
    private(set) var table: MarkdownTable
    private(set) var tableLayout: InlineTableLayout
    private(set) var editingCell: (row: Int, column: Int)?
    private(set) var cellEditor: TableCellTextView?
    private var reusableCellEditor: TableCellTextView?
    private let focusIndicator = TableFocusIndicator()
    private var focusTarget: NSRect?
    private var isFocusVisible = false
    private(set) var selectedRow: Int?
    private(set) var selectedColumn: Int?
    private var hoveredRow: Int?
    private var hoveredColumn: Int?
    private var hoveredRowBoundary: Int?
    private var hoveredColumnBoundary: Int?
    private var pointerInside = false
    private var draggingRow: Int?
    private var draggingColumn: Int?
    private var dragStart: NSPoint?
    private var dropBoundary: Int?
    private var dropColumnBoundary: Int?
    private var contextCell = (row: 0, column: 0)
    private var isUpdatingCell = false
    private var tracking: NSTrackingArea?
    let rowInsertButton = NSButton()
    let leftRowInsertButton = NSButton()
    let columnInsertButton = NSButton()
    let bottomColumnInsertButton = NSButton()
    private(set) var columnHandleButtons: [NSButton] = []

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
        focusIndicator.wantsLayer = true
        focusIndicator.alphaValue = 0
        focusIndicator.layer?.cornerRadius = 6
        focusIndicator.layer?.borderWidth = 1
        addSubview(focusIndicator)
        updateFocusColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Table", comment: "Inline table"))
        for button in [rowInsertButton, leftRowInsertButton, columnInsertButton, bottomColumnInsertButton] {
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            button.imagePosition = .imageOnly
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            button.bezelStyle = .smallSquare
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.contentTintColor = .secondaryLabelColor
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
        toolTip = NSLocalizedString("Click a cell to edit. Drag a handle to move a row or column.", comment: "Table control")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateFocusColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            focusIndicator.layer?.backgroundColor = MarkdownEditorStyle.focusSurface.cgColor
            focusIndicator.layer?.borderColor = MarkdownEditorStyle.focusBorder.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFocusColors()
        needsDisplay = true
    }

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
        cellEditor?.unmarkText()
        clearSelection()
        editingCell = (row, column)
        let editor = reusableCellEditor ?? makeCellEditor()
        editor.delegate = nil
        editor.isHidden = false
        editor.font = row == 0 ? NSFontManager.shared.convert(tableLayout.font, toHaveTrait: .boldFontMask) : tableLayout.font
        editor.string = editingText(row: row, column: column)
        let style = NSMutableParagraphStyle()
        switch table.alignments[column] {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        style.lineBreakMode = .byCharWrapping
        editor.defaultParagraphStyle = style
        editor.typingAttributes = [.font: editor.font ?? tableLayout.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        editor.delegate = self
        editor.setAccessibilityLabel(String(format: NSLocalizedString("Table row %d, column %d", comment: "Table cell"), row + 1, column + 1))
        cellEditor = editor
        positionCellEditor(animatedFocus: true)
        owner?.breakUndoCoalescing()
        owner?.isApplyingTableChange = true
        let sourceRow = table.rows[row]
        let index = column < sourceRow.cells.count ? sourceRow.cells[column].range.location : sourceRow.range.location
        owner?.setSelectedRange(NSRange(location: index, length: 0))
        owner?.saveSelectedRange()
        owner?.isApplyingTableChange = false
        if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
        if !visibleRect.contains(editor.frame) { _ = scrollToVisible(editor.frame) }
        if let event = event { editor.mouseDown(with: event) }
        else { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        updateControls()
        needsDisplay = true
    }

    private func makeCellEditor() -> TableCellTextView {
        let editor = TableCellTextView(frame: .zero)
        editor.tableView = self
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.autoresizingMask = []
        addSubview(editor)
        reusableCellEditor = editor
        return editor
    }

    private func positionCellEditor(animatedFocus: Bool = false) {
        guard let cell = editingCell, let editor = cellEditor else { return }
        let rect = tableLayout.cellRect(row: cell.row, column: cell.column)
            .offsetBy(dx: gridRect.minX, dy: gridRect.minY)
        let frame = rect.insetBy(dx: InlineTableLayout.padding, dy: InlineTableLayout.padding)
        if editor.frame != frame { editor.frame = frame }
        let target = rect.insetBy(dx: 3, dy: 3)
        if focusTarget != target {
            focusTarget = target
            if animatedFocus && isFocusVisible {
                MarkdownEditorStyle.animate { _ in self.focusIndicator.animator().frame = target }
            } else { focusIndicator.frame = target }
        }
        if !isFocusVisible {
            isFocusVisible = true
            MarkdownEditorStyle.animate { _ in self.focusIndicator.animator().alphaValue = 1 }
        }
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
        editor.unmarkText()
        cellEditor = nil
        editingCell = nil
        editor.delegate = nil
        if window?.firstResponder === editor {
            owner?.isApplyingTableChange = true
            window?.makeFirstResponder(returnToEditor ? owner : nil)
            owner?.isApplyingTableChange = false
        }
        editor.isHidden = true
        isFocusVisible = false
        MarkdownEditorStyle.animate { _ in self.focusIndicator.animator().alphaValue = 0 }
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
        // Saving happens on each edit; ending input hides the reusable cell editor.
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
        case "insertNewline:":
            if cell.row == table.rows.count - 1 { owner?.leaveTable(self) }
            else { navigate(row: cell.row + 1, column: cell.column) }
            return true
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
        cursor(at: point).set()
        needsDisplay = true
    }

    /// Borders and control gutters are click targets, while cell interiors accept text.
    func cursor(at point: NSPoint) -> NSCursor {
        if draggingRow != nil || draggingColumn != nil { return .closedHand }
        if owner?.isEditable == true {
            if [rowInsertButton, leftRowInsertButton, columnInsertButton, bottomColumnInsertButton]
                .contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return .arrow }
            if columnHandleButtons.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return .openHand }
            for row in table.rows.indices where row == hoveredRow || row == selectedRow {
                if rowHandleRect(row).contains(point) { return .openHand }
            }
        }
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
        if owner?.isEditable == true {
            for row in table.rows.indices where row == hoveredRow || row == selectedRow {
                addCursorRect(rowHandleRect(row), cursor: .openHand)
            }
        }
    }

    private func rowHandleRect(_ row: Int) -> NSRect {
        let y = gridRect.minY + tableLayout.heights.prefix(row).reduce(0, +) + tableLayout.heights[row] / 2
        return NSRect(x: 0, y: y - 10, width: 20, height: 20)
    }

    private func updateControls() {
        let enabled = owner?.isEditable == true
        for button in [rowInsertButton, leftRowInsertButton] {
            if let boundary = hoveredRowBoundary, enabled {
                button.tag = boundary
                button.frame = NSRect(x: button === rowInsertButton ? gridRect.maxX + 2 : 2,
                    y: gridRect.minY + tableLayout.heights.prefix(boundary).reduce(0, +) - 10, width: 20, height: 20)
                setControl(button, visible: true)
            } else { setControl(button, visible: false) }
        }
        for button in [columnInsertButton, bottomColumnInsertButton] {
            if let boundary = hoveredColumnBoundary, enabled {
                button.tag = boundary
                let x = gridRect.minX + tableLayout.widths.prefix(boundary).reduce(0, +)
                button.frame = NSRect(x: x - 10, y: button === columnInsertButton ? 0 : gridRect.maxY + 3, width: 20, height: 20)
                setControl(button, visible: true)
            } else { setControl(button, visible: false) }
        }
        if columnHandleButtons.count != table.alignments.count * 2 {
            columnHandleButtons.forEach { $0.removeFromSuperview() }
            columnHandleButtons = []
            for column in table.alignments.indices {
                for _ in 0..<2 {
                    let button = TableColumnHandleButton()
                    button.tableView = self
                    button.target = self
                    button.action = #selector(selectColumnFromHandle(_:))
                    button.tag = column
                    button.isBordered = false
                    button.font = NSFont.systemFont(ofSize: 15)
                    button.contentTintColor = .secondaryLabelColor
                    button.toolTip = String(format: NSLocalizedString("Select or drag column %d", comment: "Table control"), column + 1)
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
            setControl(button, visible: enabled && (column == selectedColumn || (pointerInside && column == hoveredColumn)))
            button.contentTintColor = column == selectedColumn ? .controlAccentColor : .secondaryLabelColor
        }
        window?.invalidateCursorRects(for: self)
    }

    private func setControl(_ button: NSButton, visible: Bool) {
        guard visible != !button.isHidden else { return }
        button.isHidden = !visible
        if visible {
            button.alphaValue = 0
            MarkdownEditorStyle.animate { _ in button.animator().alphaValue = 1 }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        tableLayout.draw(at: gridRect.origin, omittingCell: editingCell, clip: dirtyRect)
        if let column = selectedColumn, tableLayout.widths.indices.contains(column) {
            MarkdownEditorStyle.selectionSurface.setFill()
            NSRect(x: gridRect.minX + tableLayout.widths.prefix(column).reduce(0, +), y: gridRect.minY,
                   width: tableLayout.widths[column], height: gridRect.height).fill()
        }
        if let row = selectedRow, tableLayout.heights.indices.contains(row) {
            MarkdownEditorStyle.selectionSurface.setFill()
            NSRect(x: gridRect.minX, y: gridRect.minY + tableLayout.heights.prefix(row).reduce(0, +),
                   width: gridRect.width, height: tableLayout.heights[row]).fill()
        }
        for row in table.rows.indices where row == hoveredRow || row == selectedRow || row == draggingRow {
            drawTableHandle(at: NSPoint(x: 10, y: rowHandleRect(row).midY), color: .secondaryLabelColor)
        }
        NSColor.controlAccentColor.withAlphaComponent(draggingRow == nil && draggingColumn == nil ? 0.25 : 0.8).setStroke()
        if draggingColumn == nil, let boundary = dropBoundary ?? hoveredRowBoundary {
            let y = gridRect.minY + tableLayout.heights.prefix(boundary).reduce(0, +)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: gridRect.minX, y: y))
            path.line(to: NSPoint(x: gridRect.maxX, y: y))
            path.lineWidth = dropBoundary == nil ? 1 : 2
            path.stroke()
        }
        if draggingRow == nil, let boundary = dropColumnBoundary ?? hoveredColumnBoundary {
            let x = gridRect.minX + tableLayout.widths.prefix(boundary).reduce(0, +)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: gridRect.minY))
            path.line(to: NSPoint(x: x, y: gridRect.maxY))
            path.lineWidth = dropColumnBoundary == nil ? 1 : 2
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard owner?.isEditable == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= gridRect.maxY {
            owner?.leaveTable(self)
            return
        }
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
        clearSelection()
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
        draggingColumn = nil
        dropBoundary = nil
        dropColumnBoundary = nil
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

    fileprivate func beginColumnDrag(_ column: Int, with event: NSEvent) {
        guard owner?.isEditable == true, table.alignments.indices.contains(column) else { return }
        selectColumn(column)
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard draggingRow != nil || draggingColumn != nil || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        if let column = selectedColumn {
            draggingColumn = column
            dropColumnBoundary = columnBoundary(at: point.x)
        } else if let row = selectedRow, row > 0 {
            draggingRow = row
            dropBoundary = rowBoundary(at: point.y)
        } else { return }
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

    func columnBoundary(at x: CGFloat) -> Int {
        var edge = gridRect.minX
        for column in table.alignments.indices {
            if x < edge + tableLayout.widths[column] / 2 { return column }
            edge += tableLayout.widths[column]
        }
        return table.alignments.count
    }

    override func mouseUp(with event: NSEvent) {
        if let source = draggingRow, let target = dropBoundary {
            moveRow(from: source, to: target)
        } else if let source = draggingColumn, let target = dropColumnBoundary {
            moveColumn(from: source, to: target)
        }
        draggingRow = nil
        draggingColumn = nil
        dragStart = nil
        dropBoundary = nil
        dropColumnBoundary = nil
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    func moveRow(from source: Int, to target: Int) {
        var moved: Int?
        _ = owner?.changeTable(self, action: NSLocalizedString("Move table row", comment: "Undo action")) {
            moved = $0.moveRow(from: source, to: target)
        }
        selectedRow = moved
        updateControls()
    }

    func moveColumn(from source: Int, to target: Int) {
        var moved: Int?
        _ = owner?.changeTable(self, action: NSLocalizedString("Move table column", comment: "Undo action")) {
            moved = $0.moveColumn(from: source, to: target)
        }
        if let moved = moved { selectColumn(moved) }
    }

    @objc func insertRow(_ sender: NSButton) {
        let row = min(max(1, sender.tag), table.rows.count)
        _ = owner?.changeTable(self, action: NSLocalizedString("Add table row", comment: "Undo action")) { $0.insertRow(at: row) }
        hoveredRowBoundary = nil
        beginEditing(row: row, column: 0)
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
