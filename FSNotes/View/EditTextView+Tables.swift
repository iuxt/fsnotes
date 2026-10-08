import Cocoa

extension EditTextView {
    func scheduleTableEditorsUpdate() {
        guard !isTableEditorsUpdateScheduled else { return }
        isTableEditorsUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTableEditorsUpdateScheduled = false
            self.updateTableEditors()
        }
    }

    func updateTableEditors() {
        updateCodeCopyButtons()
        guard let manager = layoutManager as? LayoutManager, let container = textContainer else { return }
        let starts = Set(manager.inlineTables.map { $0.range.location })
        for (start, view) in tableEditorViews where !starts.contains(start) || view.note !== note {
            view.finishEditing(returnToEditor: false)
            view.removeFromSuperview()
            tableEditorViews.removeValue(forKey: start)
        }
        for table in manager.inlineTables {
            let layout = manager.inlineTableLayout(table, in: container)
            let rect = manager.inlineTableRect(table, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            let view: InlineTableEditorView
            if let existing = tableEditorViews[table.range.location] {
                view = existing
            } else {
                view = InlineTableEditorView(owner: self, table: table, layout: layout)
                tableEditorViews[table.range.location] = view
                addSubview(view)
            }
            view.frame = NSRect(x: rect.minX - InlineTableLayout.side, y: rect.minY - InlineTableLayout.top,
                                width: layout.blockSize.width, height: layout.blockSize.height)
            view.update(table: table, layout: layout)
            view.isHidden = isPreviewEnabled()
        }
    }

    func removeTableEditors() {
        removeCodeCopyButtons()
        for view in tableEditorViews.values {
            view.finishEditing(returnToEditor: false)
            view.removeFromSuperview()
        }
        tableEditorViews.removeAll()
    }

    var hasTableSelection: Bool {
        tableEditorViews.values.contains {
            !$0.isHidden && ($0.selectedRow != nil || $0.selectedColumn != nil) &&
                NSLocationInRange(selectedRange().location, $0.table.range)
        }
    }

    func clearTableSelections() {
        guard !isApplyingTableChange else { return }
        for view in tableEditorViews.values where view.selectedRow != nil || view.selectedColumn != nil {
            view.clearSelection()
        }
    }

    func enterTableForSelection() {
        guard !isApplyingTableChange, selectedRange().length == 0,
              window?.firstResponder === self, let manager = layoutManager as? LayoutManager else { return }
        let index = selectedRange().location
        guard let table = manager.inlineTables.first(where: { NSLocationInRange(index, $0.range) }) else { return }
        scheduleTableEditorsUpdate()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window?.firstResponder === self,
                  self.selectedRange().location == index, let view = self.tableEditorViews[table.range.location],
                  view.selectedRow == nil, view.selectedColumn == nil else { return }
            let row = table.rows.firstIndex { NSLocationInRange(index, $0.range) } ?? 0
            let column = table.rows[row].cells.firstIndex { index <= NSMaxRange($0.range) } ?? 0
            view.beginEditing(row: row, column: column)
        }
    }

    var tableUndoManager: UndoManager? { editorViewController?.editorUndoManager ?? undoManager }

    @discardableResult
    func changeTable(_ view: InlineTableEditorView, action: String? = nil,
                     mutation: (inout MarkdownTableDocument) -> Void) -> Bool {
        guard isEditable, view.note === note, let manager = layoutManager as? LayoutManager,
              let table = manager.inlineTables.first(where: { $0.range.location == view.table.range.location }) else { return false }
        var document = MarkdownTableDocument(table)
        mutation(&document)
        let markdown = document.markdown
        guard (string as NSString).substring(with: table.range) != markdown else { return true }
        if action != nil { breakUndoCoalescing() }
        let clip = enclosingScrollView?.contentView
        let scrollOrigin = clip?.bounds.origin
        let scrollWasLocked = isScrollPositionSaverLocked
        isScrollPositionSaverLocked = true
        defer { isScrollPositionSaverLocked = scrollWasLocked }
        isApplyingTableChange = true
        suppressCompletion = true
        insertText(markdown, replacementRange: table.range)
        isApplyingTableChange = false
        if let action = action {
            tableUndoManager?.setActionName(action)
            breakUndoCoalescing()
        }
        refreshInlineTables()
        updateTableEditors()
        if let clip = clip, let origin = scrollOrigin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return true
    }

    func leaveTable(_ view: InlineTableEditorView) {
        guard isEditable, view.note === note else { return }
        let end = min(NSMaxRange(view.table.range), (string as NSString).length)
        let source = string as NSString
        // An empty paragraph separates body input (including pipes) from table rows.
        let isNewline: (Int) -> Bool = { $0 < source.length && [10, 13].contains(source.character(at: $0)) }
        let paragraphStart: Int
        let insertion: Int
        let separator: String
        if isNewline(end) {
            let newlineLength = source.character(at: end) == 13 && end + 1 < source.length && source.character(at: end + 1) == 10 ? 2 : 1
            paragraphStart = end + newlineLength
            insertion = paragraphStart
            separator = paragraphStart < source.length && !isNewline(paragraphStart) ? "\n" : ""
        } else {
            let boundary = (view.table.endsWithNewline ? "" : "\n") + "\n"
            paragraphStart = end + boundary.utf16.count
            insertion = end
            separator = boundary + (end < source.length ? "\n" : "")
        }
        isApplyingTableChange = true
        defer { isApplyingTableChange = false }
        view.finishEditing(returnToEditor: false)
        isApplyingTableChange = true
        view.clearSelection()
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        if !separator.isEmpty {
            suppressCompletion = true
            insertText(separator, replacementRange: NSRange(location: insertion, length: 0))
            refreshInlineTables()
            updateTableEditors()
        }
        setSelectedRange(NSRange(location: paragraphStart, length: 0))
        saveSelectedRange()
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }

    func handleClickBelowTable(_ event: NSEvent) -> Bool {
        guard isEditable else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let view = tableEditorViews.values.first(where: {
            !$0.isHidden && NSMaxRange($0.table.range) == (string as NSString).length && point.y >= $0.frame.maxY
        }) else { return false }
        leaveTable(view)
        return true
    }
}

