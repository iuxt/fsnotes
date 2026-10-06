import Cocoa

final class Note {
    var markdown = true
    func isMarkdown() -> Bool { markdown }
}

final class EditTextView: NSTextView {
    var note: Note? = Note()
    var suppressCompletion = false
    private let edits = UndoManager()
    override var undoManager: UndoManager? { edits }
    override func menu(for event: NSEvent) -> NSMenu? { makeMarkdownContextMenu() }
    @objc func boldMenu(_ sender: Any) {}
    @objc func italicMenu(_ sender: Any) {}
    @objc func strikeMenu(_ sender: Any) {}
    @objc func linkMenu(_ sender: Any) {}
    @objc func insertQuote(_ sender: NSMenuItem) {}
    @objc func insertList(_ sender: NSMenuItem) {}
    @objc func insertOrderedList(_ sender: NSMenuItem) {}
    @objc func todo(_ sender: Any) {}
}
