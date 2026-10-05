import Foundation

extension Storage {
    func openMetadataLibrary(for project: Project) {
        guard project.isDefault || project.isBookmark || FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".git").path) else { return }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let database = support.appendingPathComponent("FSNotes/Metadata", isDirectory: true).appendingPathComponent(project.url.path.md5 + ".sqlite")
            let store = try MetadataStore(root: project.url, databaseURL: database)
            metadataStores[project.url.path] = store
            project.metadataStore = store
            project.metadataUnavailable = false
            let diff = project.metadataProjectDiff()
            diff.1.forEach { insertProject(project: $0) }
            loadProjectRelations()
            discoverNestedRepositories(in: project)
        } catch {
            project.metadataUnavailable = true
            metadataErrors.append(error.localizedDescription)
            NSLog("%@", error.localizedDescription)
        }
    }

    private func discoverNestedRepositories(in root: Project) {
        guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values?.isDirectory == true else { continue }
            if ["assets", "i", "files", "Trash"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { continue }
            enumerator.skipDescendants()
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if getProjectBy(url: canonical) != nil { continue }
            var parent = root
            if let store = root.metadataStore {
                let oldParent = canonical.deletingLastPathComponent().path
                if let folder = (try? store.allFolders())?.first(where: { folder in
                    folder.legacyPath.map { store.root.appendingPathComponent($0).standardizedFileURL.path == oldParent } == true
                }), let logical = getProjectBy(url: store.folderURL(folder.id)) { parent = logical }
            }
            let project = Project(storage: self, url: canonical, parent: parent)
            insertProject(project: project)
            openMetadataLibrary(for: project)
            if !parent.child.contains(where: { $0 === project }) { parent.child.append(project) }
        }
    }

    func metadataStore(for url: URL) -> MetadataStore? {
        metadataStores.values.first { $0.notesURL.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() }
    }

    func project(for entry: MetadataStore.Entry, in store: MetadataStore) -> Project? {
        if entry.trashed { return getDefaultTrash() }
        return getProjectBy(url: entry.folderID.map(store.folderURL) ?? store.root)
    }

    func refreshMetadataLibraries() {
        let diff = getProjectDiffs()
        for note in noteList where note.metadataStore != nil { note.applyMetadata() }
        for removed in diff.0 { removeBy(project: removed) }
        for project in projects where project.metadataStore != nil || project.isTrash {
            _ = project.checkFSAndMemoryDiff()
        }
        for note in noteList where note.metadataStore != nil { note.applyMetadata() }
    }

    func createMetadataFolder(in parent: Project, name: String) throws -> Project? {
        guard let store = parent.metadataStore else { return nil }
        let folder = try store.createFolder(name: name, parentID: parent.metadataFolderID)
        try FileManager.default.createDirectory(at: store.folderURL(folder.id), withIntermediateDirectories: true)
        let project = Project(storage: self, url: store.folderURL(folder.id), label: folder.name, parent: parent)
        project.metadataStore = store
        project.metadataFolderID = folder.id
        project.label = folder.name
        project.isReadyForCacheSaving = true
        insertProject(project: project)
        loadProjectRelations()
        return project
    }

    func deleteMetadataFolder(_ project: Project) throws {
        guard let store = project.metadataStore, let id = project.metadataFolderID else { return }
        try store.deleteFolder(id: id)
        refreshMetadataLibraries()
    }

    /// Import is explicit; unindexed UUID files are preserved until their metadata arrives.
    func importMetadataFile(_ source: URL, to project: Project, name: String? = nil, id: String? = nil) throws -> URL {
        guard let store = project.metadataStore else { throw MetadataStore.Failure.invalid("destination is not a metadata library") }
        let entry = try store.register(id: id ?? UUID().uuidString.lowercased(), name: name ?? source.deletingPathExtension().lastPathComponent, folderID: project.metadataFolderID, ext: source.pathExtension.lowercased())
        do { return try copyMetadataFile(source, entry: entry, store: store) }
        catch {
            try? FileManager.default.removeItem(at: store.fileURL(entry))
            try? FileManager.default.removeItem(at: store.notesURL.appendingPathComponent("assets").appendingPathComponent(entry.id))
            try? store.delete(id: entry.id)
            throw error
        }
    }

    func importMetadataDirectory(_ source: URL, to parent: Project) throws -> Project? {
        guard let store = parent.metadataStore, let destination = try createMetadataFolder(in: parent, name: source.lastPathComponent) else { return nil }
        let sourceRoot = source.standardizedFileURL.resolvingSymlinksInPath()
        var notes = [(URL, MetadataStore.Entry)]()
        var resources = [(URL, URL)]()
        var mapping = [String: URL]()
        let assets = store.notesURL.appendingPathComponent("assets").appendingPathComponent(destination.metadataFolderID!)
        do {
            func plan(_ directory: URL, project: Project) throws {
                for raw in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
                    let values = try raw.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    let file = raw.standardizedFileURL.resolvingSymlinksInPath()
                    if allowedExtensions.contains(file.pathExtension.lowercased()) {
                        let entry = try store.register(name: file.deletingPathExtension().lastPathComponent, folderID: project.metadataFolderID, ext: file.pathExtension.lowercased())
                        notes.append((file, entry))
                        mapping[file.path] = store.fileURL(entry)
                    } else if values.isDirectory == true {
                        if ["i", "files", "assets"].contains(file.lastPathComponent) {
                            guard let enumerator = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { continue }
                            for case let asset as URL in enumerator {
                                let attributes = try asset.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                if attributes.isDirectory == true || attributes.isSymbolicLink == true { continue }
                                let canonical = asset.standardizedFileURL.resolvingSymlinksInPath()
                                let target = assets.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(asset.pathExtension)
                                resources.append((canonical, target))
                                mapping[canonical.path] = target
                            }
                        } else if let child = try createMetadataFolder(in: project, name: file.lastPathComponent) {
                            try plan(file, project: child)
                        }
                    } else {
                        let target = assets.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(file.pathExtension)
                        resources.append((file, target))
                        mapping[file.path] = target
                    }
                }
            }
            try plan(sourceRoot, project: destination)
            if !resources.isEmpty { try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true) }
            for (from, to) in resources { try FileManager.default.copyItem(at: from, to: to) }
            for (file, entry) in notes { _ = try copyMetadataFile(file, entry: entry, store: store, links: mapping) }
            return destination
        } catch {
            for (_, entry) in notes {
                if let note = getBy(url: store.fileURL(entry)) { removeBy(note: note) }
                try? FileManager.default.removeItem(at: store.fileURL(entry))
                try? store.delete(id: entry.id)
            }
            try? FileManager.default.removeItem(at: assets)
            try? store.deleteFolder(id: destination.metadataFolderID!)
            refreshMetadataLibraries()
            throw error
        }
    }

    private func copyMetadataFile(_ rawSource: URL, entry: MetadataStore.Entry, store: MetadataStore, links: [String: URL] = [:]) throws -> URL {
        let manager = FileManager.default
        let source = rawSource.standardizedFileURL.resolvingSymlinksInPath()
        let destination = store.fileURL(entry)
        try manager.copyItem(at: source, to: destination)
        var mapping = links
        for existing in try store.allEntries() {
            if let legacy = existing.legacyPath { mapping[store.root.appendingPathComponent(legacy).standardizedFileURL.path] = store.fileURL(existing) }
        }
        let bodies: [URL]
        if source.pathExtension.lowercased() == "textbundle" {
            mapping[source.standardizedFileURL.path] = destination
            bodies = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter { ["md", "markdown", "txt", "fountain"].contains($0.pathExtension.lowercased()) }
        } else { bodies = ["md", "markdown", "txt", "fountain"].contains(source.pathExtension.lowercased()) ? [source] : [] }
        for rawBody in bodies {
            let body = rawBody.standardizedFileURL.resolvingSymlinksInPath()
            let targetBody = source.pathExtension.lowercased() == "textbundle" ? destination.appendingPathComponent(body.lastPathComponent) : destination
            let text = try String(contentsOf: body, encoding: .utf8)
            let resources = store.notesURL.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(entry.id, isDirectory: true)
            for target in MetadataStore.localLinkTargets(in: text) {
                let path = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                let referenced = body.deletingLastPathComponent().appendingPathComponent(path.removingPercentEncoding ?? path).standardizedFileURL
                if mapping[referenced.path] != nil { continue }
                if source.pathExtension.lowercased() == "textbundle" && referenced.path.hasPrefix(source.standardizedFileURL.path + "/") { continue }
                if metadataStore(for: referenced)?.entry(at: referenced) != nil { continue }
                guard manager.fileExists(atPath: referenced.path) else { continue }
                try manager.createDirectory(at: resources, withIntermediateDirectories: true)
                let copy = resources.appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension(referenced.pathExtension)
                try manager.copyItem(at: referenced, to: copy)
                mapping[referenced.path] = copy
            }
            let rewritten = MetadataStore.relocateLinks(text, source: body, destination: targetBody, notes: mapping)
            if rewritten != text { try rewritten.write(to: targetBody, atomically: true, encoding: .utf8) }
            let attributes = try manager.attributesOfItem(atPath: body.path)
            try manager.setAttributes(attributes.filter { [.creationDate, .modificationDate, .posixPermissions].contains($0.key) }, ofItemAtPath: targetBody.path)
        }
        _ = importNote(url: destination)
        return destination
    }

}

