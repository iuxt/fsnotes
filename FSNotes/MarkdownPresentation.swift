import Foundation
import libcmark_gfm

/// A display plan in original UTF-16 coordinates. It never rewrites Markdown.
struct MarkdownPresentation {
    enum Decoration: Equatable {
        case text(String), quote, rule, image(destination: String, title: String)
    }
    struct Element: Equatable {
        let range: NSRange
        let hidden: [NSRange]
        let decoration: Decoration?
        let anchor: Int

        func isEditing(_ selections: [NSRange]) -> Bool {
            selections.contains { selection in
                if selection.length > 0 { return NSIntersectionRange(range, selection).length > 0 }
                return selection.location >= range.location && selection.location <= NSMaxRange(range)
            }
        }
    }
    enum Style {
        case heading(Int), strong, emphasis, strike, code, codeBlock, link(String)
    }
    struct StyledRange { let range: NSRange; let style: Style }
    let elements: [Element]
    var styles: [StyledRange] = []

    static func parse(_ source: String) -> Self {
        let text = source as NSString
        let lines = SourceLines(source)
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES) else { return Self(elements: []) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return Self(elements: []) }
        defer { cmark_node_free(document) }
        var elements: [Element] = []
        var literalBlocks: [NSRange] = []
        var contentBlocks: [NSRange] = []
        var styles: [StyledRange] = []

