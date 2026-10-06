import Cocoa

extension EditTextView {
    func makeMarkdownContextMenu() -> NSMenu? {
        guard isEditable, note?.isMarkdown() == true else { return nil }

        let menu = NSMenu()
        @discardableResult
        func item(_ title: String, _ action: Selector, in parent: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            parent.addItem(item)
            return item
        }

        item(NSLocalizedString("Bold", comment: ""), #selector(boldMenu(_:)), in: menu)
        item(NSLocalizedString("Italic", comment: ""), #selector(italicMenu(_:)), in: menu)
        item(NSLocalizedString("Strikethrough", comment: ""), #selector(strikeMenu(_:)), in: menu)

        let headings = NSMenu(title: NSLocalizedString("Headers", comment: ""))
        let paragraph = item(NSLocalizedString("Paragraph", comment: ""), #selector(headerMenu(_:)), in: headings)
        paragraph.identifier = NSUserInterfaceItemIdentifier("format.h0")
        headings.addItem(.separator())
        let titles = [
            NSLocalizedString("Header 1", comment: ""), NSLocalizedString("Header 2", comment: ""),
            NSLocalizedString("Header 3", comment: ""), NSLocalizedString("Header 4", comment: ""),
            NSLocalizedString("Header 5", comment: ""), NSLocalizedString("Header 6", comment: "")
        ]
        for (index, title) in titles.enumerated() {
            item(title, #selector(headerMenu(_:)), in: headings).identifier =
                NSUserInterfaceItemIdentifier("format.h\(index + 1)")
        }
        let headingItem = NSMenuItem(title: headings.title, action: nil, keyEquivalent: "")
        headingItem.submenu = headings
        menu.addItem(headingItem)

        menu.addItem(.separator())
        item(NSLocalizedString("Code Span", comment: ""), #selector(insertCodeSpan(_:)), in: menu)
        item(NSLocalizedString("Code Block", comment: ""), #selector(insertCodeBlock(_:)), in: menu)
        item(NSLocalizedString("Link", comment: ""), #selector(linkMenu(_:)), in: menu)
        let tables = NSMenu(title: NSLocalizedString("Table", comment: ""))
        tables.autoenablesItems = false
        let tablePickerItem = NSMenuItem(title: tables.title, action: nil, keyEquivalent: "")
        let insertionRange = selectedRange()
        let insertionNote = note
        tablePickerItem.view = TableSizePickerView { [weak self, weak insertionNote] rows, columns in
            guard let self = self, let insertionNote = insertionNote, self.note === insertionNote else { return }
            self.insertTable(rows: rows, columns: columns, replacementRange: insertionRange)
        }
        tables.addItem(tablePickerItem)
        let tableItem = NSMenuItem(title: tables.title, action: nil, keyEquivalent: "")
        tableItem.identifier = NSUserInterfaceItemIdentifier("format.table")
        tableItem.submenu = tables
        menu.addItem(tableItem)
        item(NSLocalizedString("Quote", comment: ""), #selector(insertQuote(_:)), in: menu)

        let lists = NSMenu(title: NSLocalizedString("Lists", comment: ""))
        item(NSLocalizedString("List", comment: ""), #selector(insertList(_:)), in: lists)
        item(NSLocalizedString("Ordered List", comment: ""), #selector(insertOrderedList(_:)), in: lists)
        item(NSLocalizedString("Toggle Todo", comment: ""), #selector(todo(_:)), in: lists)
        let listItem = NSMenuItem(title: lists.title, action: nil, keyEquivalent: "")
        listItem.submenu = lists
        menu.addItem(listItem)
        return menu
    }

    func insertTable(rows: Int, columns: Int, replacementRange range: NSRange) {
        guard isEditable, note?.isMarkdown() == true, let storage = textStorage,
              (1...TableSizePickerView.maximumRows).contains(rows),
              (1...TableSizePickerView.maximumColumns).contains(columns),
              range.location != NSNotFound, range.location <= storage.length,
              range.length <= storage.length - range.location else { return }

        let source = storage.string as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        let newline = storage.string.contains("\r\n") ? "\r\n" : "\n"
        // Keep a blank paragraph on each side so adjacent text or tables stay separate.
        func padding(_ text: String, beforeTable: Bool) -> String {
            if beforeTable && text.isEmpty { return "" }
            if beforeTable ? text.hasSuffix(newline + newline) : text.hasPrefix(newline + newline) { return "" }
            if beforeTable ? text.hasSuffix(newline) : text.hasPrefix(newline) { return newline }
            return newline + newline
        }
        let prefix = padding(before, beforeTable: true)
        let emptyRow = "| " + Array(repeating: "", count: columns).joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let table = ([emptyRow, delimiter] + Array(repeating: emptyRow, count: rows - 1)).joined(separator: newline)
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        suppressCompletion = true
        insertText(prefix + table + padding(after, beforeTable: false), replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.utf16.count + 3, length: 0))
        undoManager?.setActionName(NSLocalizedString("Insert Table", comment: "Undo action"))
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }

    @IBAction func headerMenu(_ sender: NSMenuItem) {
        guard isEditable, note?.isMarkdown() == true,
              let identifier = sender.identifier?.rawValue,
              identifier.hasPrefix("format.h"),
              let level = Int(identifier.dropFirst("format.h".count)),
              (0...6).contains(level), let storage = textStorage else { return }

        let selection = selectedRange()
        let paragraphRange = storage.mutableString.paragraphRange(for: selection)
        let paragraph = storage.attributedSubstring(from: paragraphRange)
        let source = paragraph.string as NSString
        let result = NSMutableAttributedString(attributedString: paragraph)
        let prefix = level == 0 ? "" : String(repeating: "#", count: level) + " "
        let heading = try! NSRegularExpression(pattern: "^( {0,3})#{1,6}(?:[ \\t]+|$)")
        var edits = [(NSRange, String)]()
        var location = 0
        repeat {
            var lineEnd = 0, contentsEnd = 0
            source.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: location, length: 0))
            let line = source.substring(with: NSRange(location: location, length: contentsEnd - location))
            let match = heading.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count))
            if !line.isEmpty || source.length == 0 {
                let oldPrefix = NSRange(location: location, length: match?.range.length ?? 0)
                let indent = match.map { (line as NSString).substring(with: $0.range(at: 1)) } ?? ""
                edits.append((oldPrefix, indent + prefix))
            }
            location = lineEnd
        } while location < source.length

        var newSelection = selection
        for (range, replacement) in edits.reversed() {
            let globalRange = NSRange(location: paragraphRange.location + range.location, length: range.length)
            func moved(_ offset: Int) -> Int {
                if offset < globalRange.location { return offset }
                if offset < NSMaxRange(globalRange) { return globalRange.location + replacement.utf16.count }
                return offset + replacement.utf16.count - globalRange.length
            }
            let end = moved(NSMaxRange(newSelection))
            newSelection.location = moved(newSelection.location)
            newSelection.length = end - newSelection.location
            result.replaceCharacters(in: range, with: replacement)
        }
        guard result.string != source as String else { return }
        breakUndoCoalescing()
        insertText(result, replacementRange: paragraphRange)
        setSelectedRange(newSelection)
        breakUndoCoalescing()
    }

    @IBAction func insertCodeBlock(_ sender: Any) {
        guard isEditable, note?.isMarkdown() == true, let storage = textStorage else { return }
        let range = selectedRange()
        let selected = storage.attributedSubstring(from: range)
        let text = storage.string as NSString
        let previousCharacter = range.location > 0 ? UnicodeScalar(text.character(at: range.location - 1)) : nil
        let needsLeadingNewline = range.location > 0 &&
            !(previousCharacter.map { CharacterSet.newlines.contains($0) } ?? false)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: selected.string) + 1))
        let opening = (needsLeadingNewline ? "\n" : "") + fence + "\n"
        let result = NSMutableAttributedString(string: opening)
        result.append(selected)
        if selected.length == 0 || !selected.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n"))
        }
        result.append(NSAttributedString(string: fence + "\n"))
        breakUndoCoalescing()
        insertText(result, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + opening.utf16.count, length: selected.length))
        breakUndoCoalescing()
    }

    @IBAction func insertCodeSpan(_ sender: NSMenuItem) {
        guard isEditable, note?.isMarkdown() == true, let storage = textStorage else { return }
        let range = selectedRange()
        let selected = storage.attributedSubstring(from: range)
        let fence = String(repeating: "`", count: longestBacktickRun(in: selected.string) + 1)
        // Markdown strips one surrounding space; padding preserves spaces in the content.
        let hasEdgeSpaces = selected.string.hasPrefix(" ") && selected.string.hasSuffix(" ") &&
            selected.string.contains(where: { $0 != " " })
        let padding = selected.string.hasPrefix("`") || selected.string.hasSuffix("`") || hasEdgeSpaces ? " " : ""
        let opening = fence + padding
        let result = NSMutableAttributedString(string: opening)
        result.append(selected)
        result.append(NSAttributedString(string: padding + fence))
        breakUndoCoalescing()
        insertText(result, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + opening.utf16.count, length: selected.length))
        breakUndoCoalescing()
    }

    private func longestBacktickRun(in string: String) -> Int {
        var longest = 0, current = 0
        for character in string {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

/// A custom submenu item keeps the entire hover grid inside native menu tracking.
final class TableSizePickerView: NSView {
    static let maximumRows = 8
    static let maximumColumns = 12
    private let cellSize: CGFloat = 22
    private let spacing: CGFloat = 4
    private let inset: CGFloat = 12
    private let gridTop: CGFloat = 40
    private var tracking: NSTrackingArea?
    private let insert: (Int, Int) -> Void
    private(set) var selectedRows = 0
    private(set) var selectedColumns = 0
    private lazy var accessibleCells: [CellAccessibilityElement] = (0..<Self.maximumRows).flatMap { row in
        (0..<Self.maximumColumns).map { CellAccessibilityElement(picker: self, row: row, column: $0) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(insert: @escaping (Int, Int) -> Void) {
        self.insert = insert
        super.init(frame: NSRect(x: 0, y: 0, width: 332, height: 256))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Table", comment: ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityChildren() -> [Any]? { accessibleCells }

    var selectionTitle: String {
        guard selectedRows > 0, selectedColumns > 0 else { return NSLocalizedString("Table", comment: "") }
        return String(format: NSLocalizedString("%d rows × %d columns", comment: "Table size picker"),
                      selectedRows, selectedColumns)
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: inset + CGFloat(column) * (cellSize + spacing),
               y: gridTop + CGFloat(row) * (cellSize + spacing), width: cellSize, height: cellSize)
    }

    func updateSelection(at point: NSPoint) {
        let grid = NSRect(x: inset, y: gridTop,
                          width: CGFloat(Self.maximumColumns) * (cellSize + spacing) - spacing,
                          height: CGFloat(Self.maximumRows) * (cellSize + spacing) - spacing)
        let rows = grid.contains(point) ? Int((point.y - gridTop) / (cellSize + spacing)) + 1 : 0
        let columns = grid.contains(point) ? Int((point.x - inset) / (cellSize + spacing)) + 1 : 0
        guard rows != selectedRows || columns != selectedColumns else { return }
        selectedRows = rows
        selectedColumns = columns
        setAccessibilityValue(selectionTitle)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved,
                                            .enabledDuringMouseDrag, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            updateSelection(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            updateSelection(at: NSPoint(x: -1, y: -1))
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        updateSelection(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        updateSelection(at: NSPoint(x: -1, y: -1))
    }
    override func mouseDown(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseUp(with event: NSEvent) {
        mouseMoved(with: event)
        if selectedRows > 0 { commitSelection() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard selectedRows > 0, selectedColumns > 0 else { return false }
        commitSelection()
        return true
    }

    private func commitSelection() {
        let rows = selectedRows, columns = selectedColumns
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        let action = insert
        // Insert only after the menu's tracking loop has finished.
        DispatchQueue.main.async { action(rows, columns) }
    }

    private final class CellAccessibilityElement: NSAccessibilityElement {
        weak var picker: TableSizePickerView?
        let row: Int
        let column: Int

        init(picker: TableSizePickerView, row: Int, column: Int) {
            self.picker = picker
            self.row = row
            self.column = column
            super.init()
            setAccessibilityParent(picker)
            setAccessibilityRole(.button)
            setAccessibilityEnabled(true)
            setAccessibilityLabel(String(format: NSLocalizedString("%d rows × %d columns", comment: "Table size picker"),
                                         row + 1, column + 1))
        }

        override func accessibilityFrame() -> NSRect {
            guard let picker = picker, let window = picker.window else { return .zero }
            return window.convertToScreen(picker.convert(picker.cellRect(row: row, column: column), to: nil))
        }

        override func accessibilityPerformPress() -> Bool {
            guard let picker = picker else { return false }
            let rect = picker.cellRect(row: row, column: column)
            picker.updateSelection(at: NSPoint(x: rect.midX, y: rect.midY))
            picker.commitSelection()
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (selectionTitle as NSString).draw(at: NSPoint(x: inset, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor
        ])
        for row in 0..<Self.maximumRows {
            for column in 0..<Self.maximumColumns {
                let selected = row < selectedRows && column < selectedColumns
                let rect = cellRect(row: row, column: column).insetBy(dx: 0.5, dy: 0.5)
                let path = NSBezierPath(rect: rect)
                if selected {
                    NSColor.systemOrange.withAlphaComponent(0.5).setFill()
                    path.fill()
                }
                (selected ? NSColor.systemOrange : NSColor.secondaryLabelColor).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}
