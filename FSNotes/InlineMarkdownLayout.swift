import Cocoa

extension LayoutManager {
    func refreshInlineMarkdown() {
        guard let storage = textStorage else { return }
        let sourceChanged = markdownSource != storage.string
        if sourceChanged {
            markdownSource = storage.string
            markdownPresentation = MarkdownPresentation.parse(storage.string)
        }
        let editor = firstTextView as? EditTextView
        let enabled = editor?.note?.isMarkdown() == true
        let selections = editor?.window?.firstResponder === editor ? (editor?.selectedRanges.map { $0.rangeValue } ?? []) : []
        var hidden = IndexSet()
        var decorations: [Int: MarkdownPresentation.Decoration] = [:]
        if enabled {
            for element in markdownPresentation.elements where !element.isEditing(selections) {
                for range in element.hidden { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
                if let decoration = element.decoration { decorations[element.anchor] = decoration }
            }
        }
        guard sourceChanged || hidden != hiddenMarkdownCharacters || decorations != markdownDecorations else { return }
        let affected = hidden.union(hiddenMarkdownCharacters)
        hiddenMarkdownCharacters = hidden
        markdownDecorations = decorations
        let fullRange = NSRange(location: 0, length: storage.length)
        if sourceChanged {
            invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        } else {
            for range in affected.rangeView {
                let safe = NSRange(location: range.lowerBound, length: range.count).clamped(to: fullRange)
                if safe.length > 0 { invalidateGlyphs(forCharacterRange: safe, changeInLength: 0, actualCharacterRange: nil) }
            }
        }
        firstTextView?.needsDisplay = true
    }

    func markdownDecorationSize(_ decoration: MarkdownPresentation.Decoration, in container: NSTextContainer) -> NSSize {
        let font = UserDefaultsManagement.noteFont
        let height = defaultLineHeight(for: font)
        let width = max(1, container.size.width - container.lineFragmentPadding * 2)
        switch decoration {
        case .text(let value): return NSSize(width: (value as NSString).size(withAttributes: [.font: font]).width + 8, height: height)
        case .quote: return NSSize(width: 14, height: height)
        case .rule: return NSSize(width: width, height: height)
        case .image(let destination, let title):
            if let image = markdownImage(destination) {
                let scale = min(1, width / max(1, image.size.width))
                return NSSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            return NSSize(width: min(width, (imageLabel(title, destination) as NSString).size(withAttributes: [.font: font]).width + 12), height: height)
        }
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
            let size = markdownDecorationSize(decoration, in: container)
            let rect = NSRect(x: origin.x + line.minX + position.x, y: origin.y + line.minY,
                              width: size.width, height: size.height)
            switch decoration {
            case .text(let text):
                (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + (rect.height - size.height) / 2),
                    withAttributes: [.font: UserDefaultsManagement.noteFont, .foregroundColor: NSColor.labelColor])
            case .quote:
                NSColor.separatorColor.setFill()
                NSRect(x: rect.minX + 2, y: rect.minY, width: 3, height: line.height).fill()
            case .rule:
                NSColor.separatorColor.setFill()
                NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1).fill()
            case .image(let destination, let title):
                if let image = markdownImage(destination) {
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    (imageLabel(title, destination) as NSString).draw(in: rect,
                        withAttributes: [.font: UserDefaultsManagement.noteFont, .foregroundColor: NSColor.secondaryLabelColor])
                }
            }
        }
    }
}
