import Foundation
import Cgit2

/// A paused merge owns a detached index. Preparing or editing it changes no
/// working files, on-disk index entries, or branch references.
final class GitMergeSession {
    struct Version {
        let path: String
        let data: Data
        let mode: UInt32
        var text: String? {
            guard data.count <= 2_000_000, !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
    struct File {
        let path: String
        let paths: Set<String>
        let local: Version?
        let remote: Version?
        let document: GitConflictDocument?
    }
    enum Resolution { case local, remote, text(String) }
    let files: [File]
    let localBranch: String
    let remoteBranch: String
    let localSHA: String
    let remoteSHA: String
    let includesLocalEdits: Bool
    let fingerprint: String
    private(set) var completed = false
    private let repository: Repository
    private let original: Commit
    private let local: Commit
    private let remote: Commit
    private let workingTree: Tree
    private let mergeIndex: Index
    private let indexURL: URL
    private let indexData: Data?
    private let indexSignature: [String]
    private let branchReference: String

    private init(repository: Repository, original: Commit, local: Commit, remote: Commit,
                 workingTree: Tree, mergeIndex: Index, files: [File], indexURL: URL, indexData: Data?,
                 branch: Branch, remoteBranch: Branch, indexSignature: [String]) {
        self.repository = repository; self.original = original; self.local = local; self.remote = remote
        self.workingTree = workingTree; self.mergeIndex = mergeIndex; self.files = files
        self.indexURL = indexURL; self.indexData = indexData; self.branchReference = branch.name
        self.indexSignature = indexSignature
        self.localBranch = branch.shortName; self.remoteBranch = remoteBranch.shortName
        self.localSHA = original.oid.sha() ?? ""; self.remoteSHA = remote.oid.sha() ?? ""
        self.includesLocalEdits = local.oid.sha() != original.oid.sha()
        self.fingerprint = [localSHA, remoteSHA, Self.treeSHA(workingTree)].joined(separator: ":")
    }

    static func prepare(project: Project) throws -> GitMergeSession? {
        let repository = try project.getRepository()
        let branch = try repository.currentBranch()
        let remote = try repository.branches.get(name: "origin/" + branch.shortName, type: .remote)
        let session = try prepare(repository: repository, remoteBranch: remote, signature: project.getSign())
        return session.files.isEmpty ? nil : session
    }

    /// Automatic merges use the same validation, checkout and rollback as resolved conflicts.
    static func merge(repository: Repository, remoteBranch: Branch, signature: Signature) throws {
        let session = try prepare(repository: repository, remoteBranch: remoteBranch, signature: signature)
        guard session.files.isEmpty else {
            throw GitError.unableToMerge(msg: "Conflicting files: " + session.files.map { $0.paths.sorted().joined(separator: ", ") }.joined(separator: ", ")
                + ". Resolve the merge with an external Git client before syncing again.")
        }
        try session.finish(resolutions: [], signature: signature)
    }

    private static func prepare(repository: Repository, remoteBranch: Branch, signature: Signature) throws -> GitMergeSession {
        try repository.requireCompletedOperation()
        let branch = try repository.currentBranch()
        let original = try branch.targetCommit(), remote = try remoteBranch.targetCommit()
        guard let directory = git_repository_path(repository.pointer.pointee) else {
            throw GitError.notFound(ref: "Git directory")
        }
        let indexURL = URL(fileURLWithPath: String(cString: directory)).appendingPathComponent("index")
        let indexData = try readIndex(at: indexURL)
        let indexSignature = try signatureOfIndex(repository: repository)
        let workingTree = try snapshot(repository: repository)
        let originalTree = try original.tree()
        let local = treeSHA(workingTree) == treeSHA(originalTree) ? original
            : try detachedCommit(repository: repository, tree: workingTree, parents: [original],
                                 signature: signature, message: "Local edits before merging")
        let index = try mergedIndex(repository: repository, local: local, remote: remote)
        let files = try conflicts(repository: repository, index: index)
        return GitMergeSession(repository: repository, original: original, local: local, remote: remote,
                               workingTree: workingTree, mergeIndex: index, files: files,
                               indexURL: indexURL, indexData: indexData, branch: branch, remoteBranch: remoteBranch, indexSignature: indexSignature)
    }

    /// Validation is also used when confirming one file, before enabling sync.
    func validate(_ resolution: Resolution, file: Int) throws {
        guard files.indices.contains(file) else { throw GitError.invalidSpec(spec: "Unknown conflict file") }
        let item = files[file]
        if case .text(let text) = resolution {
            guard item.document != nil, !GitConflictDocument.containsMarkers(text) else {
                throw GitError.invalidSpec(spec: "Resolve every conflict marker before confirming the file")
            }
        }
        if item.paths.contains("metadata.json") {
            guard let version = version(for: resolution, file: item), version.path == "metadata.json" else {
                throw GitError.invalidSpec(spec: "The library metadata cannot be deleted")
            }
            try MetadataStore.validateMergedData(version.data)
        }
    }

    func finish(resolutions: [Resolution], signature: Signature) throws {
        guard !completed, resolutions.count == files.count else {
            throw GitError.invalidSpec(spec: "Confirm all conflicted files before continuing")
        }
        try requireUnchangedRepository()
        // Rebuild on every attempt. A failed validation must not damage the session.
        let index = try Self.mergedIndex(repository: repository, local: local, remote: remote)
        for (number, resolution) in resolutions.enumerated() {
            try validate(resolution, file: number)
            let file = files[number]
            for path in file.paths {
                let result = git_index_conflict_remove(index.idx.pointee, path)
                guard result == GIT_OK.rawValue || result == GIT_ENOTFOUND.rawValue else {
                    throw gitUnknownError("Unable to resolve " + path, code: result)
                }
            }
            if let selected = version(for: resolution, file: file) {
                var entry = git_index_entry(), oid = git_oid()
                try Self.check(selected.data.withUnsafeBytes {
                    git_blob_create_frombuffer(&oid, repository.pointer.pointee, $0.baseAddress, selected.data.count)
                }, "Unable to save merged content")
                entry.id = oid; entry.mode = selected.mode
                try selected.path.withCString { path in
                    entry.path = path
                    try Self.check(git_index_add(index.idx.pointee, &entry), "Unable to stage merged content")
                }
            }
        }
        guard !index.conflicts else { throw GitError.invalidSpec(spec: "Unresolved index entries remain") }
        let tree = try repository.write(index: index)
        // Validate the complete manifest too: automatic nonconflicting changes can
        // combine into an invalid metadata graph even when each input is valid.
        if let metadata = try tree.entry(byPath: "metadata.json") {
            guard let id = git_tree_entry_id(metadata.pointer.pointee),
                  git_tree_entry_filemode(metadata.pointer.pointee) == GIT_FILEMODE_BLOB else {
                throw GitError.invalidSpec(spec: "Invalid library metadata file")
            }
            try MetadataStore.validateMergedData(try repository.blobLookup(oid: OID(withGitOid: id.pointee)).rawContent)
        } else if try workingTree.entry(byPath: "metadata.json") != nil {
            throw GitError.invalidSpec(spec: "The library metadata cannot be deleted")
        }
        let commit = try Self.detachedCommit(repository: repository, tree: tree, parents: [local, remote],
                                             signature: signature, message: files.isEmpty ? "Merge branch '" + remoteBranch + "'" : "Resolve sync conflicts with " + remoteBranch)
        let backups = try changedFiles(target: tree)
        var options = git_checkout_options()
        try Self.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)), "Unable to prepare checkout")
        options.baseline = workingTree.tree.pointee
        options.checkout_strategy = GIT_CHECKOUT_NONE.rawValue | GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue | GIT_CHECKOUT_DONT_WRITE_INDEX.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        try Self.check(git_checkout_tree(repository.pointer.pointee, tree.tree.pointee, &options), "Merged files cannot be checked out safely")
        try requireUnchangedRepository()
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        do {
            try Self.check(git_checkout_tree(repository.pointer.pointee, tree.tree.pointee, &options), "Unable to install merged files")
            var reference: OpaquePointer?, oid = commit.oid.oid, oldOID = original.oid.oid
            defer { git_reference_free(reference) }
            try Self.check(git_reference_create_matching(&reference, repository.pointer.pointee, branchReference,
                                                        &oid, 1, &oldOID, "FSNotes: resolve sync conflicts"),
                           "The branch changed while installing the merge")
            completed = true
        } catch {
            // Restore only files touched by this checkout, including raw LFS
            // images and original permissions, rather than rewriting the library.
            do {
                for backup in backups { try backup.restore() }
                if let indexData = indexData { try indexData.write(to: indexURL, options: .atomic) }
                else if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
            } catch let recovery {
                throw GitError.invalidSpec(spec: "Merge installation failed and recovery failed: " + recovery.localizedDescription)
            }
            throw error
        }
    }

    private func version(for resolution: Resolution, file: File) -> Version? {
        switch resolution {
        case .local: return file.local
        case .remote: return file.remote
        case .text(let text):
            guard let source = file.local ?? file.remote else { return nil }
            return Version(path: source.path, data: Data(text.utf8), mode: source.mode)
        }
    }

    private func requireUnchangedRepository() throws {
        try repository.requireCompletedOperation()
        let branchChanged = try repository.currentBranch().name != branchReference
            || repository.head().targetCommit().oid.sha() != original.oid.sha()
        let indexChanged = try Self.signatureOfIndex(repository: repository) != indexSignature
        let notesChanged = try Self.treeSHA(Self.snapshot(repository: repository)) != Self.treeSHA(workingTree)
        guard !branchChanged && !indexChanged && !notesChanged else {
            let changed = branchChanged ? "Git branch" : indexChanged ? "Git index" : "notes"
            throw GitError.invalidSpec(spec: "The " + changed + " changed while resolving conflicts. Close this window and sync again to compare the latest versions.")
        }
    }

    private static func signatureOfIndex(repository: Repository) throws -> [String] {
        let index = try repository.head().index()
        try index.reload()
        return (0..<git_index_entrycount(index.idx.pointee)).compactMap { number in
            guard let entry = git_index_get_byindex(index.idx.pointee, number) else { return nil }
            return "\(String(cString: entry.pointee.path)):\(OID(withGitOid: entry.pointee.id).sha() ?? ""):\(entry.pointee.mode):\(entry.pointee.flags & 0xf000):\(entry.pointee.flags_extended)"
        }
    }

    private static func snapshot(repository: Repository) throws -> Tree {
        let index = try repository.head().index()
        try index.reload()
        guard !index.conflicts else { throw GitError.invalidSpec(spec: "Finish the pending external Git merge first") }
        let wrapper = StringWrapper(withStrs: ["."])
        var paths = git_strarray(strings: wrapper.pointer, count: wrapper.count)
        // Never call Index.add here: it writes the on-disk index.
        try check(git_index_add_all(index.idx.pointee, &paths, 0, Index.gitIndexCallback, nil), "Unable to snapshot local edits")
        return try repository.write(index: index)
    }

    private static func mergedIndex(repository: Repository, local: Commit, remote: Commit) throws -> Index {
        let pointer = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        let result = git_merge_commits(pointer, repository.pointer.pointee, local.pointer.pointee, remote.pointer.pointee, nil)
        guard result == GIT_OK.rawValue else {
            pointer.deinitialize(count: 1); pointer.deallocate()
            throw gitUnknownError("Unable to prepare the conflict workbench", code: result)
        }
        return Index(repository: repository, idx: pointer)
    }

    private static func conflicts(repository: Repository, index: Index) throws -> [File] {
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index.idx.pointee), "Unable to read conflict files")
        defer { git_index_conflict_iterator_free(iterator) }
        var files = [File]()
        while true {
            var base: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirs: UnsafePointer<git_index_entry>?
            let result = git_index_conflict_next(&base, &ours, &theirs, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result, "Unable to read conflict files")
            func version(_ entry: UnsafePointer<git_index_entry>?) throws -> Version? {
                guard let entry = entry else { return nil }
                let path = String(cString: entry.pointee.path)
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      !path.split(separator: "/").contains(".git"), entry.pointee.mode != GIT_FILEMODE_COMMIT.rawValue else {
                    throw GitError.invalidSpec(spec: "Unsupported conflicted path: " + path)
                }
                return Version(path: path, data: try repository.blobLookup(oid: OID(withGitOid: entry.pointee.id)).rawContent,
                               mode: entry.pointee.mode)
            }
            let local = try version(ours), remote = try version(theirs)
            let paths = Set([base, ours, theirs].compactMap { $0.map { String(cString: $0.pointee.path) } })
            guard let path = local?.path ?? remote?.path ?? paths.sorted().first else { continue }
            var document: GitConflictDocument?
            if let local = local, let remote = remote, local.path == remote.path,
               local.mode == remote.mode, [GIT_FILEMODE_BLOB.rawValue, GIT_FILEMODE_BLOB_EXECUTABLE.rawValue].contains(local.mode),
               local.text != nil, remote.text != nil,
               GitLFS.Pointer(pointer: local.data) == nil, GitLFS.Pointer(pointer: remote.data) == nil {
                var options = git_merge_file_options(), merged = git_merge_file_result()
                try check(git_merge_file_options_init(&options, UInt32(GIT_MERGE_FILE_OPTIONS_VERSION)), "Unable to compare file versions")
                let localLabel = "FSNotes-local-" + UUID().uuidString, remoteLabel = "FSNotes-remote-" + UUID().uuidString
                options.marker_size = 32
                let result = localLabel.withCString { localPointer in remoteLabel.withCString { remotePointer in
                    options.our_label = localPointer; options.their_label = remotePointer
                    return git_merge_file_from_index(&merged, repository.pointer.pointee, base, ours, theirs, &options)
                } }
                defer { git_merge_file_result_free(&merged) }
                try check(result, "Unable to compare file versions")
                if let bytes = merged.ptr, let text = String(data: Data(bytes: bytes, count: merged.len), encoding: .utf8) {
                    document = try GitConflictDocument(text: text, markerSize: 32, localLabel: localLabel, remoteLabel: remoteLabel)
                }
            }
            files.append(File(path: path, paths: paths, local: local, remote: remote, document: document))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func detachedCommit(repository: Repository, tree: Tree, parents: [Commit], signature: Signature, message: String) throws -> Commit {
        let pointer = UnsafeMutablePointer<UnsafeMutablePointer<git_signature>?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer { git_signature_free(pointer.pointee); pointer.deinitialize(count: 1); pointer.deallocate() }
        try signature.now(sig: pointer)
        var oid = git_oid()
        var parents = parents.map { $0.pointer.pointee }
        try parents.withUnsafeMutableBufferPointer {
            try check(git_commit_create(&oid, repository.pointer.pointee, nil, pointer.pointee, pointer.pointee,
                                        "UTF-8", message, tree.tree.pointee, $0.count, $0.baseAddress), "Unable to prepare merge commit")
        }
        return try repository.commitLookup(oid: OID(withGitOid: oid))
    }

    private struct Backup {
        let url: URL
        let data: Data?
        let link: String?
        let permissions: NSNumber?
        func restore() throws {
            let manager = FileManager.default
            if let link = link {
                if (try? manager.attributesOfItem(atPath: url.path)) != nil { try manager.removeItem(at: url) }
                try manager.createSymbolicLink(atPath: url.path, withDestinationPath: link)
            } else if let data = data {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if let permissions = permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            } else if (try? manager.attributesOfItem(atPath: url.path)) != nil { try manager.removeItem(at: url) }
        }
    }
    private func changedFiles(target: Tree) throws -> [Backup] {
        var diff: OpaquePointer?
        try Self.check(git_diff_tree_to_tree(&diff, repository.pointer.pointee, workingTree.tree.pointee, target.tree.pointee, nil), "Unable to inspect merged changes")
        defer { git_diff_free(diff) }
        guard let root = git_repository_workdir(repository.pointer.pointee) else { throw GitError.notFound(ref: "Working directory") }
        let rootURL = URL(fileURLWithPath: String(cString: root))
        var paths = Set<String>()
        for index in 0..<git_diff_num_deltas(diff) {
            if let delta = git_diff_get_delta(diff, index) {
                for path in [delta.pointee.old_file.path, delta.pointee.new_file.path].compactMap({ $0 }) { paths.insert(String(cString: path)) }
            }
        }
        return try paths.sorted().map { path in
            let url = rootURL.appendingPathComponent(path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let link = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
                ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
            return Backup(url: url, data: attributes == nil || link != nil ? nil : try Data(contentsOf: url),
                          link: link, permissions: attributes?[.posixPermissions] as? NSNumber)
        }
    }
    private static func treeSHA(_ tree: Tree) -> String {
        OID(withGitOid: git_tree_id(tree.tree.pointee).pointee).sha() ?? ""
    }
    private static func readIndex(at url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    private static func check(_ code: Int32, _ message: String) throws {
        guard code == GIT_OK.rawValue else { throw gitUnknownError(message, code: code) }
    }
}
