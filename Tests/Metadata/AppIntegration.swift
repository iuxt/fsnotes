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
        let physicalProject = Project(storage: storage, url: temporary.appendingPathComponent("physical"))
        try manager.createDirectory(at: physicalProject.url, withIntermediateDirectories: true)
        for project in [root, physicalProject] {
            for blank in ["", " ", "\t\n"] {
                do {
                    _ = try NameHelper.getUniqueFileName(name: blank, project: project, ext: "md")
                    throw NSError(domain: "blank name accepted", code: 1)
                } catch MetadataStore.Failure.invalid(let reason) {
                    try expect(reason == "A note name is required", "physical and UUID paths require an explicit name")
                }
            }
        }
        do {
            _ = try NameHelper.getUniqueFileName(name: "/:", project: physicalProject, ext: "md")
            throw NSError(domain: "empty sanitized filename accepted", code: 1)
        } catch MetadataStore.Failure.invalid { checks += 1 }
        let namedURL = try NameHelper.getUniqueFileName(name: "  独立名称  ", project: physicalProject, ext: "md")
        try expect(namedURL.lastPathComponent == "独立名称.md", "physical notes use the provided name")
        try "# Different body title".write(to: namedURL, atomically: true, encoding: .utf8)
        let duplicateURL = try NameHelper.getUniqueFileName(name: "独立名称", project: physicalProject, ext: "md")
        try expect(duplicateURL.lastPathComponent == "独立名称 2.md", "explicit duplicate names are made unique")
        let uuidURL = try NameHelper.getUniqueFileName(name: "独立名称", project: root, ext: "md")
        try expect(UUID(uuidString: uuidURL.deletingPathExtension().lastPathComponent) != nil && uuidURL.deletingLastPathComponent() == store.notesURL,
                   "metadata notes retain UUID paths independent of explicit names")
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
        var permanentRejected = false
        do { try replacement.deleteMetadataPermanently() } catch { permanentRejected = true }
        try expect(permanentRejected, "permanent deletion rejects active notes")
        try expect(replacement.metadataEntry != nil && manager.fileExists(atPath: replacementURL.path), "active note survives rejected deletion")

        let beforePermanentDeletion = try Data(contentsOf: store.manifestURL)
        try Data("invalid metadata".utf8).write(to: store.manifestURL, options: .atomic)
        permanentRejected = false
        do { try note.deleteMetadataPermanently() } catch { permanentRejected = true }
        try expect(permanentRejected, "invalid metadata blocks permanent deletion")
        try expect(manager.fileExists(atPath: imported.path) && manager.fileExists(atPath: imageURL.path), "invalid metadata preserves body and attachments")
        try beforePermanentDeletion.write(to: store.manifestURL, options: .atomic)

        try manager.setAttributes([.immutable: true], ofItemAtPath: store.manifestURL.path)
        permanentRejected = false
        do { try note.deleteMetadataPermanently() } catch { permanentRejected = true }
        try manager.setAttributes([.immutable: false], ofItemAtPath: store.manifestURL.path)
        try expect(permanentRejected, "failed metadata publication rejects permanent deletion")
        try expect(try Data(contentsOf: store.manifestURL) == beforePermanentDeletion, "failed publication preserves metadata")
        try expect(try String(contentsOf: imported, encoding: .utf8) == copiedBody, "failed publication restores the staged body")
        try expect(try Data(contentsOf: imageURL) == Data([1,2,3]), "failed publication restores staged attachments")

        try note.deleteMetadataPermanently()
        try expect(!manager.fileExists(atPath: imported.path), "permanent deletion removes body")
        try expect(!manager.fileExists(atPath: store.imagesURL.appendingPathComponent(identity).path), "permanent deletion removes owned attachment directory")
        try expect(store.entry(id: identity) == nil && storage.getBy(url: imported) == nil, "permanent deletion removes metadata and memory entry")
        try expect(!trash.metadataNotes().contains { $0.url == imported }, "deleted note disappears from trash")
        try expect(!(try note.restoreMetadataFile()), "permanent deletion cannot be undone as a trash restore")
        try expect(try String(contentsOf: replacementURL, encoding: .utf8) == replacementBody, "deletion preserves other notes with the same title")
        let duplicateImageURL = duplicate.deletingLastPathComponent().appendingPathComponent(duplicateImage)
        try expect(try Data(contentsOf: duplicateImageURL) == Data([1,2,3]), "deletion preserves other notes' resources")
        try emptyNote.deleteMetadataPermanently()
        try expect(!manager.fileExists(atPath: emptyURL.path), "permanent deletion supports empty notes without attachments")
        let pastedURL = try storage.importMetadataFile(empty, to: root, name: "Pasted attachments")
        let sharedURL = try storage.importMetadataFile(empty, to: root, name: "Shared attachments")
        let pastedNote = storage.getBy(url: pastedURL)!
        let sharedNote = storage.getBy(url: sharedURL)!
        let uniqueAsset = store.imagesURL.appendingPathComponent("unique asset.png")
        let sharedAsset = store.imagesURL.appendingPathComponent("shared.png")
        try Data([4,5,6]).write(to: uniqueAsset)
        try Data([7,8,9]).write(to: sharedAsset)
        try "![unique](../images/unique%20asset.png)\n![shared](../images/shared.png)\n[external](../../sources/assets/p.png)".write(to: pastedURL, atomically: true, encoding: .utf8)
        try "![shared](../images/shared.png)".write(to: sharedURL, atomically: true, encoding: .utf8)
        _ = pastedNote.removeMetadataFile()
        _ = sharedNote.removeMetadataFile()
        try pastedNote.deleteMetadataPermanently()
        try expect(!manager.fileExists(atPath: uniqueAsset.path), "permanent deletion removes unshared pasted resources")
        try expect(try Data(contentsOf: sharedAsset) == Data([7,8,9]), "shared attachments remain for another trashed note")
        try expect(manager.fileExists(atPath: source.appendingPathComponent("assets/p.png").path), "deletion leaves linked files outside the library images directory intact")
        try sharedNote.deleteMetadataPermanently()
        try expect(!manager.fileExists(atPath: sharedAsset.path), "deleting the last referencing note removes a shared attachment")
        let missingURL = try storage.importMetadataFile(empty, to: child, name: "Missing body")
        let missingNote = storage.getBy(url: missingURL)!
        _ = missingNote.removeMetadataFile()
        try manager.removeItem(at: missingURL)
        try missingNote.deleteMetadataPermanently()
        try expect(store.entry(at: missingURL) == nil, "missing files do not strand trash records")
        let afterPermanentDeletion = try MetadataStore(root: rootURL)
        try expect(afterPermanentDeletion.entry(id: identity) == nil, "permanent deletion persists after reopening")
        try expect(!(try manager.contentsOfDirectory(atPath: rootURL.path)).contains { $0.hasPrefix(".fsnotes-delete-") }, "permanent deletion and rollback leave no staged files")
        let moveDestination = try storage.createMetadataFolder(in: root, name: "Move destination")!
        let moveParent = try storage.createMetadataFolder(in: root, name: "Move parent")!
        let moving = try storage.createMetadataFolder(in: moveParent, name: "Moving")!
        let nested = try storage.createMetadataFolder(in: moving, name: "Nested")!
        let movingNoteURL = try storage.importMetadataFile(document, to: nested)
        let movingNote = storage.getBy(url: movingNoteURL)!
        let movingBody = try Data(contentsOf: movingNoteURL)
        let movingID = moving.metadataFolderID
        try storage.moveMetadataFolder(moving, to: root)
        try expect(moving.parent === root && root.child.contains { $0 === moving }, "promoted folder is linked to library root")
        try expect(!moveParent.child.contains { $0 === moving }, "promoted folder leaves old parent")
        try storage.moveMetadataFolder(moving, to: moveDestination)
        try expect(moving.parent === moveDestination && nested.parent === moving, "moving a folder preserves subtree objects")
        try expect(moving.metadataFolderID == movingID && movingNote.url == movingNoteURL && movingNote.project === nested,
                   "moving folder preserves note and folder identity")
        try expect(try Data(contentsOf: movingNoteURL) == movingBody, "adapter move retains body and relative image links")
        var rejectedCycle = false
        do { try storage.moveMetadataFolder(moving, to: nested) } catch { rejectedCycle = true }
        try expect(rejectedCycle && moving.parent === moveDestination, "adapter rejects cycles without changing memory hierarchy")
        let otherLibrary = temporary.appendingPathComponent("other-library")
        try manager.createDirectory(at: otherLibrary, withIntermediateDirectories: true)
        let otherRoot = Project(storage: storage, url: otherLibrary)
        otherRoot.metadataStore = try MetadataStore(root: otherLibrary)
        var rejectedCrossLibrary = false
        do { try storage.moveMetadataFolder(moving, to: otherRoot) } catch { rejectedCrossLibrary = true }
        try expect(rejectedCrossLibrary && moving.parent === moveDestination, "folder cannot move across libraries")
        print("Metadata adapter integration: \(checks) checks passed")
    }
}
