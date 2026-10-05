import AppKit
import UniformTypeIdentifiers

// Only scaffolding for parser, settings and UI dependencies not used by these
// tests. Attachment serialization and byte snapshots use production methods.
public final class Note {
    var imageUrl = [URL]()
    var attachments = [URL]()
    func getAttachmentFileUrl(name: String) -> URL? { URL(fileURLWithPath: name) }
}
enum FSParser {
    static let imageInlineRegex = Regex()
    struct Regex {
        func matches(_ input: String, range: NSRange, completion: (NSTextCheckingResult?) -> Void) {}
    }
}
enum AttributedBox {
    static func getUnChecked() -> NSAttributedString? { nil }
    static func getChecked() -> NSAttributedString? { nil }
}
final class UserDataService {
    static let instance = UserDataService()
    var isDark = false
}
enum UserDefaultsManagement { static let noteFont = NSFont.systemFont(ofSize: 14) }
extension URL {
    var isImage: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true }
    var isVideo: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .movie) == true }
    func isRemote() -> Bool { scheme == "http" || scheme == "https" }
}
extension Data {
    enum FileType: String { case png }
    func getFileType() -> FileType { .png }
}
