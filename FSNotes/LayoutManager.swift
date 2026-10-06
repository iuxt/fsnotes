//
//  CustomLayoutManager.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 24.08.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

extension NSRange {
    /// Clamp range to fit inside given maxRange
    func clamped(to maxRange: NSRange) -> NSRange {
        if maxRange.length == 0 { return NSRange(location: maxRange.location, length: 0) }
        if self.location >= NSMaxRange(maxRange) { return NSRange(location: NSMaxRange(maxRange), length: 0) }
        let start = max(self.location, maxRange.location)
        let end = min(NSMaxRange(self), NSMaxRange(maxRange))
        if end <= start { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }
}

class LayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    weak var processor: TextStorageProcessor?
    var markdownSource: String?
    var markdownPresentation = MarkdownPresentation(elements: [])
    var hiddenMarkdownCharacters = IndexSet()
    var markdownDecorations: [Int: MarkdownPresentation.Decoration] = [:]
    var markdownImages: [String: NSImage] = [:]
    var missingMarkdownImages = Set<String>()
    var pendingMarkdownImages = Set<String>()
    weak var inlineTableNote: Note?
    var inlineTableSource: String?
    var markdownTables: [MarkdownTable] = []
    var inlineTables: [MarkdownTable] = []
    var inlineTableLayouts: [Int: InlineTableLayout] = [:]

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
        if editMask.contains(.editedCharacters) {
            (firstTextView as? EditTextView)?.refreshInlineTables()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        drawInlineMarkdown(in: visible, at: origin, container: container)

    }
    
    override init() {
        super.init()
        
        self.allowsNonContiguousLayout = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.allowsNonContiguousLayout = true
    }
    
    public var lineHeightMultiple: CGFloat = CGFloat(UserDefaultsManagement.lineHeightMultiple)

    private var defaultFont: NSFont {
        return self.firstTextView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    private func font(for glyphRange: NSRange) -> NSFont {
        guard let textStorage = self.textStorage else {
            return defaultFont
        }
        
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        guard safeCharRange.length > 0 else {
            return defaultFont
        }
        
        let attributes = textStorage.attributes(at: safeCharRange.location, effectiveRange: nil)
        return attributes[.font] as? NSFont ?? defaultFont
    }
    
    private func hasAttachment(in glyphRange: NSRange) -> (hasAttachment: Bool, maxAttachmentHeight: CGFloat) {
        guard let textStorage = self.textStorage else {
            return (false, 0)
        }
        
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        if safeCharRange.length == 0 {
            return (false, 0)
        }
        
        var maxHeight: CGFloat = 0
        var hasAttachment = false
        
        textStorage.enumerateAttribute(.attachment, in: safeCharRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                hasAttachment = true
                let attachmentBounds = attachment.bounds
                maxHeight = max(maxHeight, attachmentBounds.height)
            }
        }
        
        return (hasAttachment, maxHeight)
    }

    public func lineHeight(for font: NSFont) -> CGFloat {
        let fontLineHeight = self.defaultLineHeight(for: font)
        let lineHeight = fontLineHeight * lineHeightMultiple
        return lineHeight
    }

    private var inlineCodeBlockRanges: [NSRange] {
        guard (firstTextView as? EditTextView)?.note?.isMarkdown() == true else { return [] }
        return markdownPresentation.styles.compactMap { styled in
            if case .codeBlock = styled.style { return styled.range }
            return nil
        }
    }

    // MARK: - Drawing
    
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawCodeBlockBackground(forGlyphRange: glyphsToShow, at: origin)
        drawInlineCodeBackground(forGlyphRange: glyphsToShow, at: origin)

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
    
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let storageLength = self.textStorage?.length ?? 0
        let storageFullRange = NSRange(location: 0, length: storageLength)
        let safeCharRange = charRange.clamped(to: storageFullRange)
        if color != MarkdownEditorStyle.surface || !isInMarkdownCode(characterIndex: safeCharRange.location) {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }
    
    private func isInMarkdownCode(characterIndex: Int) -> Bool {
        guard (firstTextView as? EditTextView)?.note?.isMarkdown() == true else { return false }
        return markdownPresentation.styles.contains { styled in
            switch styled.style {
            case .code, .codeBlock: return NSLocationInRange(characterIndex, styled.range)
            default: return false
            }
        }
    }

