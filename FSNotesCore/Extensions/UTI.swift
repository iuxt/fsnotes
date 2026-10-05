import Foundation
import UniformTypeIdentifiers

public extension String {

    func tag(withClass tagClass: UTTagClass) -> String? {
        return UTType(self)?.tags[tagClass]?.first
    }

    func uti(withClass tagClass: UTTagClass) -> String? {
        return UTType(tag: self, tagClass: tagClass, conformingTo: nil)?.identifier
    }

    var utiMimeType: String? {
        return tag(withClass: .mimeType)
    }

    var mimeTypeUTI: String? {
        return uti(withClass: .mimeType)
    }

    var fileExtensionUTI: String? {
        return uti(withClass: .filenameExtension)
    }
}
