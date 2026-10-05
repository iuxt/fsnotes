//
//  Note+History.swift
//  FSNotes iOS
//
//  Created by Александр on 14.02.2022.
//  Copyright © 2022 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import Compression

extension Note {

    public func getGitPath(history: Bool = false) -> String {
        var path = name

        if let gitPath = getGitPathPrefix() {
            path = gitPath
        }

        return path
    }

    public func getGitPathPrefix() -> String? {
        guard let project = getGitProject() else { return nil }
        let root = project.url.standardizedFileURL.resolvingSymlinksInPath().path
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    public func hasGitRepository() -> Bool {
        return getGitProject() != nil
    }

    public func getGitProject() -> Project? {
        if let store = metadataStore { return project.storage.getProjectBy(url: store.root)?.getGitProject() }
        return project.getGitProject()
    }

    public func saveRevision() throws {
        guard hasGitRepository() else { return }
        guard let project = getGitProject() else { return }

        try project.saveRevision(commitMessage: nil)
    }

    public func dropRevisions() {
        do {
            if let repository = getRepositoryUrl() {
                try FileManager.default.removeItem(at: repository)
            }
        } catch {/*_*/}
    }

    public func restore(revision: Revision) {
        guard hasGitRepository() else { return }

        checkout(commit: revision.commit!)
        forceLoad()
    }

    public func listRevisions() -> [Revision] {
        guard hasGitRepository() else { return [Revision]() }

        var result = [Revision]()
        let commits = getCommits()
        for commit in commits {
            let timestamp = commit.date.timeIntervalSince1970
            result.append(Revision(timestamp: timestamp, commit: commit))
        }
        return result
    }

    private func getRepositoryUrl() -> URL? {
        guard let url = project.getHistoryURL() else { return nil }

        return url.appendingPathComponent(name)
    }

    public func moveHistory(src: URL, dst: URL) {
        let srcFileName = src.lastPathComponent
        let dstFileName = dst.lastPathComponent

        var srcProject = project.getHistoryURL()
        var dstProject = project.getHistoryURL()

        if let dstHistory = project.storage.getProjectBy(url: dst.deletingLastPathComponent())?.getHistoryURL() {

            if !FileManager.default.directoryExists(atUrl: dstHistory) {
                try? FileManager.default.createDirectory(at: dstHistory, withIntermediateDirectories: true, attributes: nil)
            }

            dstProject = dstHistory
        }

        if let srcHistory = project.storage.getProjectBy(url: src.deletingLastPathComponent())?.getHistoryURL(),
            FileManager.default.directoryExists(atUrl: srcHistory) {

            srcProject = srcHistory
        }

        guard let srcDir = srcProject?.appendingPathComponent(srcFileName),
              FileManager.default.fileExists(atPath: srcDir.path),
              let dstDir = dstProject?.appendingPathComponent(dstFileName),
              !FileManager.default.directoryExists(atUrl: dstDir)
        else { return }

        do {
            try FileManager.default.moveItem(at: srcDir, to: dstDir)
        } catch {
            print("History transfer \(error)")
        }
    }

    public func getCommits() -> [Commit] {
        do {
            return try gitHistory()
        } catch {
            print(error)
        }
        return []
    }

    public func gitHistory() throws -> [Commit] {
        guard let project = getGitProject() else { return [] }
        let repository = try project.getRepository()
        let currentPath = getGitPath(history: true)
        var commits = try repository.fileHistory(path: currentPath)
        if let legacy = legacyGitPath() {
            let older = try repository.fileHistory(path: legacy)
            for commit in older where try commit.tree().entry(byPath: currentPath) == nil {
                if !commits.contains(where: { $0.oid.sha() == commit.oid.sha() }) { commits.append(commit) }
            }
        }
        return commits.sorted { $0.date > $1.date }
    }

    public func restoreGitCommit(_ commit: Commit) throws {
        guard let project = getGitProject(), getGitPathPrefix() != nil else {
            throw GitError.notFound(ref: name)
        }
        let repository = try project.getRepository()
        let commit = try repository.commitLookup(oid: commit.oid)
        let current = getGitPath(history: true)
        if try commit.tree().entry(byPath: current) != nil {
            try repository.checkout(commit: commit, path: current)
        } else if let legacy = legacyGitPath(), let store = metadataStore {
            let data = try repository.fileContent(commit: commit, path: legacy)
            let destination = getContentFileURL() ?? url
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MetadataStore.Failure.invalid("cannot restore through a symbolic link") }
            var restored = data
            if let text = String(data: data, encoding: .utf8) {
                let source = project.url.appendingPathComponent(legacy)
                var mapping = [String: URL]()
                for entry in try store.allEntries() {
                    if let old = entry.legacyPath { mapping[store.root.appendingPathComponent(old).standardizedFileURL.path] = store.fileURL(entry) }
                }
                restored = Data(MetadataStore.relocateLinks(text, source: source, destination: destination, notes: mapping).utf8)
            }
            try restored.write(to: destination, options: .atomic)
        } else {
            throw GitError.notFound(ref: current)
        }
    }

    public func gitContent(at commit: Commit) throws -> Data {
        guard let project = getGitProject(), getGitPathPrefix() != nil else {
            throw GitError.notFound(ref: name)
        }
        let repository = try project.getRepository()
        let commit = try repository.commitLookup(oid: commit.oid)
        let current = getGitPath(history: true)
        if try commit.tree().entry(byPath: current) != nil { return try repository.fileContent(commit: commit, path: current) }
        if let legacy = legacyGitPath() { return try repository.fileContent(commit: commit, path: legacy) }
        throw GitError.notFound(ref: current)
    }

    private func legacyGitPath() -> String? {
        guard let store = metadataStore, let entry = store.entry(at: url), let legacy = entry.legacyPath,
              let gitRoot = getGitProject()?.url.standardizedFileURL else { return nil }
        let source = store.root.appendingPathComponent(legacy).standardizedFileURL
        let prefix = gitRoot.path + "/"
        guard source.path.hasPrefix(prefix) else { return nil }
        return String(source.path.dropFirst(prefix.count))
    }

    public func checkout(commit: Commit) {
        do {
            try restoreGitCommit(commit)
        } catch {
            print(error)
        }
    }
}

public struct Revision {
    var timestamp: Double
    var url: URL?
    var commit: Commit?
}
