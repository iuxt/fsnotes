import Cocoa

final class LayoutManager: NSLayoutManager {
    func presentation(for source: String) -> MarkdownPresentation { MarkdownPresentation.parse(source) }
}

final class Note {
    var title = "Reference 😀"
    func save(attributed: NSAttributedString) {}
    func getAttachmentFileUrl(name: String) -> URL? { nil }
}
final class Table { func reloadRow(note: Note) {} }
final class Delegate { let notesTableView = Table() }
final class EditTextView: NSTextView {
    var note: Note?
    var viewDelegate: Delegate?
    var pending: [(Data?, Error?) -> Void] = []
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    func fetchDataFromURL(url: URL, completion: @escaping (Data?, Error?) -> Void) { pending.append(completion) }
    func getHTMLTitle(from data: Data) -> String? { "Loaded title" }
}
final class Storage {
    static let instance = Storage()
    static func shared() -> Storage { instance }
    var reference = Note()
    func getBy(url: URL) -> Note? { reference }
}
enum ImagesProcessor { static func writeFile(data: Data, url: URL, note: Note) -> String? { nil } }
extension NSPasteboard {
    static let note = NSPasteboard.PasteboardType("fsnotes-test-note")
    static let attributed = NSPasteboard.PasteboardType("fsnotes-test-attributed")
}
extension URL { var isWebURL: Bool { scheme == "https" } }
extension NSMutableAttributedString {
    convenience init(url: URL, title: String, path: String) { self.init(string: path) }
}
