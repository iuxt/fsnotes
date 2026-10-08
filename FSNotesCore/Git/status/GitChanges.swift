import Foundation
import Cgit2

/// Values copied out of libgit2, safe to display after the repository is closed.
struct GitChange: Equatable {
    enum Area { case staged, unstaged }
    enum Kind: String { case added = "A", modified = "M", deleted = "D", renamed = "R", typeChanged = "T", conflicted = "!", unreadable = "?" }
    let path: String
    let oldPath: String
    let area: Area
    let kind: Kind
    var identity: String { (area == .staged ? "index:" : "worktree:") + path }
    var canStage: Bool { kind != .conflicted && kind != .unreadable }
}

struct GitChangeSnapshot: Equatable {
    struct CommitSummary: Equatable {
        let summary: String
        let date: Date
    }
    let branch: String
    let changes: [GitChange]
    let operationPending: Bool
    let lastCommit: CommitSummary?
}

struct GitChangeDiff {
    struct Line {
        enum Kind { case context, added, removed, hunk, notice }
        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }
    let lines: [Line]
    let additions: Int
    let deletions: Int
    let binary: Bool
    let truncated: Bool
}

/// All calls run on the app's serial Git queue. Index operations never write the worktree.
enum GitChanges {
    static func snapshot(in repository: Repository) throws -> GitChangeSnapshot {
        var options = git_status_options()
        try check(git_status_options_init(&options, 1), "Initialize status options")
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repository.pointer.pointee, &options), "Read changed files")
        defer { git_status_list_free(list) }
        var changes = [GitChange]()
        for index in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, index) else { continue }
            let flags = entry.pointee.status.rawValue
            if flags & GIT_STATUS_CONFLICTED.rawValue != 0 {
                let delta = entry.pointee.index_to_workdir ?? entry.pointee.head_to_index
                if let delta = delta { append(delta, area: .unstaged, kind: .conflicted, to: &changes) }
                continue
            }
            let stagedFlags = GIT_STATUS_INDEX_NEW.rawValue | GIT_STATUS_INDEX_MODIFIED.rawValue | GIT_STATUS_INDEX_DELETED.rawValue
                | GIT_STATUS_INDEX_RENAMED.rawValue | GIT_STATUS_INDEX_TYPECHANGE.rawValue
            let workingFlags = GIT_STATUS_WT_NEW.rawValue | GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_DELETED.rawValue
                | GIT_STATUS_WT_RENAMED.rawValue | GIT_STATUS_WT_TYPECHANGE.rawValue | GIT_STATUS_WT_UNREADABLE.rawValue
            if let delta = entry.pointee.head_to_index, flags & stagedFlags != 0 {
                append(delta, area: .staged, kind: kind(flags: flags, staged: true), to: &changes)
            }
            if let delta = entry.pointee.index_to_workdir, flags & workingFlags != 0 {
                append(delta, area: .unstaged, kind: kind(flags: flags, staged: false), to: &changes)
            }
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var head: OpaquePointer?
        let result = git_repository_head(&head, repository.pointer.pointee)
        defer { git_reference_free(head) }
        let branch: String
        if result == GIT_EUNBORNBRANCH.rawValue {
            let reference = try repository.referenceLookup(name: "HEAD")
            let name = git_reference_symbolic_target(reference.pointer.pointee).map { String(cString: $0) } ?? "HEAD"
            branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst(11)) : name
        } else {
            try check(result, "Read branch")
            if git_reference_is_branch(head) == 1, let name = git_reference_shorthand(head) {
                branch = String(cString: name)
            } else if let oid = git_reference_target(head) {
                branch = "HEAD · " + String((OID(withGitOid: oid.pointee).sha() ?? "").prefix(8))
            } else { branch = "HEAD" }
        }
        let commit = result == GIT_EUNBORNBRANCH.rawValue ? nil : try repository.head().targetCommit()
        return GitChangeSnapshot(branch: branch, changes: changes,
            operationPending: git_repository_state(repository.pointer.pointee) != GIT_REPOSITORY_STATE_NONE.rawValue,
            lastCommit: commit.map { .init(summary: $0.summary, date: $0.date) })
    }

    private static func append(_ delta: UnsafePointer<git_diff_delta>, area: GitChange.Area,
                               kind: GitChange.Kind, to changes: inout [GitChange]) {
        guard let newPath = delta.pointee.new_file.path ?? delta.pointee.old_file.path else { return }
        let path = String(cString: newPath)
        // Match FSNotes' snapshot policy for trashed notes.
        guard path != ".Trash", !path.hasPrefix(".Trash/") else { return }
        let oldPath = delta.pointee.old_file.path.map { String(cString: $0) } ?? path
        changes.append(GitChange(path: path, oldPath: oldPath, area: area, kind: kind))
    }

    private static func kind(flags: UInt32, staged: Bool) -> GitChange.Kind {
        if flags & (staged ? GIT_STATUS_INDEX_RENAMED.rawValue : GIT_STATUS_WT_RENAMED.rawValue) != 0 { return .renamed }
        if flags & (staged ? GIT_STATUS_INDEX_DELETED.rawValue : GIT_STATUS_WT_DELETED.rawValue) != 0 { return .deleted }
        if flags & (staged ? GIT_STATUS_INDEX_NEW.rawValue : GIT_STATUS_WT_NEW.rawValue) != 0 { return .added }
        if flags & (staged ? GIT_STATUS_INDEX_TYPECHANGE.rawValue : GIT_STATUS_WT_TYPECHANGE.rawValue) != 0 { return .typeChanged }
        if !staged && flags & GIT_STATUS_WT_UNREADABLE.rawValue != 0 { return .unreadable }
        return .modified
    }

    private static func headTree(in repository: Repository) throws -> Tree? {
        let unborn = git_repository_head_unborn(repository.pointer.pointee)
        if unborn == 1 { return nil }
        try check(unborn, "Read HEAD")
        return try repository.head().targetCommit().tree()
    }

    static func diff(for change: GitChange, in repository: Repository) throws -> GitChangeDiff {
        let index = try Index(repository: repository)
        let tree = change.area == .staged ? try headTree(in: repository) : nil
        var options = git_diff_options()
        try check(git_diff_options_init(&options, 1), "Initialize diff options")
        options.context_lines = 3
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue | GIT_DIFF_INCLUDE_TYPECHANGE.rawValue | GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
        var diff: OpaquePointer?
        // Only compare the selected paths, including both sides of a rename.
        // Keep pathspec storage alive for the duration of the C call.
        let result = change.oldPath.withCString { oldPath in
            change.path.withCString { newPath in
                var paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: oldPath), UnsafeMutablePointer(mutating: newPath)]
                return paths.withUnsafeMutableBufferPointer { buffer in
                    options.pathspec = git_strarray(strings: buffer.baseAddress, count: buffer.count)
                    return change.area == .staged
                        ? git_diff_tree_to_index(&diff, repository.pointer.pointee, tree?.tree.pointee, index.idx.pointee, &options)
                        : git_diff_index_to_workdir(&diff, repository.pointer.pointee, index.idx.pointee, &options)
                }
            }
        }
        try check(result, "Compare file contents")
        defer { git_diff_free(diff) }
        var findOptions = git_diff_find_options()
        try check(git_diff_find_options_init(&findOptions, 1), "Initialize rename options")
        findOptions.flags = GIT_DIFF_FIND_RENAMES.rawValue | GIT_DIFF_FIND_FOR_UNTRACKED.rawValue
        try check(git_diff_find_similar(diff, &findOptions), "Find renamed files")
        for offset in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, offset) else { continue }
            let path = delta.pointee.new_file.path.map { String(cString: $0) }
            let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
            guard path == change.path || oldPath == change.path else { continue }
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, offset), "Read file diff")
            defer { git_patch_free(patch) }
            var additions = 0, deletions = 0, context = 0
            if let patch = patch {
                try check(git_patch_line_stats(&context, &additions, &deletions, patch), "Read diff summary")
            }
            var lines = [GitChangeDiff.Line]()
            let limit = 8000
            var truncated = false
            if let patch = patch {
                hunks: for hunkIndex in 0..<git_patch_num_hunks(patch) {
                    var hunk: UnsafePointer<git_diff_hunk>?
                    var count = 0
                    try check(git_patch_get_hunk(&hunk, &count, patch, hunkIndex), "Read diff section")
                    if let hunk = hunk {
                        let h = hunk.pointee
                        lines.append(.init(kind: .hunk, text: "@@ −\(h.old_start),\(h.old_lines) +\(h.new_start),\(h.new_lines) @@",
                                           oldNumber: nil, newNumber: nil))
                    }
                    for lineIndex in 0..<count {
                        if lines.count >= limit { truncated = true; break hunks }
                        var line: UnsafePointer<git_diff_line>?
                        try check(git_patch_get_line_in_hunk(&line, patch, hunkIndex, lineIndex), "Read diff line")
                        guard let value = line?.pointee, let content = value.content else { continue }
                        let text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(content).assumingMemoryBound(to: UInt8.self),
                                                                        count: value.content_len), as: UTF8.self)
                        let kind: GitChangeDiff.Line.Kind
                        switch value.origin { case 43: kind = .added; case 45: kind = .removed; case 32: kind = .context; default: kind = .notice }
                        lines.append(.init(kind: kind, text: text.hasSuffix("\n") ? String(text.dropLast()) : text,
                                           oldNumber: value.old_lineno > 0 ? Int(value.old_lineno) : nil,
                                           newNumber: value.new_lineno > 0 ? Int(value.new_lineno) : nil))
                    }
                }
            }
            return GitChangeDiff(lines: lines, additions: additions, deletions: deletions,
                binary: delta.pointee.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0, truncated: truncated)
        }
        return GitChangeDiff(lines: [], additions: 0, deletions: 0, binary: false, truncated: false)
    }

    static func stage(_ changes: [GitChange], in repository: Repository) throws {
        try requireWritable(repository)
        let current = try snapshot(in: repository).changes
        let index = try Index(repository: repository)
        for change in changes {
            guard change.area == .unstaged, change.canStage, current.contains(change) else {
                throw GitError.invalidSpec(spec: "The file status changed. Refresh the changes list and try again.")
            }
            if change.kind == .deleted {
                try check(git_index_remove_bypath(index.idx.pointee, change.path), "Stage deleted file")
            } else {
                try check(git_index_add_bypath(index.idx.pointee, change.path), "Stage file")
                if change.kind == .renamed {
                    try check(git_index_remove_bypath(index.idx.pointee, change.oldPath), "Stage rename")
                }
            }
        }
        try index.save()
    }

    static func unstage(_ changes: [GitChange], in repository: Repository) throws {
        try requireWritable(repository)
        let current = try snapshot(in: repository).changes
        let tree = try headTree(in: repository)
        let index = try Index(repository: repository)
        for change in changes {
            guard change.area == .staged, current.contains(change) else {
                throw GitError.invalidSpec(spec: "The file status changed. Refresh the changes list and try again.")
            }
            for path in Set([change.path, change.oldPath]) {
                if let entry = try tree?.entry(byPath: path) {
                    var value = git_index_entry()
                    value.id = git_tree_entry_id(entry.pointer.pointee).pointee
                    value.mode = git_tree_entry_filemode(entry.pointer.pointee).rawValue
                    try path.withCString { pointer in
                        value.path = pointer
                        try check(git_index_add(index.idx.pointee, &value), "Unstage file")
                    }
                } else {
                    let result = git_index_remove_bypath(index.idx.pointee, path)
                    if result != GIT_ENOTFOUND.rawValue { try check(result, "Unstage new file") }
                }
            }
        }
        try index.save()
    }

    static func commit(message: String, signature: Signature, in repository: Repository) throws {
        try requireWritable(repository)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitError.invalidSpec(spec: "Enter a commit message first.") }
        guard try snapshot(in: repository).changes.contains(where: { $0.area == .staged }) else { throw GitError.noAddedFiles }
        let index = try Index(repository: repository)
        if try headTree(in: repository) == nil {
            _ = try index.createInitialCommit(msg: message, signature: signature)
        } else {
            _ = try index.createCommit(msg: message, signature: signature)
        }
    }

    private static func requireWritable(_ repository: Repository) throws {
        try repository.requireCompletedOperation()
        let index = try Index(repository: repository)
        guard !index.conflicts else { throw GitError.invalidSpec(spec: "Resolve Git conflicts before staging or committing.") }
    }

    private static func check(_ result: Int32, _ message: String) throws {
        guard result == 0 else { throw gitUnknownError(message, code: result) }
    }
}