extension Project {
    var noteStorageURL: URL { metadataStore?.notesURL ?? url }

    func metadataProjectDiff() -> ([Project], [Project]) {
        guard let store = metadataStore else { return ([], []) }
        do {
            let folders = try store.allFolders()
            let relevant = storage.projects.filter { $0.metadataStore === store && $0.metadataFolderID != nil }
            var added = [Project]()
            for folder in folders {
                if let existing = relevant.first(where: { $0.metadataFolderID == folder.id }) {
                    existing.label = folder.name
                } else {
                    try FileManager.default.createDirectory(at: store.folderURL(folder.id), withIntermediateDirectories: true)
                    let project = Project(storage: storage, url: store.folderURL(folder.id), label: folder.name)
                    project.metadataStore = store
                    project.metadataFolderID = folder.id
                    project.label = folder.name
                    if project.getSettings() == nil, let legacy = folder.legacyPath {
                        let previous = Project(storage: storage, url: store.root.appendingPathComponent(legacy))
                        project.settings = previous.settings
                        project.saveSettings()
                    }
                    added.append(project)
                }
            }
            let ids = Set(folders.map { $0.id })
            return (relevant.filter { !ids.contains($0.metadataFolderID!) }, added)
        } catch {
            NSLog("%@", error.localizedDescription)
            return ([], [])
        }
    }

