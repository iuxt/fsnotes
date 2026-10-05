import Foundation
import Cgit2

@main struct LFSTests {
    // Public test CA only; no private key is stored in the fixture.
    static let ca = """
    -----BEGIN CERTIFICATE-----
    MIIBaTCCAQ6gAwIBAgIUMvxljAu6gBPvHBl/VMWYcb5XIOkwCgYIKoZIzj0EAwIw
    GjEYMBYGA1UEAwwPRlNOb3Rlcy1UZXN0LUNBMB4XDTI2MTAwNTE1MTMxOVoXDTM2
    MTAwMjE1MTMxOVowGjEYMBYGA1UEAwwPRlNOb3Rlcy1UZXN0LUNBMFkwEwYHKoZI
    zj0CAQYIKoZIzj0DAQcDQgAEwYVBYCxOc+7M8WHDX1lc+M1Z2mXAkkENfZKmKh7+
    pozOXMG7ipPn5BXver40fglyLormgMUVqAU+fg4gh9KVq6MyMDAwHQYDVR0OBBYE
    FDQUshevm85onKjrvXYsfK9gBktPMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0E
    AwIDSQAwRgIhAOTvogarzr3jPLlFwiTedZf4wUdTKc3EA4aM7cGxX6WZAiEAxa8M
    UcdA8buDD5NrsnpavZIlsAjuF20Qqs/0yGV8qdY=
    -----END CERTIFICATE-----
    """
    static var checks = 0

    static func testSSHHostTrust(in root: URL) throws {
        let encoded = "AAAAC3NzaC1lZDI1NTE5AAAAIBmdQtZh4K0IX2cu53XWakZMvhZYNwWPEiIY+cyyD5/f"
        let host = GitLFS.SSHHost(origin: "ssh://git@git.example.com:2222/owner/repo.git")!
        try expect(host.hostname == "git.example.com" && host.port == 2222, "SSH URL retains its custom port")
        try expect(GitLFS.SSHHost(origin: "git@git.example.com:owner/repo.git")?.port == 22, "SCP remote uses SSH port 22")
        try expect(GitLFS.SSHHost(origin: "ssh://git@[::1]:2222/owner/repo.git")?.hostname == "::1", "IPv6 SSH host is unbracketed for scanning")
        try expect(GitLFS.SSHHost(origin: "/tmp/repo.git") == nil && GitLFS.SSHHost(origin: "https://git.example.com/repo.git") == nil,
                   "non-SSH remotes do not trigger trust prompts")
        let keys = try GitLFS.scannedSSHHostKeys("# SSH-2.0-test\n[git.example.com]:2222 ssh-ed25519 " + encoded + "\n")
        try expect(keys.count == 1 && keys[0].fingerprint == "SHA256:g3rDTul/7kFkLISaF2lE+fMiDhqQrL+ctjt/woo1UmA",
                   "displayed SHA-256 fingerprint matches OpenSSH")
        do {
            _ = try GitLFS.scannedSSHHostKeys("git.example.com ssh-ed25519 YWJj\n")
            try expect(false, "malformed scanned key accepted")
        } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        let file = root.appendingPathComponent("SSH trust test/known_hosts")
        do {
            try GitLFS.ensureSSHHostTrust(host, file: file, scan: { _ in keys }, confirm: { _, _ in false })
            try expect(false, "cancelled host trust was accepted")
        } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        try expect(try Data(contentsOf: file).isEmpty, "cancel does not remember unapproved host keys")
        var prompts = 0
        try GitLFS.ensureSSHHostTrust(host, file: file, scan: { _ in keys }, confirm: { promptedHost, promptedKeys in
            prompts += 1
            return promptedHost == host && promptedKeys == keys
        })
        try expect(prompts == 1, "first connection asks approval for the exact scanned keys")
        let approved = try Data(contentsOf: file)
        try expect(String(decoding: approved, as: UTF8.self) == "[git.example.com]:2222 ssh-ed25519 " + encoded + "\n",
                   "approved keys are saved with the host and port")
        try GitLFS.ensureSSHHostTrust(host, file: file, scan: { _ in
            throw NSError(domain: "LFSTests", code: 1)
        }, confirm: { _, _ in prompts += 1; return false })
        try expect(prompts == 1 && (try Data(contentsOf: file)) == approved, "later connections reuse persisted trust without rescanning or prompting")
        let otherPort = GitLFS.SSHHost(origin: "ssh://git@git.example.com:2223/repo.git")!
        do {
            try GitLFS.ensureSSHHostTrust(otherPort, file: file, scan: { _ in keys }, confirm: { _, _ in prompts += 1; return false })
            try expect(false, "another port inherited trust")
        } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        try expect(prompts == 2 && (try Data(contentsOf: file)) == approved, "a different SSH port needs its own approval")

        // Ask real OpenSSH to expand the production command, including a path
        // containing spaces and a quote. No user's SSH files may be consulted.
        let key = root.appendingPathComponent("test key's file")
        try Data("test key placeholder".utf8).write(to: key)
        let command = GitLFS.sshCommand(knownHosts: file, key: key)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " -G -p 2222 git@git.example.com"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let config = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "sandboxed OpenSSH accepts the generated command")
        try expect(config.contains("userknownhostsfile " + file.path), "SSH reads the app's saved host keys")
        try expect(config.contains("globalknownhostsfile /dev/null") && config.contains("stricthostkeychecking true"),
                   "unknown or changed host keys remain blocked")
        try expect(config.contains("identityfile " + key.path) && config.contains("identitiesonly yes"), "SSH uses the app's private key with correctly quoted paths")
        try expect(!config.contains("/.ssh/known_hosts"), "SSH does not access the user's inaccessible known_hosts file")

