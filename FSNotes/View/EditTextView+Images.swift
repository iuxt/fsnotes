import Cocoa

extension EditTextView {
    /// Keep the document caret outside hidden image source and expand partial selections.
    func imageSelectionRanges(_ ranges: [NSValue]) -> [NSValue] {
        guard note?.isMarkdown() == true, !isPreviewEnabled(), let manager = layoutManager as? LayoutManager else { return ranges }
        let plan = manager.markdownSource == string ? manager.markdownPresentation : MarkdownPresentation.parse(string)
        let images = plan.elements.filter { if case .image = $0.decoration { return true }; return false }
        let previous = selectedRange().location
        return ranges.map { value in
            var range = value.rangeValue
            for image in images {
                let start = image.range.location, end = NSMaxRange(image.range)
                if range.length == 0, range.location > start, range.location < end {
                    range.location = range.location >= previous ? end : start
                } else if range.length > 0, NSIntersectionRange(range, image.range).length > 0 {
                    range = NSUnionRange(range, image.range)
                }
            }
            return NSValue(range: range)
        }
    }

    func inlineImage(at point: NSPoint) -> MarkdownPresentation.Element? {
        guard note?.isMarkdown() == true, !isPreviewEnabled(),
              let manager = layoutManager as? LayoutManager, let container = textContainer else { return nil }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return manager.markdownPresentation.elements.first {
            if case .image = $0.decoration { return manager.inlineImageRect($0, in: container).contains(location) }
            return false
        }
    }

    func handleImageClick(_ event: NSEvent) -> Bool {
        guard let image = inlineImage(at: convert(event.locationInWindow, from: nil)) else { return false }
        window?.makeFirstResponder(self)
        let range = event.modifierFlags.contains(.shift) ? NSUnionRange(selectedRange(), image.range) : image.range
        setSelectedRange(range)
        saveSelectedRange()
        return true
    }

    func handleImageKeyDown(_ event: NSEvent) -> Bool {
        guard isEditable, note?.isMarkdown() == true, !isPreviewEnabled(),
              !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              [51, 117].contains(event.keyCode), let manager = layoutManager as? LayoutManager else { return false }
        let range = selectedRange()
        guard range.length == 0, let image = manager.markdownPresentation.elements.first(where: {
            guard case .image = $0.decoration else { return false }
            return event.keyCode == 51 ? NSMaxRange($0.range) == range.location : $0.range.location == range.location
        }) else { return false }
        breakUndoCoalescing()
        insertText("", replacementRange: image.range)
        breakUndoCoalescing()
        return true
    }

    func makeImageContextMenu(for event: NSEvent) -> NSMenu? {
        guard let image = inlineImage(at: convert(event.locationInWindow, from: nil)) else { return nil }
        window?.makeFirstResponder(self)
        setSelectedRange(image.range)
        saveSelectedRange()
        let menu = NSMenu()
        for (title, action) in [("Open Image", #selector(openSelectedImage(_:))),
                                ("Edit Image…", #selector(editSelectedImage(_:))),
                                ("Delete Image", #selector(deleteSelectedImage(_:)))] {
            let item = NSMenuItem(title: NSLocalizedString(title, comment: "Image context menu"), action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action == #selector(openSelectedImage(_:)) || isEditable
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    private var selectedInlineImage: MarkdownPresentation.Element? {
        (layoutManager as? LayoutManager)?.markdownPresentation.elements.first {
            if case .image = $0.decoration { return $0.range == selectedRange() }
            return false
        }
    }

    private func openInlineImage(_ image: MarkdownPresentation.Element) {
        guard case .image(let destination, _) = image.decoration,
              let url = note?.getAttachmentFileUrl(name: destination.hasPrefix("http") ? destination : (destination.removingPercentEncoding ?? destination)) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openSelectedImage(_ sender: Any?) {
        if let image = selectedInlineImage { openInlineImage(image) }
    }

    @objc func deleteSelectedImage(_ sender: Any?) {
        guard isEditable, let image = selectedInlineImage else { return }
        breakUndoCoalescing()
        insertText("", replacementRange: image.range)
        breakUndoCoalescing()
    }

    @objc func editSelectedImage(_ sender: Any?) {
        guard isEditable, let image = selectedInlineImage,
              let manager = layoutManager as? LayoutManager, let container = textContainer else { return }
        imagePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = InlineImagePropertiesController(owner: self, image: image, popover: popover)
        imagePopover = popover
        let rect = manager.inlineImageRect(image, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxX)
    }
}

/// Editing image properties never replaces the preview with source or changes document focus/layout.
final class InlineImagePropertiesController: NSViewController {
    private weak var owner: EditTextView?
    private weak var note: Note?
    private weak var popover: NSPopover?
    private let image: MarkdownPresentation.Element
    private let original: String
    private let originalAltText: String
    let altField = NSTextField()
    let pathField = NSTextField()

    init(owner: EditTextView, image: MarkdownPresentation.Element, popover: NSPopover) {
        self.owner = owner
        self.note = owner.note
        self.popover = popover
        self.image = image
        self.original = (owner.string as NSString).substring(with: image.range)
        if case .image(_, let title) = image.decoration { originalAltText = title } else { originalAltText = "" }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 198))
        let heading = NSTextField(labelWithString: NSLocalizedString("Edit Image…", comment: "Image properties"))
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 16, y: 164, width: 328, height: 20)
        view.addSubview(heading)
        for (label, field, y) in [("Description", altField, CGFloat(112)), ("Image path or URL", pathField, CGFloat(58))] {
            let caption = NSTextField(labelWithString: NSLocalizedString(label, comment: "Image properties"))
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.frame = NSRect(x: 16, y: y + 27, width: 328, height: 16)
            field.frame = NSRect(x: 16, y: y, width: 328, height: 24)
            field.setAccessibilityLabel(caption.stringValue)
            view.addSubview(caption)
            view.addSubview(field)
        }
        if case .image(let path, let title) = image.decoration {
            altField.stringValue = title
            pathField.stringValue = path
        }
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 180, y: 12, width: 80, height: 32)
        let save = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(save(_:)))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 264, y: 12, width: 80, height: 32)
        view.addSubview(cancel)
        view.addSubview(save)
        altField.nextKeyView = pathField
        pathField.nextKeyView = save
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(altField)
    }

    @objc func cancel(_ sender: Any?) { popover?.close() }

    @objc func save(_ sender: Any?) {
        guard let owner = owner, owner.note === note, owner.isEditable,
              NSMaxRange(image.range) <= (owner.string as NSString).length,
              (owner.string as NSString).substring(with: image.range) == original else {
            popover?.close()
            return
        }
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { view.window?.makeFirstResponder(pathField); return }
        let updated: String
        if case .image(let destination, _) = image.decoration,
           path == destination, altField.stringValue == originalAltText {
            updated = original
        } else {
            updated = MarkdownPresentation.imageSource(altText: altField.stringValue, destination: path,
                                                       original: original, originalAltText: originalAltText)
        }
        let clip = owner.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        let scrollWasLocked = owner.isScrollPositionSaverLocked
        owner.isScrollPositionSaverLocked = true
        defer { owner.isScrollPositionSaverLocked = scrollWasLocked }
        popover?.close()
        owner.window?.makeFirstResponder(owner)
        if updated != original {
            owner.breakUndoCoalescing()
            owner.insertText(updated, replacementRange: image.range)
            owner.breakUndoCoalescing()
        }
        owner.setSelectedRange(NSRange(location: image.range.location, length: updated.utf16.count))
        owner.saveSelectedRange()
        if let clip = clip, let origin = origin {
            clip.scroll(to: origin)
            owner.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
}
