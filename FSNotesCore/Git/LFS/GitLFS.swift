import Foundation
import CryptoKit
import Cgit2
import FSNotesGitFilters

/// libgit2 does not run Git's external clean/smudge drivers or pre-push hooks.
/// Store standard LFS pointers and objects locally, and explicitly transfer them.
enum GitLFS {
    static let version = "version https://git-lfs.github.com/spec/v1"

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

    static func transfer(_ arguments: [String], in root: URL, sshKey: URL? = nil) throws {
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
        // A sandbox has no system-wide `git lfs install` configuration. Supply
        // filters for this invocation so `pull` also checks out downloaded images.
        process.arguments = [
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
        if let key = sshKey, manager.isReadableFile(atPath: key.path) {
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -oBatchMode=yes -i '" + key.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("Git LFS " + arguments.joined(separator: " ") + ": " + String(decoding: data, as: UTF8.self))
        }
#else
        throw failure("Image LFS transfers require the macOS Git LFS client. Local image commits remain available.")
#endif
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GitLFS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
