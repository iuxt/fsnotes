import Cocoa

/// Shared typography, surfaces and motion for the native Markdown editor.
enum MarkdownEditorStyle {
    static let cornerRadius: CGFloat = 9
    static let blockInset: CGFloat = 14
    static let codeCopyButtonSize: CGFloat = 24
    static let tablePadding: CGFloat = 12
    static let headingScales: [CGFloat] = [1.75, 1.45, 1.25, 1.12, 1.06, 1]
    static var hairline: NSColor { .labelColor.withAlphaComponent(0.09) }
    static var secondaryLine: NSColor { .labelColor.withAlphaComponent(0.055) }
    static var surface: NSColor { .labelColor.withAlphaComponent(0.035) }
    static var headerSurface: NSColor { .labelColor.withAlphaComponent(0.045) }
    static var selectionSurface: NSColor { .controlAccentColor.withAlphaComponent(0.075) }
    static var focusSurface: NSColor { .controlAccentColor.withAlphaComponent(0.035) }
    static var focusBorder: NSColor { .controlAccentColor.withAlphaComponent(0.65) }
    static var transitionDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
    }

    static func headingFont(level: Int, base: NSFont) -> NSFont {
        let size = base.pointSize * headingScales[min(5, max(0, level - 1))]
        return NSFontManager.shared.convert(NSFontManager.shared.convert(base, toSize: size), toHaveTrait: .boldFontMask)
    }

    static func animate(_ changes: (NSAnimationContext) -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes(context)
        }
    }
}

extension MarkdownPresentation {
    /// Block spacing is part of text layout, so the caret and selection share it.
    func applyParagraphStyles(to content: NSMutableAttributedString, in affected: NSRange, font: NSFont) {
        let source = content.string as NSString
        let fullRange = NSRange(location: 0, length: content.length)
        func update(_ range: NSRange, _ configure: (NSMutableParagraphStyle) -> Void) {
            let intersection = NSIntersectionRange(range, affected)
            guard intersection.length > 0 else { return }
            let safe = NSIntersectionRange(source.paragraphRange(for: intersection), fullRange)
            guard safe.length > 0 else { return }
            content.enumerateAttribute(.paragraphStyle, in: safe) { value, span, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                configure(style)
                content.addAttribute(.paragraphStyle, value: style, range: span)
            }
        }
        for styled in styles {
            guard NSIntersectionRange(styled.range, affected).length > 0 else { continue }
            switch styled.style {
            case .heading(let level):
                update(styled.range) { style in
                    style.paragraphSpacingBefore = styled.range.location == 0 ? 0 : font.pointSize * (level <= 2 ? 0.6 : 0.4)
                    style.paragraphSpacing = font.pointSize * 0.25
                }
            case .codeBlock:
                update(styled.range) { style in
                    style.firstLineHeadIndent = MarkdownEditorStyle.blockInset
                    style.headIndent = MarkdownEditorStyle.blockInset
                    style.tailIndent = -MarkdownEditorStyle.blockInset
                    style.paragraphSpacing = 0
                    style.paragraphSpacingBefore = 0
                }
                let first = source.paragraphRange(for: NSRange(location: styled.range.location, length: 0))
                update(first) {
                    $0.paragraphSpacingBefore = font.pointSize * 0.7
                    $0.tailIndent = -(MarkdownEditorStyle.blockInset + MarkdownEditorStyle.codeCopyButtonSize + 8)
                }
                let last = source.paragraphRange(for: NSRange(location: max(styled.range.location, NSMaxRange(styled.range) - 1), length: 0))
                update(last) { $0.paragraphSpacing = font.pointSize * 0.7 }
            default: break
            }
        }
        for element in elements {
            if case .quote = element.decoration {
                update(element.range) { style in
                    style.firstLineHeadIndent = 4
                    style.headIndent = 24
                    style.tailIndent = -MarkdownEditorStyle.blockInset
                    style.paragraphSpacing = 3
                }
            }
        }
    }
}
