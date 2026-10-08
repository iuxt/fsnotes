import Foundation
import UniformTypeIdentifiers

enum PreviewImages {
    private static let sourceRegex = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc\s*=\s*(["'])(.*?)\1"#,
                                                             options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// Embed local images in previews; exported pages use files inside their own i/.
    static func render(_ html: String, relativeTo directory: URL,
                       exportDirectory: URL, forWeb: Bool) -> String {
        var renderedImages: [URL: String] = [:]
        let result = NSMutableString(string: html)
        for match in sourceRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let range = match.range(at: 2)
            let source = (html as NSString).substring(with: range)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let components = URLComponents(string: source), components.scheme == nil,
                  components.host == nil, !source.hasPrefix("/"),
                  let path = components.percentEncodedPath.removingPercentEncoding, !path.isEmpty else { continue }
            let image = directory.appendingPathComponent(path).standardizedFileURL
            guard let type = UTType(filenameExtension: image.pathExtension), type.conforms(to: .image) else { continue }
            if let cached = renderedImages[image] {
                result.replaceCharacters(in: range, with: cached)
                continue
            }
            var replacement = ""
            if let data = try? Data(contentsOf: image) {
                if forWeb {
                    let assets = exportDirectory.appendingPathComponent("i", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                        let name = image.lastPathComponent
                        try data.write(to: assets.appendingPathComponent(name), options: .atomic)
                        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "\"'&?#"))
                        replacement = "i/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
                    } catch { NSLog("Preview image export: %@", error.localizedDescription) }
                } else if let mime = type.preferredMIMEType {
                    replacement = "data:\(mime);base64," + data.base64EncodedString()
                }
            }
            renderedImages[image] = replacement
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }
}
