//
//  Project+Git.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 31.10.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation

extension Project {
    public func getGitOrigin() -> String? {
        if let origin = settings.gitOrigin, origin.count > 0 {
            return origin
        }

        return nil
    }

    public func getRepositoryUrl() -> URL {
        return WorkspaceLocation.repositoryURL(for: url)
    }

    public func hasRepository() -> Bool {
        let url = getRepositoryUrl()

        return FileManager.default.fileExists(atPath: url.path)
    }

    public func getGitProject() -> Project? {
        if metadataFolderID != nil, let store = metadataStore {
            return storage.getProjectBy(url: store.root)?.getGitProject()
        }
        if hasRepository() {
            return self
        }

        if let parent = parent, let root = parent.getGitProject() {
            return root
        }

        return nil
    }

    public func initRepository() throws {
        let repositoryManager = RepositoryManager()
        // Initialize in place so Git infers a relative, portable worktree.
        _ = try repositoryManager.initRepository(at: url, signature: getSign())
    }

    public func cloneRepository() throws -> Repository? {
        try requireEmptyCloneDestination()
        let repositoryManager = RepositoryManager()
        let repoURL = getRepositoryUrl()

        // Prepare temporary dir
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("FSNotes-clone-" + UUID().uuidString, isDirectory: true)
        var preserveRecoveryFiles = false
        defer { if !preserveRecoveryFiles { try? FileManager.default.removeItem(at: tempURL) } }

        // Clone
        if let originString = getGitOrigin(), let origin = URL(string: originString) {
            _ = try repositoryManager.cloneRepository(from: origin, at: tempURL, authentication: getAuthHandler())

            let dotGit = tempURL.appendingPathComponent(".git")

            if FileManager.default.directoryExists(atUrl: dotGit) {
                // Clone away from the library, then install only into an empty
                // destination. Preserve its empty scaffolding if installation fails.
                let backup = tempURL.appendingPathComponent(".fsnotes-clone-backup")
                let contents = try FileManager.default.contentsOfDirectory(at: tempURL, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent != ".git" }
                var installed = [URL]()
                var originals = [(URL, URL)]()
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var result: Result<Repository, Error>?
                coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
                    result = Result {
                        try requireEmptyCloneDestination()
                        do {
                            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                            for source in contents {
                                let destination = url.appendingPathComponent(source.lastPathComponent)
                                if FileManager.default.fileExists(atPath: destination.path) {
                                    let saved = backup.appendingPathComponent(source.lastPathComponent)
                                    try FileManager.default.moveItem(at: destination, to: saved)
                                    originals.append((saved, destination))
                                }
                                installed.append(destination)
                                try FileManager.default.copyItem(at: source, to: destination)
                            }
                            installed.append(repoURL)
                            try FileManager.default.moveItem(at: dotGit, to: repoURL)
                            return try repositoryManager.openRepository(at: repoURL)
                        } catch {
                            var rollbackFailed = false
                            for destination in installed.reversed() where FileManager.default.fileExists(atPath: destination.path) {
                                do { try FileManager.default.removeItem(at: destination) }
                                catch { rollbackFailed = true }
                            }
                            for (saved, destination) in originals.reversed() {
                                do { try FileManager.default.moveItem(at: saved, to: destination) }
                                catch { rollbackFailed = true }
                            }
                            if rollbackFailed {
                                preserveRecoveryFiles = true
                                throw GitError.invalidSpec(spec: "Clone failed: \(error.localizedDescription). Recovery files are preserved at \(backup.path)")
                            }
                            throw error
                        }
                    }
                }
                if let error = coordinationError { throw error }
                guard let result = result else { throw GitError.invalidSpec(spec: "Clone installation did not complete") }
                return try result.get()
            }

            return nil
        }

