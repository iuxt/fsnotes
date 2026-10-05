//
//  Repository.swift
//  Git2Swift
//
//  Created by Damien Giron on 31/07/2016.
//  Copyright © 2016 Creabox. All rights reserved.
//

import Foundation
import Cgit2

/// Repository wrapping a libgit2 repository
public class Repository {
    
    /// Repository URL
    public let url : URL
    
    /// Repository manager
    private let manager : RepositoryManager
    
    /// Libgit2 pointer to repository
    internal let pointer : UnsafeMutablePointer<OpaquePointer?>
    
    /// Branches manager
    lazy public private(set) var branches : Branches = {
        Branches(repository: self)
    } ()
    
    /// Statuses manager
    lazy public private(set) var statuses : Statuses = {
        Statuses(repository: self)
    } ()
    
    /// Access tags manager
    lazy public private(set) var tags : Tags = {
        Tags(repository: self)
    } ()
    
    lazy public private(set) var remotes : Remotes = {
        Remotes(repository: self)
    } ()
    
    /// Constructor with repository manager and libgit2 repository
    ///
    /// - parameter url:        URL repository
    /// - parameter manager:    Repository manager
    /// - parameter repository: Libgit2 repository
    ///
    /// - returns: Repository
    init(at url: URL, manager: RepositoryManager, repository: UnsafeMutablePointer<OpaquePointer?>) {
        self.url = url
        self.manager = manager
        self.pointer = repository
    }
    
    deinit {
        if let ptr = pointer.pointee {
            git_repository_free(ptr)
        }
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    
    /// Retrieve head
    ///
    /// - throws: GitError
    ///
    /// - returns: Head
    public func head() throws -> Head {
        // Create head
        return try Head(repository: self, name: "HEAD", pointer: try gitReferenceLookup(repository: pointer, name: "HEAD"))
    }

    /// Retrieve the local branch referenced by HEAD.
    public func currentBranch() throws -> Branch {
        let reference = try head().targetReference()
        return try branches.get(spec: reference.name)
    }
    
    /// Get the index for the repo. The caller is responsible for freeing the index.
    func unsafeIndex() -> Result<OpaquePointer, NSError> {
        guard let ptr = pointer.pointee else { return .failure(NSError()) }
        
        var index: OpaquePointer? = nil
        let result = git_repository_index(&index, ptr)
        guard result == GIT_OK.rawValue && index != nil else {
            let err = NSError(gitError: result, pointOfFailure: "git_repository_index")
            return .failure(err)
        }
        return .success(index!)
    }
    
    public func add(path: String) -> Result<(), NSError> {
        guard pointer.pointee != nil else { return .failure(NSError()) }
        
        var dirPointer = UnsafeMutablePointer<Int8>(mutating: (path as NSString).utf8String)
        var paths = withUnsafeMutablePointer(to: &dirPointer) {
            git_strarray(strings: $0, count: 1)
        }
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            let addResult = git_index_add_all(index, &paths, 0, nil, nil)
            guard addResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: addResult, pointOfFailure: "git_index_add_all"))
            }
            // write index to disk
            let writeResult = git_index_write(index)
            guard writeResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
            }
            return .success(())
        }
    }
    
    public func addRemoteOrigin(path: String) throws {
        var remote: OpaquePointer?
        var result = git_remote_lookup(&remote, self.pointer.pointee, "origin")
        if result == GIT_ENOTFOUND.rawValue {
            result = git_remote_create(&remote, self.pointer.pointee, "origin", path)
        } else if result == GIT_OK.rawValue {
            result = git_remote_set_url(self.pointer.pointee, "origin", path)
        }
        defer { git_remote_free(remote) }
        guard result == GIT_OK.rawValue else { throw gitUnknownError("Unable to configure origin", code: result) }
        var refspecs = git_strarray()
        defer { git_strarray_dispose(&refspecs) }
        result = git_remote_get_fetch_refspecs(&refspecs, remote)
        if result == GIT_OK.rawValue, refspecs.count == 0 {
            result = git_remote_add_fetch(self.pointer.pointee, "origin", "+refs/heads/*:refs/remotes/origin/*")
        }
        guard result == GIT_OK.rawValue else { throw gitUnknownError("Unable to configure origin fetch", code: result) }
    }
    
    /// Read a saved file without touching the working tree, index, or HEAD.
    public func fileContent(commit: Commit, path: String) throws -> Data {
        let (_, entry) = try fileEntry(commit: commit, path: path)
        guard let id = git_tree_entry_id(entry.pointer.pointee) else {
            throw GitError.notFound(ref: path)
        }
        return try blobLookup(oid: OID(withGitOid: id.pointee)).rawContent
    }

    private func fileEntry(commit: Commit, path: String) throws -> (Tree, TreeEntry) {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw GitError.invalidSpec(spec: path)
        }
        let tree = try commit.tree()
        guard let entry = try tree.entry(byPath: path) else {
            throw GitError.notFound(ref: path)
        }
        guard git_tree_entry_type(entry.pointer.pointee) == GIT_OBJECT_BLOB,
              git_tree_entry_filemode(entry.pointer.pointee) != GIT_FILEMODE_LINK else {
            throw GitError.invalidSpec(spec: path)
        }
        return (tree, entry)
    }

    public func checkout(commit: Commit, path: String) throws {
        let (tree, _) = try fileEntry(commit: commit, path: path)

        // Keep the C strings and array alive throughout checkout. Treat the path
        // literally (including brackets and '*') and leave HEAD and the index intact.
        let error = path.withCString { pathPointer -> Int32 in
            var mutablePath: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: pathPointer)
            return withUnsafeMutablePointer(to: &mutablePath) { strings in
                var opts = git_checkout_options()
                opts.version = 1
                opts.paths = git_strarray(strings: strings, count: 1)
                opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                    | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                    | GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue
                return git_checkout_tree(self.pointer.pointee, tree.tree.pointee, &opts)
            }
        }
        if error != 0 {
            throw gitUnknownError("Unable to checkout commit path", code: error)
        }
    }
}
