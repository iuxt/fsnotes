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
        let store = try MetadataStore(root: rootURL, databaseURL: temporary.appendingPathComponent("local.sqlite"))
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
        let package = source.appendingPathComponent("Bundle.textbundle")
        try manager.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([4,5]).write(to: package.appendingPathComponent("assets/b.png"))
        try "![b](assets/b.png)\n![external](../assets/p.png)".write(to: package.appendingPathComponent("text.markdown"), atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: package.appendingPathComponent("info.json"))
        let importedPackage = try storage.importMetadataFile(package, to: child)
        let packageBody = try String(contentsOf: importedPackage.appendingPathComponent("text.markdown"), encoding: .utf8)
        try expect(packageBody.contains("assets/b.png"), "TextBundle internal links unchanged")
        let externalImage = MetadataStore.localLinkTargets(in: packageBody).last!
        try expect(try Data(contentsOf: importedPackage.appendingPathComponent(externalImage).standardizedFileURL) == Data([1,2,3]), "TextBundle external resource copied")
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
        let invalid = source.appendingPathComponent("Invalid.md")
        try Data([0xff,0xfe,0x80]).write(to: invalid)
        let countBefore = try store.allEntries().count
        do { _ = try storage.importMetadataFile(invalid, to: root); throw MetadataStore.Failure.invalid("invalid UTF8 accepted") }
        catch let error as NSError where error.domain == NSCocoaErrorDomain { checks += 1 }
        try expect(try store.allEntries().count == countBefore, "failed import rolls back metadata")
        try expect(manager.fileExists(atPath: invalid.path), "failed import preserves original")
        let snapshot = try Data(contentsOf: store.manifestURL)
        _ = note.removeMetadataFile(completely: false)
        try expect(note.project === trash && manager.fileExists(atPath: imported.path), "trash retains body path")
        try store.moveNote(id: note.metadataEntry!.id, folderID: child.metadataFolderID)
        note.applyMetadata()
        try storage.deleteMetadataFolder(folder)
        try expect(note.project === trash && note.metadataEntry!.folderID == nil, "folder deletion preserves notes in trash")
        try expect(storage.getProjectBy(url: child.url) == nil, "deleted child removed from in-memory tree")
        try snapshot.write(to: store.manifestURL, options: .atomic)
        storage.refreshMetadataLibraries()
        try expect(note.metadataEntry?.trashed == false, "snapshot restoration restores membership")
        try expect(note.project.metadataFolderID == child.metadataFolderID, "restored note belongs to restored logical folder")
        _ = note.removeMetadataFile(completely: true)
        try expect(!manager.fileExists(atPath: imported.path) && store.entry(at: imported) == nil, "permanent deletion removes body and record")
        print("Metadata adapter integration: \(checks) checks passed")
    }
}