        return nil
    }

    private func requireEmptyCloneDestination() throws {
        guard !hasRepository() else { throw GitError.alreadyExists(ref: getRepositoryUrl().path) }
        let manager = FileManager.default
        var scaffolding = Set<String>()
        if let store = metadataStore {
            try store.refresh()
            guard try store.allEntries().isEmpty, try store.allFolders().isEmpty else {
                throw GitError.invalidSpec(spec: "Clone requires an empty workspace. Choose a new folder to keep your existing notes.")
            }
            scaffolding = [store.manifestURL.path, store.notesURL.appendingPathComponent(".fsnotes-library").path]
            let attributes = url.appendingPathComponent(".gitattributes")
            if (try? String(contentsOf: attributes, encoding: .utf8)) == "images/** filter=lfs diff=lfs merge=lfs -text\n" {
                scaffolding.insert(attributes.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            throw GitError.invalidSpec(spec: "Unable to inspect clone destination")
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true { continue }
            guard values.isSymbolicLink != true, scaffolding.contains(file.standardizedFileURL.resolvingSymlinksInPath().path) || file.lastPathComponent == ".DS_Store" else {
                throw GitError.invalidSpec(spec: "Clone requires an empty workspace. Choose a new folder to keep your existing files.")
            }
        }
    }

    public func getRepository() throws -> Repository {
        let repositoryManager = RepositoryManager()
        let repoURL = getRepositoryUrl()

        return try repositoryManager.openRepository(at: repoURL)
    }

    public func getAuthHandler() -> SshKeyHandler? {
        var rsa: URL?

        if let rsaURL = installSSHKey() {
            rsa = rsaURL
        }

        guard let rsaURL = rsa else { return nil }

        let passphrase = settings.gitPrivateKeyPassphrase ?? ""
        let sshKeyDelegate = StaticSshKeyDelegate(privateUrl: rsaURL, passphrase: passphrase)
        let handler = SshKeyHandler(sshKeyDelegate: sshKeyDelegate)

        return handler
    }

    public func getSSHKeyUrl() -> URL? {
        let keyName = getSettingsKey()

        return storage
            .getGitKeysDir()?
            .appendingPathComponent(keyName)
    }

    public func removeSSHKey() {
        guard let url = getSSHKeyUrl() else { return }

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pub"))
    }

    public func installSSHKey() -> URL? {
        guard let url = getSSHKeyUrl() else { return nil }

        if let key = settings.gitPrivateKey {
            do {
                try key.write(to: url, options: .atomic)
                // OpenSSH refuses private keys readable by other users. Apply
                // this after every import/rewrite, including atomic replacement.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

                if let publicKey = settings.gitPublicKey {
                    let publicKeyUrl = url.appendingPathExtension("pub")
                    try publicKey.write(to: publicKeyUrl)
                }

                return url
            } catch {/*_*/}
        }

        return nil
    }

    public func getSign() -> Signature {
        return Signature(name: "FSNotes App", email: "support@fsnot.es")
    }

    public func commit(message: String? = nil, progress: GitProgress? = nil) throws {
        guard !gitMergePending else { throw GitError.invalidSpec(spec: "Resolve or close the sync conflict workbench first") }
        guard !metadataUnavailable else { throw MetadataStore.Failure.invalid("library migration or metadata loading failed") }
        let repository = try getRepository()
        try repository.requireCompletedOperation()
        try metadataStore?.refresh()
        let lastCommit = try? repository.head().targetCommit()

        // Add all and save index
        let head = try repository.head().index()
        if let progress = progress {
            progress.log(message: "git add .")
        }

        let success = try head.add(path: ".")

        // No commits yet or added files was found
        if success || lastCommit == nil {
            try head.save()

            do {
                progress?.log(message: "git commit")

                let sign = getSign()
                if lastCommit == nil {
                    let commitMessage = message ?? "FSNotes Init"
                    _ = try head.createInitialCommit(msg: commitMessage, signature: sign)
                } else {
                    let commitMessage = message ?? "Usual commit"
                    _ = try head.createCommit(msg: commitMessage, signature: sign)
                }

                progress?.log(message: "git commit done 🤟")

                cacheHistory(progress: progress)
            } catch {
                progress?.log(message: "commit error: \(error)")
                throw error
            }
        } else {
            progress?.log(message: "git add: no new data")

            throw GitError.noAddedFiles
        }
    }

    public func checkGitState() throws -> Bool {
        let repository = try getRepository()
        let statuses = Statuses(repository: repository)

        isCleanGit = statuses.workingDirectoryClean
        return isCleanGit
    }

    public func getLocalBranch(repository: Repository) -> Branch? {
        do {
            return try repository.currentBranch()
        } catch {/**/}

        return nil
    }

    public func push(progress: GitProgress? = nil) throws {
        guard !gitMergePending else { throw GitError.invalidSpec(spec: "Resolve or close the sync conflict workbench first") }
        guard let origin = getGitOrigin() else { return }

        let repository = try getRepository()
        try repository.addRemoteOrigin(path: origin)

        let handler = getAuthHandler()
        let localBranch = try repository.currentBranch()
        try GitLFS.transfer(["push", "origin", localBranch.shortName], in: url, sshKey: getSSHKeyUrl(),
                            caCertificates: settings.gitCACertificates, origin: getGitOrigin())
        try repository.remotes.get(remoteName: "origin").push(local: localBranch, authentication: handler)

        if let progress = progress {
            progress.log(message: "\(label) – successful push 👌")
        }
    }

    public func pull(progress: GitProgress? = nil) throws {
        guard !gitMergePending else { throw GitError.invalidSpec(spec: "Resolve or close the sync conflict workbench first") }
        guard let origin = getGitOrigin() else { return }

        let repository = try getRepository()
        try repository.requireCompletedOperation()
        try repository.addRemoteOrigin(path: origin)

        let authHandler = getAuthHandler()
        let sign = getSign()

        let remote = repository.remotes
        let remoteBranch = try remote.get(remoteName: "origin")

        try remoteBranch.pull(signature: sign, authentication: authHandler, project: self)

        try metadataStore?.refresh()
        try GitLFS.transfer(["pull", "origin"], in: url, sshKey: getSSHKeyUrl(),
                            caCertificates: settings.gitCACertificates, origin: getGitOrigin())
        DispatchQueue.main.async { self.storage.refreshMetadataLibraries() }

        if let progress = progress {
            progress.log(message: "\(label) – successful git pull 👌")
        }
    }

    public func isGitOriginExist() -> Bool {
        if let origin = settings.gitOrigin, origin.count > 0 {
            return true
        }

        return false
    }

    /// Explicit sync keeps the user-visible order: pull, commit, then push.
    public func synchronize(progress: GitProgress? = nil) throws {
        guard hasRepository(), getGitOrigin() != nil else {
            throw GitError.invalidSpec(spec: "Git sync requires a repository and remote")
        }
        do { try pull(progress: progress) }
        catch GitError.notFound(let ref) {
            let branch = try getRepository().currentBranch()
            guard ref == "origin/\(branch.shortName)" else { throw GitError.notFound(ref: ref) }
            // A new remote has no branch to pull until its first push.
        }
        do { try commit(progress: progress) }
        catch GitError.noAddedFiles { }
        try push(progress: progress)
    }

    public func removeCommitsCache() {
        if let url = getCommitsDiffsCache() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func loadCommitsCache() {
        if !commitsCache.isEmpty {
            return
        }

        if let commitsDiffCache = getCommitsDiffsCache(),
            let data = try? Data(contentsOf: commitsDiffCache),
            let result = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self], from: data) as? [String: [String]] {
            commitsCache = result
        }
    }

    public func cacheHistory(progress: GitProgress? = nil) {
        progress?.log(message: "git history caching ...")

        guard let repository = try? getRepository() else { return }

        do {
            let fileRevLog = try FileHistoryIterator(repository: repository, path: "Test", project: self)
            fileRevLog.walkCacheDiff()

            let cacheData = try? NSKeyedArchiver.archivedData(withRootObject: commitsCache, requiringSecureCoding: true)
            if let data = cacheData, let writeTo = getCommitsDiffsCache() {
                do {
                    try data.write(to: writeTo)
                } catch {
                    print("Caching error: " + error.localizedDescription)
                }
            }
        } catch {
            print(error)
        }

        progress?.log(message: "git history caching done 🤟")
    }

    public func getCommitsDiffsCache() -> URL? {
        guard let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let fileName = "commitsDiff-\(settingsKey).cache"
        return documentDir.appendingPathComponent(fileName, isDirectory: false)
    }

    public func hasCommitsDiffsCache() -> Bool {
        guard let project = getGitProject() else { return false }

        if let url = project.getCommitsDiffsCache() {
            return FileManager.default.fileExists(atPath: url.path)
        }

        return false
    }

    public func getRepositoryState() -> RepositoryAction {
        if hasRepository() {
            if settings.gitOrigin != nil {
                return .pullPush
            } else {
                return .commit
            }
        } else {
            if settings.gitOrigin != nil {
                return .clonePush
            } else {
                return .initCommit
            }
        }
    }

    public func gitDo(_ action: RepositoryAction, progress: GitProgress? = nil) -> String? {
        var message: String?

        do {
            switch action {
            case .initCommit:
                try initRepository()
                try commit(message: nil, progress: progress)
            case .clonePush:
                removeCommitsCache()
                message = clonePush(progress: progress)
            case .commit:
                try commit(message: nil, progress: progress)
            case .pullPush:
                try synchronize(progress: progress)
            }
        } catch {
            if let error = error as? GitError {
                message = error.associatedValue()
            } else {
                message = error.localizedDescription
            }
        }

        return message
    }

    private func clonePush(progress: GitProgress? = nil) -> String? {
        var message: String?

        do {
            if let repo = try cloneRepository(), getLocalBranch(repository: repo) != nil {
                try GitLFS.transfer(["pull", "origin"], in: url, sshKey: getSSHKeyUrl(),
                                    caCertificates: settings.gitCACertificates, origin: getGitOrigin())
                try metadataStore?.refresh()
                DispatchQueue.main.async { self.storage.refreshMetadataLibraries() }
                cacheHistory(progress: progress)
            } else {
                do {
                    try commit(message: nil, progress: progress)
                    try push(progress: progress)
                } catch {
                    message = error.localizedDescription
                }
            }
        } catch GitError.unknownError(let errorMessage, _, let desc) {
            message = errorMessage + " – " + desc
        } catch GitError.notFound(let ref) {

            // Empty repository – commit and push
            if ref.hasPrefix("refs/heads/") {
                do {
                    try commit(message: nil, progress: progress)
                    try push(progress: progress)
                } catch {
                    message = error.localizedDescription
                }
            }
        } catch {
            message = error.localizedDescription
        }

        return message
    }

    public func saveRevision(commitMessage: String? = nil) throws {
        try commit(message: commitMessage)
        
        // No hands – no mults
        guard getGitOrigin() != nil else { return }

        do {
            try pull()
        } catch GitError.notFound(let ref) {
            let repository = try getRepository()
            let branch = try repository.currentBranch()

            // The current branch has not been pushed to origin yet.
            guard ref == "origin/\(branch.shortName)" else {
                throw GitError.notFound(ref: ref)
            }
        }

        try push()
    }
}
