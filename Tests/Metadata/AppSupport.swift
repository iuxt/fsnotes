import Foundation

// Minimal UI/model scaffolding for the production MetadataLibrary adapter.
// Memory indexes, snapshots, migration, import, rename, move and deletion are not mocked.
final class Storage {
    var metadataStores = [String: MetadataStore]()
    var metadataErrors = [String]()
    var projects = [Project]()
    var noteList = [Note]()
    let allowedExtensions = ["md", "markdown", "txt", "fountain"]
    func insertProject(project: Project) { if getProjectBy(url: project.url) == nil { projects.append(project) } }
    func getProjectBy(url: URL) -> Project? { projects.first { $0.url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() } }
    func getDefaultTrash() -> Project? { projects.first { $0.isTrash } }
    func getBy(url: URL) -> Note? { noteList.first { $0.url == url } }
    func removeBy(note: Note) { noteList.removeAll { $0 === note } }
    func removeBy(project: Project) { projects.removeAll { $0 === project }; noteList.removeAll { $0.project === project } }
    func loadProjectRelations() {
        for project in projects { project.child = [] }
        for project in projects {
            guard let store = project.metadataStore, let id = project.metadataFolderID,
                  let folder = (try? store.allFolders())?.first(where: { $0.id == id }) else { continue }
            project.parent = getProjectBy(url: folder.parentID.map(store.folderURL) ?? store.root)
            project.parent?.child.append(project)
        }
    }
    func getProjectDiffs() -> ([Project], [Project], [Note], [Note]) {
        var removed = [Project](), added = [Project]()
        for root in projects where root.metadataStore != nil && root.metadataFolderID == nil {
            let diff = root.metadataProjectDiff()
            removed += diff.0; added += diff.1
        }
        added.forEach { insertProject(project: $0) }
        loadProjectRelations()
        return (removed, added, [], [])
    }
    func importNote(url: URL) -> Note? {
        guard let store = metadataStore(for: url), let entry = store.entry(at: url),
              let owner = project(for: entry, in: store) else { return nil }
        if let existing = getBy(url: url) { return existing }
        let note = Note(url: url, with: owner)
        noteList.append(note)
        return note
    }
}
final class Project {
    let storage: Storage
    var url: URL
    var label: String
    var isDefault = false, isBookmark = false, isTrash = false
    var metadataStore: MetadataStore?
    var metadataFolderID: String?
    var metadataUnavailable = false
    var isReadyForCacheSaving = false
    var parent: Project?
    var child = [Project]()
    var settings = 0
    init(storage: Storage, url: URL, label: String? = nil, parent: Project? = nil) {
        self.storage = storage; self.url = url; self.label = label ?? url.lastPathComponent; self.parent = parent
    }
    func getSettings() -> Int? { nil }
    func saveSettings() {}
    func checkFSAndMemoryDiff() -> ([Note], [Note], [Note]) { ([], [], []) }
}
final class Note {
    var url: URL
    var project: Project
    var title = "", fileName = ""
    var modifiedLocalAt = Date()
    init(url: URL, with project: Project, modified: Date? = nil, created: Date? = nil) {
        self.url = url; self.project = project; self.modifiedLocalAt = modified ?? Date(); applyMetadata()
    }
}