    func metadataNotes() -> [Note] {
        let stores = isTrash ? Array(storage.metadataStores.values) : metadataStore.map { [$0] } ?? []
        return stores.flatMap { store -> [Note] in
            guard let entries = try? (isTrash ? store.allEntries() : store.entries(inFolder: metadataFolderID)) else { return [] }
            return entries.filter { entry in
                (isTrash ? entry.trashed : !entry.trashed && entry.folderID == metadataFolderID)
                && FileManager.default.fileExists(atPath: store.fileURL(entry).path)
            }.map { entry in
                let url = store.fileURL(entry)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                return Note(url: url, with: self, modified: values?.contentModificationDate ?? .distantPast, created: values?.creationDate ?? .distantPast)
            }
        }
    }

    func renameMetadataFolder(to name: String) throws {
        guard let store = metadataStore, let id = metadataFolderID else { return }
        try store.renameFolder(id: id, name: name)
        label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Note {
    var metadataStore: MetadataStore? { project.storage.metadataStore(for: url) }
    var metadataEntry: MetadataStore.Entry? { metadataStore?.entry(at: url) }

    func applyMetadata() {
        guard let store = metadataStore, let entry = store.entry(at: url) else { return }
        title = entry.name
        fileName = entry.name
        if let destination = project.storage.project(for: entry, in: store) { project = destination }
    }

    @discardableResult func moveMetadata(to destination: Project) throws -> Bool {
        guard let store = metadataStore, destination.metadataStore === store, let entry = store.entry(at: url) else { return false }
        try store.moveNote(id: entry.id, folderID: destination.metadataFolderID)
        project = destination
        applyMetadata()
        return true
    }

    func renameMetadata(to name: String) throws {
        guard let store = metadataStore, let entry = store.entry(at: url) else { throw MetadataStore.Failure.invalid("missing note metadata") }
        try store.renameNote(id: entry.id, name: name)
        applyMetadata()
    }

    func removeMetadataFile(completely: Bool) -> [URL]? {
        guard let store = metadataStore, let entry = store.entry(at: url) else { return nil }
        do {
            if completely || entry.trashed {
                // Remove the file first; a crash leaves a harmless missing-file record.
                try FileManager.default.removeItem(at: url)
                try store.delete(id: entry.id)
                return nil
            }
            try store.trashNote(id: entry.id)
            applyMetadata()
            return [url, url]
        } catch {
            NSLog("%@", error.localizedDescription)
            return nil
        }
    }
}
