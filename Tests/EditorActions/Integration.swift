import Cocoa

@main struct EditorActionsTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    static func drainMain() {
        var finished = false
        DispatchQueue.main.async { finished = true }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.isEditable = true; editor.allowsUndo = true
        let source = "😀\n- [x] done\n- [ ] pending\n\n```md\n- [x] fenced\n```\n\n    - [x] code\n\n> - [X] quoted\n"
        editor.string = source
        editor.undoManager?.removeAllActions()
        editor.clearCompletedTodos()
        expect(!editor.string.contains("done") && !editor.string.contains("quoted"), "completed raw Markdown tasks are removed")
        expect(editor.string.contains("pending") && editor.string.contains("- [x] fenced") && editor.string.contains("- [x] code"), "pending tasks and literal code are retained")
        editor.undoManager?.undo()
        expect(editor.string == source, "clearing completed tasks is one undoable action")

        let body = String(repeating: "😀", count: 20) + "\n- [ ] first\n- [x] second\n"
        let content = NSMutableAttributedString(string: body)
        expect(MarkdownCheckbox.toggle(in: content, at: 1), "preview can reach a task after non-BMP text")
        expect(content.string == body.replacingOccurrences(of: "- [x] second", with: "- [ ] second"), "preview changes only the selected checkbox")
        expect(MarkdownCheckbox.toggle(in: content, at: 1) && content.string == body, "preview toggles back without corrupting Unicode")
        expect(!MarkdownCheckbox.toggle(in: content, at: -1) && !MarkdownCheckbox.toggle(in: content, at: 99) && content.string == body, "invalid preview positions do not change content")

        let a = Note(), b = Note()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(string: "https://example.invalid")! as NSURL])
        func begin(_ text: String, range: NSRange) {
            editor.note = a; editor.string = text; editor.pending = []
            expect(editor.handleURLs(pasteboard, note: a, replacementRange: range), "URL drop begins")
        }
        func complete() {
            editor.pending[0](Data("response".utf8), nil)
            drainMain()
        }
        begin("A", range: NSRange(location: 0, length: 0))
        editor.note = b; editor.string = "B"
        complete()
        expect(editor.string == "B", "delayed URL completion cannot edit a different note")
        begin("original", range: NSRange(location: 8, length: 0))
        editor.string = "short"
        complete()
        expect(editor.string == "short", "editing during a request invalidates its old insertion range")
        begin("A", range: NSRange(location: 99, length: 0))
        complete()
        expect(editor.string == "A", "invalid drop range is ignored without a crash")
        begin("A", range: NSRange(location: 0, length: 0))
        editor.isEditable = false
        complete()
        expect(editor.string == "A", "termination cannot receive a late URL insertion after editing is disabled")
        editor.isEditable = true
        begin("A", range: NSRange(location: 0, length: 0))
        complete()
        expect(editor.string == "[Loaded title](https://example.invalid)A", "unchanged document accepts the downloaded link")

        // Note references also complete asynchronously, without a network request.
        pasteboard.clearContents()
        pasteboard.setData(try NSKeyedArchiver.archivedData(withRootObject: [URL(fileURLWithPath: "/reference.md")], requiringSecureCoding: true), forType: NSPasteboard.note)
        editor.note = a; editor.string = "A"
        expect(editor.handleNoteReference(pasteboard, note: a, replacementRange: NSRange(location: 0, length: 0)), "reference drop begins")
        editor.note = b; editor.string = "B"
        drainMain()
        expect(editor.string == "B", "delayed reference cannot edit a different note")
        print("Editor actions integration: \(checks) checks passed")
    }
}
