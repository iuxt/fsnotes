import Foundation

@main struct GitChangesTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw NSError(domain: "GitChangesTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @discardableResult static func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = ["-c", "user.name=Tests", "-c", "user.email=tests@example.com"] + arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitChangesTests", code: 2, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ text: String, _ path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    static func change(_ path: String, _ area: GitChange.Area, in repository: Repository) throws -> GitChange {
        guard let change = try GitChanges.snapshot(in: repository).changes.first(where: { $0.path == path && $0.area == area }) else {
            throw NSError(domain: "GitChangesTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing change: \(path)"])
        }
        return change
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fsnotes-git-changes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q", "-b", "notes"], in: root)
        let repository = try RepositoryManager().openRepository(at: root.appendingPathComponent(".git"))
        try expect(try GitChanges.snapshot(in: repository).branch == "notes", "unborn branch has a name")
        try write("one\ntwo\nthree\n", "note.md", in: root)
        try write("draft\n", "folder/draft.md", in: root)
        try write("ignored.md\n", ".gitignore", in: root)
        try write("ignored", "ignored.md", in: root)
        try write("trash", ".Trash/deleted.md", in: root)
        try expect(try !GitChanges.snapshot(in: repository).changes.contains(where: { $0.path == "ignored.md" || $0.path.hasPrefix(".Trash/") }), "ignored and trashed files are excluded")
        let new = try change("note.md", .unstaged, in: repository)
        try expect(new.kind == .added, "new file is added")
        let newDiff = try GitChanges.diff(for: new, in: repository)
        try expect(newDiff.additions == 3 && newDiff.deletions == 0, "untracked file diff shows content")
        try GitChanges.stage([new], in: repository)
        let stagedNew = try change("note.md", .staged, in: repository)
        try GitChanges.unstage([stagedNew], in: repository)
        try expect(try git(["ls-files"], in: root).isEmpty, "unstaging in unborn repository removes the index entry")
        try expect(try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8) == "one\ntwo\nthree\n", "unstage preserves working contents")
        try git(["add", "note.md", ".gitignore"], in: root)
        try GitChanges.commit(message: "initial note", signature: Signature(name: "Tests", email: "tests@example.com"), in: repository)
        try expect(try GitChanges.snapshot(in: repository).lastCommit?.summary == "initial note", "snapshot explains the most recent commit")
        try expect(try git(["show", "HEAD:note.md"], in: root) == "one\ntwo\nthree", "initial commit records the staged file")
        try expect(try GitChanges.snapshot(in: repository).changes.contains(where: { $0.path == "folder/draft.md" && $0.area == .unstaged }), "commit leaves untracked files alone")

        try write("one\nstaged\nthree\n", "note.md", in: root)
        try GitChanges.stage([change("note.md", .unstaged, in: repository)], in: repository)
        try write("one\nworking\nthree\n", "note.md", in: root)
        let status = try GitChanges.snapshot(in: repository)
        try expect(status.changes.filter { $0.path == "note.md" }.count == 2, "combined index and worktree flags produce two entries")
        let staged = try change("note.md", .staged, in: repository), working = try change("note.md", .unstaged, in: repository)
        let stagedDiff = try GitChanges.diff(for: staged, in: repository), workDiff = try GitChanges.diff(for: working, in: repository)
        try expect(stagedDiff.lines.contains(where: { $0.kind == .removed && $0.text == "two" }) && stagedDiff.lines.contains(where: { $0.kind == .added && $0.text == "staged" }), "staged diff is HEAD to index")
        try expect(workDiff.lines.contains(where: { $0.kind == .removed && $0.text == "staged" }) && workDiff.lines.contains(where: { $0.kind == .added && $0.text == "working" }), "working diff is index to worktree")
        try expect(workDiff.lines.contains(where: { $0.kind == .added && $0.newNumber == 2 }), "diff carries line numbers")
        try GitChanges.commit(message: "staged only", signature: Signature(name: "Tests", email: "tests@example.com"), in: repository)
        try expect(try git(["show", "HEAD:note.md"], in: root).contains("staged"), "commit uses the index instead of current working data")
        try expect(try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8).contains("working"), "commit preserves further working edits")
        let draft = try change("folder/draft.md", .unstaged, in: repository)
        try GitChanges.stage([draft], in: repository)
        try GitChanges.stage([change("note.md", .unstaged, in: repository)], in: repository)
        try GitChanges.unstage([change("note.md", .staged, in: repository)], in: repository)
        try expect(try git(["show", ":note.md"], in: root).contains("staged"), "unstage restores the HEAD version in index")
        try expect(try git(["diff", "--cached", "--name-only"], in: root) == "folder/draft.md", "unstage preserves unrelated staged entries")
        try GitChanges.unstage([change("folder/draft.md", .staged, in: repository)], in: repository)
        try git(["checkout", "--", "note.md"], in: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("note.md"), to: root.appendingPathComponent("renamed.md"))
        let renamed = try change("renamed.md", .unstaged, in: repository)
        try expect(renamed.kind == .renamed && renamed.oldPath == "note.md", "rename retains the old path")
        try GitChanges.stage([renamed], in: repository)
        let stagedRename = try change("renamed.md", .staged, in: repository)
        try expect(stagedRename.kind == .renamed, "rename is staged")
        try GitChanges.unstage([stagedRename], in: repository)
        try expect(try git(["ls-files", "note.md", "renamed.md"], in: root) == "note.md", "unstage restores rename index paths")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.md").path), "unstage does not undo the working rename")
        try FileManager.default.moveItem(at: root.appendingPathComponent("renamed.md"), to: root.appendingPathComponent("note.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("note.md"))
        let deleted = try change("note.md", .unstaged, in: repository)
        try expect(deleted.kind == .deleted && GitChanges.diff(for: deleted, in: repository).deletions == 3, "deletion diff shows removed lines")
        try GitChanges.stage([deleted], in: repository)
        try GitChanges.unstage([change("note.md", .staged, in: repository)], in: repository)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("note.md").path), "unstaging deletion keeps working deletion")
        try git(["checkout", "--", "note.md"], in: root)

        try Data([0, 1, 2, 3, 0, 255]).write(to: root.appendingPathComponent("image.bin"))
        let binary = try GitChanges.diff(for: change("image.bin", .unstaged, in: repository), in: repository)
        try expect(binary.binary, "binary files are identified")
        try write("<script>alert('x')</script>\n& raw text\n", "markup.md", in: root)
        let markup = try change("markup.md", .unstaged, in: repository)
        let markupDiff = try GitChanges.diff(for: markup, in: repository)
        for side in [true, false] {
            let html = GitDiffPage.render(markupDiff, change: markup, sideBySide: side, dark: false)
            try expect(!html.contains("<script>") && html.contains("&lt;script&gt;") && html.contains("&amp; raw"), "diff HTML escapes repository contents")
        }
        let content = (0...8100).map { "line \($0)\n" }.joined()
        try write(content, "large.md", in: root)
        let large = try GitChanges.diff(for: change("large.md", .unstaged, in: repository), in: repository)
        try expect(large.truncated && large.lines.count == 8000 && large.additions == 8101, "large diff preview is bounded without losing totals")
        do { try GitChanges.stage([new], in: repository); try expect(false, "stale file status was staged") }
        catch GitError.invalidSpec { checks += 1 }
        do { try GitChanges.commit(message: " ", signature: Signature(name: "Tests", email: "tests@example.com"), in: repository); try expect(false, "empty message was accepted") }
        catch GitError.invalidSpec { checks += 1 }
        do { try GitChanges.commit(message: "empty", signature: Signature(name: "Tests", email: "tests@example.com"), in: repository); try expect(false, "empty commit was accepted") }
        catch GitError.noAddedFiles { checks += 1 }
        try git(["checkout", "--detach", "-q"], in: root)
        try expect(try GitChanges.snapshot(in: repository).branch.hasPrefix("HEAD · "), "detached HEAD has a readable label")
        try git(["checkout", "-q", "notes"], in: root)
        try write("first\n", "notes/identity.md", in: root)
        try git(["add", "notes/identity.md"], in: root)
        try git(["commit", "-qm", "stored note"], in: root)
        try Data("other\n".utf8).write(to: root.appendingPathComponent("notes/identity.md"), options: .atomic)
        let stored = try change("notes/identity.md", .unstaged, in: repository)
        try expect(stored.kind == .modified, "atomic same-size edits inside the notes directory are visible")
        let storedDiff = try GitChanges.diff(for: stored, in: repository)
        try expect(storedDiff.lines.contains(where: { $0.kind == .added && $0.text == "other" }), "nested stored-note diff reads the current saved content")
        try git(["checkout", "--", "notes/identity.md"], in: root)
        try git(["checkout", "-qb", "peer"], in: root)
        try write("peer\n", "note.md", in: root)
        try git(["add", "note.md"], in: root); try git(["commit", "-qm", "peer"], in: root)
        try git(["checkout", "-q", "notes"], in: root)
        try write("local\n", "note.md", in: root)
        try git(["add", "note.md"], in: root); try git(["commit", "-qm", "local"], in: root)
        do { try git(["merge", "peer"], in: root) } catch { }
        let conflicted = try GitChanges.snapshot(in: repository)
        try expect(conflicted.operationPending && conflicted.changes.contains(where: { $0.kind == .conflicted && $0.path == "note.md" }), "conflicts are visible and marked as pending")
        do { try GitChanges.stage([change("markup.md", .unstaged, in: repository)], in: repository); try expect(false, "pending merge allowed staging") }
        catch GitError.invalidSpec { checks += 1 }
        print("Git changes: \(checks) checks passed")
    }
}