        func add(_ scope: NSRange, _ hidden: [NSRange], _ decoration: Decoration? = nil, anchor: Int? = nil) {
            let valid = hidden.filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= text.length }
            guard !valid.isEmpty else { return }
            elements.append(Element(range: scope, hidden: valid, decoration: decoration, anchor: anchor ?? valid[0].location))
        }
        func match(_ pattern: String, in range: NSRange) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern)).flatMap { $0.firstMatch(in: source, range: range) }
        }
        func walk(_ node: UnsafeMutablePointer<cmark_node>) {
            let type = String(cString: cmark_node_get_type_string(node))
            let range = lines.range(node)
            guard range.length > 0 else { return }
            if ["paragraph", "heading", "code_block", "html_block", "thematic_break", "table"].contains(type) {
                contentBlocks.append(range)
            }
            if type == "table" { literalBlocks.append(range); return }
            switch type {
            case "strong", "emph", "strikethrough":
                styles.append(StyledRange(range: range, style: type == "emph" ? .emphasis : (type == "strong" ? .strong : .strike)))
                let count = type == "emph" ? 1 : 2
                if range.length >= count * 2 {
                    add(range, [NSRange(location: range.location, length: count),
                                NSRange(location: NSMaxRange(range) - count, length: count)])
                }
            case "code":
                // cmark reports the content range, excluding the backtick delimiters.
                var start = range.location, end = NSMaxRange(range)
                while start > 0 && text.character(at: start - 1) == 96 { start -= 1 }
                while end < text.length && text.character(at: end) == 96 { end += 1 }
                let scope = NSRange(location: start, length: end - start)
                literalBlocks.append(scope)
                styles.append(StyledRange(range: scope, style: .code))
                add(scope, [NSRange(location: start, length: range.location - start),
                            NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))])
                return
            case "link", "image":
                if text.character(at: range.location) == 60, text.character(at: NSMaxRange(range) - 1) == 62 {
                    add(range, [NSRange(location: range.location, length: 1), NSRange(location: NSMaxRange(range) - 1, length: 1)])
                } else if let label = labelRange(in: range, text: text) {
                    let hidden = [NSRange(location: range.location, length: label.location - range.location),
                                  NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label))]
                    if type == "image" {
                        let destination = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                        add(range, [range], .image(destination: destination, title: text.substring(with: label)))
                        return
                    }
                    if let url = cmark_node_get_url(node) {
                        styles.append(StyledRange(range: label, style: .link(String(cString: url))))
                    }
                    add(range, hidden)
                }
            case "heading":
                styles.append(StyledRange(range: range, style: .heading(Int(cmark_node_get_heading_level(node)))))
                let line = lines.content(at: Int(cmark_node_get_start_line(node)))
                if let opening = match(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#, in: line) {
                    var hidden = [opening.range]
                    if let closing = match(#"[ \t]+#+[ \t]*$"#, in: line) { hidden.append(closing.range) }
                    add(range, hidden)
                } else {
                    let last = Int(cmark_node_get_end_line(node))
                    for lineNumber in Int(cmark_node_get_start_line(node)) + 1...max(last, Int(cmark_node_get_start_line(node)) + 1) {
                        let underline = lines.content(at: lineNumber)
                        if match(#"^ {0,3}(?:=+|-+)[ \t]*$"#, in: underline) != nil {
                            add(range, [lines.full(at: lineNumber)])
                        }
                    }
                }
            case "item", "tasklist":
                let line = lines.content(at: Int(cmark_node_get_start_line(node)))
                let search = NSRange(location: range.location, length: max(0, NSMaxRange(line) - range.location))
                if let marker = match(#"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#, in: search) {
                    let raw = text.substring(with: marker.range)
                    let label: String
                    if raw.contains("[ ]") { label = "☐" }
                    else if raw.lowercased().contains("[x]") { label = "☑" }
                    else if raw.first?.isNumber == true { label = raw.trimmingCharacters(in: .whitespaces) }
                    else { label = "•" }
                    add(line, [marker.range], .text(label))
                    if label == "☑" {
                        let content = NSRange(location: NSMaxRange(marker.range), length: NSMaxRange(line) - NSMaxRange(marker.range))
                        styles.append(StyledRange(range: content, style: .strike))
                    }
                }
            case "block_quote":
                for number in Int(cmark_node_get_start_line(node))...Int(cmark_node_get_end_line(node)) {
                    let line = lines.content(at: number)
                    if let prefix = match(#"^ {0,3}(?:>[ \t]?)+"#, in: line) { add(line, [prefix.range], .quote) }
                }
            case "thematic_break":
                add(range, [range], .rule)
                return
            case "code_block":
                styles.append(StyledRange(range: range, style: .codeBlock))
                literalBlocks.append(range)
                let first = Int(cmark_node_get_start_line(node)), last = Int(cmark_node_get_end_line(node))
                let opening = lines.content(at: first)
                if let fence = match(#"^ {0,3}(`{3,}|~{3,})"#, in: opening) {
                    var hidden = [lines.full(at: first)]
                    if last > first {
                        let character = text.substring(with: fence.range(at: 1)).first!
                        let closing = lines.content(at: last)
                        let pattern = "^ {0,3}" + NSRegularExpression.escapedPattern(for: String(character)) + "{\(fence.range(at: 1).length),}[ \\t]*$"
                        if match(pattern, in: closing) != nil { hidden.append(lines.full(at: last)) }
                    }
                    add(range, hidden)
                } else {
                    var hidden: [NSRange] = []
                    for number in first...last {
                        if let indent = match(#"^(?: {4}|\t)"#, in: lines.content(at: number)) { hidden.append(indent.range) }
                    }
                    add(range, hidden)
                }
                return
            case "html_inline", "html_block":
                let tags = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?[A-Za-z][^>]*>"#)
                let scope = text.paragraphRange(for: range)
                for tag in tags.matches(in: source, range: range) { add(scope, [tag.range]) }
                return
            case "text":
                // Escaped punctuation is literal content, including within link labels.
                let regex = try! NSRegularExpression(pattern: ##"\\[!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~]"##)
                for escape in regex.matches(in: source, range: range) {
                    add(escape.range, [NSRange(location: escape.range.location, length: 1)])
                }
                let entities = try! NSRegularExpression(pattern: #"&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);"#)
                for entity in entities.matches(in: source, range: range) {
                    let raw = text.substring(with: entity.range)
                    if let decoded = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        let value = String(decoded.characters)
                        if value != raw { add(entity.range, [entity.range], .text(value)) }
                    }
                }
            default: break
            }
            var child = cmark_node_first_child(node)
            while let current = child { walk(current); child = cmark_node_next(current) }
        }
        walk(document)

        // FSNotes wiki links are an editor extension to CommonMark.
        let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
        for result in wiki.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !literalBlocks.contains(where: { NSIntersectionRange($0, result.range).length > 0 }),
                  !elements.contains(where: { NSIntersectionRange($0.range, result.range).length > 0 }) else { continue }
            add(result.range, [NSRange(location: result.range.location, length: 2),
                               NSRange(location: NSMaxRange(result.range) - 2, length: 2)])
        }
        // Reference definitions have no rendered text. Keep their source accessible at the caret.
        let definitions = try! NSRegularExpression(pattern: #"(?m)^ {0,3}\[[^\]\n]+\]:[ \t]+[^\n]+"#)
        for result in definitions.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !contentBlocks.contains(where: { NSIntersectionRange($0, result.range).length > 0 }) else { continue }
            add(result.range, [text.lineRange(for: result.range)])
        }
        return Self(elements: elements, styles: styles)
    }

    private static func labelRange(in range: NSRange, text: NSString) -> NSRange? {
        var index = range.location
        if text.character(at: index) == 33 { index += 1 }
        guard index < NSMaxRange(range), text.character(at: index) == 91 else { return nil }
        let start = index + 1
        var depth = 1
        index += 1
        while index < NSMaxRange(range) {
            let char = text.character(at: index)
            if char == 92 { index += 2; continue }
            if char == 91 { depth += 1 }
            if char == 93 {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: index - start) }
            }
            index += 1
        }
        return nil
    }
}

