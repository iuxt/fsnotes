import Foundation

/// A merge-file result stays in memory; conflict markers never enter note files.
struct GitConflictDocument {
    enum Choice: String, Codable { case local, remote, both }
    struct Hunk {
        let local: String
        let remote: String
        let line: Int
        let remoteLine: Int
        let markerText: String
    }
    private enum Part { case text(String), conflict(Int) }
    private let parts: [Part]
    let hunks: [Hunk]

    init(text: String, markerSize: Int, localLabel: String, remoteLabel: String) throws {
        let start = String(repeating: "<", count: markerSize) + " " + localLabel
        let separator = String(repeating: "=", count: markerSize)
        let end = String(repeating: ">", count: markerSize) + " " + remoteLabel
        let lines = Self.lines(text)
        var parts = [Part](), hunks = [Hunk](), common = ""
        var cursor = 0, localLine = 1, remoteLine = 1
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .newlines) != start {
                common += lines[cursor]; localLine += 1; remoteLine += 1; cursor += 1
                continue
            }
            if !common.isEmpty { parts.append(.text(common)); common = "" }
            let first = cursor
            cursor += 1
            var local = "", remote = ""
            while cursor < lines.count && lines[cursor].trimmingCharacters(in: .newlines) != separator {
                local += lines[cursor]; cursor += 1
            }
            guard cursor < lines.count else { throw GitError.invalidSpec(spec: "Incomplete merge conflict") }
            cursor += 1
            while cursor < lines.count && lines[cursor].trimmingCharacters(in: .newlines) != end {
                remote += lines[cursor]; cursor += 1
            }
            guard cursor < lines.count else { throw GitError.invalidSpec(spec: "Incomplete merge conflict") }
            hunks.append(Hunk(local: local, remote: remote, line: localLine, remoteLine: remoteLine,
                              markerText: lines[first...cursor].joined()))
            parts.append(.conflict(hunks.count - 1))
            localLine += Self.lines(local).count
            remoteLine += Self.lines(remote).count
            cursor += 1
        }
        if !common.isEmpty { parts.append(.text(common)) }
        self.parts = parts
        self.hunks = hunks
    }

    func render(choices: [Choice?], unresolvedPlaceholder: ((Int) -> String)? = nil) -> String {
        parts.map { part in
            switch part {
            case .text(let text): return text
            case .conflict(let index):
                let hunk = hunks[index]
                switch index < choices.count ? choices[index] : nil {
                case .local: return hunk.local
                case .remote: return hunk.remote
                case .both:
                    // Preserve both versions exactly, including repeated lines.
                    return hunk.local + (hunk.local.isEmpty || hunk.remote.isEmpty || hunk.local.hasSuffix("\n") ? "" : "\n") + hunk.remote
                case nil: return unresolvedPlaceholder?(index) ?? hunk.markerText
                }
            }
        }.joined()
    }

    static func containsMarkers(_ text: String) -> Bool {
        text.range(of: "(?m)^(?:<{7,}|>{7,}|\\|{7,})(?: |$)|^={32,}\\r?$", options: .regularExpression) != nil
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        for index in 0..<max(0, lines.count - 1) { lines[index] += "\n" }
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
