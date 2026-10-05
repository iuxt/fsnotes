import Foundation
import SQLite3

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
    static func main() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("fsnotes-metadata-tests-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("library")
        try manager.createDirectory(at: root.appendingPathComponent("技术/Git/assets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data([0,1,2,3]).write(to: root.appendingPathComponent("技术/Git/assets/p.png"))
        try "old\n".write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        let original = "# Title\n![photo](assets/p.png)\n[other](../../Other.md#section)\n[site](https://example.com/)\n`[code](assets/p.png)`\n```md\n[code](assets/p.png)\n```\n"
        try original.write(to: root.appendingPathComponent("技术/Git/笔记.md"), atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("技术/Git/Bundle.textbundle")
        try manager.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([4,5,6]).write(to: bundle.appendingPathComponent("assets/b.png"))
        try "![b](assets/b.png)\n[other](../../../Other.md)".write(to: bundle.appendingPathComponent("text.markdown"), atomically: true, encoding: .utf8)
        try "{\"version\":2,\"type\":\"net.daringfireball.markdown\"}".write(to: bundle.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
        try command(["init", "-q"], in: root)
        try command(["config", "user.name", "Tests"], in: root)
        try command(["config", "user.email", "test@example.com"], in: root)
        try command(["add", "."], in: root)
        try command(["commit", "-qm", "legacy"], in: root)
        let database = temporary.appendingPathComponent("local/index.sqlite")
        var store: MetadataStore? = try MetadataStore(root: root, databaseURL: database)
        let initial = try store!.allEntries()
        let note = initial.first { $0.name == "笔记" }!
        let other = initial.first { $0.name == "Other" }!
        let package = initial.first { $0.name == "Bundle" }!
        try expect(initial.count == 3, "all note formats migrate")
        try expect(note.aliases?.contains("Title") == true, "old heading remains a link alias")
        try expect(try store!.allFolders().count == 3, "nested and empty folders preserved")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("技术/Git/笔记.md").path), "legacy file removed after publishing metadata")
        let physical = store!.fileURL(note)
        let content = try String(contentsOf: physical, encoding: .utf8)
        try expect(content.contains("../技术/Git/assets/p.png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!), "relative image remains reachable")
        try expect(content.contains(other.id + ".md#section"), "note link uses stable UUID")
        try expect(content.contains("`[code](assets/p.png)`"), "inline code untouched")
        try expect(content.contains("```md\n[code](assets/p.png)\n```"), "fenced code untouched")
        try expect(content.contains("https://example.com/"), "remote URLs untouched")
        let packageText = try String(contentsOf: store!.fileURL(package).appendingPathComponent("text.markdown"), encoding: .utf8)
        try expect(packageText.contains("assets/b.png"), "TextBundle internal assets stay relative")
        try expect(packageText.contains("../" + other.id + ".md"), "TextBundle external note links relocate")
        try expect(try Data(contentsOf: store!.fileURL(package).appendingPathComponent("assets/b.png")) == Data([4,5,6]), "TextBundle assets preserved")
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
        try manager.removeItem(at: database)
        store = try MetadataStore(root: root, databaseURL: database)
        try expect(store!.entry(id: note.id)!.name.contains("新名称"), "SQLite rebuilds from portable snapshot")
        try expect(try command(["ls-files"], in: root).contains("metadata.json"), "metadata tracked by Git")
        try expect(!command(["ls-files"], in: root).contains("sqlite"), "local database excluded from Git")
        let second = try MetadataStore(root: root, databaseURL: temporary.appendingPathComponent("another.sqlite"))
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
        _ = try MetadataStore(root: root, databaseURL: database)
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
        let resumed = try MetadataStore(root: interrupted, databaseURL: temporary.appendingPathComponent("resumed.sqlite"))
        try expect(resumed.entry(id: interruptedEntry.id)?.name == "Old", "interrupted migration reuses ID")
        try expect(try String(contentsOf: resumed.fileURL(interruptedEntry), encoding: .utf8) == "original", "partial staging replaced")
        // A changed original must survive post-publication cleanup.
        try "external change".write(to: interrupted.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(interruptedPlan).write(to: interrupted.appendingPathComponent(".fsnotes-migration.json"))
        do {
            _ = try MetadataStore(root: interrupted, databaseURL: temporary.appendingPathComponent("changed.sqlite"))
            throw MetadataStore.Failure.invalid("changed original deleted")
        } catch MetadataStore.Failure.invalid(let message) {
            try expect(message.contains("original changed"), "external edit blocks cleanup")
        }
        try expect(try String(contentsOf: interrupted.appendingPathComponent("Old.md"), encoding: .utf8) == "external change", "external edit retained")
        try manager.removeItem(at: interrupted.appendingPathComponent(".fsnotes-migration.json"))
        try manager.removeItem(at: resumed.manifestURL)
        do {
            _ = try MetadataStore(root: interrupted, databaseURL: temporary.appendingPathComponent("missing.sqlite"))
            throw MetadataStore.Failure.invalid("missing manifest accepted")
        } catch MetadataStore.Failure.invalid(let message) {
            try expect(message.contains("metadata.json is missing"), "missing manifest never resets IDs")
        }
        // A pre-existing user folder named notes is migrated as a logical folder.
        let namedNotes = temporary.appendingPathComponent("named-notes")
        try manager.createDirectory(at: namedNotes.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "body".write(to: namedNotes.appendingPathComponent("notes/Human.md"), atomically: true, encoding: .utf8)
        let namedStore = try MetadataStore(root: namedNotes, databaseURL: temporary.appendingPathComponent("named.sqlite"))
        try expect(try namedStore.allFolders().first?.name == "notes", "existing notes folder preserved")
        try expect(try namedStore.allEntries().first?.name == "Human", "existing notes folder content migrated")
        // Corrupt SQLite is quarantined and rebuilt from JSON.
        let corruptDB = temporary.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corruptDB)
        let repaired = try MetadataStore(root: namedNotes, databaseURL: corruptDB)
        try expect(try repaired.allEntries().first?.name == "Human", "corrupt index rebuilds")
        let special = "![space](<assets/my photo.png>)\n[paren](assets/a(b).png)\n[ref]: <assets/my photo.png>\n    [code](assets/a.png)"
        let relocated = MetadataStore.relocateLinks(special, source: namedNotes.appendingPathComponent("Old.md"), destination: namedNotes.appendingPathComponent("notes/New.md"), notes: [:])
        try expect(relocated.contains("<../assets/my%20photo.png>"), "angle-bracket paths with spaces preserved")
        try expect(relocated.contains("../assets/a(b).png"), "parentheses in filenames preserved")
        try expect(relocated.contains("    [code](assets/a.png)"), "indented code preserved")
        let cloud = temporary.appendingPathComponent("cloud")
        try manager.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data("remote snapshot".utf8).write(to: cloud.appendingPathComponent(".metadata.json.icloud"))
        do {
            _ = try MetadataStore(root: cloud, databaseURL: temporary.appendingPathComponent("cloud.sqlite"))
            throw MetadataStore.Failure.invalid("cloud placeholder overwritten")
        } catch MetadataStore.Failure.invalid(let reason) { try expect(reason.contains("finish downloading"), "cloud placeholder blocks migration") }
        try expect(!manager.fileExists(atPath: cloud.appendingPathComponent("metadata.json").path), "cloud snapshot not replaced by empty metadata")
        print("Metadata integration: \(checks) checks passed")
    }
}
