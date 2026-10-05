import Foundation
import Cgit2

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "GitHistoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "GitHistoryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

private final class Fixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.name", "History Test"])
        _ = try git(["config", "user.email", "test@example.com"])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    @discardableResult func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(process.terminationStatus == 0, "git \(arguments): \(text)")
        return text
    }
    func write(_ path: String, _ content: String) throws {
        let destination = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: destination, atomically: true, encoding: .utf8)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
    @discardableResult func commit(_ message: String) throws -> String {
        try git(["add", "."])
        try git(["commit", "-m", message])
        return try git(["rev-parse", "HEAD"])
    }
    func open(_ repositoryURL: URL? = nil) throws -> Repository {
        let repositoryURL = repositoryURL ?? url.appendingPathComponent(".git")
        let pointer = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        let result = git_repository_open(pointer, repositoryURL.path)
        guard result == 0 else {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
            throw gitUnknownError("Open fixture", code: result)
        }
        return Repository(at: repositoryURL, manager: RepositoryManager(), repository: pointer)
    }
}

@main private struct GitHistoryIntegration {
    static func main() throws {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        let fixture = try Fixture()
        let repository = try fixture.open()
        try expect(try repository.fileHistory(path: "missing.md").isEmpty, "Empty repository should have no history")
        let target = "nested/[a].md"
        let unicode = "nested/中文 空格 📝.md"
        let bundle = "note.textbundle/text.md"
        for path in [target, unicode, bundle, "nested/a.md", "other.md", "note.textbundle/assets/image.txt"] {
            try fixture.write(path, "initial \(path)")
        }
        try fixture.write("empty.md", "")
        let first = try fixture.commit("Initial")
        let initialCommit = try repository.commitLookup(sha: first)
        // The selected library and its .git directory remain portable as one folder.
        try expect(try WorkspaceLocation.validate(fixture.url) == fixture.url.resolvingSymlinksInPath(), "Workspace validation")
        try expectFailure("A note file cannot be a workspace") { _ = try WorkspaceLocation.validate(fixture.url.appendingPathComponent("empty.md")) }
        try expectFailure("A missing folder cannot silently fall back to Documents") { _ = try WorkspaceLocation.validate(fixture.url.appendingPathComponent("missing")) }
        try expectFailure("Git internals cannot be selected as a library") { _ = try WorkspaceLocation.validate(WorkspaceLocation.repositoryURL(for: fixture.url)) }
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("工作目录 " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.copyItem(at: fixture.url, to: moved)
        let movedRepository = try fixture.open(WorkspaceLocation.repositoryURL(for: moved))
        let worktree = String(cString: git_repository_workdir(movedRepository.pointer.pointee))
        try expect(URL(fileURLWithPath: worktree).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath(), "Moved .git infers the new workspace without an absolute worktree")
        try expect(String(data: movedRepository.fileContent(commit: movedRepository.commitLookup(sha: first), path: target), encoding: .utf8) == "initial \(target)", "History travels with the notes")
        try "changed after move".write(to: moved.appendingPathComponent(target), atomically: true, encoding: .utf8)
        try movedRepository.checkout(commit: movedRepository.commitLookup(sha: first), path: target)
        try expect(try String(contentsOf: moved.appendingPathComponent(target), encoding: .utf8) == "initial \(target)", "Restore writes into the moved workspace")
        try expect(try fixture.read(target) == "initial \(target)", "Moved workspace never writes back to its original location")
        // Cloning through a temporary folder must infer the destination worktree
        // after moving .git beside the workspace notes.
        let cloneTemp = FileManager.default.temporaryDirectory.appendingPathComponent("clone-" + UUID().uuidString)
        let cloneWorkspace = FileManager.default.temporaryDirectory.appendingPathComponent("克隆工作目录 " + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: cloneTemp)
            try? FileManager.default.removeItem(at: cloneWorkspace)
        }
        var clonedPointer: OpaquePointer?
        let cloneResult = git_clone(&clonedPointer, fixture.url.absoluteString, cloneTemp.path, nil)
        git_repository_free(clonedPointer)
        try expect(cloneResult == 0, "Clone local fixture")
        try FileManager.default.createDirectory(at: cloneWorkspace, withIntermediateDirectories: true)
        try "local draft".write(to: cloneWorkspace.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: WorkspaceLocation.repositoryURL(for: cloneTemp),
                                         to: WorkspaceLocation.repositoryURL(for: cloneWorkspace))
        let clonedRepository = try fixture.open(WorkspaceLocation.repositoryURL(for: cloneWorkspace))
        let clonedWorktree = String(cString: git_repository_workdir(clonedRepository.pointer.pointee))
        try expect(URL(fileURLWithPath: clonedWorktree).resolvingSymlinksInPath() == cloneWorkspace.resolvingSymlinksInPath(),
                   "Cloned .git infers the workspace rather than the temporary directory")
        try clonedRepository.checkout(commit: clonedRepository.commitLookup(sha: first), path: target)
        try expect(try String(contentsOf: cloneWorkspace.appendingPathComponent(target), encoding: .utf8) == "initial \(target)",
                   "Cloned history restores into the workspace")
        try expect(try String(contentsOf: cloneWorkspace.appendingPathComponent("draft.md"), encoding: .utf8) == "local draft",
                   "Cloned history preserves unrelated workspace notes")
        try expect(initialCommit.summary == "Initial", "Subject-only commit summary")
        try expect(initialCommit.body.isEmpty, "Subject-only commits must have an empty body without crashing")
        for path in [target, unicode, bundle] { try fixture.write(path, "second \(path)") }
        let second = try fixture.commit("Change notes\n\n正文 📝\nSecond paragraph.")
        let detailedCommit = try repository.commitLookup(sha: second)
        try expect(detailedCommit.summary == "Change notes", "Commit summary must exclude the body")
        try expect(detailedCommit.body == "正文 📝\nSecond paragraph.", "Commit body must preserve Unicode and line breaks")
        try fixture.write("other.md", "unrelated commit")
        try fixture.commit("Unrelated")
        for path in [target, unicode, bundle] {
            let history = try repository.fileHistory(path: path)
            try expect(history.compactMap { $0.oid.sha() } == [second, first], "History must include only file changes and one initial commit")
        }
        try expect(try repository.fileHistory(path: "missing.md").isEmpty, "Missing file should have no history")
        let commit = try repository.commitLookup(sha: " \(first.prefix(12))\n")
        try expect(commit.oid.sha() == first, "Abbreviated SHA must resolve")
        for invalid in ["HEAD", "", "../main", "fff", String(repeating: "0", count: 40)] {
            try expectFailure("Invalid commit must fail") { _ = try repository.commitLookup(sha: invalid) }
        }
        let treeID = try fixture.git(["rev-parse", "HEAD^{tree}"])
        try expectFailure("Tree IDs must not resolve as commits") { _ = try repository.commitLookup(sha: treeID) }

        // Both the target and another file have staged and unstaged edits.
        try fixture.write(target, "staged target")
        try fixture.write("other.md", "staged other")
        try fixture.git(["add", "--", target, "other.md"])
        try fixture.write(target, "unsaved target")
        try fixture.write("other.md", "unsaved other")
        try fixture.write("nested/a.md", "glob neighbor")
        try fixture.write("note.textbundle/assets/image.txt", "new asset")
        let indexURL = fixture.url.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try fixture.git(["rev-parse", "HEAD"])
        // Browsing saved versions must never check them out or flush current edits.
        for path in [target, unicode, bundle] {
            let data = try repository.fileContent(commit: commit, path: path)
            try expect(String(data: data, encoding: .utf8) == "initial \(path)", "Preview must read the saved blob")
        }
        try expect(try repository.fileContent(commit: commit, path: "empty.md").isEmpty, "Empty files must be previewable")
        try expect(try fixture.read(target) == "unsaved target", "Preview must preserve working edits")
        try expect(try Data(contentsOf: indexURL) == indexBefore, "Preview must preserve the index")
        try expect(try fixture.git(["rev-parse", "HEAD"]) == headBefore, "Preview must preserve HEAD")
        for path in ["missing.md", "nested", "../other.md", "/other.md", ""] {
            try expectFailure("Unsafe or missing preview path must fail") { _ = try repository.fileContent(commit: commit, path: path) }
        }
        for path in [target, unicode, bundle] { try repository.checkout(commit: commit, path: path) }
        try expect(try fixture.read(target) == "initial \(target)", "Target restored")
        try expect(try fixture.read(unicode) == "initial \(unicode)", "Unicode path restored")
        try expect(try fixture.read(bundle) == "initial \(bundle)", "Bundle text restored")
        try expect(try fixture.read("nested/a.md") == "glob neighbor", "Literal path must not match a glob neighbor")
        try expect(try fixture.read("other.md") == "unsaved other", "Other working files preserved")
        try expect(try fixture.read("note.textbundle/assets/image.txt") == "new asset", "Bundle assets preserved")
        try expect(try Data(contentsOf: indexURL) == indexBefore, "Index must remain byte-for-byte unchanged")
        try expect(try fixture.git(["rev-parse", "HEAD"]) == headBefore, "HEAD unchanged")
        for path in ["missing.md", "nested", "../other.md", "/other.md", ""] {
            try expectFailure("Unsafe or missing path must fail") { try repository.checkout(commit: commit, path: path) }
        }
        try expect(try fixture.read("other.md") == "unsaved other", "Failed restore leaves files intact")

        // A deletion/recreation must expose both restorable versions, never the deletion.
        try fixture.git(["reset", "--hard", "HEAD"])
        try fixture.git(["rm", "--", target])
        try fixture.commit("Delete target")
        try fixture.write(target, "recreated")
        let recreated = try fixture.commit("Recreate target")
        let history = try repository.fileHistory(path: target)
        try expect(history.compactMap { $0.oid.sha() } == [recreated, second, first], "Deletion and recreation history")

        let branches = try Fixture()
        try branches.write("note.md", "initial")
        let branchRoot = try branches.commit("Root")
        try branches.git(["checkout", "-b", "feature"])
        try branches.write("note.md", "feature")
        let feature = try branches.commit("Feature note")
        try branches.git(["checkout", "main"])
        try branches.write("other.md", "main only")
        try branches.commit("Main other file")
        try branches.git(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let merge = try branches.git(["rev-parse", "HEAD"])
        let branchRepository = try branches.open()
        let mergeHistory = try branchRepository.fileHistory(path: "note.md")
        try expect(mergeHistory.compactMap { $0.oid.sha() } == [merge, feature, branchRoot], "History must compare real parents, including merged branches")
        try FileManager.default.createSymbolicLink(atPath: branches.url.appendingPathComponent("link.md").path, withDestinationPath: "note.md")
        let linkCommit = try branches.commit("Symbolic link")
        try expectFailure("Symbolic links must not preview another file") {
            _ = try branchRepository.fileContent(commit: branchRepository.commitLookup(sha: linkCommit), path: "link.md")
        }
        try expectFailure("Symbolic links must not restore another file") {
            try branchRepository.checkout(commit: branchRepository.commitLookup(sha: linkCommit), path: "link.md")
        }
        try expect(try branches.read("note.md") == "feature", "Rejected symlink leaves its target intact")
        for (saved, current) in [("", ""), ("", "新增 📝"), ("deleted", ""), ("same\n", "same\n"),
                                 ("a\nb\nc", "a\nnew\nc"), ("a\na\nb\n", "a\nb\na"),
                                 ("old\nmiddle\nend", "first\nmiddle\nlast")] {
            let lines = HistoryDiff.lines(from: saved, to: current)
            try expect(lines.filter { $0.kind != .added }.map { $0.text }.joined(separator: "\n") == saved,
                       "Diff must preserve every saved line, including duplicates and trailing newlines")
            try expect(lines.filter { $0.kind != .removed }.map { $0.text }.joined(separator: "\n") == current,
                       "Diff must represent every current line")
        }
        let replacement = HistoryDiff.lines(from: "old", to: "new")
        try expect(replacement.count == 2 && replacement[0].kind == .removed && replacement[1].kind == .added,
                   "Diff direction must be saved version to current note")
        print("PASS: read-only and empty previews, line differences, commit messages, history, initial commit, unrelated changes, SHA lookup, literal/Unicode paths, single-file restore, unchanged index/HEAD, failed restore, deletion/recreation, portable workspace and clone, merges, symlinks")
    }
}