        // Complete a real SSH handshake against the runner's loopback server.
        // The server deliberately rejects all authentication after key exchange.
        let port = ProcessInfo.processInfo.environment["FSNOTES_TEST_SSH_PORT"]!
        let loopback = GitLFS.SSHHost(origin: "ssh://127.0.0.1:" + port + "/repo.git")!
        let loopbackFile = root.appendingPathComponent("SSH trust test/loopback_hosts")
        var loopbackPrompts = 0
        try GitLFS.ensureSSHHostTrust(loopback, file: loopbackFile, scan: GitLFS.scanSSHHost, confirm: { _, scanned in
            loopbackPrompts += 1
            return scanned.count == 1 && scanned[0].algorithm == "ssh-ed25519"
        })
        try expect(loopbackPrompts == 1, "real server's first connection requests approval")
        func connect() throws -> String {
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/bin/sh")
            ssh.arguments = ["-c", GitLFS.sshCommand(knownHosts: loopbackFile, key: nil)
                + " -oConnectTimeout=5 -p " + port + " 127.0.0.1 true"]
            let output = Pipe(); ssh.standardOutput = output; ssh.standardError = output
            try ssh.run()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ssh.waitUntilExit()
            try expect(ssh.terminationStatus == 255, "fixture rejects SSH authentication")
            return result
        }
        let acceptedOutput = try connect()
        try expect(acceptedOutput.contains("Permission denied") && !acceptedOutput.contains("Host key verification failed")
                   && !acceptedOutput.contains("Operation not permitted"), "real SSH accepts the approved key inside the sandbox: " + acceptedOutput)
        let loopbackApproved = try Data(contentsOf: loopbackFile)
        // Substitute a different well-formed public key for the same endpoint.
        try Data((loopback.knownHostsName + " ssh-ed25519 " + encoded + "\n").utf8).write(to: loopbackFile, options: .atomic)
        try GitLFS.ensureSSHHostTrust(loopback, file: loopbackFile, scan: GitLFS.scanSSHHost, confirm: { _, _ in
            loopbackPrompts += 1; return true
        })
        let changedOutput = try connect()
        try expect(changedOutput.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") && loopbackPrompts == 1,
                   "changed server key is rejected without silently replacing trust or asking to reapprove")
        try Data().write(to: loopbackFile, options: .atomic)
        try expect(try connect().contains("Host key verification failed"), "OpenSSH blocks a server whose keys were not approved")
        try loopbackApproved.write(to: loopbackFile, options: .atomic)
    }
    static func testLFSAuthentication(in root: URL, knownHosts: URL) throws {
        let port = ProcessInfo.processInfo.environment["FSNOTES_TEST_SSH_PORT"]!
        let branch = try git(["branch", "--show-current"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let lfs = Process()
        lfs.executableURL = Bundle.main.url(forAuxiliaryExecutable: "git")!
        lfs.currentDirectoryURL = root
        lfs.arguments = ["-c", "remote.origin.url=ssh://127.0.0.1:" + port + "/repo.git", "lfs", "push", "origin", branch]
        var lfsEnvironment = ProcessInfo.processInfo.environment
        let helpers = lfs.executableURL!.deletingLastPathComponent().path
        lfsEnvironment["PATH"] = helpers + ":/usr/bin:/bin:/usr/sbin:/sbin"
        lfsEnvironment["GIT_EXEC_PATH"] = helpers
        lfsEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        lfsEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        lfsEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        lfsEnvironment["GIT_SSH_COMMAND"] = GitLFS.sshCommand(knownHosts: knownHosts, key: nil)
        lfs.environment = lfsEnvironment
        let lfsPipe = Pipe(); lfs.standardOutput = lfsPipe; lfs.standardError = lfsPipe
        try lfs.run()
        let lfsOutput = String(decoding: lfsPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lfs.waitUntilExit()
        try expect(lfs.terminationStatus != 0 && lfsOutput.contains("Permission denied")
                   && !lfsOutput.contains("Host key verification failed") && !lfsOutput.contains("Operation not permitted"),
                   "bundled Git LFS uses the same approved keys when obtaining SSH credentials: " + lfsOutput)
    }
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

    static func testCACertificates(in root: URL) throws {
        let normalized = try GitLFS.normalizedCACertificates(ca)
        try expect(try GitLFS.normalizedCACertificates("\r\n" + ca.replacingOccurrences(of: "\n", with: "\r\n") + "\n") == normalized,
                   "pasted CRLF certificate is normalized")
        try expect(try GitLFS.normalizedCACertificates(ca + "\n" + ca) == normalized + normalized,
                   "CA bundles accept multiple certificates")
        try expect(try GitLFS.normalizedCACertificates(" \n") == "", "empty certificate clears the setting")
        for invalid in ["not a certificate", "-----BEGIN CERTIFICATE-----\nYWJj\n-----END CERTIFICATE-----", ca + "\n-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----"] {
            do {
                _ = try GitLFS.normalizedCACertificates(invalid)
                try expect(false, "invalid PEM or private key accepted")
            } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        }
        let settings = ProjectSettings()
        settings.gitCACertificates = normalized
        let archive = try NSKeyedArchiver.archivedData(withRootObject: settings, requiringSecureCoding: true)
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: ProjectSettings.self, from: archive)
        try expect(restored?.gitCACertificates == normalized, "CA setting survives secure settings archive")
        settings.gitCACertificates = nil
        let cleared = try NSKeyedArchiver.archivedData(withRootObject: settings, requiringSecureCoding: true)
        try expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: ProjectSettings.self, from: cleared)?.gitCACertificates == nil,
                   "cleared CA stays cleared after reopening settings")

        let file = root.appendingPathComponent(".git/ca-test.pem")
        defer { try? FileManager.default.removeItem(at: file) }
        for origin in ["ssh://git@git.example.com:2222/owner/repo.git", "git@git.example.com:owner/repo.git", "https://git.example.com/owner/repo.git"] {
            let config = try GitLFS.certificateConfiguration(ca, origin: origin, file: file)
            try expect(try Data(contentsOf: file) == Data(normalized.utf8), "CA bundle can be read inside the sandbox")
            try expect(try git(config + ["config", "--get-urlmatch", "http.sslCAInfo", "https://git.example.com/owner/repo.git/info/lfs"], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines) == file.path, "real Git selects CA for the remote's HTTPS hostname")
            try expect(try git(["-c", "http.sslCAInfo=/default-ca.pem"] + config + ["config", "--get-urlmatch", "http.sslCAInfo", "https://other.example.com/"], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "/default-ca.pem", "other domains retain their default CA config")
        }
        let portConfig = try GitLFS.certificateConfiguration(ca, origin: "https://git.example.com:8443/owner/repo.git", file: file)
        try expect(try git(portConfig + ["config", "--get-urlmatch", "http.sslCAInfo", "https://git.example.com:8443/owner/repo.git/info/lfs"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines) == file.path, "HTTPS remotes retain their custom HTTPS port")
        // LFS initializes its own standard repository settings on first use.
        try GitLFS.transfer(["ls-files"], in: root)
        let configBefore = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        func temporaryBundles() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("FSNotes-CA-") })
        }
        let bundlesBefore = try temporaryBundles()
        try GitLFS.transfer(["ls-files"], in: root, caCertificates: ca, origin: "git@git.example.com:owner/repo.git")
        try expect(try temporaryBundles() == bundlesBefore, "successful LFS process removes its temporary CA bundle")
        do {
            try GitLFS.transfer(["invalid-fsnotes-command"], in: root, caCertificates: ca, origin: "git@git.example.com:owner/repo.git")
            try expect(false, "invalid LFS command unexpectedly succeeded")
        } catch let error as NSError where error.domain == "GitLFS" { checks += 1 }
        try expect(try temporaryBundles() == bundlesBefore, "failed LFS process also removes its temporary CA bundle")
        try expect(try Data(contentsOf: root.appendingPathComponent(".git/config")) == configBefore, "custom CA leaves repository config unchanged")
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
        try testSSHHostTrust(in: temp)
        try testCACertificates(in: root)
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
        try testLFSAuthentication(in: root, knownHosts: temp.appendingPathComponent("SSH trust test/loopback_hosts"))
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