    private func displayedRange(_ range: NSRange) -> NSRange {
        guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
        let safe = range.clamped(to: NSRange(location: 0, length: storage.length))
        var start = safe.location, end = NSMaxRange(safe)
        let source = storage.string as NSString
        while start < end && hiddenMarkdownCharacters.contains(start) { start += 1 }
        while end > start && (hiddenMarkdownCharacters.contains(end - 1) || source.character(at: end - 1) == 10 || source.character(at: end - 1) == 13) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func drawCodeBlockBackground(forGlyphRange visibleGlyphs: NSRange, at origin: CGPoint) {
        guard let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for block in inlineCodeBlockRanges where NSIntersectionRange(block, visible).length > 0 {
            let range = displayedRange(block)
            guard range.length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let textRect = boundingRect(forGlyphRange: glyphs, in: container)
            let rect = NSRect(x: container.lineFragmentPadding + origin.x, y: textRect.minY + origin.y - 7,
                              width: max(1, container.size.width - container.lineFragmentPadding * 2), height: textRect.height + 14)
            let panel = NSBezierPath(roundedRect: rect, xRadius: MarkdownEditorStyle.cornerRadius, yRadius: MarkdownEditorStyle.cornerRadius)
            MarkdownEditorStyle.surface.setFill()
            panel.fill()
        }
    }

    private func drawInlineCodeBackground(forGlyphRange visibleGlyphs: NSRange, at origin: CGPoint) {
        guard (firstTextView as? EditTextView)?.note?.isMarkdown() == true, let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for styled in markdownPresentation.styles {
            guard case .code = styled.style, NSIntersectionRange(styled.range, visible).length > 0 else { continue }
            let range = displayedRange(styled.range)
            guard range.length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let panel = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: 1).offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4)
                MarkdownEditorStyle.surface.setFill()
                panel.fill()
            }
        }
    }

    public func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange) -> Bool {

        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if let table = inlineTables.first(where: { NSLocationInRange($0.range.location, characterRange) }) {
            let size = inlineTableLayout(table, in: textContainer).blockSize
            lineFragmentRect.pointee.size.height = size.height
            lineFragmentUsedRect.pointee.size = size
            baselineOffset.pointee = 0
            return true
        }

        // Get the font for the current range of glyphs
        let currentFont = font(for: glyphRange)
        let fontLineHeight = layoutManager.defaultLineHeight(for: currentFont)
        let standardLineHeight = fontLineHeight * lineHeightMultiple
        
        let attachmentInfo = hasAttachment(in: glyphRange)
        let decorationHeight = markdownDecorations.filter { NSLocationInRange($0.key, characterRange) }
            .map { markdownDecorationSize($0.value, in: textContainer, at: $0.key).height }.max() ?? 0
        
        var finalLineHeight: CGFloat
        var baselineNudge: CGFloat
        
        if attachmentInfo.hasAttachment && attachmentInfo.maxAttachmentHeight > 0 {
            if attachmentInfo.maxAttachmentHeight > standardLineHeight {
                finalLineHeight = attachmentInfo.maxAttachmentHeight
                baselineNudge = 0
            } else {
                finalLineHeight = standardLineHeight
                let extraSpace = finalLineHeight - fontLineHeight
                baselineNudge = extraSpace * 0.5
            }
        } else {
            finalLineHeight = standardLineHeight
            let extraSpace = finalLineHeight - fontLineHeight
            baselineNudge = extraSpace * 0.5
        }

        finalLineHeight = max(finalLineHeight, decorationHeight)
        var rect = lineFragmentRect.pointee
        rect.size.height = ceil(finalLineHeight)

        var usedRect = lineFragmentUsedRect.pointee
        usedRect.size.height = max(rect.size.height, ceil(usedRect.size.height))

        lineFragmentRect.pointee = rect
        lineFragmentUsedRect.pointee = usedRect
        baselineOffset.pointee = baselineOffset.pointee + baselineNudge

        return true
    }
    
    func refreshLayoutSoftly() {
        invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                                actualCharacterRange: nil)
                
        textContainers.forEach { container in
            container.textView?.needsDisplay = true
        }
    }
    
    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect,
        usedRect: NSRect,
        textContainer container: NSTextContainer) {
        
        var fontToUse: NSFont

        if let textStorage = self.textStorage, textStorage.length > 0 {
            let lastIndex = textStorage.length - 1
            let attributes = textStorage.attributes(at: lastIndex, effectiveRange: nil)
            let nsString = textStorage.string as NSString
            let lastCharIsNewline = nsString.character(at: lastIndex) == 0x0A // '\n'

            if !lastCharIsNewline, let font = attributes[.font] as? NSFont {
                fontToUse = font
            } else {
                fontToUse = UserDefaultsManagement.noteFont
            }
        } else {
            fontToUse = UserDefaultsManagement.noteFont
        }
        
        let lineHeight = self.lineHeight(for: fontToUse)
        
        var fragmentRect = fragmentRect
        fragmentRect.size.height = ceil(lineHeight)
        var usedRect = usedRect
        usedRect.size.height = ceil(lineHeight)

        super.setExtraLineFragmentRect(fragmentRect,
            usedRect: usedRect,
            textContainer: container)
    }
}
