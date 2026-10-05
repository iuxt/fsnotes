import Foundation
import UniformTypeIdentifiers

/// Embeds saved images so WebKit never reads assets from the current working tree.
enum HistoryPreview {
    static func imageData(path: String, repository: Repository, commit: Commit) throws -> Data {
        let blob = try repository.fileContent(commit: commit, path: path)
        let image = try GitLFS.smudge(blob, gitDirectory: repository.url)
        guard GitLFS.Pointer(pointer: image) == nil else { throw GitError.notFound(ref: path) }
        return image
    }

    static func embedImages(in html: String, notePath: String,
                            read: (String) throws -> Data) -> String {
        let regex = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc\s*=\s*(["'])(.*?)\1"#,
                                             options: [.caseInsensitive, .dotMatchesLineSeparators])
        let output = NSMutableString(string: html)
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let range = match.range(at: 2)
            let source = (html as NSString).substring(with: range)
            let decoded = source.replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            if let scheme = URL(string: decoded)?.scheme?.lowercased(),
               ["http", "https", "data"].contains(scheme) { continue }
            // Missing or invalid assets stay broken images with their alt text.
            // They must never resolve against a live file or a different revision.
            var replacement = ""
            if let path = imagePath(source: decoded, notePath: notePath),
               let type = UTType(filenameExtension: (path as NSString).pathExtension),
               type.conforms(to: .image), let mime = type.preferredMIMEType,
               let data = try? read(path) {
                replacement = "data:\(mime);base64," + data.base64EncodedString()
            }
            output.replaceCharacters(in: range, with: replacement)
        }
        return output as String
    }

    static func imagePath(source: String, notePath: String) -> String? {
        guard !source.isEmpty, !source.hasPrefix("/"),
              let encoded = source.addingPercentEncoding(withAllowedCharacters:
                .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))),
              let components = URLComponents(string: encoded), components.scheme == nil,
              components.host == nil, let path = components.percentEncodedPath.removingPercentEncoding,
              !path.isEmpty, !path.hasPrefix("/") else { return nil }
        var parts = notePath.split(separator: "/").dropLast().map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static func page(body: String, style: String, fontSize: CGFloat) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline'">
        <style>\(style)</style>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 24px 28px; font: \(fontSize)px -apple-system, sans-serif;
               line-height: 1.6; overflow-wrap: anywhere; color: CanvasText; background: Canvas; }
        img { max-width: 100% !important; height: auto; max-height: 90vh; object-fit: contain; }
        pre { white-space: pre-wrap; }
        input { pointer-events: none; }
        @media (prefers-color-scheme: dark) {
            a { color: #98e7a7; }
            pre, code, table tr, table tr:nth-child(2n) { background-color: #303030; color: inherit; }
        }
        </style></head><body>\(body)</body></html>
        """
    }
}
