import Cocoa

enum SidebarItemType { case All, Untagged, Trash }

final class Project: Equatable {
    var visible = true
    func isVisibleInCommon() -> Bool { visible }
    static func == (lhs: Project, rhs: Project) -> Bool { lhs === rhs }
}

final class Note {
    var name: String
    var fileName: String
    var title: String
    var content: NSMutableAttributedString
    var project: Project
    var tags: [String]
    var trashed = false

    init(_ name: String, content: String = "", project: Project, tags: [String] = []) {
        self.name = name
        self.fileName = name
        self.title = name
        self.content = NSMutableAttributedString(string: content)
        self.project = project
        self.tags = tags
    }

    func isTrash() -> Bool { trashed }
}

enum UserDefaultsManagement {
    static var inlineTags = true
    static var recentSearches: [String]?
    static var textMatchAutoSelection = false
}

final class UserDataService {
    static let instance = UserDataService()
    var searchTrigger = false
}

extension String {
    func trim() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func startsWith(string: String) -> Bool { hasPrefix(string) }
}

extension Date {
    func toMillis() -> Int64 { Int64(timeIntervalSince1970 * 1000) }
}

final class TestNotesTable {
    var notes: [Note] = []
    var selected: Note?
    func getSelectedNote() -> Note? { selected }
    func getNoteList() -> [Note] { notes }
    func setSelected(note: Note) { selected = note }
    func selectCurrent() {}
}

final class TestMarkdownView { var webView: NSView? }
final class TestEditor: NSView {
    var markdownView: TestMarkdownView?
    func clear() {}
    func scrollToCursor() {}
}

final class TestEditorController {
    func isPreviewEnabled() -> Bool { false }
    func disablePreviewEditorAndNote() {}
}

// Deliberately has no note creation API: search commands only navigate results.
final class ViewController {
    let notesTableView = TestNotesTable()
    let sidebarOutlineView = NSOutlineView()
    let editor = TestEditor()
    var vcEditor: TestEditorController?
    var focusCount = 0
    func focusTable() {}
    func focusEditArea() { focusCount += 1 }
    func refillEditArea() {}
    func buildSearchQuery() {}
    func updateTable(completion: @escaping () -> Void) { completion() }
}
