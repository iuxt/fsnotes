import Cocoa

/// Draws a table without replacing any characters or attributes in text storage.
struct InlineTableLayout {
    let table: MarkdownTable
    let availableWidth: CGFloat
    let font: NSFont
    let widths: [CGFloat]
    let heights: [CGFloat]
    let cells: [[NSAttributedString]]
    static let padding: CGFloat = 8
    static let side: CGFloat = 24
    static let top: CGFloat = 22
    static let bottom: CGFloat = 50

    var size: NSSize { NSSize(width: widths.reduce(0, +), height: heights.reduce(0, +)) }
    var blockSize: NSSize { NSSize(width: size.width + Self.side * 2, height: size.height + Self.top + Self.bottom) }

    func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: widths.prefix(column).reduce(0, +), y: heights.prefix(row).reduce(0, +),
               width: widths[column], height: heights[row])
    }

    func cell(at point: NSPoint) -> (row: Int, column: Int) {
        var row = 0, y: CGFloat = 0
        while row + 1 < heights.count && point.y >= y + heights[row] { y += heights[row]; row += 1 }
        var column = 0, x: CGFloat = 0
        while column + 1 < widths.count && point.x >= x + widths[column] { x += widths[column]; column += 1 }
        return (row, column)
    }

    init(table: MarkdownTable, availableWidth: CGFloat, font: NSFont) {
        self.table = table
        self.availableWidth = availableWidth
        self.font = font
        let cellValues = table.rows.enumerated().map { rowIndex, row in
            table.alignments.indices.map { column in
                let text = column < row.cells.count ? row.cells[column].text : ""
                let displayText = text.replacingOccurrences(of: "<br>", with: "\n")
                    .replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br />", with: "\n")
                let value = (try? AttributedString(markdown: displayText,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
                let attributed = NSMutableAttributedString(string: String(value.characters))
                var offset = 0
                for run in value.runs {
                    let length = String(value[run.range].characters).utf16.count
                    let range = NSRange(location: offset, length: length)
                    var traits: NSFontTraitMask = rowIndex == 0 ? .boldFontMask : []
                    let intent = run.inlinePresentationIntent ?? []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                    if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                    let base = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFontManager.shared.convert(base, toHaveTrait: traits),
                        .foregroundColor: NSColor.labelColor
                    ]
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if run.link != nil { attributes[.foregroundColor] = NSColor.linkColor }
                    attributed.addAttributes(attributes, range: range)
                    offset += length
                }
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byCharWrapping
                switch table.alignments[column] {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                }
                attributed.addAttribute(.paragraphStyle, value: style,
                    range: NSRange(location: 0, length: attributed.length))
                return attributed
            }
        }
        // Also measure the editable Markdown so markers never clip while entering a cell.
        let editingValues = table.rows.enumerated().map { rowIndex, row in
            table.alignments.indices.map { column in
                let text = column < row.cells.count ? MarkdownTableDocument.editingText(row.cells[column].text) : ""
                let cellFont = rowIndex == 0 ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
                return NSAttributedString(string: text, attributes: [.font: cellFont])
            }
        }
        let preferred = table.alignments.indices.map { column in
            max(60, cellValues.indices.map {
                max(cellValues[$0][column].size().width, editingValues[$0][column].size().width) + Self.padding * 2
            }.max() ?? 60)
        }
        let total = preferred.reduce(0, +)
        let width = max(1, availableWidth)
        let minimum = min(60, width / CGFloat(preferred.count))
        let remaining = max(0, width - minimum * CGFloat(preferred.count))
        let weights = preferred.map { max(0, $0 - minimum) }
        let weight = weights.reduce(0, +)
        let columnWidths = total <= width ? preferred : weights.map {
            minimum + (weight > 0 ? remaining * $0 / weight : 0)
        }
        let rowHeights = cellValues.indices.map { row in
            max(ceil(font.ascender - font.descender + font.leading),
                columnWidths.indices.map { column in
                    let constraint = NSSize(width: max(1, columnWidths[column] - Self.padding * 2), height: CGFloat.greatestFiniteMagnitude)
                    return ceil(max(cellValues[row][column].boundingRect(with: constraint,
                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height,
                        editingValues[row][column].boundingRect(with: constraint,
                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
                }.max() ?? 0) + Self.padding * 2
        }
        cells = cellValues
        widths = columnWidths
        heights = rowHeights
    }

    func draw(at origin: NSPoint) {
        var y = origin.y
        for (rowIndex, row) in cells.enumerated() {
            var x = origin.x
            for (column, cell) in row.enumerated() {
                let rect = NSRect(x: x, y: y, width: widths[column], height: heights[rowIndex])
                (rowIndex == 0 ? NSColor.quaternaryLabelColor : NSColor.textBackgroundColor).setFill()
                rect.fill()
                NSColor.separatorColor.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 0.5
                border.stroke()
                let textRect = NSRect(x: rect.minX + Self.padding, y: rect.minY + Self.padding,
                                      width: max(1, rect.width - Self.padding * 2), height: max(1, rect.height - Self.padding * 2))
                cell.draw(with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += widths[column]
            }
            y += heights[rowIndex]
        }
    }


}

extension LayoutManager {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !inlineTables.isEmpty || !hiddenMarkdownCharacters.isEmpty else { return 0 }
        var modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard let table = inlineTables.first(where: { NSLocationInRange(index, $0.range) }) else {
                if hiddenMarkdownCharacters.contains(index) {
                    let firstGlyph = offset == 0 || characterIndexes[offset - 1] != index
                    modified[offset] = markdownDecorations[index] != nil && firstGlyph ? .controlCharacter : .null
                    changed = true
                }
                continue
            }
            if table.endsWithNewline && index == NSMaxRange(table.range) - 1 { continue }
            let firstGlyph = index == table.range.location &&
                (offset == 0 || characterIndexes[offset - 1] != index)
            modified[offset] = firstGlyph ? .controlCharacter : .null
            changed = true
        }
        guard changed else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                      font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        inlineTables.contains { $0.range.location == charIndex } || markdownDecorations[charIndex] != nil ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if let decoration = markdownDecorations[charIndex] {
            return NSRect(origin: .zero, size: markdownDecorationSize(decoration, in: textContainer, at: charIndex))
        }
        guard let table = inlineTables.first(where: { $0.range.location == charIndex }) else { return .zero }
        let layout = inlineTableLayout(table, in: textContainer)
        return NSRect(origin: .zero, size: layout.blockSize)
    }

    func inlineTableLayout(_ table: MarkdownTable, in container: NSTextContainer) -> InlineTableLayout {
        let width = container.size.width - container.lineFragmentPadding * 2 - InlineTableLayout.side * 2
        let font = UserDefaultsManagement.noteFont
        if let cached = inlineTableLayouts[table.range.location], cached.table == table,
           cached.availableWidth == width, cached.font == font { return cached }
        let layout = InlineTableLayout(table: table, availableWidth: width, font: font)
        inlineTableLayouts[table.range.location] = layout
        return layout
    }

    func inlineTableRect(_ table: MarkdownTable, in container: NSTextContainer) -> NSRect {
        let glyph = glyphIndexForCharacter(at: table.range.location)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: fragment.minX + container.lineFragmentPadding + InlineTableLayout.side,
                      y: fragment.minY + InlineTableLayout.top,
                      width: inlineTableLayout(table, in: container).size.width,
                      height: inlineTableLayout(table, in: container).size.height)
    }

    func refreshInlineTables() {
        guard let storage = textStorage else { return }
        let source = storage.string
        let sourceChanged = inlineTableSource != source
        if sourceChanged {
            inlineTableSource = source
            markdownTables = MarkdownTable.parse(source)
        }
        let tables = processor?.editor?.note?.isMarkdown() == true ? markdownTables : []
        guard sourceChanged || tables != inlineTables else { return }
        let affected = inlineTables + tables
        inlineTables = tables
        inlineTableLayouts.removeAll()
        for table in affected {
            let range = table.range.clamped(to: NSRange(location: 0, length: storage.length))
            if range.length > 0 { invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil) }
        }
        firstTextView?.needsDisplay = true
    }
}
