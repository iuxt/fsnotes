import Foundation

@main struct ConflictTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw NSError(domain: "ConflictTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @discardableResult static func git(_ arguments: [String], at root: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Tests", "-c", "user.email=tests@example.com"] + arguments
        process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    struct Fixture {
        let local: URL, peer: URL, project: Project
        init(root: URL, base: Data, ours: Data?, theirs: Data?, path: String = "note.md", dirty: Bool = false) throws {
            let local = root.appendingPathComponent(UUID().uuidString), remote = local.appendingPathExtension("git"), peer = local.appendingPathExtension("peer")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try base.write(to: local.appendingPathComponent(path))
            try git(["init", "-q"], at: local); try git(["add", "."], at: local); try git(["commit", "-qm", "base"], at: local)
            try git(["clone", "--bare", "-q", local.path, remote.path], at: root)
            try git(["remote", "add", "origin", remote.path], at: local)
            try git(["clone", "-q", remote.path, peer.path], at: root)
            if let ours = ours { try ours.write(to: local.appendingPathComponent(path)) }
            else { try FileManager.default.removeItem(at: local.appendingPathComponent(path)) }
            if !dirty { try git(["add", "."], at: local); try git(["commit", "-qm", "local"], at: local) }
            if let theirs = theirs { try theirs.write(to: peer.appendingPathComponent(path)) }
            else { try FileManager.default.removeItem(at: peer.appendingPathComponent(path)) }
            try Data("remote addition\n".utf8).write(to: peer.appendingPathComponent("remote-only.md"))
            try git(["add", "."], at: peer); try git(["commit", "-qm", "remote"], at: peer); try git(["push", "-q"], at: peer)
            try git(["fetch", "-q"], at: local)
            self.local = local; self.peer = peer
            self.project = Project(url: local); project.settings.gitOrigin = remote.path
        }
    }
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fsnotes-conflicts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let middle = (1...12).map { "common \($0)\n" }.joined()
        let base = "heading\nbase first\n" + middle + "base last\nend\n"
        let ours = base.replacingOccurrences(of: "base first", with: "local first").replacingOccurrences(of: "base last", with: "local last")
        let theirs = base.replacingOccurrences(of: "base first", with: "remote first").replacingOccurrences(of: "base last", with: "remote last")
        for dirty in [false, true] {
            let fixture = try Fixture(root: temp, base: Data(base.utf8), ours: Data(ours.utf8), theirs: Data(theirs.utf8), dirty: dirty)
            fixture.project.gitMergePending = true
            do { try fixture.project.synchronize(); try expect(false, "background sync entered an active workbench") }
            catch GitError.invalidSpec { checks += 1 }
            fixture.project.gitMergePending = false
            do { try fixture.project.synchronize(); try expect(false, "sync ignored the conflict") }
            catch GitError.uncommittedConflict { checks += 1 }
            catch GitError.unableToMerge { checks += 1 }
            let head = try git(["rev-parse", "HEAD"], at: fixture.local), status = try git(["status", "--porcelain"], at: fixture.local)
            let index = try Data(contentsOf: fixture.local.appendingPathComponent(".git/index"))
            let session = try GitMergeSession.prepare(project: fixture.project)!
            try expect(session.includesLocalEdits == dirty, "local source distinguishes working edits from committed content")
            try expect(session.files.count == 1, "one conflicted file")
            let document = session.files[0].document!
            try expect(document.hunks.count == 2, "both distinct conflicts are available")
            try expect(try git(["rev-parse", "HEAD"], at: fixture.local) == head, "preparation does not move HEAD")
            try expect(try Data(contentsOf: fixture.local.appendingPathComponent(".git/index")) == index, "preparation preserves the index")
            try expect(try git(["status", "--porcelain"], at: fixture.local) == status, "preparation preserves the worktree status")
            try expect(try String(contentsOf: fixture.local.appendingPathComponent("note.md"), encoding: .utf8) == ours, "no conflict markers are written")
            let unresolved = document.render(choices: [nil, .remote])
            do { try session.validate(.text(unresolved), file: 0); try expect(false, "unresolved document accepted") }
            catch GitError.invalidSpec { checks += 1 }
            let combined = document.render(choices: [.local, .remote])
            try expect(combined == base.replacingOccurrences(of: "base first", with: "local first").replacingOccurrences(of: "base last", with: "remote last"), "hunk choices retain the common text exactly")
            try session.finish(resolutions: [.text(combined)], signature: fixture.project.getSign())
            try expect(session.completed, "session is completed")
            try expect(try String(contentsOf: fixture.local.appendingPathComponent("note.md"), encoding: .utf8) == combined, "resolved content is installed")
            try expect(try git(["status", "--porcelain"], at: fixture.local).isEmpty, "resolved index is clean")
            try expect(try git(["rev-parse", "HEAD^2"], at: fixture.local) == git(["rev-parse", "HEAD"], at: fixture.peer), "merge includes the remote parent")
            try expect(FileManager.default.fileExists(atPath: fixture.local.appendingPathComponent("remote-only.md").path), "nonconflicting remote files are installed")
            try fixture.project.synchronize()
            try expect(try git(["rev-parse", "HEAD"], at: fixture.local) == git(["rev-parse", "origin/" + session.localBranch], at: fixture.local), "resolved merge is pushed")
            fixture.project.removeCommitsCache()
        }
        let stale = try Fixture(root: temp, base: Data(base.utf8), ours: Data(ours.utf8), theirs: Data(theirs.utf8))
        let staleSession = try GitMergeSession.prepare(project: stale.project)!
        let staleHead = try git(["rev-parse", "HEAD"], at: stale.local)
        try Data("new edits while the workbench was open".utf8).write(to: stale.local.appendingPathComponent("note.md"))
        do { try staleSession.finish(resolutions: [.local], signature: stale.project.getSign()); try expect(false, "stale merge was installed") }
        catch GitError.invalidSpec { checks += 1 }
        try expect(try git(["rev-parse", "HEAD"], at: stale.local) == staleHead, "stale resolution does not move HEAD")
        try expect(try String(contentsOf: stale.local.appendingPathComponent("note.md"), encoding: .utf8).hasPrefix("new edits"), "new editor changes survive")
        let rollback = try Fixture(root: temp, base: Data(base.utf8), ours: Data(ours.utf8), theirs: Data(theirs.utf8))
        let rollbackSession = try GitMergeSession.prepare(project: rollback.project)!
        let rollbackHead = try git(["rev-parse", "HEAD"], at: rollback.local)
        let rollbackIndex = try Data(contentsOf: rollback.local.appendingPathComponent(".git/index"))
        let referenceLock = rollback.local.appendingPathComponent(".git/refs/heads/" + rollbackSession.localBranch + ".lock")
        try Data().write(to: referenceLock)
        do { try rollbackSession.finish(resolutions: [.remote], signature: rollback.project.getSign()); try expect(false, "locked branch update unexpectedly succeeded") }
        catch GitError.unknownError { checks += 1 }
        try expect(!rollbackSession.completed, "failed checkout/ref update remains retryable")
        try expect(try git(["rev-parse", "HEAD"], at: rollback.local) == rollbackHead, "failed branch update preserves HEAD")
        try expect(try Data(contentsOf: rollback.local.appendingPathComponent(".git/index")) == rollbackIndex, "failed branch update restores the original index")
        try expect(try String(contentsOf: rollback.local.appendingPathComponent("note.md"), encoding: .utf8) == ours, "failed branch update restores local content")
        try expect(!FileManager.default.fileExists(atPath: rollback.local.appendingPathComponent("remote-only.md").path), "rollback removes only newly installed remote files")
        try FileManager.default.removeItem(at: referenceLock)
        try rollbackSession.finish(resolutions: [.local], signature: rollback.project.getSign())
        try expect(rollbackSession.completed, "a recovered session can be retried")
        for chooseDeletion in [false, true] {
            let deleted = try Fixture(root: temp, base: Data("base\n".utf8), ours: nil, theirs: Data("remote edit\n".utf8))
            let session = try GitMergeSession.prepare(project: deleted.project)!
            try expect(session.files[0].local == nil && session.files[0].document == nil, "delete/modify has whole-file choices")
            try session.finish(resolutions: [chooseDeletion ? .local : .remote], signature: deleted.project.getSign())
            try expect(FileManager.default.fileExists(atPath: deleted.local.appendingPathComponent("note.md").path) != chooseDeletion, "chosen deletion or content is retained")
        }
        let binary = try Fixture(root: temp, base: Data([0, 1, 2]), ours: Data([0, 3, 4]), theirs: Data([0, 5, 6]), path: "image.png")
        let binarySession = try GitMergeSession.prepare(project: binary.project)!
        try expect(binarySession.files[0].document == nil, "binary data is never parsed as text")
        try binarySession.finish(resolutions: [.remote], signature: binary.project.getSign())
        try expect(try Data(contentsOf: binary.local.appendingPathComponent("image.png")) == Data([0, 5, 6]), "binary resolution preserves exact bytes")
        let id = UUID().uuidString
        func manifest(_ name: String) throws -> Data {
            try JSONEncoder().encode(MetadataStore.Snapshot(notes: [.init(id: id, name: name, fileExtension: "md")]))
        }
        let localManifest = try manifest("Local"), remoteManifest = try manifest("Remote")
        let metadata = try Fixture(root: temp, base: manifest("Base"), ours: localManifest, theirs: remoteManifest, path: "metadata.json")
        let metadataSession = try GitMergeSession.prepare(project: metadata.project)!
        do { try metadataSession.finish(resolutions: [.text("{}")], signature: metadata.project.getSign()); try expect(false, "invalid metadata was installed") }
        catch is DecodingError { checks += 1 }
        catch is MetadataStore.Failure { checks += 1 }
        try expect(try Data(contentsOf: metadata.local.appendingPathComponent("metadata.json")) == localManifest, "invalid metadata leaves the library intact")
        try metadataSession.finish(resolutions: [.remote], signature: metadata.project.getSign())
        try expect(try Data(contentsOf: metadata.local.appendingPathComponent("metadata.json")) == remoteManifest, "valid metadata choice is installed")
        print("Git conflict workbench integration: \(checks) checks passed")
    }
}
