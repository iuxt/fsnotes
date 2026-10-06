import Cocoa

@main struct SearchTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else {
            throw NSError(domain: "SearchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let currentFolder = Project()
        let otherFolder = Project()
        let hiddenFolder = Project()
        hiddenFolder.visible = false
        let local = Note("Local", content: "needle", project: currentFolder, tags: ["work"])
        let remote = Note("Remote", content: "Needle café alpha beta", project: otherFolder, tags: ["personal"])
        let hidden = Note("Hidden needle", project: hiddenFolder)
        let trash = Note("Trashed needle", project: otherFolder)
        trash.trashed = true
        let unrelated = Note("Unrelated", project: otherFolder)
        let unnamed = Note("", content: "needle", project: otherFolder)

        let query = SearchQuery()
        query.projects = [currentFolder]
        query.setFilter("needle")
        try expect(query.isFit(note: local), "search matches the current folder")
        try expect(query.isFit(note: remote), "search matches another folder's content")
        try expect(query.isFit(note: hidden), "global search includes folders excluded from the common list")
        try expect(!query.isFit(note: trash), "global search excludes trash")
        try expect(!query.isFit(note: unrelated), "global search excludes nonmatches")
        try expect(!query.isFit(note: unnamed), "global search excludes unnamed notes")

        query.tags = ["work"]
        query.tagsModifierAnd(true)
        for inlineTags in [true, false] {
            UserDefaultsManagement.inlineTags = inlineTags
            try expect(query.isFit(note: remote), "search ignores selected tags with inlineTags=\(inlineTags)")
        }
        UserDefaultsManagement.inlineTags = true
        query.type = .Untagged
        try expect(query.isFit(note: remote), "search ignores the Untagged sidebar filter")
        query.type = .Trash
        try expect(query.isFit(note: remote) && !query.isFit(note: trash), "search remains global when Trash is selected")

        query.setFilter("cafe beta")
        try expect(query.isFit(note: remote), "global search retains multiple terms and accent-insensitive matching")
        query.setFilter("\"alpha beta\"")
        try expect(query.isFit(note: remote), "global search retains quoted phrase matching")
        query.setFilter("\"beta alpha\"")
        try expect(!query.isFit(note: remote), "quoted phrases preserve word order")

        query.type = nil
        query.setFilter("")
        try expect(query.isFit(note: local) && !query.isFit(note: remote), "clearing search restores the selected folder and tags")
        query.setFilter("needle")
        query.dropFilter()
        try expect(!query.isFit(note: remote), "dropping the filter restores the sidebar scope")
        query.projects = []
        query.tags = []
        query.type = .All
        try expect(query.isFit(note: remote) && !query.isFit(note: hidden), "browsing All retains common-list visibility")
        query.type = .Trash
        try expect(query.isFit(note: trash) && !query.isFit(note: remote), "browsing Trash still shows deleted notes")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let field = SearchTextField(frame: .zero)
        let controller = ViewController()
        field.vcDelegate = controller
        let editor = NSTextView()
        func enter(_ command: Selector = #selector(NSResponder.insertNewline(_:))) -> Bool {
            field.control(field, textView: editor, doCommandBy: command)
        }

        field.stringValue = "no results"
        try expect(enter(), "Return with no results is handled")
        try expect(controller.notesTableView.notes.isEmpty && controller.focusCount == 0, "Return with no results leaves notes and focus unchanged")
        try expect(field.stringValue == "no results", "Return with no results preserves the search text")

        field.stringValue = "needle"
        controller.notesTableView.notes = [remote, local]
        try expect(enter(), "Return with a content match is handled")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try expect(controller.notesTableView.selected === remote && controller.focusCount == 1, "Return opens the first result even without an exact title match")
        try expect(field.stringValue == "needle", "opening a content match preserves the query")

        controller.notesTableView.selected = local
        try expect(enter(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), "alternate Return command is handled")
        try expect(controller.notesTableView.selected === local, "Return opens the selected result")
        try expect(controller.notesTableView.notes.count == 2, "Return never adds a note")
        print("Passed \(checks) search checks")
    }
}
