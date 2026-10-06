import Foundation

/// Source ranges always refer to UTF-16 offsets in the original Markdown.
struct MarkdownTable: Equatable {
    struct Cell: Equatable {
        let text: String
        let range: NSRange
    }
    struct Row: Equatable {
        let range: NSRange
        let cells: [Cell]
    }
    enum Alignment: Equatable { case left, center, right }

    let range: NSRange
    let rows: [Row]
    let alignments: [Alignment]
    let endsWithNewline: Bool

    static func parse(_ source: String) -> [MarkdownTable] {
        let text = source as NSString
        var lines: [(range: NSRange, content: NSRange, eligible: Bool)] = []
        var location = 0
        var fence: (character: Character, count: Int)?
        while location < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: location, length: 0))
            let content = NSRange(location: start, length: contentsEnd - start)
            let line = text.substring(with: content)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            var eligible = fence == nil && indent < 4 && !line.hasPrefix("\t")
            if let character = trimmed.first, character == "`" || character == "~" {
                let count = trimmed.prefix { $0 == character }.count
                if count >= 3 && indent < 4 {
                    eligible = false
                    if let active = fence {
                        if active.character == character && count >= active.count &&
                            trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                            fence = nil
                        }
                    } else { fence = (character, count) }
                }
            }
            lines.append((NSRange(location: start, length: end - start), content, eligible))
            location = end
        }

        var result: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            let header = lines[index], delimiter = lines[index + 1]
            guard header.eligible, delimiter.eligible,
                  let headerCells = cells(in: header.content, text: text),
                  let separators = cells(in: delimiter.content, text: text),
                  separators.count == headerCells.count,
                  separators.allSatisfy({ isDelimiter($0.text) }) else {
                index += 1
                continue
            }
            var rows = [Row(range: header.range, cells: headerCells)]
            var last = index + 1
            while last + 1 < lines.count {
                let line = lines[last + 1]
                guard line.eligible, let rowCells = cells(in: line.content, text: text) else { break }
                rows.append(Row(range: line.range, cells: Array(rowCells.prefix(headerCells.count))))
                last += 1
            }
            let range = NSRange(location: header.range.location,
                                length: NSMaxRange(lines[last].range) - header.range.location)
            let alignments = separators.map { cell -> Alignment in
                if cell.text.hasSuffix(":") { return cell.text.hasPrefix(":") ? .center : .right }
                return .left
            }
            result.append(MarkdownTable(range: range, rows: rows, alignments: alignments,
                endsWithNewline: NSMaxRange(lines[last].content) < NSMaxRange(lines[last].range)))
            index = last + 1
        }
        return result
    }

    private static func isDelimiter(_ value: String) -> Bool {
        var dashes = value[...]
        if dashes.first == ":" { dashes = dashes.dropFirst() }
        if dashes.last == ":" { dashes = dashes.dropLast() }
        return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
    }

    private static func cells(in range: NSRange, text: NSString) -> [Cell]? {
        var pipes: [Int] = []
        var escaped = false
        for index in range.location..<NSMaxRange(range) {
            let character = text.character(at: index)
            if character == 124 && !escaped { pipes.append(index) }
            escaped = character == 92 && !escaped
        }
        guard !pipes.isEmpty else { return nil }
        var boundaries = [range.location - 1] + pipes + [NSMaxRange(range)]
        if text.substring(with: NSRange(location: range.location,
            length: pipes[0] - range.location)).trimmingCharacters(in: .whitespaces).isEmpty {
            boundaries.removeFirst()
        }
        if text.substring(with: NSRange(location: pipes.last! + 1,
            length: NSMaxRange(range) - pipes.last! - 1)).trimmingCharacters(in: .whitespaces).isEmpty {
            boundaries.removeLast()
        }
        guard boundaries.count >= 2 else { return nil }
        return zip(boundaries, boundaries.dropFirst()).map { left, right in
            var start = left + 1, end = right
            while start < end && (text.character(at: start) == 32 || text.character(at: start) == 9) { start += 1 }
            while end > start && (text.character(at: end - 1) == 32 || text.character(at: end - 1) == 9) { end -= 1 }
            let cellRange = NSRange(location: start, length: end - start)
            return Cell(text: text.substring(with: cellRange), range: cellRange)
        }
    }
}

/// Table commands operate on cells, then serialize one valid Markdown table.
struct MarkdownTableDocument {
    var rows: [[String]]
    var alignments: [MarkdownTable.Alignment]
    let endsWithNewline: Bool

    init(_ table: MarkdownTable) {
        alignments = table.alignments
        endsWithNewline = table.endsWithNewline
        rows = table.rows.map { row in
            table.alignments.indices.map { $0 < row.cells.count ? row.cells[$0].text : "" }
        }
    }

    var markdown: String {
        let header = serialize(rows[0])
        let delimiter = serialize(alignments.map {
            switch $0 {
            case .left: return "---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        })
        return ([header, delimiter] + rows.dropFirst().map(serialize)).joined(separator: "\n") +
            (endsWithNewline ? "\n" : "")
    }

    mutating func setCell(row: Int, column: Int, text: String) {
        guard rows.indices.contains(row), alignments.indices.contains(column) else { return }
        var value = "", backslashes = 0
        for character in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") {
            if character == "|" && backslashes % 2 == 0 { value.append("\\") }
            value.append(character == "\n" ? "<br>" : String(character))
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        let leading = value.prefix { $0 == " " }.count
        value.removeFirst(leading)
        let trailing = value.reversed().prefix { $0 == " " }.count
        value.removeLast(trailing)
        rows[row][column] = String(repeating: "&#32;", count: leading) + value + String(repeating: "&#32;", count: trailing)
    }

    mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: alignments.count), at: min(max(1, index), rows.count))
    }

    mutating func insertColumn(at index: Int) {
        let column = min(max(0, index), alignments.count)
        alignments.insert(.left, at: column)
        for row in rows.indices { rows[row].insert("", at: column) }
    }

    mutating func removeRow(at index: Int) {
        if index > 0 && rows.indices.contains(index) { rows.remove(at: index) }
    }

    mutating func removeColumn(at index: Int) {
        guard alignments.count > 1, alignments.indices.contains(index) else { return }
        alignments.remove(at: index)
        for row in rows.indices { rows[row].remove(at: index) }
    }

    /// Destination is a boundary in the table before removing the source row.
    @discardableResult mutating func moveRow(from source: Int, to destination: Int) -> Int? {
        guard source > 0, rows.indices.contains(source) else { return nil }
        let boundary = min(max(1, destination), rows.count)
        let target = boundary > source ? boundary - 1 : boundary
        let row = rows.remove(at: source)
        rows.insert(row, at: target)
        return target
    }

    static func editingText(_ source: String) -> String {
        source.replacingOccurrences(of: "&#32;", with: " ").replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
    }

    private func serialize(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
}
