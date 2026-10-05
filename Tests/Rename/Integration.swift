import Cocoa

final class FocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@main struct InlineRenameTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw NSError(domain: "InlineRenameTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fsnotes-rename-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MetadataStore(root: root)
        let entry = try store.register(name: "原始名称", folderID: nil, ext: "md")
        let other = try store.register(name: "另一篇文章", folderID: nil, ext: "md")
        let bodyURL = store.fileURL(entry)
        try "# 正文标题\n内容".write(to: bodyURL, atomically: true, encoding: .utf8)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let field = NameTextField(frame: NSRect(x: 10, y: 50, width: 250, height: 20))
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.stringValue = "正文标题"
        let focus = FocusView(frame: NSRect(x: 10, y: 10, width: 200, height: 20))
        window.contentView!.addSubview(field)
        window.contentView!.addSubview(focus)
        var completions = 0
        var selectedID = entry.id
        var failure: Error?
        func begin() {
            let targetID = selectedID
            field.beginRenaming(name: store.entry(id: targetID)!.name, restoringFocusTo: focus) { value in
                completions += 1
                do {
                    if let value = value { try store.renameNote(id: targetID, name: value) }
                    field.stringValue = store.entry(id: targetID)!.name
                } catch { failure = error }
            }
        }

        begin()
        try expect(field.isRenaming && field.isEditable, "list title enters editing")
        try expect(field.stringValue == entry.name, "edit the stored name even when the row displays a content heading")
        let editor = field.currentEditor() as! NSTextView
        try expect(editor.selectedRange().length == entry.name.utf16.count, "select the complete name")
        editor.string = "重命名后的文章"
        _ = field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        if let failure = failure { throw failure }
        try expect(completions == 1 && !field.isRenaming && !field.isEditable, "Enter commits once and leaves editing")
        try expect(window.firstResponder === focus, "Enter restores list focus")
        try expect(store.entry(id: entry.id)?.name == "重命名后的文章", "Enter persists the name")
        try expect(store.fileURL(store.entry(id: entry.id)!) == bodyURL, "rename retains the UUID body path")
        try expect(try String(contentsOf: bodyURL, encoding: .utf8) == "# 正文标题\n内容", "rename preserves the body")

        begin()
        let cancelEditor = field.currentEditor() as! NSTextView
        cancelEditor.string = "不应保存"
        _ = field.control(field, textView: cancelEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try expect(completions == 2 && !field.isRenaming, "Escape ends editing once")
        try expect(store.entry(id: entry.id)?.name == "重命名后的文章", "Escape discards the draft")
        try expect(field.stringValue == "重命名后的文章", "Escape restores the row title")

        begin()
        (field.currentEditor() as! NSTextView).string = "焦点移开后保存"
        selectedID = other.id
        window.makeFirstResponder(focus)
        if let failure = failure { throw failure }
        try expect(completions == 3 && !field.isRenaming, "losing focus commits once")
        try expect(store.entry(id: entry.id)?.name == "焦点移开后保存", "commit targets the original row after selection changes")
        try expect(store.entry(id: other.id)?.name == other.name, "new selection remains unchanged")

        selectedID = entry.id
        begin()
        let tabEditor = field.currentEditor() as! NSTextView
        tabEditor.string = "Tab 保存"
        _ = field.control(field, textView: tabEditor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try expect(completions == 4 && store.entry(id: entry.id)?.name == "Tab 保存", "Tab commits once")
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        try expect(completions == 4, "late end notification does not duplicate the commit")

        begin()
        (field.currentEditor() as! NSTextView).string = "回收时丢弃"
        field.cancelRenaming()
        try expect(completions == 5 && store.entry(id: entry.id)?.name == "Tab 保存", "cell reuse can cancel without saving the draft")
        let reopened = try MetadataStore(root: root)
        try expect(reopened.entry(id: entry.id)?.name == "Tab 保存", "name persists after reopening")
        print("Inline rename integration: \(checks) checks passed")
    }
}
