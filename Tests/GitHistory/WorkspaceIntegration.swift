import Foundation

@main struct WorkspaceTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() {
            throw NSError(domain: "WorkspaceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        try expect(false, "Invalid workspace must be rejected")
    }

    @discardableResult static func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        let executable = Bundle.main.url(forAuxiliaryExecutable: "git")!
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_EXEC_PATH"] = executable.deletingLastPathComponent().path
        process.environment = environment
        process.arguments = ["-c", "user.name=Tests", "-c", "user.email=tests@example.com"] + arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func expectRepositoryRoot(_ root: URL) throws {
        let workdir = try git(["rev-parse", "--show-toplevel"], in: root)
        var relationship = FileManager.URLRelationship.other
        try FileManager.default.getRelationship(&relationship, ofDirectoryAt: root,
            toItemAt: URL(fileURLWithPath: workdir))
        try expect(relationship == .same, "Repository is colocated with the selected folder")
    }

    static func main() throws {
        let files = FileManager.default
        let temp = files.temporaryDirectory.appendingPathComponent("fsnotes-workspace-" + UUID().uuidString)
        try files.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temp) }
        let manager = RepositoryManager()

        let root = temp.appendingPathComponent("新资料库 with spaces")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let draft = root.appendingPathComponent("draft.md")
        try "existing draft".write(to: draft, atomically: true, encoding: .utf8)
        let attributes = root.appendingPathComponent(".gitattributes")
        try "*.md text".write(to: attributes, atomically: true, encoding: .utf8)
        try manager.prepareWorkspace(at: root)
        try expect(try String(contentsOf: draft, encoding: .utf8) == "existing draft", "Initialization retains existing files")
        try expectRepositoryRoot(root)
        try expect(try git(["config", "--local", "--get", "filter.lfs.required"], in: root) == "true",
                   "LFS is installed locally even without images")
        try expect(try git(["config", "--local", "--get", "filter.lfs.clean"], in: root) == "git-lfs clean -- %f",
                   "External Git clients receive the LFS clean filter")
        let hook = root.appendingPathComponent(".git/hooks/pre-push")
        let hookMode = try files.attributesOfItem(atPath: hook.path)[.posixPermissions] as? Int ?? 0
        try expect(hookMode & 0o111 != 0, "The local pre-push hook has executable permissions")
        try expect(try String(contentsOf: hook, encoding: .utf8).contains("git lfs pre-push"),
                   "The local hook invokes Git LFS")
        try expect(try String(contentsOf: attributes, encoding: .utf8) == "*.md text\nimages/** filter=lfs diff=lfs merge=lfs -text\n",
                   "Recursive image tracking preserves existing attributes")

        let store = try MetadataStore(root: root)
        let project = Project(url: root)
        project.metadataStore = store
        defer { project.removeCommitsCache() }
        try project.commit(message: "First notes")
        try expect(try git(["show", "HEAD:metadata.json"], in: root).contains("\"notes\""),
                   "The opened workspace can save notes and metadata immediately")
        try expect(try git(["status", "--porcelain"], in: root).isEmpty, "First snapshot leaves a clean workspace")

        // Existing history, local config, staged changes and untracked files are untouched.
        try git(["remote", "add", "origin", "ssh://example.com/notes.git"], in: root)
        try "staged change".write(to: draft, atomically: true, encoding: .utf8)
        try git(["add", "draft.md"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root)
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let rules = try Data(contentsOf: attributes)
        try manager.prepareWorkspace(at: root)
        try manager.prepareWorkspace(at: URL(fileURLWithPath: git(["rev-parse", "--show-toplevel"], in: root)))
        try expect(try git(["rev-parse", "HEAD"], in: root) == head, "Opening an existing repository creates no commit")
        try expect(try Data(contentsOf: root.appendingPathComponent(".git/config")) == config, "Existing configuration is unchanged")
        try expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Existing index is unchanged")
        try expect(try Data(contentsOf: attributes) == rules, "Opening retains existing tracking rules")
        try expect(try String(contentsOf: draft, encoding: .utf8) == "staged change", "Opening retains local edits")

        // Choosing a subfolder creates an independent repository, not the parent's history.
        let nested = root.appendingPathComponent("independent")
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.prepareWorkspace(at: nested)
        try expectRepositoryRoot(nested)

        let invalid = temp.appendingPathComponent("invalid")
        try files.createDirectory(at: invalid, withIntermediateDirectories: true)
        let invalidMarker = invalid.appendingPathComponent(".git")
        try "invalid git marker".write(to: invalidMarker, atomically: true, encoding: .utf8)
        try expectFailure { try manager.prepareWorkspace(at: invalid) }
        try expect(try String(contentsOf: invalidMarker, encoding: .utf8) == "invalid git marker", "Invalid .git is never replaced")

        let bare = temp.appendingPathComponent("bare.git")
        try git(["init", "--bare", "-q", bare.path], in: temp)
        try expectFailure { try manager.prepareWorkspace(at: bare) }
        try expect(!files.fileExists(atPath: bare.appendingPathComponent(".git").path), "Bare repositories are not reinitialized")

        // A tracking-rule write failure rolls back the newly created Git repo and permits retry.
        let retry = temp.appendingPathComponent("retry")
        let blockedAttributes = retry.appendingPathComponent(".gitattributes")
        try files.createDirectory(at: blockedAttributes, withIntermediateDirectories: true)
        try expectFailure { try manager.prepareWorkspace(at: retry) }
        try expect(!files.fileExists(atPath: retry.appendingPathComponent(".git").path), "Failed initialization leaves no partial Git repository")
        try expect(files.fileExists(atPath: blockedAttributes.path), "Failure retains the user's files")
        try files.removeItem(at: blockedAttributes)
        try manager.prepareWorkspace(at: retry)
        try expect(try git(["config", "--local", "--get", "filter.lfs.required"], in: retry) == "true", "Retry completes LFS initialization")

        print("Workspace integration: \(checks) checks passed")
    }
}
