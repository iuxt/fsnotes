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
    static func testImagePreview() throws {
        let fixture = try Fixture()
        let repository = try fixture.open()
        let notePath = "notes/nested/note.md"
        let imagePath = "images/中文 & picture.png"
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5ioAAAAASUVORK5CYII=")!
        try fixture.write(notePath, "![saved](../../images/中文%20%26%20picture.png)")
        let destination = fixture.url.appendingPathComponent(imagePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: destination)
        let saved = try repository.commitLookup(sha: fixture.commit("Save image"))
        try Data("changed image".utf8).write(to: destination)
        try fixture.commit("Replace image")
        try FileManager.default.removeItem(at: destination)
        let indexURL = repository.url.appendingPathComponent("index")
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try fixture.git(["rev-parse", "HEAD"])
        let source = "<p>图片</p><img alt=\"saved\" src=\"../../images/中文%20%26%20picture.png\">"
        let preview = HistoryPreview.embedImages(in: source, notePath: notePath) {
            try HistoryPreview.imageData(path: $0, repository: repository, commit: saved)
        }
        try expect(preview.contains("data:image/png;base64," + image.base64EncodedString()),
                   "History embeds the saved image after replacement and deletion in the working tree")
        try expect(preview.contains("<p>图片</p>"), "Image embedding preserves the surrounding content")
        try expect(try Data(contentsOf: indexURL) == indexBefore && fixture.git(["rev-parse", "HEAD"]) == headBefore,
                   "Image preview leaves the index and HEAD unchanged")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Preview must not restore assets into the working tree")
        try expect(HistoryPreview.imagePath(source: "../../images/中文%20%26%20picture.png?size=1#image", notePath: notePath) == imagePath,
                   "Relative parent paths, Unicode, percent escapes, queries and fragments resolve from the saved note")
        for path in ["../../../outside.png", "%2Foutside.png", "/outside.png", "file:///outside.png", "//example.com/image.png", ""] {
            try expect(HistoryPreview.imagePath(source: path, notePath: notePath) == nil, "Non-repository image paths rejected")
        }
        let remote = "<img src=\"https://example.com/a.png?x=1&amp;y=2\"><img src='data:image/png;base64,AA=='>"
        try expect(HistoryPreview.embedImages(in: remote, notePath: notePath) { _ in
            throw GitError.notFound(ref: "Must not read remote images")
        } == remote, "Remote and inline images remain displayable")
        let missing = HistoryPreview.embedImages(in: "<img alt='missing' src='missing.png'>", notePath: notePath) {
            try HistoryPreview.imageData(path: $0, repository: repository, commit: saved)
        }
        try expect(missing == "<img alt='missing' src=''>", "Missing images retain their alt text without resolving to live files")
        let entity = HistoryPreview.embedImages(in: "<img data-src='ignored' src='../../images/中文%20&amp;%20picture.png'>", notePath: notePath) {
            try HistoryPreview.imageData(path: $0, repository: repository, commit: saved)
        }
        try expect(entity.contains("src='data:image/png;base64," + image.base64EncodedString()), "HTML entities and single-quoted image sources resolve")

        let lfsPath = "images/lfs.png"
        let pointer = try GitLFS.clean(image, gitDirectory: repository.url)
        try pointer.write(to: fixture.url.appendingPathComponent(lfsPath))
        let lfsCommit = try repository.commitLookup(sha: fixture.commit("Save LFS image"))
        try expect(try HistoryPreview.imageData(path: lfsPath, repository: repository, commit: lfsCommit) == image,
                   "History preview resolves LFS pointers to the saved image object")
        let object = GitLFS.Pointer(pointer: pointer)!.objectURL(in: repository.url)
        try FileManager.default.removeItem(at: object)
        try expectFailure("Missing LFS objects must not display pointer text as an image") {
            _ = try HistoryPreview.imageData(path: lfsPath, repository: repository, commit: lfsCommit)
        }
        print("PASS: historical image preview, nested/Unicode paths, deleted assets, remote/inline images, LFS objects, unchanged index/HEAD")
    }

    static func main() throws {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        try testImagePreview()
        let fixture = try Fixture()
        let repository = try fixture.open()
        try expect(try repository.fileHistory(path: "missing.md").isEmpty, "Empty repository should have no history")
        let target = "nested/[a].md"
        let unicode = "nested/中文 空格 📝.md"
        let nested = "nested/document.md"
        for path in [target, unicode, nested, "nested/a.md", "other.md", "images/image.txt"] {
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
        for path in [target, unicode, nested] { try fixture.write(path, "second \(path)") }
        let second = try fixture.commit("Change notes\n\n正文 📝\nSecond paragraph.")
        let detailedCommit = try repository.commitLookup(sha: second)
        try expect(detailedCommit.summary == "Change notes", "Commit summary must exclude the body")
        try expect(detailedCommit.body == "正文 📝\nSecond paragraph.", "Commit body must preserve Unicode and line breaks")
        try fixture.write("other.md", "unrelated commit")
        try fixture.commit("Unrelated")
        for path in [target, unicode, nested] {
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
        try fixture.write("images/image.txt", "new asset")
        let indexURL = fixture.url.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let headBefore = try fixture.git(["rev-parse", "HEAD"])
        // Browsing saved versions must never check them out or flush current edits.
        for path in [target, unicode, nested] {
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
        for path in [target, unicode, nested] { try repository.checkout(commit: commit, path: path) }
        try expect(try fixture.read(target) == "initial \(target)", "Target restored")
        try expect(try fixture.read(unicode) == "initial \(unicode)", "Unicode path restored")
        try expect(try fixture.read(nested) == "initial \(nested)", "Nested note restored")
        try expect(try fixture.read("nested/a.md") == "glob neighbor", "Literal path must not match a glob neighbor")
        try expect(try fixture.read("other.md") == "unsaved other", "Other working files preserved")
        try expect(try fixture.read("images/image.txt") == "new asset", "Image assets preserved")
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
