import Foundation
import Cgit2

@main struct LFSTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NSError(domain: "LFSTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @discardableResult static func git(_ arguments: [String], in root: URL, skipSmudge: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = Bundle.main.url(forAuxiliaryExecutable: "git")!
        process.arguments = arguments; process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Bundle.main.url(forAuxiliaryExecutable: "git-lfs")!
            .deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_EXEC_PATH"] = process.executableURL!.deletingLastPathComponent().path
        if skipSmudge { environment["GIT_LFS_SKIP_SMUDGE"] = "1" }
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, "git " + arguments.joined(separator: " ") + ": " + String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
    static func main() throws {
        git_libgit2_init()
        GitLFS.registerFilter()
        GitLFS.registerFilter() // Another wrapper may initialize while libgit2 remains alive.
        defer { git_libgit2_shutdown() }
        let manager = FileManager.default
        try expect(Bundle.main.url(forAuxiliaryExecutable: "git-lfs") != nil, "LFS client is embedded beside the test executable")
        try expect(Bundle.main.url(forAuxiliaryExecutable: "git") != nil, "real Git executable is embedded beside the LFS client")
        let temp = manager.temporaryDirectory.appendingPathComponent("fsnotes-lfs-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temp) }
        let root = temp.appendingPathComponent("library")
        try manager.createDirectory(at: root.appendingPathComponent("images/nested"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let image = root.appendingPathComponent("images/nested/photo.png")
        let bytes = Data([0, 255, 1, 128, 7, 9])
        try bytes.write(to: image)
        try Data().write(to: root.appendingPathComponent("images/empty.png"))
        try "body\n".write(to: root.appendingPathComponent("notes/note.md"), atomically: true, encoding: .utf8)
        try "images/** filter=lfs diff=lfs merge=lfs -text\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: root)
        var repo: OpaquePointer?
        try expect(git_repository_open(&repo, root.path) == 0, "open repository")
        defer { git_repository_free(repo) }
        var index: OpaquePointer?
        try expect(git_repository_index(&index, repo) == 0, "open index")
        defer { git_index_free(index) }
        let wrapperPointer = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        wrapperPointer.initialize(to: nil)
        try expect(git_repository_open(wrapperPointer, root.path) == 0, "open app repository wrapper")
        let wrapper = Repository(at: root, manager: RepositoryManager(), repository: wrapperPointer)
        let appIndex = try Index(repository: wrapper)
        try expect(try appIndex.add(path: "."), "app stages files through LFS")
        try appIndex.save() // Index.add must retain ownership of the live index.
        let pointerData = try git(["show", ":images/nested/photo.png"], in: root)
        let pointer = GitLFS.Pointer(pointer: Data(pointerData.utf8))!
        try expect(pointer.size == bytes.count, "index stores LFS size")
        try expect(pointer.oid == GitLFS.Pointer(data: bytes).oid, "index stores SHA-256")
        let gitDirectory = root.appendingPathComponent(".git")
        try expect(try Data(contentsOf: pointer.objectURL(in: gitDirectory)) == bytes, "object cache contains original image")
        try expect(try Data(contentsOf: image) == bytes, "staging leaves image intact")
        try expect(try git(["show", ":notes/note.md"], in: root) == "body\n", "notes remain ordinary blobs")
        let empty = try git(["show", ":images/empty.png"], in: root)
        try expect(GitLFS.Pointer(pointer: Data(empty.utf8))?.size == 0, "empty images get valid LFS pointers")
        try git(["-c", "user.name=Tests", "-c", "user.email=test@example.com", "commit", "-qm", "images"], in: root)
        var status: UInt32 = 0
        try expect(git_status_file(&status, repo, "images/nested/photo.png") == 0 && status == 0, "native Git reports smudged images as clean")
        try manager.removeItem(at: image)
        var options = git_checkout_options(); options.version = 1
        options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try expect(git_checkout_head(repo, &options) == 0, "native checkout smudges image")
        try expect(try Data(contentsOf: image) == bytes, "native checkout restores original bytes")
        try expect(try GitLFS.clean(pointer.data, gitDirectory: gitDirectory) == pointer.data, "clean does not double-wrap a pointer")
        try Data([3]).write(to: pointer.objectURL(in: gitDirectory), options: .atomic)
        do {
            _ = try GitLFS.smudge(pointer.data, gitDirectory: gitDirectory)
            try expect(false, "corrupt object accepted")
        } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        _ = try GitLFS.clean(bytes, gitDirectory: gitDirectory)

        let objects = gitDirectory.appendingPathComponent("lfs/objects")
        try manager.removeItem(at: objects)
        try Data("blocked".utf8).write(to: objects)
        try Data([99, 11]).write(to: image)
        do {
            _ = try appIndex.add(path: ".")
            try expect(false, "LFS cache write failure was swallowed by staging")
        } catch is GitError { checks += 1 }
        try manager.removeItem(at: objects)
        try bytes.write(to: image)
        try Data().write(to: root.appendingPathComponent("images/empty.png"), options: .atomic)
        _ = try appIndex.add(path: ".")
        try expect(try git(["show", ":images/nested/photo.png"], in: root) == pointerData, "staging recovers after a cache failure")
        _ = try GitLFS.clean(bytes, gitDirectory: gitDirectory)
        _ = try GitLFS.clean(Data(), gitDirectory: gitDirectory)

        // Actual Git LFS transport against an isolated local bare remote.
        let remote = temp.appendingPathComponent("remote.git")
        try git(["init", "--bare", "-q", remote.path], in: root)
        try git(["remote", "add", "origin", remote.path], in: root)
        let branch = try git(["branch", "--show-current"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try GitLFS.transfer(["push", "origin", branch], in: root)
        try git(["push", "-q", "origin", branch], in: root)
        let clone = temp.appendingPathComponent("clone")
        try git(["clone", "-q", remote.path, clone.path], in: temp, skipSmudge: true)
        let clonedImage = clone.appendingPathComponent("images/nested/photo.png")
        try expect(GitLFS.Pointer(pointer: Data(contentsOf: clonedImage)) != nil, "clone begins with image pointer")
        try GitLFS.transfer(["pull", "origin"], in: clone)
        try expect(try Data(contentsOf: clonedImage) == bytes, "LFS pull hydrates a fresh clone")
        print("Git LFS integration: \(checks) checks passed")
    }
}
