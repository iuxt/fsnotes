import Foundation

@main struct MetadataAdapterTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw MetadataStore.Failure.invalid("adapter test failed: " + message) }
    }
    static func main() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("fsnotes-adapter-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        let rootURL = temporary.appendingPathComponent("library")
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = try MetadataStore(root: rootURL)
        let storage = Storage()
        let root = Project(storage: storage, url: store.root)
        root.isDefault = true; root.metadataStore = store
        let trash = Project(storage: storage, url: rootURL.appendingPathComponent("Trash"))
        trash.isTrash = true
        storage.projects = [root, trash]; storage.metadataStores[store.root.path] = store
        let folder = try storage.createMetadataFolder(in: root, name: "技术")!
        let child = try storage.createMetadataFolder(in: folder, name: "Git")!
        try expect(child.parent === folder && folder.parent === root, "logical hierarchy")
        try expect(child.label == "Git", "labels use virtual names")
        let source = temporary.appendingPathComponent("sources")
        try manager.createDirectory(at: source.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: source.appendingPathComponent("assets/p.png"))
        let body = "# Body\n![p](assets/p.png)\n"
        let document = source.appendingPathComponent("Human.md")
        try body.write(to: document, atomically: true, encoding: .utf8)
        let imported = try storage.importMetadataFile(document, to: folder)
        let note = storage.getBy(url: imported)!
        try expect(UUID(uuidString: imported.deletingPathExtension().lastPathComponent) != nil, "import uses UUID")
        try expect(note.fileName == "Human" && note.project === folder, "import indexes display name and folder")
        let copiedBody = try String(contentsOf: imported, encoding: .utf8)
        let copiedImage = MetadataStore.localLinkTargets(in: copiedBody).first!
        let imageURL = imported.deletingLastPathComponent().appendingPathComponent(copiedImage)
        try expect(imageURL.standardizedFileURL.path.hasPrefix(store.imagesURL.path + "/"), "imported images live in root images directory")
        try expect(try Data(contentsOf: imageURL) == Data([1,2,3]), "import copies relative resources")
        try expect(manager.fileExists(atPath: document.path), "import retains source")
        try note.renameMetadata(to: "新名称")
        try expect(note.fileName == "新名称" && note.url == imported, "rename retains physical path")
        try expect(try note.moveMetadata(to: child), "logical move succeeds")
        try expect(note.project === child && note.url == imported, "move retains identity and path")
        let scanned = child.metadataNotes().first { $0.url == imported }!
        try expect(scanned.modifiedLocalAt == (try imported.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate, "scan uses actual modification date")
        try folder.renameMetadataFolder(to: "技术资料")
        try expect(note.project.parent?.label == "技术资料", "parent rename reflected")
        let duplicate = try storage.importMetadataFile(note.url, to: child, name: note.fileName + " Copy")
        try expect(duplicate != imported, "duplicate creates new identity")
        let duplicateBody = try String(contentsOf: duplicate, encoding: .utf8)
        let duplicateImage = MetadataStore.localLinkTargets(in: duplicateBody).first!
        try expect(duplicateImage != copiedImage, "duplicate resources independently copied")
        try expect(try Data(contentsOf: duplicate.deletingLastPathComponent().appendingPathComponent(duplicateImage)) == Data([1,2,3]), "duplicate image reachable")
        let countBeforeRejection = try store.allEntries().count
        let unsupported = source.appendingPathComponent("Unsupported.archive")
        try Data([1, 2, 3]).write(to: unsupported)
        var rejected = false
        do { _ = try storage.importMetadataFile(unsupported, to: child) }
        catch { rejected = true }
        try expect(rejected, "unsupported formats cannot be imported")
        let fakeNote = source.appendingPathComponent("Directory.md")
        try manager.createDirectory(at: fakeNote, withIntermediateDirectories: true)
        rejected = false
        do { _ = try storage.importMetadataFile(fakeNote, to: child) }
        catch { rejected = true }
        try expect(rejected, "directories cannot be imported as notes")
        try expect(try store.allEntries().count == countBeforeRejection, "rejected imports do not create metadata")
        let opaquePackage = source.appendingPathComponent("Opaque.rtfd")
        try manager.createDirectory(at: opaquePackage, withIntermediateDirectories: true)
        try "hidden".write(to: opaquePackage.appendingPathComponent("Hidden.md"), atomically: true, encoding: .utf8)
        try expect(try storage.importMetadataDirectory(opaquePackage, to: root) == nil, "document packages are not traversed as folders")
        let directory = source.appendingPathComponent("Imported")
        try manager.createDirectory(at: directory.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "[B](nested/B.md)".write(to: directory.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "[A](../A.md)".write(to: directory.appendingPathComponent("nested/B.md"), atomically: true, encoding: .utf8)
        let importedFolder = try storage.importMetadataDirectory(directory, to: root)!
        let records = try store.allEntries()
        let entryA = records.first { $0.name == "A" && $0.folderID == importedFolder.metadataFolderID }!
        let entryB = records.first { $0.name == "B" }!
        try expect(try String(contentsOf: store.fileURL(entryA), encoding: .utf8) == "[B](" + entryB.id + ".md)", "directory forward link uses planned UUID")
        try expect(try String(contentsOf: store.fileURL(entryB), encoding: .utf8) == "[A](" + entryA.id + ".md)", "directory reverse link uses planned UUID")
        try expect(importedFolder.child.count == 1, "directory hierarchy imported")
        try expect(!manager.fileExists(atPath: rootURL.appendingPathComponent("Trash").path), "metadata trash has no physical folder")
        let invalid = source.appendingPathComponent("Invalid.md")
        try Data([0xff,0xfe,0x80]).write(to: invalid)
        let countBefore = try store.allEntries().count
        do { _ = try storage.importMetadataFile(invalid, to: root); throw MetadataStore.Failure.invalid("invalid UTF8 accepted") }
        catch let error as NSError where error.domain == NSCocoaErrorDomain { checks += 1 }
        try expect(try store.allEntries().count == countBefore, "failed import rolls back metadata")
        try expect(manager.fileExists(atPath: invalid.path), "failed import preserves original")
        root.filesystemChanges = ([note], [], [note, note])
        child.filesystemChanges = ([], [storage.getBy(url: duplicate)!], [])
        var received: Notification?
        let observer = NotificationCenter.default.addObserver(forName: .metadataLibraryDidRefresh,
                                                              object: storage, queue: nil) { received = $0 }
        storage.refreshMetadataLibraries()
        NotificationCenter.default.removeObserver(observer)
        try expect(received?.object as? Storage === storage, "refresh identifies the library storage")
        try expect((received?.userInfo?["changed"] as? [Note])?.first === note,
                   "refresh propagates content changes to open editors")
        try expect((received?.userInfo?["changed"] as? [Note])?.count == 1,
                   "refresh deduplicates changes gathered from overlapping projects")
        try expect((received?.userInfo?["removed"] as? [Note])?.isEmpty == true,
                   "moving a surviving note between logical projects does not report deletion")
        try expect((received?.userInfo?["added"] as? [Note])?.first === storage.getBy(url: duplicate),
                   "refresh propagates added notes to the table")
        root.filesystemChanges = ([], [], []); child.filesystemChanges = ([], [], [])
        let snapshot = try Data(contentsOf: store.manifestURL)
        _ = note.removeMetadataFile()
        try expect(note.project === trash && manager.fileExists(atPath: imported.path), "trash retains body path")
        try store.moveNote(id: note.metadataEntry!.id, folderID: child.metadataFolderID)
        note.applyMetadata()
        try storage.deleteMetadataFolder(folder)
        try expect(note.project === trash && note.metadataEntry!.folderID == nil, "folder deletion preserves notes in trash")
        try expect(try note.restoreMetadataFile() && note.project === root, "deleted folder restores its note to the library root")
        _ = note.removeMetadataFile()
        try expect(storage.getProjectBy(url: child.url) == nil, "deleted child removed from in-memory tree")
        try snapshot.write(to: store.manifestURL, options: .atomic)
        storage.refreshMetadataLibraries()
        try expect(note.metadataEntry?.trashed == false, "snapshot restoration restores membership")
        try expect(note.project.metadataFolderID == child.metadataFolderID, "restored note belongs to restored logical folder")
        try note.renameMetadata(to: "Same Title")
        let identity = note.metadataEntry!.id
        let title = note.fileName
        let modified = try imported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = note.removeMetadataFile()
        let trashSnapshot = try Data(contentsOf: store.manifestURL)
        _ = note.removeMetadataFile()
        try expect(try Data(contentsOf: store.manifestURL) == trashSnapshot, "repeated deletion does not change trash metadata")
        try expect(store.entry(id: identity)?.trashed == true, "repeated deletion retains the record")
        try expect(try String(contentsOf: imported, encoding: .utf8) == copiedBody, "repeated deletion preserves the body")
        try expect(try Data(contentsOf: imageURL) == Data([1,2,3]), "repeated deletion preserves attachments")
        try expect(try imported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "trash leaves file modification time unchanged")
        try expect(!child.metadataNotes().contains { $0.url == imported }, "trash disappears from original folder")
        try expect(trash.metadataNotes().contains { $0.url == imported }, "trash remains discoverable")
        let replacementURL = try storage.importMetadataFile(document, to: child, name: title)
        let replacement = storage.getBy(url: replacementURL)!
        try expect(replacement.fileName == title && replacementURL != imported, "trashed title can be reused with a distinct UUID")
        let collidingURL = try storage.importMetadataFile(document, to: child, name: title)
        try expect(storage.getBy(url: collidingURL)?.fileName == title + " 2", "active duplicate title receives suffix")
        let caseURL = try storage.importMetadataFile(document, to: child, name: title.lowercased())
        try expect(storage.getBy(url: caseURL)?.fileName == title.lowercased() + " 3", "duplicate title comparison ignores case")
        let otherFolderURL = try storage.importMetadataFile(document, to: root, name: title)
        try expect(storage.getBy(url: otherFolderURL)?.fileName == title, "different folders can reuse a title")
        try expect(try note.restoreMetadataFile(), "undo restores the original folder")
        try expect(note.project.metadataFolderID == child.metadataFolderID && note.url == imported && note.metadataEntry?.id == identity, "restore retains identity and body path")
        try expect(note.fileName == title + " 4", "restore avoids overwriting an active title")
        try expect(replacement.metadataEntry?.trashed == false && replacement.fileName == title, "restore preserves replacement metadata")
        let replacementBody = try String(contentsOf: replacementURL, encoding: .utf8)
        try expect(MetadataStore.localLinkTargets(in: replacementBody).contains { path in
            (try? Data(contentsOf: replacementURL.deletingLastPathComponent().appendingPathComponent(path))) == Data([1,2,3])
        }, "restore preserves replacement body and attachment")
        _ = note.removeMetadataFile()
        let reopened = try MetadataStore(root: rootURL)
        try expect(reopened.entry(id: identity)?.trashed == true, "trash persists after reopening and index rebuilding")
        try expect(try String(contentsOf: reopened.fileURL(reopened.entry(id: identity)!), encoding: .utf8) == copiedBody, "reopening preserves trash body")
        let empty = source.appendingPathComponent("Empty.md")
        try Data().write(to: empty)
        let emptyURL = try storage.importMetadataFile(empty, to: child)
        let emptyNote = storage.getBy(url: emptyURL)!
        _ = emptyNote.removeMetadataFile()
        _ = emptyNote.removeMetadataFile()
        try expect(manager.fileExists(atPath: emptyURL.path) && emptyNote.metadataEntry?.trashed == true, "empty note is retained in trash")
        print("Metadata adapter integration: \(checks) checks passed")
    }
}
