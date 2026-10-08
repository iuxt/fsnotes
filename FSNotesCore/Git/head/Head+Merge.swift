//
//  Head+Merge.swift
//  Git2Swift
//
//  Created by Damien Giron on 08/08/2016.
//
//

import Foundation
import Cgit2

/// Merge type
///
/// - none:        No entries to merge
/// - upToDate:    All entries up to date
/// - fastForward: Fast forward
/// - normal:      Nomral merge
public enum MergeType {
    case none
    case upToDate
    case fastForward
    case normal
}

// MARK: - Head extension for merging
extension Head {

    /// Head analysis
    ///
    /// - parameter branch: branch to analysis
    ///
    /// - throws: GitError
    ///
    /// - returns: MergeType résult
    public func analysis(branch: Branch) throws -> MergeType {
        
        // Find oid
        var oid = try branch.targetCommit().oid
        
        // Find annotated commit
        let annotatedCommit = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        defer {
            if let ptr = annotatedCommit.pointee {
                git_annotated_commit_free(ptr)
            }
            annotatedCommit.deinitialize(count: 1)
            annotatedCommit.deallocate()
        }
        
        // Find annoted commit
        var error = git_annotated_commit_lookup(annotatedCommit, repository.pointer.pointee, &oid.oid)
        if (error != 0) {
            throw gitUnknownError("Analysis : unable to create annotated commit", code: error)
        }
        
        // Allow fast-forward or normal merge
        var preference : git_merge_preference_t = GIT_MERGE_PREFERENCE_NONE
        
        // Merge analysis
        var analysis = GIT_MERGE_ANALYSIS_NONE
        error = git_merge_analysis(&analysis, &preference, repository.pointer.pointee, annotatedCommit, 1)
        if (error != 0) {
            throw gitUnknownError("Unable to analysis", code: error)
        }
        
        /*
        print("GIT_MERGE_ANALYSIS_NONE : \(analysis.rawValue & GIT_MERGE_ANALYSIS_NONE.rawValue)")
        print("GIT_MERGE_ANALYSIS_NORMAL : \(analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue)")
        print("GIT_MERGE_ANALYSIS_UP_TO_DATE : \(analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue)")
        print("GIT_MERGE_ANALYSIS_FASTFORWARD : \(analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue)")
        print("GIT_MERGE_ANALYSIS_UNBORN : \(analysis.rawValue & GIT_MERGE_ANALYSIS_UNBORN.rawValue)")
        */
        
        // Test up to date
        if (analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0) {
            return .upToDate
        }
        
        // Test fast-froward
        if (analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0) {
            return .fastForward
        }
        
        // Test normal
        if (analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0) {
            return .normal
        }
        
        // Test none
        if (analysis.rawValue & GIT_MERGE_ANALYSIS_NONE.rawValue != 0) {
            return .none
        }
        
        throw GitError.notImplemented(msg: "Index iterator not implemented \(analysis.rawValue).")
    }

    /// Merge branch with signature
    ///
    /// - parameter branch:    branch to merge
    /// - parameter signature: signature for commiter
    /// - parameter progress: Progress object
    ///
    /// - throws: GitError
    ///
    /// - returns: True if branch is merged or false if conflicted files
    public func merge(branch: Branch, signature: Signature, progress: Progress? = nil) throws -> Bool {
        
        // Analysis branch
        let mergeType = try analysis(branch: branch)
        
        switch (mergeType) {
        case .upToDate:
            return true
        case .fastForward:
            try fastForward(branch: branch, signature: signature, progress: progress)
            return true
        case .normal:
            // Do not overwrite uncommitted edits while creating a merge commit.
            do { try checkout(tree: revTree(), type: .none, progress: progress) }
            catch { throw GitError.uncommittedConflict }
            return try normalMerge(branch: branch, signature: signature, progress: progress)
        case .none:
            throw GitError.unableToMerge(msg: "Unmergeable branch \(branch)")
        }
    }

    /// Internal fast forward
    ///
    /// - parameter branch:    branch to merge
    /// - parameter signature: signature for commiter
    /// - parameter progress: Progress object
    ///
    /// - throws: GitError
    private func fastForward(branch: Branch, signature: Signature, progress: Progress? = nil) throws {
        do {
            // Git pull can preserve edits to files untouched by the remote update.
            // Checkout first: a conflict must leave HEAD at its original commit.
            try checkout(tree: branch.revTree(), type: .safe, progress: progress)
            try targetReference().updateTargetCommit(commit: try branch.targetCommit(), message: "Merge '\(branch.name)': Fast forward")
        } catch {
            throw GitError.uncommittedConflict
        }
    }

    /// Internal normal merge
    ///
    /// - parameter branch:    branch to merge
    /// - parameter signature: signature for commiter
    /// - parameter progress: Progress object
    ///
    /// - throws: GitError
    ///
    /// - returns: True if branch is merged or false if conflicted files
    public func normalMerge(branch: Branch, signature: Signature, progress: Progress? = nil) throws -> Bool {
        try GitMergeSession.merge(repository: repository, remoteBranch: branch, signature: signature)
        return true
    }
}
