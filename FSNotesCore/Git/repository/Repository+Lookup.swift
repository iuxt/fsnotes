//
//  Repository+Lookup.swift
//  Git2Swift
//
//  Created by Dami on 31/07/2016.
//
//

import Foundation
import Cgit2

/// Git reference lookup
///
/// - parameter repository: Libgit2 repository pointer
/// - parameter name:       Reference name
///
/// - throws: GitError
///
/// - returns: Libgit2 reference pointer
internal func gitReferenceLookup(repository: UnsafeMutablePointer<OpaquePointer?>,
                                 name: String) throws -> UnsafeMutablePointer<OpaquePointer?> {
    
    // Find reference pointer
    let reference = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
    
    // Lookup reference
    let error = git_reference_lookup(reference, repository.pointee, name)
    if (error != 0) {
        
        reference.deinitialize(count: 1)
        reference.deallocate()
        
        // 0 on success, GIT_ENOTFOUND, GIT_EINVALIDSPEC or an error code.
        switch (error) {
        case GIT_ENOTFOUND.rawValue :
            throw GitError.notFound(ref: name)
        case GIT_EINVALIDSPEC.rawValue:
            throw GitError.invalidSpec(spec: name)
        default:
            throw gitUnknownError("Unable to lookup reference \(name)", code: error)
        }
    }
    
    return reference
}

// MARK: - Repository extension for lookup
extension Repository {

    /// Resolve a full or abbreviated commit ID. References and tree IDs are rejected.
    public func commitLookup(sha: String) throws -> Commit {
        let sha = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...40).contains(sha.count),
              sha.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw GitError.invalidSHA(sha: sha)
        }

        var object: OpaquePointer?
        let result = git_revparse_single(&object, pointer.pointee, sha)
        guard result == 0, let object = object else {
            throw gitUnknownError("Unable to resolve commit \(sha)", code: result)
        }
        defer { git_object_free(object) }
        guard git_object_type(object) == GIT_OBJECT_COMMIT,
              let oid = git_object_id(object) else {
            throw GitError.invalidSHA(sha: sha)
        }
        return try commitLookup(oid: OID(withGitOid: oid.pointee))
    }

    /// Read history directly from Git, without relying on the on-disk diff cache.
    public func fileHistory(path: String) throws -> [Commit] {
        let unborn = git_repository_head_unborn(pointer.pointee)
        if unborn == 1 { return [] }
        guard unborn == 0 else { throw gitUnknownError("Unable to read HEAD", code: unborn) }
        var walker: OpaquePointer?
        var result = git_revwalk_new(&walker, pointer.pointee)
        guard result == 0 else { throw gitUnknownError("Unable to read history", code: result) }
        defer { git_revwalk_free(walker) }
        git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
        result = git_revwalk_push_head(walker)
        if result == GIT_EUNBORNBRANCH.rawValue || result == GIT_ENOTFOUND.rawValue { return [] }
        guard result == 0 else { throw gitUnknownError("Unable to read HEAD", code: result) }

        var commits = [Commit]()
        var oid = git_oid()
        while true {
            result = git_revwalk_next(&oid, walker)
            if result == GIT_ITEROVER.rawValue { break }
            guard result == 0 else { throw gitUnknownError("Unable to read history", code: result) }
            let commit = try commitLookup(oid: OID(withGitOid: oid))
            let tree = try commit.tree()
            // Deleted files have no content to restore at this commit.
            guard let entry = try tree.entry(byPath: path) else { continue }
            if git_commit_parentcount(commit.pointer.pointee) == 0 {
                commits.append(commit)
                continue
            }
            guard let parentID = git_commit_parent_id(commit.pointer.pointee, 0) else { continue }
            let parent = try commitLookup(oid: OID(withGitOid: parentID.pointee))
            let parentTree = try parent.tree()
            let parentEntry = try parentTree.entry(byPath: path)
            if let parentEntry = parentEntry,
               git_oid_equal(git_tree_entry_id(entry.pointer.pointee), git_tree_entry_id(parentEntry.pointer.pointee)) == 1,
               git_tree_entry_filemode(entry.pointer.pointee) == git_tree_entry_filemode(parentEntry.pointer.pointee) {
                continue
            }
            commits.append(commit)
        }
        return commits
    }

    /// Lookup reference
    ///
    /// - parameter name: Refrence name
    ///
    /// - throws: GitError
    ///
    /// - returns: Refernce
    public func referenceLookup(name: String) throws -> Reference {
        return try Reference(repository: self, name: name, pointer: try gitReferenceLookup(repository: pointer, name: name))
    }

    /// Lookup a tree
    ///
    /// - parameter tree_id: Tree OID
    ///
    /// - throws: GitError
    ///
    /// - returns: Tree
    public func treeLookup(oid tree_id: OID) throws -> Tree {
        
        // Create tree
        let tree : UnsafeMutablePointer<OpaquePointer?> = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        
        var oid = tree_id.oid
        let error = git_tree_lookup(tree, pointer.pointee, &oid)
        if (error != 0) {
            
            tree.deinitialize(count: 1)
            tree.deallocate()
            
            throw gitUnknownError("Unable to lookup tree", code: error)
        }
        
        return Tree(repository: self, tree: tree)
    }
    
    /// Lookup a commit
    ///
    /// - parameter commit_id: OID
    ///
    /// - throws: GitError
    ///
    /// - returns: Commit
    public func commitLookup(oid commit_id: OID) throws -> Commit {
        
        // Create tree
        let commit : UnsafeMutablePointer<OpaquePointer?> = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        
        var oid = commit_id.oid
        let error = git_commit_lookup(commit, pointer.pointee, &oid)
        if (error != 0) {
            
            commit.deinitialize(count: 1)
            commit.deallocate()
            
            throw gitUnknownError("Unable to lookup commit", code: error)
        }
        
        return Commit(repository: self, pointer: commit, oid: OID(withGitOid: oid))
    }

    /// Lookup a blob
    ///
    /// - parameter blob_id: OID
    ///
    /// - throws: GitError
    ///
    /// - returns: Blob
    public func blobLookup(oid blob_id: OID) throws -> Blob {

        // Create tree
        let blob : UnsafeMutablePointer<OpaquePointer?> = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)

        var oid = blob_id.oid
        let error = git_blob_lookup(blob, pointer.pointee, &oid)
        if error != 0 {

            blob.deinitialize(count: 1)
            blob.deallocate()

            throw gitUnknownError("Unable to lookup blob", code: error)
        }

        return Blob(blob: blob)
    }
}
