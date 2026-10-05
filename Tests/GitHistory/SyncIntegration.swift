import Foundation

@main struct SyncTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw NSError(domain: "SyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @discardableResult static func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Tests", "-c", "user.email=tests@example.com"] + arguments
        process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try expect(process.terminationStatus == 0, String(decoding: output, as: UTF8.self))
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
        print("Git sync integration: \(checks) checks passed")
    }
}
