import Cocoa

extension LayoutManager {
    func refreshInlineMarkdown(editedRange: NSRange? = nil, changeInLength delta: Int = 0) {
        guard let storage = textStorage else { return }
        let source = storage.string
        let sourceChanged = inlineMarkdownSource != source
        let previousSource = inlineMarkdownSource
        let plan = presentation(for: source)
        inlineMarkdownSource = source
        let editor = firstTextView as? EditTextView
        let enabled = editor?.note?.isMarkdown() == true
        let selections = editor?.window?.firstResponder === editor ? (editor?.selectedRanges.map { $0.rangeValue } ?? []) : []
        guard sourceChanged || enabled != inlineMarkdownEnabled || selections != inlineMarkdownSelections else { return }
        inlineMarkdownEnabled = enabled
        inlineMarkdownSelections = selections
        var hidden = IndexSet()
        var decorations: [Int: MarkdownPresentation.Decoration] = [:]
        if enabled {
            for element in plan.elements where !element.isEditing(selections) {
                for range in element.hidden { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
                if let decoration = element.decoration { decorations[element.anchor] = decoration }
            }
        }
        guard sourceChanged || hidden != hiddenMarkdownCharacters || decorations != markdownDecorations else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        var previousHidden = hiddenMarkdownCharacters
        var previousDecorations = markdownDecorations
        var affected = IndexSet()
        if sourceChanged, let previousSource = previousSource {
            // TextKit shifts unchanged glyphs after an edit. Compare decorations
            // in those same coordinates instead of invalidating the whole note.
            let old = previousSource as NSString, new = source as NSString
            let start: Int, oldEnd: Int, newEnd: Int
            if let edit = editedRange, old.length + delta == new.length,
               NSMaxRange(edit) <= new.length, NSMaxRange(edit) - delta >= edit.location {
                start = edit.location
                newEnd = NSMaxRange(edit)
                oldEnd = newEnd - delta
            } else {
                var prefix = 0
                while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
                var previousEnd = old.length, currentEnd = new.length
                while previousEnd > prefix, currentEnd > prefix, old.character(at: previousEnd - 1) == new.character(at: currentEnd - 1) {
                    previousEnd -= 1; currentEnd -= 1
                }
                start = prefix; oldEnd = previousEnd; newEnd = currentEnd
            }
            previousHidden.remove(integersIn: start..<oldEnd)
            previousHidden.shift(startingAt: oldEnd, by: newEnd - oldEnd)
            previousDecorations = Dictionary(uniqueKeysWithValues: previousDecorations.compactMap { index, value in
                if index < start { return (index, value) }
                if index >= oldEnd { return (index + newEnd - oldEnd, value) }
                return nil
            })
            let paragraph = new.paragraphRange(for: NSRange(location: start, length: newEnd - start))
            affected.insert(integersIn: paragraph.location..<NSMaxRange(paragraph))
        } else if sourceChanged {
            affected.insert(integersIn: 0..<storage.length)
        }
        affected.formUnion(hidden.symmetricDifference(previousHidden))
        for index in Set(previousDecorations.keys).union(decorations.keys) where previousDecorations[index] != decorations[index] {
            if index < storage.length { affected.insert(index) }
        }
        hiddenMarkdownCharacters = hidden
        markdownDecorations = decorations
        for range in affected.rangeView {
            let safe = NSRange(location: range.lowerBound, length: range.count).clamped(to: fullRange)
            if safe.length > 0 { invalidateGlyphs(forCharacterRange: safe, changeInLength: 0, actualCharacterRange: nil) }
        }
        firstTextView?.needsDisplay = true
    }

    func markdownDecorationSize(_ decoration: MarkdownPresentation.Decoration, in container: NSTextContainer, at index: Int? = nil) -> NSSize {
        let font = markdownDecorationFont(decoration, at: index)
        let height = defaultLineHeight(for: font)
        let width = max(1, container.size.width - container.lineFragmentPadding * 2)
        switch decoration {
        case .text(let value):
            if value == "☐" || value == "☑" { return NSSize(width: 22, height: height) }
            return NSSize(width: (value as NSString).size(withAttributes: [.font: font]).width + 8, height: height)
        case .literal(let value), .footnote(let value): return NSSize(width: (value as NSString).size(withAttributes: [.font: font]).width, height: height)
        case .quote: return NSSize(width: 20, height: height)
        case .rule: return NSSize(width: width, height: height)
        case .image(let destination, let title):
            if let image = markdownImage(destination) {
                let scale = min(1, width / max(1, image.size.width))
                return NSSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            return NSSize(width: min(width, (imageLabel(title, destination) as NSString).size(withAttributes: [.font: font]).width + 12), height: height)
        }
    }

    private func markdownDecorationFont(_ decoration: MarkdownPresentation.Decoration, at index: Int?) -> NSFont {
        var font = UserDefaultsManagement.noteFont
        if let index = index, let storage = textStorage, index < storage.length {
            font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? font
        }
        if case .footnote = decoration { return NSFontManager.shared.convert(font, toSize: font.pointSize * 0.75) }
        return font
    }

    private func imageLabel(_ title: String, _ destination: String) -> String {
        "▧ " + (title.isEmpty ? (destination as NSString).lastPathComponent : title)
    }

    private func markdownImage(_ destination: String) -> NSImage? {
        if let image = markdownImages[destination] { return image }
        guard !missingMarkdownImages.contains(destination),
              let note = (firstTextView as? EditTextView)?.note,
              let url = note.getAttachmentFileUrl(name: destination.hasPrefix("http") ? destination : (destination.removingPercentEncoding ?? destination)) else { return nil }
        if !url.isFileURL {
            guard ["http", "https"].contains(url.scheme ?? ""), !pendingMarkdownImages.contains(destination) else { return nil }
            pendingMarkdownImages.insert(destination)
            URLSession.shared.dataTask(with: url) { [weak self, weak note] data, _, _ in
                DispatchQueue.main.async {
                    guard let self = self, let note = note, (self.firstTextView as? EditTextView)?.note === note else { return }
                    self.pendingMarkdownImages.remove(destination)
                    if let data = data, let image = NSImage(data: data), image.size.width > 0 && image.size.height > 0 {
                        self.markdownImages[destination] = image
                    } else { self.missingMarkdownImages.insert(destination) }
                    self.refreshLayoutSoftly()
                    (self.firstTextView as? EditTextView)?.scheduleTableEditorsUpdate()
                }
            }.resume()
            return nil
        }
        if let image = NSImage(contentsOf: url), image.size.width > 0 && image.size.height > 0 {
            markdownImages[destination] = image
            return image
        }
        missingMarkdownImages.insert(destination)
        return nil
    }

    func drawInlineMarkdown(in visible: NSRange, at origin: NSPoint, container: NSTextContainer) {
        for (index, decoration) in markdownDecorations where NSLocationInRange(index, visible) {
            let glyph = glyphIndexForCharacter(at: index)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let size = markdownDecorationSize(decoration, in: container, at: index)
            let rect = NSRect(x: origin.x + line.minX + position.x, y: origin.y + line.minY,
                              width: size.width, height: size.height)
            switch decoration {
            case .text(let text), .literal(let text), .footnote(let text):
                if case .text = decoration, text == "☐" || text == "☑" {
                    drawTaskCheckbox(checked: text == "☑", in: rect)
                    continue
                }
                var color = textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor ?? NSColor.labelColor
                if case .text = decoration { color = .labelColor }
                (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY),
                    withAttributes: [.font: markdownDecorationFont(decoration, at: index), .foregroundColor: color])
            case .quote:
                let range = markdownPresentation.elements.first { $0.anchor == index && $0.decoration == .quote }?.range
                let height = range.map { boundingRect(forGlyphRange: glyphRange(forCharacterRange: $0, actualCharacterRange: nil), in: container).height } ?? line.height
                NSColor.labelColor.withAlphaComponent(0.19).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 2, y: rect.minY + 2, width: 2.5, height: max(1, height - 4)), xRadius: 1.25, yRadius: 1.25).fill()
            case .rule:
                MarkdownEditorStyle.hairline.setFill()
                NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
            case .image(let destination, let title):
                if let image = markdownImage(destination) {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: rect, xRadius: MarkdownEditorStyle.cornerRadius, yRadius: MarkdownEditorStyle.cornerRadius).addClip()
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    (imageLabel(title, destination) as NSString).draw(in: rect,
                        withAttributes: [.font: UserDefaultsManagement.noteFont, .foregroundColor: NSColor.secondaryLabelColor])
                }
                if let editor = firstTextView as? EditTextView, editor.window?.firstResponder === editor,
                   let element = markdownPresentation.elements.first(where: { $0.anchor == index }),
                   editor.selectedRanges.contains(where: { NSIntersectionRange($0.rangeValue, element.range).length > 0 }) {
                    NSColor.controlAccentColor.setStroke()
                    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                              xRadius: MarkdownEditorStyle.cornerRadius, yRadius: MarkdownEditorStyle.cornerRadius)
                    border.lineWidth = 2
                    border.stroke()
                }
            }
        }
    }

    func inlineImageRect(_ element: MarkdownPresentation.Element, in container: NSTextContainer) -> NSRect {
        guard case .image = element.decoration, let decoration = markdownDecorations[element.anchor] else { return .zero }
        ensureLayout(forCharacterRange: NSRange(location: element.anchor, length: 1))
        let glyph = glyphIndexForCharacter(at: element.anchor)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = location(forGlyphAt: glyph)
        return NSRect(origin: NSPoint(x: line.minX + position.x, y: line.minY),
                      size: markdownDecorationSize(decoration, in: container, at: element.anchor))
    }
    private func drawTaskCheckbox(checked: Bool, in rect: NSRect) {
        let size = min(14, rect.height - 4)
        let box = NSRect(x: rect.minX + 1, y: rect.minY + (rect.height - size) / 2, width: size, height: size)
        let shape = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if checked {
            NSColor.controlAccentColor.setFill()
            shape.fill()
            NSColor.white.setStroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            check.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 4))
            check.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 4))
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

}
