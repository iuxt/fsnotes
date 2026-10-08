import Foundation

enum MarkdownCheckbox {
    private static let markers = try! NSRegularExpression(pattern: #"- \[[ xX]\] "#)

    @discardableResult static func toggle(in content: NSMutableAttributedString, at position: Int) -> Bool {
        guard position >= 0 else { return false }
        let matches = markers.matches(in: content.string, range: NSRange(location: 0, length: content.length))
        guard matches.indices.contains(position) else { return false }
        let range = matches[position].range
        let checked = content.mutableString.substring(with: range).lowercased().contains("[x]")
        content.replaceCharacters(in: range, with: checked ? "- [ ] " : "- [x] ")
        return true
    }
}
