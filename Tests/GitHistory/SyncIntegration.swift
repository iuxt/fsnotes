import Foundation

@main struct SyncTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NSError(domain: "SyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @discardableResult static func git(_ arguments: [String], in root: URL, expectSuccess: Bool = true) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Tests", "-c", "user.email=tests@example.com"] + arguments
        process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expect((process.terminationStatus == 0) == expectSuccess, String(decoding: output, as: UTF8.self))
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ text: String, _ path: String, in root: URL) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    static func main() throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("fsnotes-sync-" + UUID().uuidString)
        try manager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temp) }
        let remote = temp.appendingPathComponent("remote.git")
        let local = temp.appendingPathComponent("local")
        try git(["init", "--bare", "-q", remote.path], in: temp)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        let project = Project(url: local)
        let keysDirectory = temp.appendingPathComponent("Keys")
        try manager.createDirectory(at: keysDirectory, withIntermediateDirectories: true)
        project.storage.gitKeysDir = keysDirectory
        project.settings.gitPrivateKey = Data("test private key".utf8)
        let keyURL = project.installSSHKey()!
        try expect(try manager.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? Int == 0o600,
                   "imported private key is only readable by its owner")
        try expect(try Data(contentsOf: keyURL) == project.settings.gitPrivateKey, "private key import preserves its contents")
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyURL.path)
        project.settings.gitPrivateKey = Data("replacement test key".utf8)
        try expect(project.installSSHKey() == keyURL, "private key replacement succeeds")
        try expect(try manager.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? Int == 0o600,
                   "rewriting an existing private key enforces mode 0600")
        try expect(try Data(contentsOf: keyURL) == project.settings.gitPrivateKey, "private key replacement preserves the new contents")
        project.settings.gitPrivateKey = nil
        project.storage.gitKeysDir = nil
        project.settings.gitOrigin = remote.path
        defer { if let cache = project.getCommitsDiffsCache() { try? manager.removeItem(at: cache) } }
        try project.initRepository()
        try write("initial", "local.md", in: local)
        try project.synchronize()
        let branch = try git(["branch", "--show-current"], in: local)
        try git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/" + branch], in: temp)
        try expect(try git(["rev-parse", "HEAD"], in: local) == git(["--git-dir", remote.path, "rev-parse", branch], in: temp), "first sync creates remote branch")
        let before = try git(["rev-parse", "HEAD"], in: local)
        try project.synchronize()
        try expect(try git(["rev-parse", "HEAD"], in: local) == before, "unchanged sync skips empty commit")

        let peer = temp.appendingPathComponent("peer")
        try git(["clone", "-q", remote.path, peer.path], in: temp)
        try write("remote update", "remote.md", in: peer)
        try git(["add", "."], in: peer); try git(["commit", "-qm", "remote update"], in: peer)
        try git(["push", "-q"], in: peer)
        let remoteHead = try git(["rev-parse", "HEAD"], in: peer)
        try write("local update", "local.md", in: local)
        try project.synchronize()
        try expect(manager.fileExists(atPath: local.appendingPathComponent("remote.md").path), "pulled file exists")
        try expect(try String(contentsOf: local.appendingPathComponent("remote.md"), encoding: .utf8) == "remote update", "sync pulls remote content")
        try expect(try String(contentsOf: local.appendingPathComponent("local.md"), encoding: .utf8) == "local update", "sync preserves and commits local edits")
        try expect(try git(["rev-parse", "HEAD^"], in: local) == remoteHead, "local commit is created after pull")
        try expect(try git(["rev-parse", "HEAD"], in: local) == git(["--git-dir", remote.path, "rev-parse", branch], in: temp), "sync pushes the new commit")

        try git(["pull", "-q"], in: peer)
        try write("remote conflict", "local.md", in: peer)
        try git(["add", "."], in: peer); try git(["commit", "-qm", "conflicting update"], in: peer)
        try git(["push", "-q"], in: peer)
        let remoteConflict = try git(["rev-parse", "HEAD"], in: peer)
        let localHead = try git(["rev-parse", "HEAD"], in: local)
        try write("unsaved local conflict", "local.md", in: local)
        do { try project.synchronize(); try expect(false, "pull conflict was ignored") }
        catch GitError.uncommittedConflict { checks += 1 }
        try expect(try git(["rev-parse", "HEAD"], in: local) == localHead, "failed pull creates no local commit")
        try expect(try String(contentsOf: local.appendingPathComponent("local.md"), encoding: .utf8) == "unsaved local conflict", "failed pull retains local edits")
        try expect(try git(["--git-dir", remote.path, "rev-parse", branch], in: temp) == remoteConflict, "failed pull does not push")
        try testMetadataConflicts(in: temp)
        try testCleanDivergentMerge(in: temp)
        try testMergedFolderCycle(in: temp)
        try testCloneProtection(in: temp)
        print("Git sync integration: \(checks) checks passed")
    }
    static func testCleanDivergentMerge(in temp: URL) throws {
        let local = temp.appendingPathComponent("clean-merge-local")
        let peer = temp.appendingPathComponent("clean-merge-peer")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try git(["init", "-q"], in: local)
        try write("base A", "a.md", in: local); try write("base B", "b.md", in: local)
        try git(["add", "."], in: local); try git(["commit", "-qm", "base"], in: local)
        try git(["clone", "-q", local.path, peer.path], in: temp)
        try write("local content", "a.md", in: local)
        try git(["add", "."], in: local); try git(["commit", "-qm", "local"], in: local)
        let localSHA = try git(["rev-parse", "HEAD"], in: local)
        try write("remote content", "b.md", in: peer)
        try git(["add", "."], in: peer); try git(["commit", "-qm", "remote"], in: peer)
        let remoteSHA = try git(["rev-parse", "HEAD"], in: peer)
        let project = Project(url: local); project.settings.gitOrigin = peer.path
        defer { project.removeCommitsCache() }
        try project.pull()
        try expect(try String(contentsOf: local.appendingPathComponent("b.md"), encoding: .utf8) == "remote content", "divergent merge installs the remote body")
        try expect(try git(["status", "--porcelain"], in: local).isEmpty, "merge leaves HEAD, index and worktree consistent")
        try expect(try git(["rev-parse", "HEAD^1"], in: local) == localSHA && git(["rev-parse", "HEAD^2"], in: local) == remoteSHA, "merge retains both parents")
        try write("next local edit", "a.md", in: local)
        try project.commit()
        try expect(try git(["show", "HEAD:b.md"], in: local) == "remote content", "later autosave commit cannot revert remote content")
    }

    static func testMergedFolderCycle(in temp: URL) throws {
        let local = temp.appendingPathComponent("cycle-local"), peer = temp.appendingPathComponent("cycle-peer")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let store = try MetadataStore(root: local)
        // Keep the two changes far apart so Git merges them without textual conflicts.
        let folders = (1...8).map { MetadataStore.Folder(id: String(format: "00000000-0000-4000-8000-%012d", $0), name: "F\($0)") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(MetadataStore.Snapshot(folders: folders)).write(to: store.manifestURL)
        try store.refresh()
        try git(["init", "-q"], in: local)
        try git(["add", "."], in: local); try git(["commit", "-qm", "base folders"], in: local)
        try git(["clone", "-q", local.path, peer.path], in: temp)
        try store.moveFolder(id: folders[0].id, parentID: folders[7].id)
        try git(["add", "."], in: local); try git(["commit", "-qm", "local reparent"], in: local)
        let peerStore = try MetadataStore(root: peer)
        try peerStore.moveFolder(id: folders[7].id, parentID: folders[0].id)
        try git(["add", "."], in: peer); try git(["commit", "-qm", "remote reparent"], in: peer)
        let project = Project(url: local); project.metadataStore = store; project.settings.gitOrigin = peer.path
        let head = try git(["rev-parse", "HEAD"], in: local)
        let index = try Data(contentsOf: local.appendingPathComponent(".git/index"))
        let manifest = try Data(contentsOf: store.manifestURL)
        do { try project.pull(); try expect(false, "clean text merge must reject a cyclic folder graph") }
        catch MetadataStore.Failure.invalid(let reason) { try expect(reason == "folder cycle", "full merged manifest is validated") }
        try expect(try git(["rev-parse", "HEAD"], in: local) == head, "invalid metadata never advances HEAD")
        try expect(try Data(contentsOf: local.appendingPathComponent(".git/index")) == index, "invalid merge preserves index bytes")
        try expect(try Data(contentsOf: store.manifestURL) == manifest, "invalid merge preserves working metadata")
        try expect(try git(["status", "--porcelain"], in: local).isEmpty, "invalid merge leaves no staged reversal")
    }
    static func testMetadataConflicts(in temp: URL) throws {
        let manager = FileManager.default
        let local = temp.appendingPathComponent("metadata-local")
        let peer = temp.appendingPathComponent("metadata-peer")
        let remote = temp.appendingPathComponent("metadata-remote.git")
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        let store = try MetadataStore(root: local)
        let entry = try store.register(name: "Original", folderID: nil, ext: "md")
        try "body remains valid".write(to: store.fileURL(entry), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: local)
        try git(["add", "."], in: local); try git(["commit", "-qm", "base"], in: local)
        try git(["clone", "--bare", "-q", local.path, remote.path], in: temp)
        try git(["clone", "-q", remote.path, peer.path], in: temp)
        let peerStore = try MetadataStore(root: peer)
        try peerStore.renameNote(id: entry.id, name: "Remote title")
        try write("remote add/add", "shared.md", in: peer)
        try git(["add", "."], in: peer); try git(["commit", "-qm", "remote metadata"], in: peer)
        try git(["push", "-q"], in: peer)
        try store.renameNote(id: entry.id, name: "Local title")
        try write("local add/add", "shared.md", in: local)
        try git(["add", "."], in: local); try git(["commit", "-qm", "local metadata"], in: local)
        let project = Project(url: local)
        project.metadataStore = store; project.settings.gitOrigin = remote.path
        defer { project.removeCommitsCache() }
        let head = try git(["rev-parse", "HEAD"], in: local)
        let remoteHead = try git(["--git-dir", remote.path, "rev-parse", "HEAD"], in: temp)
        let manifest = try Data(contentsOf: store.manifestURL)
        do { try project.synchronize(); try expect(false, "committed metadata conflict must stop sync") }
        catch GitError.unableToMerge(let message) {
            try expect(message.contains("metadata.json") && message.contains("shared.md"),
                       "conflict report includes modify/modify and ancestor-free add/add paths")
        }
        try expect(try git(["rev-parse", "HEAD"], in: local) == head, "conflict does not create a merge commit")
        try expect(try Data(contentsOf: store.manifestURL) == manifest, "conflict does not write markers into metadata")
        try expect(try git(["status", "--porcelain"], in: local).isEmpty, "failed merge leaves index and worktree intact")
        try expect(try git(["--git-dir", remote.path, "rev-parse", "HEAD"], in: temp) == remoteHead,
                   "failed metadata merge publishes nothing")
        try expect(try String(contentsOf: store.fileURL(entry), encoding: .utf8) == "body remains valid", "note body is retained")
        _ = try store.refresh()
        try expect(store.entry(id: entry.id)?.name == "Local title", "metadata remains readable after a conflict")

        // An external client can start a real conflicted merge. Sync must not
        // stage its marker-filled files and erase Git's unresolved entries.
        try git(["merge", "origin/" + git(["branch", "--show-current"], in: local)], in: local, expectSuccess: false)
        let unresolved = try git(["ls-files", "-u"], in: local)
        let conflictedManifest = try Data(contentsOf: store.manifestURL)
        do { try project.commit(); try expect(false, "pending external merge must block auto-commit") }
        catch GitError.invalidSpec { checks += 1 }
        try expect(try git(["ls-files", "-u"], in: local) == unresolved && !unresolved.isEmpty,
                   "pending external merge retains all unresolved index stages")
        try expect(try Data(contentsOf: store.manifestURL) == conflictedManifest, "pending merge worktree remains untouched")
        try expect(try git(["rev-parse", "HEAD"], in: local) == head, "pending merge is not committed")
        try git(["merge", "--abort"], in: local)
    }

    static func testCloneProtection(in temp: URL) throws {
        let manager = FileManager.default
        let seed = temp.appendingPathComponent("clone-seed")
        let remote = temp.appendingPathComponent("clone-remote.git")
        try manager.createDirectory(at: seed, withIntermediateDirectories: true)
        let seedStore = try MetadataStore(root: seed)
        let entry = try seedStore.register(name: "Remote note", folderID: nil, ext: "md")
        try "remote body".write(to: seedStore.fileURL(entry), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: seed)
        try git(["add", "."], in: seed); try git(["commit", "-qm", "remote library"], in: seed)
        try git(["clone", "--bare", "-q", seed.path, remote.path], in: temp)

        let populated = temp.appendingPathComponent("clone-populated")
        try manager.createDirectory(at: populated, withIntermediateDirectories: true)
        let existingStore = try MetadataStore(root: populated)
        let existing = try existingStore.register(name: "Local note", folderID: nil, ext: "md")
        try "local body".write(to: existingStore.fileURL(existing), atomically: true, encoding: .utf8)
        let project = Project(url: populated)
        project.metadataStore = existingStore; project.settings.gitOrigin = remote.path
        let manifest = try Data(contentsOf: existingStore.manifestURL)
        do { _ = try project.cloneRepository(); try expect(false, "clone must reject a populated library") }
        catch GitError.invalidSpec { checks += 1 }
        try expect(!project.hasRepository(), "rejected clone does not install .git")
        try expect(try Data(contentsOf: existingStore.manifestURL) == manifest, "rejected clone retains local metadata byte for byte")
        try expect(try String(contentsOf: existingStore.fileURL(existing), encoding: .utf8) == "local body", "rejected clone retains note content")

        let fresh = temp.appendingPathComponent("clone-fresh")
        try manager.createDirectory(at: fresh, withIntermediateDirectories: true)
        let emptyStore = try MetadataStore(root: fresh)
        let empty = Project(url: fresh)
        empty.metadataStore = emptyStore; empty.settings.gitOrigin = remote.path
        try expect(try empty.cloneRepository() != nil, "empty initialized workspace can clone")
        try expect(try Data(contentsOf: emptyStore.manifestURL) == Data(contentsOf: seedStore.manifestURL), "clone installs the remote manifest")
        _ = try emptyStore.refresh()
        try expect(emptyStore.entry(id: entry.id)?.name == "Remote note", "cloned metadata indexes the remote note")
        try expect(try String(contentsOf: emptyStore.fileURL(entry), encoding: .utf8) == "remote body", "clone installs the note worktree")
        try expect(try git(["status", "--porcelain"], in: fresh).isEmpty, "cloned index agrees with its installed worktree")

        let unindexed = temp.appendingPathComponent("clone-unindexed")
        try manager.createDirectory(at: unindexed, withIntermediateDirectories: true)
        let unindexedStore = try MetadataStore(root: unindexed)
        try write("unindexed body", "notes/unindexed.md", in: unindexed)
        let unsafe = Project(url: unindexed)
        unsafe.metadataStore = unindexedStore; unsafe.settings.gitOrigin = remote.path
        do { _ = try unsafe.cloneRepository(); try expect(false, "clone must preserve unindexed notes too") }
        catch GitError.invalidSpec { checks += 1 }
        try expect(try String(contentsOf: unindexed.appendingPathComponent("notes/unindexed.md"), encoding: .utf8) == "unindexed body",
                   "empty metadata does not permit overwriting unindexed files")
    }

}
