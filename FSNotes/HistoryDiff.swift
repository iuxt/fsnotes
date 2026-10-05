import Foundation

/// Lines in a comparison from the saved version to the current editor contents.
enum HistoryDiff {
    enum Kind { case unchanged, added, removed }
    struct Line {
        let kind: Kind
        let text: String
    }

    static func lines(from saved: String, to current: String) -> [Line] {
        let old = saved.isEmpty ? [] : saved.components(separatedBy: "\n")
        let new = current.isEmpty ? [] : current.components(separatedBy: "\n")
        let changes = new.difference(from: old)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result = [Line]()
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: old[i]))
                i += 1
            } else if j < new.count, added.contains(j) {
                result.append(Line(kind: .added, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                result.append(Line(kind: .unchanged, text: old[i]))
                i += 1
                j += 1
            }
        }
        return result
    }
}
