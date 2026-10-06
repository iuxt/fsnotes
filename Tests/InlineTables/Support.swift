import Cocoa
final class Note {
    var markdown = true
    var codeBlockRangesCache: [NSRange] = []
    func isMarkdown() -> Bool { markdown }
    func getAttachmentFileUrl(name: String) -> URL? { URL(fileURLWithPath: name) }
}
final class TextStorageProcessor { weak var editor: EditTextView? }
final class EditorViewController { var editorUndoManager: UndoManager? }
final class EditTextView: NSTextView {
    var note: Note? = Note()
    var processor: TextStorageProcessor!
    let editorViewController: EditorViewController? = EditorViewController()
    var tableEditorViews: [Int: InlineTableEditorView] = [:]
    var isTableEditorsUpdateScheduled = false
    var isApplyingTableChange = false
    var suppressCompletion = false
    var isScrollPositionSaverLocked = false
    var savedRange: NSRange?
    private let noteUndo = UndoManager()
    override var undoManager: UndoManager? { noteUndo }
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        for view in tableEditorViews.values.sorted(by: { $0.table.range.location < $1.table.range.location }) {
            if !children.contains(where: { ($0 as? NSView) === view }) { children.append(view) }
        }
        return children
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        clearTableSelections()
        refreshInlineTables()
        enterTableForSelection()
    }
    func refreshInlineTables() {
        (layoutManager as? LayoutManager)?.refreshInlineMarkdown()
        (layoutManager as? LayoutManager)?.refreshInlineTables()
        scheduleTableEditorsUpdate()
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if !hasTableSelection { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
    }
    override func keyDown(with event: NSEvent) {
        if !handleTableKeyDown(event) { super.keyDown(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let view = tableEditorViews.values.first(where: { $0.frame.contains(point) }) {
            view.updateHover(at: view.convert(point, from: self))
        } else { super.mouseMoved(with: event) }
    }
    func saveSelectedRange() { savedRange = selectedRange() }
    func isPreviewEnabled() -> Bool { false }
}
enum UserDefaultsManagement {
    static let noteFont = NSFont.systemFont(ofSize: 14)
    static let lineHeightMultiple = 1.2
}
enum NotesTextProcessor {
    struct Style { let backgroundColor = NSColor.gray }
    struct Options { let style = Style() }
    struct Highlighter { let options = Options() }
    static func getHighlighter() -> Highlighter { Highlighter() }
}
