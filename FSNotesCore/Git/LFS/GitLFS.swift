import Foundation
import CryptoKit
import Security
import Cgit2
import FSNotesGitFilters
#if os(macOS)
import AppKit
#endif

/// libgit2 does not run Git's external clean/smudge drivers or pre-push hooks.
/// Store standard LFS pointers and objects locally, and explicitly transfer them.
enum GitLFS {
    static let version = "version https://git-lfs.github.com/spec/v1"

#if os(macOS)
    struct SSHHost: Equatable {
        let hostname: String
        let port: Int
        var knownHostsName: String { port == 22 ? hostname : "[\(hostname)]:\(port)" }
        var displayName: String { "\(hostname):\(port)" }

        init?(origin: String) {
            let remote: URL?
            if origin.contains("://") {
                remote = URL(string: origin)
                guard remote?.scheme == "ssh" else { return nil }
            } else {
                // SCP-style remotes have a host before the colon; local paths do not.
                guard let separator = origin.firstIndex(of: ":"),
                      !origin[..<separator].contains("/") else { return nil }
                remote = URL(string: "ssh://" + origin[..<separator] + "/")
            }
            guard let rawHost = remote?.host else { return nil }
            let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
                ? String(rawHost.dropFirst().dropLast()) : rawHost
            guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }) else { return nil }
            let port = remote?.port ?? 22
            guard (1...65535).contains(port) else { return nil }
            hostname = host.lowercased()
            self.port = port
        }
    }

    struct SSHHostKey: Equatable {
        let algorithm: String
        let encoded: String
        let fingerprint: String
    }

    private static let sshTrustLock = NSLock()

    private static func runSSHHelper(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func scannedSSHHostKeys(_ output: String) throws -> [SSHHostKey] {
        var keys = [SSHHostKey]()
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            guard fields.count == 3, let data = Data(base64Encoded: String(fields[2])), data.count > 4 else {
                throw failure(NSLocalizedString("Unable to read the SSH server's host keys.", comment: ""))
            }
            let typeLength = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard typeLength > 0, typeLength < data.count - 4,
                  String(data: data[4..<(4 + typeLength)], encoding: .utf8) == String(fields[1]) else {
                throw failure(NSLocalizedString("Unable to read the SSH server's host keys.", comment: ""))
            }
            let fingerprint = "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let key = SSHHostKey(algorithm: String(fields[1]), encoded: String(fields[2]), fingerprint: fingerprint)
            if !keys.contains(key) { keys.append(key) }
        }
        guard !keys.isEmpty else {
            throw failure(NSLocalizedString("Unable to read the SSH server's host keys.", comment: ""))
        }
        return keys.sorted { $0.algorithm < $1.algorithm }
    }

    static func scanSSHHost(_ host: SSHHost) throws -> [SSHHostKey] {
        let (status, output) = try runSSHHelper("/usr/bin/ssh-keyscan",
            ["-T", "5", "-p", String(host.port), "-t", "ed25519,ecdsa,rsa", host.hostname])
        guard status == 0 else {
            throw failure(NSLocalizedString("Unable to read the SSH server's host keys.", comment: "") + " " + host.displayName + "\n" + output)
        }
        return try scannedSSHHostKeys(output)
    }

    private static func confirmSSHHost(_ host: SSHHost, keys: [SSHHostKey]) -> Bool {
        let showAlert = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("Trust SSH Server?", comment: "")
            alert.informativeText = host.displayName + "\n\n"
                + NSLocalizedString("This is your first connection to this SSH server. Check its fingerprints before allowing the connection. FSNotes will remember the approved host keys.", comment: "")
                + "\n\n" + keys.map { $0.algorithm + "\n" + $0.fingerprint }.joined(separator: "\n\n")
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Allow", comment: ""))
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertSecondButtonReturn
        }
        return Thread.isMainThread ? showAlert() : DispatchQueue.main.sync(execute: showAlert)
    }

    /// Pin only the keys shown in the approval dialog. SSH verifies them again
    /// on the actual authenticated connection, closing the scan-to-connect race.
    static func ensureSSHHostTrust(_ host: SSHHost, file: URL,
                                  scan: (SSHHost) throws -> [SSHHostKey],
                                  confirm: (SSHHost, [SSHHostKey]) -> Bool) throws {
        sshTrustLock.lock()
        defer { sshTrustLock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .atomic)
        }
        let (status, _) = try runSSHHelper("/usr/bin/ssh-keygen", ["-F", host.knownHostsName, "-f", file.path])
        if status == 0 { return }
        guard status == 1 else {
            throw failure(NSLocalizedString("Unable to read FSNotes' saved SSH host keys.", comment: ""))
        }
        let keys = try scan(host)
        guard !keys.isEmpty, confirm(host, keys) else {
            throw failure(NSLocalizedString("SSH server trust was cancelled. Sync stopped.", comment: ""))
        }
        var contents = try String(contentsOf: file, encoding: .utf8)
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += keys.map { host.knownHostsName + " " + $0.algorithm + " " + $0.encoded + "\n" }.joined()
        try Data(contents.utf8).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func sshCommand(knownHosts: URL, key: URL?) -> String {
        // OpenSSH parses this option as a list of filenames after shell parsing.
        // Preserve config-level quotes for paths such as "Application Support".
        let knownHostsValue = "\"" + knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        var arguments = ["/usr/bin/ssh", "-F", "/dev/null", "-oBatchMode=yes",
                         "-oUserKnownHostsFile=" + knownHostsValue, "-oGlobalKnownHostsFile=/dev/null",
                         "-oStrictHostKeyChecking=yes", "-oUpdateHostKeys=no", "-oIdentitiesOnly=yes"]
        if let key = key {
            arguments += ["-i", key.path]
        } else {
            arguments += ["-oIdentityFile=none"]
        }
        return arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
#endif

    struct Pointer {
        let oid: String
        let size: Int
        var data: Data { Data("\(version)\noid sha256:\(oid)\nsize \(size)\n".utf8) }
        init(data: Data) {
            oid = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            size = data.count
        }
        init?(pointer: Data) {
            guard pointer.count < 1024, let text = String(data: pointer, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\n")
            guard lines.count == 4, lines[0] == version, lines[1].hasPrefix("oid sha256:"),
                  lines[2].hasPrefix("size "), lines[3].isEmpty else { return nil }
            let hash = String(lines[1].dropFirst(11))
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let count = Int(lines[2].dropFirst(5)), count >= 0 else { return nil }
            oid = hash; size = count
        }
        func objectURL(in gitDirectory: URL) -> URL {
            gitDirectory.appendingPathComponent("lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
        }
    }

    static func clean(_ data: Data, gitDirectory: URL) throws -> Data {
        if Pointer(pointer: data) != nil { return data }
        let pointer = Pointer(data: data)
        let object = pointer.objectURL(in: gitDirectory)
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: object, options: .atomic)
        return pointer.data
    }

    static func smudge(_ data: Data, gitDirectory: URL) throws -> Data {
        guard let pointer = Pointer(pointer: data) else { return data }
        // A missing object stays a pointer until the explicit LFS fetch/checkout.
        let object = pointer.objectURL(in: gitDirectory)
        guard FileManager.default.fileExists(atPath: object.path) else { return data }
        let content = try Data(contentsOf: object)
        guard content.count == pointer.size, Pointer(data: content).oid == pointer.oid else {
            throw failure("Git LFS object failed SHA-256 verification: " + pointer.oid)
        }
        return content
    }

    /// Called under RepositoryManager's initialization lock before any Git use.
    static func registerFilter() {
        guard git_filter_lookup("lfs") == nil else { return }
        let filter = UnsafeMutablePointer<git_filter>.allocate(capacity: 1)
        filter.initialize(to: git_filter())
        filter.pointee.version = 1
        filter.pointee.attributes = UnsafePointer(strdup("filter=lfs"))
        filter.pointee.shutdown = { filter in
            guard let filter = filter else { return }
            free(UnsafeMutablePointer(mutating: filter.pointee.attributes))
            filter.deinitialize(count: 1)
            filter.deallocate()
        }
        filter.pointee.apply = { _, _, output, input, source in
            guard let output = output, let input = input, let source = source,
                  let repository = git_filter_source_repo(source), let path = git_repository_path(repository) else { return -1 }
            do {
                let data = input.pointee.size == 0 ? Data() : Data(bytes: input.pointee.ptr, count: input.pointee.size)
                let directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                let result = try git_filter_source_mode(source) == GIT_FILTER_TO_ODB
                    ? GitLFS.clean(data, gitDirectory: directory) : GitLFS.smudge(data, gitDirectory: directory)
                return result.withUnsafeBytes { git_buf_set(output, $0.baseAddress, result.count) }
            } catch {
                _ = error.localizedDescription.withCString { git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), $0) }
                return -1
            }
        }
        let result = git_filter_register("lfs", filter, 200)
        precondition(result == 0, "Unable to register the Git LFS filter")
    }

    /// Accept only PEM certificates, never keys or arbitrary surrounding text.
    static func normalizedCACertificates(_ pem: String) throws -> String {
        var remaining = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        var certificates = [String]()
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        while !remaining.isEmpty {
            guard remaining.hasPrefix(begin), let endRange = remaining.range(of: end) else {
                throw failure("Paste CA certificates in PEM format, including BEGIN CERTIFICATE and END CERTIFICATE.")
            }
            let body = remaining[remaining.index(remaining.startIndex, offsetBy: begin.count)..<endRange.lowerBound]
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: String(body)),
                  SecCertificateCreateWithData(nil, data as CFData) != nil else {
                throw failure("The CA certificate is invalid. Paste a PEM certificate, not a private key.")
            }
            certificates.append(begin + "\n" + data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n" + end + "\n")
            remaining = String(remaining[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return certificates.joined()
    }

    /// Command-scoped configuration reaches Git LFS and its Git subprocesses
    /// without relying on global config or writing certificate paths to a repo.
    static func certificateConfiguration(_ pem: String, origin: String, file: URL) throws -> [String] {
        let normalized = try normalizedCACertificates(pem)
        guard !normalized.isEmpty else { return [] }
        let host: String?
        var httpsPort: Int?
        if origin.contains("://") {
            let remote = URL(string: origin)
            host = remote?.host
            if remote?.scheme == "https" { httpsPort = remote?.port }
        } else if let separator = origin.firstIndex(of: ":") {
            // SCP-style Git remotes: git@example.com:owner/repo.git.
            host = origin[..<separator].split(separator: "@").last.map(String.init)
        } else {
            host = nil
        }
        guard let host = host, !host.isEmpty,
              let url = URL(string: "https://" + host + "/"), url.host == host else {
            throw failure("A remote repository hostname is required to use a custom CA certificate.")
        }
        try Data(normalized.utf8).write(to: file, options: .atomic)
        let authority = host + (httpsPort.map { ":\($0)" } ?? "")
        return ["-c", "http.https://\(authority)/.sslCAInfo=\(file.path)"]
    }

    static func transfer(_ arguments: [String], in root: URL, sshKey: URL? = nil,
                         caCertificates: String? = nil, origin: String? = nil) throws {
        // No LFS work is required for a repository with no image objects or pointers.
        let images = root.appendingPathComponent("images")
        let objects = root.appendingPathComponent(".git/lfs/objects")
        let manager = FileManager.default
        let hasImages = (manager.enumerator(atPath: images.path)?.nextObject() != nil)
        let hasObjects = (manager.enumerator(atPath: objects.path)?.nextObject() != nil)
        guard hasImages || hasObjects else { return }
#if os(macOS)
        // External Homebrew executables are inaccessible from the app sandbox.
        // The build embeds and signs this helper with sandbox inheritance.
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "git-lfs"),
              let git = Bundle.main.url(forAuxiliaryExecutable: "git"),
              manager.isExecutableFile(atPath: executable.path),
              manager.isExecutableFile(atPath: git.path) else {
            throw failure("The app's bundled Git LFS client is missing. Reinstall FSNotes to sync images.")
        }
        let process = Process()
        process.executableURL = git
        // Keep each transfer's CA bundle in the app sandbox for its full lifetime.
        let certificateDirectory = manager.temporaryDirectory.appendingPathComponent("FSNotes-CA-" + UUID().uuidString)
        defer { try? manager.removeItem(at: certificateDirectory) }
        var configuration = [String]()
        if let pem = caCertificates, !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try manager.createDirectory(at: certificateDirectory, withIntermediateDirectories: true)
            configuration = try certificateConfiguration(pem, origin: origin ?? "",
                file: certificateDirectory.appendingPathComponent("ca.pem"))
        }
        // A sandbox has no system-wide `git lfs install` configuration. Supply
        // filters for this invocation so `pull` also checks out downloaded images.
        process.arguments = configuration + [
            "-c", "filter.lfs.clean=git-lfs clean -- %f",
            "-c", "filter.lfs.smudge=git-lfs smudge -- %f",
            "-c", "filter.lfs.process=git-lfs filter-process",
            "-c", "filter.lfs.required=true",
            "lfs"
        ] + arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        // LFS launches Git and may launch itself again for local transfers or
        // filters. Finder's PATH does not include the app's helper directory.
        environment["PATH"] = executable.deletingLastPathComponent().path
            + ":/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["GIT_EXEC_PATH"] = executable.deletingLastPathComponent().path
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let origin = origin, let host = SSHHost(origin: origin),
           let action = arguments.first, ["push", "pull", "fetch"].contains(action) {
            guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw failure(NSLocalizedString("Unable to read FSNotes' saved SSH host keys.", comment: ""))
            }
            let knownHosts = support.appendingPathComponent("FSNotes/SSH/known_hosts")
            try ensureSSHHostTrust(host, file: knownHosts, scan: scanSSHHost, confirm: confirmSSHHost)
            environment["GIT_SSH_COMMAND"] = sshCommand(knownHosts: knownHosts, key: sshKey)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self)
            if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                throw failure(NSLocalizedString("The SSH server's host key has changed. Sync stopped to protect your connection.", comment: "") + "\n" + message)
            }
            throw failure("Git LFS " + arguments.joined(separator: " ") + ": " + message)
        }
#else
        throw failure("Image LFS transfers require the macOS Git LFS client. Local image commits remain available.")
#endif
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GitLFS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