extension EditTextView {
    /// Keyboard input that reaches the document caret enters the native cell editor.
    func handleTableKeyDown(_ event: NSEvent) -> Bool {
        guard isEditable, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              selectedRange().length == 0, let manager = layoutManager as? LayoutManager else { return false }
        let index = selectedRange().location
        guard let table = manager.inlineTables.first(where: {
            NSLocationInRange(index, $0.range) || (!$0.endsWithNewline && index == NSMaxRange($0.range))
        }) else { return false }
        updateTableEditors()
        guard let view = tableEditorViews[table.range.location] else { return false }
        if index == NSMaxRange(table.range) {
            guard ![51, 117, 123, 124, 126, 48].contains(event.keyCode) else { return false }
            leaveTable(view)
            return [36, 76, 125, 53].contains(event.keyCode)
        }
        if let row = view.selectedRow {
            switch event.keyCode {
            case 51, 117:
                if row > 0 {
                    _ = changeTable(view, action: NSLocalizedString("Delete table row", comment: "Undo action")) { $0.removeRow(at: row) }
                }
                return true
            case 126: view.selectRow(max(0, row - 1)); return true
            case 125: view.selectRow(min(table.rows.count - 1, row + 1)); return true
            case 53: leaveTable(view); return true
            default: view.beginEditing(row: row, column: 0)
            }
        } else if let column = view.selectedColumn {
            switch event.keyCode {
            case 51, 117:
                _ = changeTable(view, action: NSLocalizedString("Delete table column", comment: "Undo action")) { $0.removeColumn(at: column) }
                view.selectColumn(min(column, view.table.alignments.count - 1))
                return true
            case 123: view.selectColumn(max(0, column - 1)); return true
            case 124: view.selectColumn(min(table.alignments.count - 1, column + 1)); return true
            case 53: leaveTable(view); return true
            default: view.beginEditing(row: 0, column: column)
            }
        } else {
            let row = table.rows.firstIndex { NSLocationInRange(index, $0.range) } ?? table.rows.count - 1
            let column = table.rows[row].cells.firstIndex { index <= NSMaxRange($0.range) } ?? 0
            view.beginEditing(row: row, column: column)
        }
        view.cellEditor?.keyDown(with: event)
        return true
    }
}
