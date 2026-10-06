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
