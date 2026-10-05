import Foundation
import SQLite3

/// metadata.json is the portable snapshot. SQLite is a local, rebuildable query store.
/// Every mutation reads the current snapshot before changing it, including after Git checkout.
final class MetadataStore {
    struct Folder: Codable, Equatable {
        var id: String
        var name: String
        var parentID: String?
        var legacyPath: String?
    }
    struct Entry: Codable, Equatable {
        var id: String
        var name: String
        var folderID: String?
        var fileExtension: String
        var trashed: Bool = false
        var legacyPath: String?
        var aliases: [String]?
    }
    struct Snapshot: Codable, Equatable {
        var version = 1
        var folders: [Folder] = []
        var notes: [Entry] = []
    }
    enum Failure: LocalizedError {
        case invalid(String)
        case database(String, Int32)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "FSNotes metadata: " + reason
            case .database(let reason, _): return "FSNotes local index: " + reason
            }
        }
    }

    let root: URL
    let databaseURL: URL
    var manifestURL: URL { root.appendingPathComponent("metadata.json") }
    var notesURL: URL { root.appendingPathComponent("notes", isDirectory: true) }
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private struct Stamp: Equatable { let modified: Date; let size: UInt64; let inode: UInt64 }
    private var loadedStamp: Stamp?
    private var failedStamp: Stamp?
    private var loadedData: Data?
    private var snapshot = Snapshot()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(root: URL, databaseURL: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.databaseURL = databaseURL
        if (try? notesURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.invalid("the reserved notes directory cannot be a symbolic link") }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var initialized = false
        defer { if !initialized { sqlite3_close(database); database = nil } }
        do { try openDatabase() }
        catch Failure.database(_, let code) where code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            sqlite3_close(database)
            database = nil
            // The portable manifest is authoritative; quarantine a corrupt local index.
            let quarantine = databaseURL.appendingPathExtension("corrupt-" + UUID().uuidString)
            try FileManager.default.moveItem(at: databaseURL, to: quarantine)
            try openDatabase()
        }
        try coordinateWrite(at: self.root) {
            if !FileManager.default.fileExists(atPath: manifestURL.path) { try migrate() }
            try finishMigrationCleanup()
        }
        try refresh()
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        initialized = true
    }

    private func openDatabase() throws {
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else { throw Failure.database("cannot open local database", status) }
        sqlite3_busy_timeout(database, 5000)
        try execute("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, record TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, name TEXT NOT NULL, folder_id TEXT, record TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS notes_folder ON notes(folder_id)")
        try execute("CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent_id)")
    }

    deinit { sqlite3_close(database) }

    @discardableResult func refresh(force: Bool = true) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let stamp = try manifestStamp()
        if !force && (stamp == loadedStamp || stamp == failedStamp) { return false }
        do {
            let data = try Data(contentsOf: manifestURL)
            guard try manifestStamp() == stamp else { throw Failure.invalid("metadata changed while reading; retry") }
            if loadedData == data { loadedStamp = stamp; failedStamp = nil; return false }
            let next = try JSONDecoder().decode(Snapshot.self, from: data)
            try validate(next)
            try rebuildDatabase(next)
            snapshot = next
            loadedData = data
            loadedStamp = stamp
            failedStamp = nil
            return true
        } catch {
            failedStamp = stamp
            throw error
        }
    }

    private func manifestStamp() throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        return Stamp(modified: attributes[.modificationDate] as? Date ?? .distantPast,
                     size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                     inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    func allFolders() throws -> [Folder] {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        return try query("SELECT record FROM folders ORDER BY id", as: Folder.self)
    }

    func allEntries() throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        return try query("SELECT record FROM notes ORDER BY id", as: Entry.self)
    }

    func entries(inFolder id: String?) throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        let predicate = id.map { "folder_id = " + quote($0) } ?? "folder_id IS NULL"
        return try query("SELECT record FROM notes WHERE " + predicate + " ORDER BY id", as: Entry.self)
    }

    func entry(at url: URL) -> Entry? {
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == notesURL.standardizedFileURL else { return nil }
        return entry(id: url.deletingPathExtension().lastPathComponent)
    }

    func entry(id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        // A malformed/conflicted snapshot blocks writes; the last valid index stays readable.
        do { try refresh(force: false) } catch { NSLog("%@", error.localizedDescription) }
        return try? query("SELECT record FROM notes WHERE id = \(quote(id))", as: Entry.self).first
    }

    func fileURL(_ entry: Entry) -> URL {
        notesURL.appendingPathComponent(entry.id + "." + entry.fileExtension)
    }

    func folderURL(_ id: String) -> URL {
        root.appendingPathComponent(".fsnotes-folders", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    func register(id: String = UUID().uuidString.lowercased(), name: String, folderID: String?, ext: String, legacyPath: String? = nil) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        var entry = Entry(id: id, name: name, folderID: folderID, fileExtension: ext, legacyPath: legacyPath)
        try mutate { next in
            guard !next.notes.contains(where: { $0.id == id }) else { throw Failure.invalid("duplicate note ID") }
            entry.name = Self.availableName(name, folderID: folderID, excluding: nil, in: next)
            next.notes.append(entry)
        }
        return entry
    }

    func renameNote(id: String, name: String) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            let folder = next.notes[index].folderID
            let target = Self.availableName(name, folderID: folder, excluding: id, in: next)
            guard target != next.notes[index].name else { return }
            Self.rememberName(&next.notes[index])
            next.notes[index].name = target
        }
    }

    func moveNote(id: String, folderID: String?) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            let target = Self.availableName(next.notes[index].name, folderID: folderID, excluding: id, in: next)
            if target != next.notes[index].name { Self.rememberName(&next.notes[index]) }
            next.notes[index].folderID = folderID
            next.notes[index].trashed = false
            next.notes[index].name = target
        }
    }

    func trashNote(id: String) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            next.notes[index].trashed = true
        }
    }

    private static func rememberName(_ entry: inout Entry) {
        var aliases = entry.aliases ?? []
        if !aliases.contains(entry.name) { aliases.append(entry.name) }
        entry.aliases = Array(aliases.suffix(50))
    }

    private static func availableName(_ name: String, folderID: String?, excluding id: String?, in next: Snapshot) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Note" : trimmed
        var candidate = base
        var number = 2
        while next.notes.contains(where: { !$0.trashed && $0.folderID == folderID && $0.id != id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    func changeExtension(id: String, to ext: String) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            next.notes[index].fileExtension = ext
        }
    }

    func delete(id: String) throws {
        try mutate { $0.notes.removeAll(where: { $0.id == id }) }
    }

    func createFolder(name: String, parentID: String?) throws -> Folder {
        let folder = Folder(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentID: parentID)
        try mutate { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(id: String, name: String) throws {
        try mutate { next in
            guard let index = next.folders.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("folder no longer exists") }
            next.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Deleting a folder sends its notes to logical Trash without changing their physical paths.
    func deleteFolder(id: String) throws {
        try mutate { next in
            var deleted: Set<String> = [id]
            var previous = 0
            while previous != deleted.count {
                previous = deleted.count
                for folder in next.folders where folder.parentID.map(deleted.contains) == true { deleted.insert(folder.id) }
            }
            for index in next.notes.indices where next.notes[index].folderID.map(deleted.contains) == true {
                next.notes[index].trashed = true
                next.notes[index].folderID = nil
            }
            next.folders.removeAll { deleted.contains($0.id) }
        }
    }

    private func mutate(_ change: (inout Snapshot) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try coordinateWrite(at: manifestURL) {
            try refresh()
            var next = snapshot
            try change(&next)
            try validate(next)
            next.folders.sort { $0.id < $1.id }
            next.notes.sort { $0.id < $1.id }
            let data = try encoder.encode(next)
            guard data != loadedData else { return }
            // Publish the portable snapshot first. If SQLite fails, refresh rebuilds it.
            guard try Data(contentsOf: manifestURL) == loadedData else { throw Failure.invalid("metadata changed during this operation; retry") }
            try data.write(to: manifestURL, options: .atomic)
            loadedData = nil
            try refresh()
        }
    }

    private func coordinateWrite(at url: URL, _ action: () throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
            result = Result { try action() }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw Failure.invalid("file coordination did not complete") }
        try result.get()
    }

    private func validate(_ next: Snapshot) throws {
        guard next.version == 1 else { throw Failure.invalid("unsupported metadata version") }
        let folders = Dictionary(grouping: next.folders, by: { $0.id })
        guard folders.count == next.folders.count, Set(next.notes.map { $0.id }).count == next.notes.count else { throw Failure.invalid("duplicate IDs") }
        for folder in next.folders {
            guard UUID(uuidString: folder.id) != nil, !folder.name.isEmpty, !folder.name.contains("/"), folder.parentID == nil || folders[folder.parentID!] != nil else { throw Failure.invalid("invalid folder") }
            var seen: Set<String> = [folder.id]
            var parent = folder.parentID
            while let id = parent {
                guard seen.insert(id).inserted else { throw Failure.invalid("folder cycle") }
                parent = folders[id]?.first?.parentID
            }
            guard !next.folders.contains(where: { $0.id != folder.id && $0.parentID == folder.parentID && $0.name.caseInsensitiveCompare(folder.name) == .orderedSame }) else { throw Failure.invalid("folder name already exists") }
        }
        for entry in next.notes {
            guard UUID(uuidString: entry.id) != nil, ["md", "markdown", "txt", "fountain", "textbundle", "etp"].contains(entry.fileExtension), !entry.name.isEmpty, entry.folderID == nil || folders[entry.folderID!] != nil else { throw Failure.invalid("invalid note") }
        }
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    private func nullable(_ value: String?) -> String { value.map(quote) ?? "NULL" }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database(String(cString: sqlite3_errmsg(database)), sqlite3_errcode(database)) }
    }

    private func query<T: Decodable>(_ sql: String, as type: T.Type) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.database("database query failed", sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        var result = [T]()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let bytes = sqlite3_column_text(statement, 0) else { throw Failure.invalid("invalid database row") }
            result.append(try JSONDecoder().decode(T.self, from: Data(String(cString: bytes).utf8)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw Failure.database("database read failed", sqlite3_errcode(database)) }
        return result
    }

    private func rebuildDatabase(_ next: Snapshot) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM notes")
            try execute("DELETE FROM folders")
            for folder in next.folders {
                let json = String(decoding: try encoder.encode(folder), as: UTF8.self)
                try execute("INSERT INTO folders VALUES (\(quote(folder.id)), \(quote(folder.name)), \(nullable(folder.parentID)), \(quote(json)))")
            }
            for entry in next.notes {
                let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
                try execute("INSERT INTO notes VALUES (\(quote(entry.id)), \(quote(entry.name)), \(nullable(entry.folderID)), \(quote(json)))")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Copies first, publishes metadata atomically, then removes old note files.
    /// The persisted plan makes interrupted migrations resumable with the same IDs.
    private func migrate() throws {
        try ensureMigrationFilesAvailable()
        let manager = FileManager.default
        let journal = root.appendingPathComponent(".fsnotes-migration.json")
        var plan = Snapshot()
        if manager.fileExists(atPath: journal.path) {
            plan = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal))
        } else {
            // An existing UUID library without its manifest must never be silently re-imported.
            let indexedNotes = try query("SELECT record FROM notes LIMIT 1", as: Entry.self)
            let indexedFolders = try query("SELECT record FROM folders LIMIT 1", as: Folder.self)
            let knownLibrary = manager.fileExists(atPath: notesURL.appendingPathComponent(".fsnotes-library").path)
                || !indexedNotes.isEmpty || !indexedFolders.isEmpty
            if knownLibrary {
                throw Failure.invalid("metadata.json is missing from an existing UUID library; restore it from Git")
            }
            func scan(_ directory: URL, parentID: String?) throws {
                let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles).sorted { $0.path < $1.path }
                for rawFile in files {
                    let file = rawFile.standardizedFileURL.resolvingSymlinksInPath()
                    let values = try rawFile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    let relative = String(file.path.dropFirst(root.path.count + 1))
                    if ["md", "markdown", "txt", "fountain", "textbundle", "etp"].contains(file.pathExtension.lowercased()) {
                        var id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
                        if plan.notes.contains(where: { $0.id == id }) { id = UUID().uuidString.lowercased() }
                        let displayName = Self.availableName(Self.legacyDisplayName(file), folderID: parentID, excluding: nil, in: plan)
                        var entry = Entry(id: id, name: displayName, folderID: parentID, fileExtension: file.pathExtension.lowercased(), legacyPath: relative)
                        if let heading = Self.legacyContentTitle(file), heading != displayName { entry.aliases = [heading] }
                        plan.notes.append(entry)
                    } else if values.isDirectory == true, !["Trash", "assets", "i", "files"].contains(file.lastPathComponent) {
                        // Nested repositories keep their independent storage and Git root.
                        if manager.fileExists(atPath: file.appendingPathComponent(".git").path) { continue }
                        let folder = Folder(id: UUID().uuidString.lowercased(), name: file.lastPathComponent, parentID: parentID, legacyPath: relative)
                        plan.folders.append(folder)
                        try scan(file, parentID: folder.id)
                    }
                }
            }
            try scan(root, parentID: nil)
            try validate(plan)
            try encoder.encode(plan).write(to: journal, options: .atomic)
        }
        try validateMigrationPlan(plan)
        try manager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        let paths = Dictionary(uniqueKeysWithValues: plan.notes.compactMap { entry -> (String, URL)? in
            guard let path = entry.legacyPath else { return nil }
            return (root.appendingPathComponent(path).standardizedFileURL.path, fileURL(entry))
        })
        for entry in plan.notes {
            guard let path = entry.legacyPath else { continue }
            let source = root.appendingPathComponent(path)
            let destination = fileURL(entry)
            if manager.fileExists(atPath: destination.path) { continue }
            let staging = notesURL.appendingPathComponent(".migration-" + entry.id + "." + entry.fileExtension)
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            try manager.copyItem(at: source, to: staging)
            if ["md", "markdown", "txt", "fountain"].contains(entry.fileExtension) {
                let original = try String(contentsOf: source, encoding: .utf8)
                let rewritten = Self.relocateLinks(original, source: source, destination: destination, notes: paths)
                if rewritten != original { try rewritten.write(to: staging, atomically: true, encoding: .utf8) }
            } else if entry.fileExtension == "textbundle" {
                for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where ["md", "markdown"].contains(file.pathExtension) {
                    let original = try String(contentsOf: file, encoding: .utf8)
                    let rewritten = Self.relocateLinks(original, source: file, destination: destination.appendingPathComponent(file.lastPathComponent), notes: paths)
                    if rewritten != original { try rewritten.write(to: staging.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8) }
                }
            }
            let attributes = try manager.attributesOfItem(atPath: source.path)
            try manager.setAttributes(attributes.filter { [.creationDate, .modificationDate, .posixPermissions].contains($0.key) }, ofItemAtPath: staging.path)
            try manager.moveItem(at: staging, to: destination)
        }
        // Preserve existing encrypted-folder markers at a stable folder ID path.
        for folder in plan.folders {
            if let old = folder.legacyPath {
                let marker = root.appendingPathComponent(old).appendingPathComponent(".encrypt")
                if manager.fileExists(atPath: marker.path) {
                    let directory = folderURL(folder.id)
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(".encrypt")
                    if !manager.fileExists(atPath: destination.path) { try manager.copyItem(at: marker, to: destination) }
                }
            }
        }
        plan.folders.sort { $0.id < $1.id }
        plan.notes.sort { $0.id < $1.id }
        try encoder.encode(plan).write(to: manifestURL, options: .atomic)
        try Data("1\n".utf8).write(to: notesURL.appendingPathComponent(".fsnotes-library"), options: .atomic)
        try finishMigrationCleanup()
    }

    private func ensureMigrationFilesAvailable() throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey], options: []) else { return }
        var waiting = false
        for case let file as URL in enumerator {
            if file.pathExtension == "icloud" {
                var filename = file.deletingPathExtension().lastPathComponent
                if filename.hasPrefix(".") { filename.removeFirst() }
                let original = file.deletingLastPathComponent().appendingPathComponent(filename)
                try? manager.startDownloadingUbiquitousItem(at: original)
                waiting = true
                continue
            }
            if file.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
            if (try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded {
                try? manager.startDownloadingUbiquitousItem(at: file)
                waiting = true
            }
        }
        if waiting { throw Failure.invalid("iCloud files must finish downloading before migration; original files and metadata have been retained") }
    }

    private static func legacyDisplayName(_ file: URL) -> String {
        let filename = file.deletingPathExtension().lastPathComponent
        return UUID(uuidString: filename) == nil ? filename : legacyContentTitle(file) ?? "Untitled Note"
    }

    private static func legacyContentTitle(_ file: URL) -> String? {
        if file.pathExtension.lowercased() == "etp" { return nil }
        var body = file
        if file.pathExtension.lowercased() == "textbundle" {
            body = ["text.markdown", "text.md", "text.txt", "text.fountain"].map { file.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) } ?? file
        }
        guard let text = try? String(contentsOf: body, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines)
        if lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") {
            if let title = lines[1..<closing].first(where: { $0.hasPrefix("title:") }) {
                let value = String(title.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { return value }
            }
            lines = Array(lines.dropFirst(closing + 1))
        }
        guard var first = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while first.hasPrefix("#") { first.removeFirst() }
        first = first.trimmingCharacters(in: .whitespaces)
        return first.isEmpty || first.hasPrefix("![") ? nil : String(first.prefix(100))
    }

    private func validateMigrationPlan(_ plan: Snapshot) throws {
        try validate(plan)
        for entry in plan.notes {
            guard let path = entry.legacyPath, !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }),
                  (path as NSString).pathExtension.lowercased() == entry.fileExtension else {
                throw Failure.invalid("invalid migration source path")
            }
            let source = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard source.path.hasPrefix(root.path + "/") else { throw Failure.invalid("migration source is outside the library") }
        }
    }

    private func finishMigrationCleanup() throws {
        let manager = FileManager.default
        let journal = root.appendingPathComponent(".fsnotes-migration.json")
        guard manager.fileExists(atPath: journal.path), manager.fileExists(atPath: manifestURL.path) else { return }
        let plan = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: journal))
        let published = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: manifestURL))
        try validateMigrationPlan(plan)
        guard Set(plan.notes.map { $0.id }) == Set(published.notes.map { $0.id }) else {
            throw Failure.invalid("migration metadata changed; original files have been retained")
        }
        let mapping = Dictionary(uniqueKeysWithValues: plan.notes.map { (root.appendingPathComponent($0.legacyPath!).standardizedFileURL.path, fileURL($0)) })
        var originals = [URL]()
        // Verify every remaining original before deleting any of them. External edits made
        // during an interrupted migration must be retained, rather than replaced by stale copies.
        for entry in plan.notes {
            guard let path = entry.legacyPath else { continue }
            let source = root.appendingPathComponent(path).standardizedFileURL
            let destination = fileURL(entry).standardizedFileURL
            guard source.path.hasPrefix(root.path + "/"), manager.fileExists(atPath: destination.path) else { throw Failure.invalid("incomplete migration; original files have been retained") }
            if source == destination || !manager.fileExists(atPath: source.path) { continue }
            func verify(_ from: URL, _ to: URL, rewrite: Bool) throws {
                let original = try Data(contentsOf: from)
                let expected: Data
                if rewrite, let text = String(data: original, encoding: .utf8) {
                    expected = Data(Self.relocateLinks(text, source: from, destination: to, notes: mapping).utf8)
                } else { expected = original }
                guard try Data(contentsOf: to) == expected else { throw Failure.invalid("original changed during migration; both copies have been retained") }
            }
            if entry.fileExtension == "textbundle" {
                guard let files = manager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { throw Failure.invalid("cannot validate migrated TextBundle") }
                for case let raw as URL in files {
                    if try raw.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
                    let from = raw.standardizedFileURL.resolvingSymlinksInPath()
                    let target = destination.appendingPathComponent(String(from.path.dropFirst(source.path.count + 1)))
                    try verify(from, target, rewrite: from.deletingLastPathComponent() == source && ["md", "markdown"].contains(from.pathExtension))
                }
            } else {
                try verify(source, destination, rewrite: ["md", "markdown", "txt", "fountain"].contains(entry.fileExtension))
            }
            originals.append(source)
        }
        for source in originals { try manager.removeItem(at: source) }
        try manager.removeItem(at: journal)
    }

    private static let linkRegex = try! NSRegularExpression(pattern: "\\]\\((?:<([^>\\n]+)>|((?:[^\\s()]|\\([^\\s()]*\\))+))|^ {0,3}\\[[^\\]]+\\]:[ \\t]*(?:<([^>\\n]+)>|([^\\s]+))")

    static func localLinkTargets(in text: String) -> [String] {
        var targets = [String]()
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            if fence != nil || line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            let nsLine = line as NSString
            for match in linkRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                guard let range = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
                if nsLine.substring(to: range.location).filter({ $0 == "`" }).count % 2 == 1 { continue }
                let target = nsLine.substring(with: range)
                if !target.hasPrefix("#"), !target.hasPrefix("/"), URLComponents(string: target)?.scheme == nil { targets.append(target) }
            }
        }
        return targets
    }

    /// Preserve local inline/reference Markdown links when moving a document into notes/.
    /// Code fences, inline code, absolute URLs and anchors are left untouched.
    static func relocateLinks(_ text: String, source: URL, destination: URL, notes: [String: URL]) -> String {
        func relocate(_ target: String) -> String {
            guard !target.isEmpty, !target.hasPrefix("#"), !target.hasPrefix("/"), URLComponents(string: target)?.scheme == nil else { return target }
            let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let resolved = source.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            var to = notes[resolved.path] ?? resolved
            if notes[resolved.path] == nil, let package = notes.keys.first(where: { $0.hasSuffix(".textbundle") && resolved.path.hasPrefix($0 + "/") }), let moved = notes[package] {
                to = moved.appendingPathComponent(String(resolved.path.dropFirst(package.count + 1)))
            }
            let fromParts = destination.deletingLastPathComponent().pathComponents
            let toParts = to.pathComponents
            var common = 0
            while common < min(fromParts.count, toParts.count), fromParts[common] == toParts[common] { common += 1 }
            let relative = (Array(repeating: "..", count: fromParts.count - common) + toParts.dropFirst(common)).joined(separator: "/")
            return (relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative) + (parts.count > 1 ? "#" + parts[1] : "")
        }
        let regex = Self.linkRegex
        var result = String()
        var fence: String?
        for line in text.components(separatedBy: "\n") {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("```") || trim.hasPrefix("~~~") {
                let marker = String(trim.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                result += line + "\n"
                continue
            }
            var rewritten = line
            if fence == nil && !line.hasPrefix("    ") && !line.hasPrefix("\t") {
                let nsLine = line as NSString
                for match in regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)).reversed() {
                    let range = (1..<match.numberOfRanges).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
                    let prefix = nsLine.substring(to: range.location)
                    if prefix.filter({ $0 == "`" }).count % 2 == 1 { continue }
                    let value = relocate(nsLine.substring(with: range))
                    if let swiftRange = Range(range, in: rewritten) { rewritten.replaceSubrange(swiftRange, with: value) }
                }
            }
            result += rewritten + "\n"
        }
        return String(result.dropLast())
    }
}