private struct SourceLines {
    struct Line {
        let range: NSRange
        let content: NSRange
        let byteOffsets: [Int]
    }
    let lines: [Line]
    let length: Int

    init(_ source: String) {
        let text = source as NSString
        length = text.length
        var result: [Line] = []
        var offset = 0
        while offset < text.length {
            var start = 0, end = 0, contentEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            let content = NSRange(location: start, length: contentEnd - start)
            var map = [0], utf16 = 0
            for scalar in text.substring(with: content).unicodeScalars {
                let bytes = String(scalar).utf8.count
                map.append(contentsOf: Array(repeating: utf16, count: bytes - 1))
                utf16 += scalar.utf16.count
                map.append(utf16)
            }
            result.append(Line(range: NSRange(location: start, length: end - start), content: content, byteOffsets: map))
            offset = end
        }
        lines = result
    }
    func content(at number: Int) -> NSRange {
        guard number > 0 && number <= lines.count else { return NSRange(location: length, length: 0) }
        return lines[number - 1].content
    }
    func full(at number: Int) -> NSRange {
        guard number > 0 && number <= lines.count else { return NSRange(location: length, length: 0) }
        return lines[number - 1].range
    }
    func offset(line: Int, byte: Int) -> Int {
        guard line > 0 && line <= lines.count else { return length }
        let value = lines[line - 1]
        return value.content.location + value.byteOffsets[min(max(0, byte), value.byteOffsets.count - 1)]
    }
    func range(_ node: UnsafeMutablePointer<cmark_node>) -> NSRange {
        let start = offset(line: Int(cmark_node_get_start_line(node)), byte: Int(cmark_node_get_start_column(node)) - 1)
        let end = offset(line: Int(cmark_node_get_end_line(node)), byte: Int(cmark_node_get_end_column(node)))
        return NSRange(location: start, length: max(0, end - start))
    }
}

#if os(macOS)
import Cocoa

extension MarkdownPresentation {
    func applyStyles(to content: NSMutableAttributedString, in affected: NSRange,
                     font: NSFont, codeFont: NSFont, textColor: NSColor,
                     codeBackground: NSColor, codeSpanBackground: NSColor) {
        for styled in styles {
            let range = NSIntersectionRange(styled.range, affected)
            guard range.length > 0 else { continue }
            switch styled.style {
            case .heading(let level):
                let scales: [CGFloat] = [2, 1.7, 1.4, 1.2, 1.1, 1.05]
                let size = font.pointSize * scales[min(5, max(0, level - 1))]
                let header = NSFontManager.shared.convert(NSFontManager.shared.convert(font, toSize: size), toHaveTrait: .boldFontMask)
                content.addAttribute(.font, value: header, range: range)
            case .strong, .emphasis:
                let trait: NSFontTraitMask = { if case .strong = styled.style { return .boldFontMask }; return .italicFontMask }()
                content.enumerateAttribute(.font, in: range) { value, span, _ in
                    content.addAttribute(.font, value: NSFontManager.shared.convert(value as? NSFont ?? font, toHaveTrait: trait), range: span)
                }
            case .strike:
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code, .codeBlock:
                content.addAttributes([.font: codeFont, .foregroundColor: textColor], range: range)
                content.removeAttribute(.strikethroughStyle, range: range)
                content.removeAttribute(.link, range: range)
                let background = { if case .codeBlock = styled.style { return codeBackground }; return codeSpanBackground }()
                content.addAttribute(.backgroundColor, value: background, range: range)
            case .link(let destination):
                content.addAttributes([.font: font, .foregroundColor: NSColor.linkColor, .link: destination], range: range)
            }
        }
    }
}
#endif
