import Foundation

@main struct MetadataTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw MetadataStore.Failure.invalid("test failed: " + message) }
    }
    @discardableResult static func command(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MetadataStore.Failure.invalid(String(decoding: data, as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self)
    }
    static func checkMemoryIndexes(in temporary: URL) throws {
        let root = temporary.appendingPathComponent("memory-indexes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (0..<20).map { i in
            MetadataStore.Folder(id: String(format: "11111111-0000-4000-8000-%012d", i), name: "目录 \(i)")
        }
        let entries = (0..<2000).map { i in
            MetadataStore.Entry(id: String(format: "00000000-0000-4000-8000-%012d", i), name: "文章 \(i)",
                                folderID: i % 21 == 20 ? nil : folders[i % 21].id,
                                fileExtension: "md", trashed: i % 13 == 0)
        }
        let initial = MetadataStore.Snapshot(folders: Array(folders.reversed()), notes: Array(entries.reversed()))
        let manifest = root.appendingPathComponent("metadata.json")
        let originalData = try JSONEncoder().encode(initial)
        try originalData.write(to: manifest, options: .atomic)
        let store = try MetadataStore(root: root)
        try expect(try store.allEntries() == entries, "2000 entries sorted by ID regardless of JSON order")
        try expect(try store.allFolders() == folders, "folders sorted by ID regardless of JSON order")
        for entry in entries {
            try expect(store.entry(id: entry.id) == entry, "UUID index retrieves the exact record")
        }
        for folderID in folders.map({ Optional($0.id) }) + [nil] {
            try expect(try store.entries(inFolder: folderID) == entries.filter { $0.folderID == folderID }, "folder index includes root and trashed records in ID order")
        }
        try expect(store.entry(id: "unknown") == nil, "unknown UUID has no record")
        try expect(try store.entries(inFolder: "unknown").isEmpty, "unknown folder has no records")
        try expect(try !store.refresh(force: false), "unchanged JSON keeps current indexes")
        try expect(try Data(contentsOf: manifest) == originalData, "queries do not rewrite JSON")

        let target = entries[1]
        let destination = folders[2].id
        try store.moveNote(id: target.id, folderID: destination)
        try expect(try !store.entries(inFolder: target.folderID).contains { $0.id == target.id }, "move removes old folder membership")
        try expect(try store.entries(inFolder: destination).contains { $0.id == target.id }, "move updates destination membership")
        try store.changeExtension(id: target.id, to: "txt")
        try store.renameNote(id: target.id, name: "更新后的标题")
        try expect(store.entry(id: target.id)?.fileExtension == "txt" && store.entry(id: target.id)?.name == "更新后的标题", "UUID index updates extension and title")
        try expect(try store.entries(inFolder: destination).first { $0.id == target.id } == store.entry(id: target.id), "folder and UUID indexes agree after edits")
        let unchangedData = try Data(contentsOf: manifest)
        try store.renameNote(id: target.id, name: "更新后的标题")
        try expect(try Data(contentsOf: manifest) == unchangedData, "unchanged mutation does not publish JSON")
        try store.delete(id: target.id)
        try expect(store.entry(id: target.id) == nil, "deletion removes UUID lookup")
        try expect(try !store.entries(inFolder: destination).contains { $0.id == target.id }, "deletion removes folder lookup")

        try originalData.write(to: manifest, options: .atomic)
        try expect(store.entry(id: target.id) == target, "external replacement refreshes UUID index without explicit refresh")
        try expect(try store.entries(inFolder: target.folderID).contains(target), "external replacement restores folder membership")
        let second = try MetadataStore(root: root)
        try second.renameNote(id: target.id, name: "另一个实例")
        try expect(store.entry(id: target.id)?.name == "另一个实例", "independent store refreshes its memory index")
        let lastValidEntries = try store.allEntries()
        let lastValidFolders = try store.allFolders()
        let validData = try Data(contentsOf: manifest)

        var invalid = initial
        invalid.notes.append(entries[0])
        let invalidData = try JSONEncoder().encode(invalid)
        try invalidData.write(to: manifest, options: .atomic)
        do { try store.refresh(); throw MetadataStore.Failure.invalid("duplicate ID accepted") }
        catch MetadataStore.Failure.invalid(let reason) { try expect(reason == "duplicate IDs", "duplicate IDs rejected before building dictionaries") }
        try expect(try store.allEntries() == lastValidEntries && store.allFolders() == lastValidFolders, "rejected snapshot preserves both last valid indexes")
        do { try store.renameNote(id: target.id, name: "must fail"); throw MetadataStore.Failure.invalid("invalid snapshot overwritten") }
        catch MetadataStore.Failure.invalid(let reason) { try expect(reason == "duplicate IDs", "invalid snapshot blocks writes") }
        try expect(try Data(contentsOf: manifest) == invalidData, "invalid JSON is not overwritten by cached records")
        try validData.write(to: manifest, options: .atomic)
        try expect(store.entry(id: target.id)?.name == "另一个实例", "valid snapshot recovers after rejection")
        let reopened = try MetadataStore(root: root)
        try expect(try reopened.allEntries() == lastValidEntries, "reopening reconstructs 2000 memory records from JSON")
        try expect(try reopened.entries(inFolder: nil) == lastValidEntries.filter { $0.folderID == nil }, "reopening reconstructs root membership")
    }
    static func checkFolderMoves(in temporary: URL) throws {
        let root = temporary.appendingPathComponent("folder-moves")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MetadataStore(root: root)
        let first = try store.createFolder(name: "First", parentID: nil)
        let second = try store.createFolder(name: "Second", parentID: nil)
        let child = try store.createFolder(name: "Child", parentID: first.id)
        let descendant = try store.createFolder(name: "Descendant", parentID: child.id)
        let note = try store.register(name: "Preserved", folderID: descendant.id, ext: "md")
        let body = Data("![image](../images/preserved.png)".utf8)
        try body.write(to: store.fileURL(note))
        let image = store.imagesURL.appendingPathComponent("preserved.png")
        try Data([1, 2, 3]).write(to: image)
        let beforeValidation = try Data(contentsOf: store.manifestURL)
        try store.validateFolderMove(id: child.id, parentID: nil)
        try expect(try Data(contentsOf: store.manifestURL) == beforeValidation, "drag validation is read-only")
        try store.moveFolder(id: child.id, parentID: nil)
        try expect(try store.allFolders().first { $0.id == child.id }?.parentID == nil, "subfolder can move to root")
        try store.moveFolder(id: child.id, parentID: second.id)
        try expect(try store.allFolders().first { $0.id == child.id }?.parentID == second.id, "folder moves between parents")
        try expect(try store.allFolders().first { $0.id == descendant.id }?.parentID == child.id, "descendants keep their parent identity")
        try expect(store.entry(id: note.id) == note, "folder move preserves note metadata")
        try expect(try Data(contentsOf: store.fileURL(note)) == body && Data(contentsOf: image) == Data([1, 2, 3]), "folder move preserves bodies and image paths")
        let reopened = try MetadataStore(root: root)
        try expect(try reopened.allFolders().first { $0.id == child.id }?.parentID == second.id, "folder parent persists after reopening")
        let duplicate = try store.createFolder(name: "child", parentID: first.id)
        func reject(_ id: String, parentID: String?, message: String) throws {
            let before = try Data(contentsOf: store.manifestURL)
            var validationRejected = false
            do { try store.validateFolderMove(id: id, parentID: parentID) }
            catch { validationRejected = true }
            var moveRejected = false
            do { try store.moveFolder(id: id, parentID: parentID) }
            catch { moveRejected = true }
            try expect(validationRejected && moveRejected, message)
            try expect(try Data(contentsOf: store.manifestURL) == before, "rejected folder move preserves snapshot")
        }
        try reject(child.id, parentID: child.id, message: "folder cannot contain itself")
        try reject(child.id, parentID: descendant.id, message: "folder cannot move into descendant")
        try reject(child.id, parentID: first.id, message: "folder name collision is rejected ignoring case")
        try reject(child.id, parentID: UUID().uuidString.lowercased(), message: "missing destination is rejected")
        try reject(UUID().uuidString.lowercased(), parentID: second.id, message: "missing source is rejected")
        try store.renameFolder(id: duplicate.id, name: "Another")
        try reopened.moveFolder(id: child.id, parentID: first.id)
        try expect(try store.allFolders().first { $0.id == duplicate.id }?.name == "Another", "folder move preserves concurrent metadata updates")
    }

    static func checkExplicitNames(in temporary: URL) throws {
        let root = temporary.appendingPathComponent("explicit-names")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let uuidName = "2972690b-0b5c-43cc-9463-df948282b965"
        let original = "---\ntitle: YAML title\n---\n# Content heading\n![](../images/photo.png)\n"
        try original.write(to: root.appendingPathComponent(uuidName + ".md"), atomically: true, encoding: .utf8)
        let store = try MetadataStore(root: root)
        let migrated = try store.allEntries().first!
        try expect(migrated.name == uuidName && migrated.aliases == nil, "UUID source names are preserved without reading YAML or headings")
        let before = try Data(contentsOf: store.manifestURL)
        for name in ["", " ", "\t\n "] {
            do {
                _ = try store.register(name: name, folderID: nil, ext: "md")
                throw FailureForTest.unexpectedSuccess
            } catch MetadataStore.Failure.invalid(let reason) {
                try expect(reason == "A note name is required", "blank creation requires a name")
            }
            try expect(try Data(contentsOf: store.manifestURL) == before, "blank creation publishes no metadata")
            do {
                try store.renameNote(id: migrated.id, name: name)
                throw FailureForTest.unexpectedSuccess
            } catch MetadataStore.Failure.invalid(let reason) {
                try expect(reason == "A note name is required", "blank rename is rejected")
            }
            try expect(try Data(contentsOf: store.manifestURL) == before, "blank rename retains the name and aliases")
        }
        let entry = try store.register(name: "  个人化数据生成问题  ", folderID: nil, ext: "md")
        try expect(entry.name == "个人化数据生成问题", "explicit names are trimmed at creation")
        let body = store.fileURL(entry)
        for content in ["![](../images/6f6b050f-b76b-4f93-b01b-02107165abcd.png)", "# Changed heading", "---\ntitle: Changed YAML title\n---\nBody"] {
            try content.write(to: body, atomically: true, encoding: .utf8)
            let reopened = try MetadataStore(root: root)
            try expect(reopened.entry(id: entry.id)?.name == entry.name && reopened.entry(id: entry.id)?.aliases == nil,
                       "images, headings and YAML do not change the stored name")
        }
        try store.renameNote(id: entry.id, name: "手动设置的新名称")
        try expect(store.entry(id: entry.id)?.name == "手动设置的新名称", "manual rename updates the stored name")
        try expect(store.entry(id: entry.id)?.aliases == [entry.name], "only manual rename remembers the previous name")
    }
    enum FailureForTest: Error { case unexpectedSuccess }

    static func checkSharedHTMLResources(in temporary: URL) throws {
        let root = temporary.appendingPathComponent("html-resources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MetadataStore(root: root)
        let owner = try store.register(name: "Owner", folderID: nil, ext: "md")
        let reader = try store.register(name: "Reader", folderID: nil, ext: "md")
        let directory = store.imagesURL.appendingPathComponent(owner.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["a&b.png", "中文 图.png", "video.mp4", "linked.pdf", "unquoted.png", "set.png"]
        for name in names { try Data([1, 2, 3]).write(to: directory.appendingPathComponent(name)) }
        let prefix = "../images/\(owner.id)/"
        let html = "<IMG\n SRC='\(prefix)a&amp;b.png'>"
            + "<img src=\"\(prefix)中文%20图.png\"><video poster='\(prefix)video.mp4?size=1#preview'></video>"
            + "<a href='\(prefix)linked.pdf'>file</a><img src=\(prefix)unquoted.png>"
            + "<source srcset='\(prefix)set.png 1x, https://example.com/remote.png 2x'>"
        try html.write(to: store.fileURL(reader), atomically: true, encoding: .utf8)
        try "![image](\(prefix)a%26b.png)".write(to: store.fileURL(owner), atomically: true, encoding: .utf8)
        try store.trashNote(id: owner.id)
        try store.deletePermanently(id: owner.id)
        for name in names { try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "HTML resource survives deletion: " + name) }
        try expect(try String(contentsOf: store.fileURL(reader), encoding: .utf8) == html, "deletion preserves the referencing document")
        try store.trashNote(id: reader.id)
        try store.deletePermanently(id: reader.id)
        for name in names { try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "unshared HTML resource can be reclaimed: " + name) }
    }

    static func checkConflictCopies(in temporary: URL) throws {
        let root = temporary.appendingPathComponent("conflict-copies")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MetadataStore(root: root)
        let folder = try store.createFolder(name: "Folder", parentID: nil)
        let original = try store.register(name: "Original", folderID: folder.id, ext: "md")
        try "current body".write(to: store.fileURL(original), atomically: true, encoding: .utf8)
        let source = temporary.appendingPathComponent("conflict-version")
        let body = Data("alternate 😀\n<img src='../images/shared.png'>".utf8)
        try body.write(to: source)
        let copy = try store.preserveConflict(at: source, for: original.id, name: "Original (CONFLICT time)")
        try expect(copy.id != original.id && copy.folderID == folder.id, "conflict gets a separate identity in the same folder")
        try expect(try Data(contentsOf: store.fileURL(copy)) == body, "conflict bytes and relative resource links are preserved")
        let reopened = try MetadataStore(root: root)
        try expect(reopened.entry(at: store.fileURL(copy)) == copy, "conflict is discoverable after reopening")
        let second = try store.preserveConflict(at: source, for: original.id, name: copy.name)
        try expect(second.id != copy.id && second.name != copy.name, "same timestamp never drops another conflict")
        let manifest = try Data(contentsOf: store.manifestURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.notesURL.path).sorted()
        do { try store.preserveConflict(at: source.appendingPathExtension("missing"), for: original.id, name: "failed"); throw FailureForTest.unexpectedSuccess }
        catch is CocoaError { checks += 1 }
        try expect(try Data(contentsOf: store.manifestURL) == manifest, "failed copy publishes no metadata")
        try expect(try FileManager.default.contentsOfDirectory(atPath: store.notesURL.path).sorted() == files, "failed copy leaves no orphan body")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.manifestURL.path)
        var publicationRejected = false
        do { try store.preserveConflict(at: source, for: original.id, name: "failed publication") }
        catch { publicationRejected = true }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.manifestURL.path)
        try expect(publicationRejected, "conflict stays unresolved when metadata cannot be published")
        try expect(try Data(contentsOf: store.manifestURL) == manifest, "failed publication preserves the original manifest")
        try expect(try FileManager.default.contentsOfDirectory(atPath: store.notesURL.path).sorted() == files, "failed publication removes its unpublished copy")
        try expect(try Data(contentsOf: source) == body, "source version stays available")
        try expect(try String(contentsOf: store.fileURL(original), encoding: .utf8) == "current body", "conflict preservation never overwrites current text")
    }

    static func main() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("fsnotes-metadata-tests-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try checkExplicitNames(in: temporary)
        try checkSharedHTMLResources(in: temporary)
        try checkConflictCopies(in: temporary)
        let root = temporary.appendingPathComponent("library")
        try manager.createDirectory(at: root.appendingPathComponent("技术/Git/assets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("images/nested"), withIntermediateDirectories: true)
        try "image attachment".write(to: root.appendingPathComponent("images/nested/resource.txt"), atomically: true, encoding: .utf8)
        try "*.md text\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try Data([0,1,2,3]).write(to: root.appendingPathComponent("技术/Git/assets/p.png"))
        try "old\n".write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        let original = "# Title\n![photo](assets/p.png)\n[other](../../Other.md#section)\n[site](https://example.com/)\n`[code](assets/p.png)`\n```md\n[code](assets/p.png)\n```\n"
        try original.write(to: root.appendingPathComponent("技术/Git/笔记.md"), atomically: true, encoding: .utf8)
        try command(["init", "-q"], in: root)
        try command(["config", "user.name", "Tests"], in: root)
        try command(["config", "user.email", "test@example.com"], in: root)
        try command(["add", "."], in: root)
        try command(["commit", "-qm", "legacy"], in: root)
        var store: MetadataStore? = try MetadataStore(root: root)
        let initial = try store!.allEntries()
        try expect(manager.fileExists(atPath: store!.imagesURL.path), "root image directory created")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("Trash").path), "empty obsolete trash directory removed")
        let attributes = try String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8)
        try expect(attributes == "*.md text\nimages/** filter=lfs diff=lfs merge=lfs -text\n", "LFS rule added without losing user attributes")
        let note = initial.first { $0.name == "笔记" }!
        let other = initial.first { $0.name == "Other" }!
        try expect(initial.count == 2, "ordinary notes migrate")
        try expect(note.aliases == nil, "migration does not read headings into names or aliases")
        try expect(try store!.allFolders().count == 3, "nested and empty folders preserved")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("技术/Git/笔记.md").path), "legacy file removed after publishing metadata")
        let physical = store!.fileURL(note)
        let content = try String(contentsOf: physical, encoding: .utf8)
        try expect(content.contains("../技术/Git/assets/p.png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!), "relative image remains reachable")
        try expect(content.contains(other.id + ".md#section"), "note link uses stable UUID")
        try expect(content.contains("`[code](assets/p.png)`"), "inline code untouched")
        try expect(content.contains("```md\n[code](assets/p.png)\n```"), "fenced code untouched")
        try expect(content.contains("https://example.com/"), "remote URLs untouched")
        try command(["add", "."], in: root)
        try command(["commit", "-qm", "migrate"], in: root)
        let snapshot = try Data(contentsOf: store!.manifestURL)
        try store!.renameNote(id: note.id, name: "新名称: 'quote' \"双引号\"")
        try expect(store!.entry(id: note.id)?.aliases?.contains("笔记") == true, "renaming remembers old display name")
        let folder = try store!.createFolder(name: "Destination", parentID: nil)
        try store!.moveNote(id: note.id, folderID: folder.id)
        try store!.renameFolder(id: folder.id, name: "Renamed")
        try expect(store!.entry(id: note.id)!.folderID == folder.id, "logical move indexed")
        try expect(try String(contentsOf: physical, encoding: .utf8) == content, "rename and move leave body unchanged")
        try expect(manager.fileExists(atPath: physical.path), "physical path unchanged")
        try expect(try command(["diff", "--name-only"], in: root).trimmingCharacters(in: .whitespacesAndNewlines) == "metadata.json", "Git rename/move changes only metadata")
        let latest = try Data(contentsOf: store!.manifestURL)
        try store!.trashNote(id: note.id)
        try expect(store!.entry(id: note.id)!.trashed, "logical trash")
        try expect(manager.fileExists(atPath: physical.path), "trash preserves body history path")
        try store!.moveNote(id: note.id, folderID: folder.id)
        try store!.deleteFolder(id: folder.id)
        try expect(store!.entry(id: note.id)!.trashed && store!.entry(id: note.id)!.folderID == nil, "folder deletion moves notes to trash")
        try snapshot.write(to: store!.manifestURL, options: .atomic)
        try expect(try store!.refresh(), "Git checkout detected")
        try expect(store!.entry(id: note.id)!.name == "笔记", "old title restored")
        try expect(!store!.entry(id: note.id)!.trashed, "old folder/trash state restored")
        try latest.write(to: store!.manifestURL, options: .atomic)
        try store!.renameNote(id: other.id, name: "Other renamed")
        try expect(store!.entry(id: note.id)!.name.contains("新名称"), "mutation preserves external metadata changes")
        let valid = try Data(contentsOf: store!.manifestURL)
        try "<<<<<<< HEAD\nconflict".write(to: store!.manifestURL, atomically: true, encoding: .utf8)
        do { try store!.renameNote(id: other.id, name: "must fail"); throw MetadataStore.Failure.invalid("conflict accepted") } catch is DecodingError { checks += 1 }
        try expect(try String(contentsOf: store!.manifestURL, encoding: .utf8).hasPrefix("<<<<<<<"), "conflict is never overwritten")
        try valid.write(to: store!.manifestURL, options: .atomic)
        store = nil
        store = try MetadataStore(root: root)
        try expect(store!.entry(id: note.id)!.name.contains("新名称"), "memory index rebuilds from portable snapshot")
        try expect(try command(["ls-files"], in: root).contains("metadata.json"), "metadata tracked by Git")
        let second = try MetadataStore(root: root)
        try expect(try String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8) == attributes, "reopening does not duplicate LFS attributes")
        let nested = try second.createFolder(name: "Child", parentID: folder.id)
        try store!.renameNote(id: other.id, name: "from first instance")
        try expect(try store!.allFolders().contains { $0.id == nested.id }, "independent instances preserve updates")
        var bad = try JSONDecoder().decode(MetadataStore.Snapshot.self, from: Data(contentsOf: store!.manifestURL))
        bad.folders[0].parentID = bad.folders[0].id
        try JSONEncoder().encode(bad).write(to: store!.manifestURL, options: .atomic)
        do { try store!.refresh(); throw MetadataStore.Failure.invalid("cycle accepted") } catch MetadataStore.Failure.invalid(let reason) { try expect(reason == "folder cycle", "cycles rejected") }
        try valid.write(to: store!.manifestURL, options: .atomic)
        let journal = root.appendingPathComponent(".fsnotes-migration.json")
        try snapshot.write(to: journal)
        try "old\n".write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        store = nil
        _ = try MetadataStore(root: root)
        try expect(!manager.fileExists(atPath: journal.path), "post-publication migration cleanup resumes")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("Other.md").path), "resumed cleanup removes remaining original")
        // Interrupted before publication: the journal reuses IDs and replaces partial staging.
        let interrupted = temporary.appendingPathComponent("interrupted")
        try manager.createDirectory(at: interrupted.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "original".write(to: interrupted.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        let interruptedEntry = MetadataStore.Entry(id: UUID().uuidString.lowercased(), name: "Old", folderID: nil, fileExtension: "md", legacyPath: "Old.md")
        let interruptedPlan = MetadataStore.Snapshot(notes: [interruptedEntry])
        try JSONEncoder().encode(interruptedPlan).write(to: interrupted.appendingPathComponent(".fsnotes-migration.json"))
        try "partial".write(to: interrupted.appendingPathComponent("notes/.migration-" + interruptedEntry.id + ".md"), atomically: true, encoding: .utf8)
        let resumed = try MetadataStore(root: interrupted)
        try expect(resumed.entry(id: interruptedEntry.id)?.name == "Old", "interrupted migration reuses ID")
        try expect(try String(contentsOf: resumed.fileURL(interruptedEntry), encoding: .utf8) == "original", "partial staging replaced")
        // A changed original must survive post-publication cleanup.
        try "external change".write(to: interrupted.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(interruptedPlan).write(to: interrupted.appendingPathComponent(".fsnotes-migration.json"))
        do {
            _ = try MetadataStore(root: interrupted)
            throw MetadataStore.Failure.invalid("changed original deleted")
        } catch MetadataStore.Failure.invalid(let message) {
            try expect(message.contains("original changed"), "external edit blocks cleanup")
        }
        try expect(try String(contentsOf: interrupted.appendingPathComponent("Old.md"), encoding: .utf8) == "external change", "external edit retained")
        try manager.removeItem(at: interrupted.appendingPathComponent(".fsnotes-migration.json"))
        try manager.removeItem(at: resumed.manifestURL)
        do {
            _ = try MetadataStore(root: interrupted)
            throw MetadataStore.Failure.invalid("missing manifest accepted")
        } catch MetadataStore.Failure.invalid(let message) {
            try expect(message.contains("metadata.json is missing"), "missing manifest never resets IDs")
        }
        // A pre-existing user folder named notes is migrated as a logical folder.
        let namedNotes = temporary.appendingPathComponent("named-notes")
        try manager.createDirectory(at: namedNotes.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "body".write(to: namedNotes.appendingPathComponent("notes/Human.md"), atomically: true, encoding: .utf8)
        let namedStore = try MetadataStore(root: namedNotes)
        try expect(try namedStore.allFolders().first?.name == "notes", "existing notes folder preserved")
        try expect(try namedStore.allEntries().first?.name == "Human", "existing notes folder content migrated")
        let special = "![space](<assets/my photo.png>)\n[paren](assets/a(b).png)\n[ref]: <assets/my photo.png>\n    [code](assets/a.png)"
        let relocated = MetadataStore.relocateLinks(special, source: namedNotes.appendingPathComponent("Old.md"), destination: namedNotes.appendingPathComponent("notes/New.md"), notes: [:])
        try expect(relocated.contains("<../assets/my%20photo.png>"), "angle-bracket paths with spaces preserved")
        try expect(relocated.contains("../assets/a(b).png"), "parentheses in filenames preserved")
        try expect(relocated.contains("    [code](assets/a.png)"), "indented code preserved")
        let cloud = temporary.appendingPathComponent("cloud")
        try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data("remote snapshot".utf8).write(to: cloud.appendingPathComponent(".metadata.json.icloud"))
        do {
            _ = try MetadataStore(root: cloud)
            throw MetadataStore.Failure.invalid("cloud placeholder overwritten")
        } catch MetadataStore.Failure.invalid(let reason) { try expect(reason.contains("finish downloading"), "cloud placeholder blocks migration") }
        try expect(!manager.fileExists(atPath: cloud.appendingPathComponent("metadata.json").path), "cloud snapshot not replaced by empty metadata")
        try checkFolderMoves(in: temporary)
        try checkMemoryIndexes(in: temporary)
        print("Metadata integration: \(checks) checks passed")
    }
}
