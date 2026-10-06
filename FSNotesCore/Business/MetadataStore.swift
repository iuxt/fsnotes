import Foundation

/// metadata.json is the persistent snapshot; queries use a rebuildable in-memory index.
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
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "FSNotes metadata: " + reason
            }
        }
    }

    let root: URL
    var manifestURL: URL { root.appendingPathComponent("metadata.json") }
    var notesURL: URL { root.appendingPathComponent("notes", isDirectory: true) }
    var imagesURL: URL { root.appendingPathComponent("images", isDirectory: true) }
    private let lock = NSRecursiveLock()
    private struct Stamp: Equatable { let modified: Date; let size: UInt64; let inode: UInt64 }
    private var loadedStamp: Stamp?
    private var failedStamp: Stamp?
    private var loadedData: Data?
    private var snapshot = Snapshot()
    private struct Index {
        let folders: [Folder]
        let entries: [Entry]
        let entriesByID: [String: Entry]
        let entriesByFolder: [String?: [Entry]]

        init(_ snapshot: Snapshot) {
            folders = snapshot.folders.sorted { $0.id < $1.id }
            entries = snapshot.notes.sorted { $0.id < $1.id }
            entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            entriesByFolder = Dictionary(grouping: entries, by: { $0.folderID })
        }
    }
    private var index = Index(Snapshot())
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        for directory in [notesURL, imagesURL] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.invalid("reserved storage directories cannot be symbolic links") }
        }
        try coordinateWrite(at: self.root) {
            if !FileManager.default.fileExists(atPath: manifestURL.path) { try migrate() }
            try finishMigrationCleanup()
        }
        try refresh()
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try Self.configureImageTracking(in: self.root)
        for name in ["Trash", "trash"] {
            let directory = self.root.appendingPathComponent(name)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path), files.isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Keep the rule in the library, so external Git clients use the same storage format.
    static func configureImageTracking(in root: URL) throws {
        let attributes = root.appendingPathComponent(".gitattributes")
        let rule = "images/** filter=lfs diff=lfs merge=lfs -text"
        let current = FileManager.default.fileExists(atPath: attributes.path) ? try String(contentsOf: attributes, encoding: .utf8) : ""
        if current.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) == rule { return }
        try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + rule + "\n").write(to: attributes, atomically: true, encoding: .utf8)
    }

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
            try Self.validate(next)
            index = Index(next)
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
        return index.folders
    }

    func allEntries() throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        return index.entries
    }

    func entries(inFolder id: String?) throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        return index.entriesByFolder[id] ?? []
    }

    func entry(at url: URL) -> Entry? {
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == notesURL.standardizedFileURL else { return nil }
        return entry(id: url.deletingPathExtension().lastPathComponent)
    }

    func entry(id: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        // A malformed/conflicted snapshot blocks writes; the last valid index stays readable.
        do { try refresh(force: false) } catch { NSLog("%@", error.localizedDescription) }
        return index.entriesByID[id]
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
            entry.name = try Self.availableName(name, folderID: folderID, excluding: nil, in: next)
            next.notes.append(entry)
        }
        return entry
    }

    func renameNote(id: String, name: String) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            let folder = next.notes[index].folderID
            let target = try Self.availableName(name, folderID: folder, excluding: id, in: next)
            guard target != next.notes[index].name else { return }
            Self.rememberName(&next.notes[index])
            next.notes[index].name = target
        }
    }

    func moveNote(id: String, folderID: String?) throws {
        try mutate { next in
            guard let index = next.notes.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("note no longer exists") }
            let target = try Self.availableName(next.notes[index].name, folderID: folderID, excluding: id, in: next)
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

    static func validatedNoteName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.invalid("A note name is required") }
        return name
    }

    private static func availableName(_ name: String, folderID: String?, excluding id: String?, in next: Snapshot) throws -> String {
        let base = try validatedNoteName(name)
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

    /// Remove a trashed note and its owned resources, publishing metadata before
    /// discarding the staged files so a failed snapshot write preserves the note.
    func deletePermanently(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        let staging = root.appendingPathComponent(".fsnotes-delete-" + UUID().uuidString, isDirectory: true)
        var moved = [(source: URL, staged: URL)]()
        do {
            try mutate { next in
                guard let index = next.notes.firstIndex(where: { $0.id == id }), next.notes[index].trashed else {
                    throw Failure.invalid("only trashed notes can be permanently deleted")
                }
                let entry = next.notes[index]
                let resources = try unreferencedResources(for: entry, in: next)
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
                for source in [fileURL(entry)] + resources {
                    let destination = staging.appendingPathComponent(UUID().uuidString)
                    do {
                        try manager.moveItem(at: source, to: destination)
                        moved.append((source, destination))
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                        // Missing bodies or attachments must not strand a trash record.
                        continue
                    }
                }
                next.notes.remove(at: index)
            }
        } catch {
            for file in moved.reversed() {
                try manager.moveItem(at: file.staged, to: file.source)
            }
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            throw error
        }
        try manager.removeItem(at: staging)
    }

    private func unreferencedResources(for entry: Entry, in snapshot: Snapshot) throws -> [URL] {
        let images = imagesURL.standardizedFileURL.resolvingSymlinksInPath()
        func references(in note: Entry) throws -> Set<URL> {
            let body = fileURL(note)
            let data: Data
            do { data = try Data(contentsOf: body) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return [] }
            return Set(Self.localLinkTargets(in: String(decoding: data, as: UTF8.self)).compactMap { target in
                let path = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                let resource = body.deletingLastPathComponent().appendingPathComponent(path.removingPercentEncoding ?? path)
                    .standardizedFileURL.resolvingSymlinksInPath()
                return resource == images || resource.path.hasPrefix(images.path + "/") ? resource : nil
            })
        }
        func contains(_ parent: URL, _ child: URL) -> Bool {
            parent == child || child.path.hasPrefix(parent.path + "/")
        }
        var candidates = try references(in: entry).filter { $0 != images }
        let owned = imagesURL.appendingPathComponent(entry.id, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        if owned.path.hasPrefix(images.path + "/") { candidates.insert(owned) }
        var shared = Set<URL>()
        for other in snapshot.notes where other.id != entry.id {
            shared.formUnion(try references(in: other))
        }
        let removable = candidates.filter { candidate in
            !shared.contains { contains(candidate, $0) || contains($0, candidate) }
        }
        // Move a directory once, omitting any of its children already included.
        return removable.filter { candidate in
            !removable.contains { $0 != candidate && contains($0, candidate) }
        }.sorted { $0.path < $1.path }
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

    func validateFolderMove(id: String, parentID: String?) throws {
        lock.lock(); defer { lock.unlock() }
        try refresh(force: false)
        var next = snapshot
        try Self.reparentFolder(in: &next, id: id, parentID: parentID)
        try Self.validate(next)
    }

    func moveFolder(id: String, parentID: String?) throws {
        try mutate { next in
            try Self.reparentFolder(in: &next, id: id, parentID: parentID)
        }
    }

    private static func reparentFolder(in snapshot: inout Snapshot, id: String, parentID: String?) throws {
        guard let index = snapshot.folders.firstIndex(where: { $0.id == id }) else {
            throw Failure.invalid("folder no longer exists")
        }
        snapshot.folders[index].parentID = parentID
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
            try Self.validate(next)
            next.folders.sort { $0.id < $1.id }
            next.notes.sort { $0.id < $1.id }
            let data = try encoder.encode(next)
            guard data != loadedData else { return }
            // Publish the persistent snapshot before replacing the in-memory index.
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

    static func validateMergedData(_ data: Data) throws {
        try validate(JSONDecoder().decode(Snapshot.self, from: data))
    }

    private static func validate(_ next: Snapshot) throws {
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
            guard UUID(uuidString: entry.id) != nil, ["md", "markdown", "txt", "fountain"].contains(entry.fileExtension), !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.folderID == nil || folders[entry.folderID!] != nil else { throw Failure.invalid("invalid note") }
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
            let knownLibrary = manager.fileExists(atPath: notesURL.appendingPathComponent(".fsnotes-library").path)
            if knownLibrary {
                throw Failure.invalid("metadata.json is missing from an existing UUID library; restore it from Git")
            }
            func scan(_ directory: URL, parentID: String?) throws {
                let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: .skipsHiddenFiles).sorted { $0.path < $1.path }
                for rawFile in files {
                    let file = rawFile.standardizedFileURL.resolvingSymlinksInPath()
                    let values = try rawFile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    if values.isSymbolicLink == true || values.isPackage == true { continue }
                    let relative = String(file.path.dropFirst(root.path.count + 1))
                    if values.isDirectory != true, ["md", "markdown", "txt", "fountain"].contains(file.pathExtension.lowercased()) {
                        var id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
                        if plan.notes.contains(where: { $0.id == id }) { id = UUID().uuidString.lowercased() }
                        let displayName = try Self.availableName(file.deletingPathExtension().lastPathComponent, folderID: parentID, excluding: nil, in: plan)
                        let entry = Entry(id: id, name: displayName, folderID: parentID, fileExtension: file.pathExtension.lowercased(), legacyPath: relative)
                        plan.notes.append(entry)
                    } else if values.isDirectory == true, !["Trash", "trash", "images", "assets", "i", "files"].contains(file.lastPathComponent) {
                        // Nested repositories keep their independent storage and Git root.
                        if manager.fileExists(atPath: file.appendingPathComponent(".git").path) { continue }
                        let folder = Folder(id: UUID().uuidString.lowercased(), name: file.lastPathComponent, parentID: parentID, legacyPath: relative)
                        plan.folders.append(folder)
                        try scan(file, parentID: folder.id)
                    }
                }
            }
            try scan(root, parentID: nil)
            try Self.validate(plan)
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
            }
            let attributes = try manager.attributesOfItem(atPath: source.path)
            try manager.setAttributes(attributes.filter { [.creationDate, .modificationDate, .posixPermissions].contains($0.key) }, ofItemAtPath: staging.path)
            try manager.moveItem(at: staging, to: destination)
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

    private func validateMigrationPlan(_ plan: Snapshot) throws {
        try Self.validate(plan)
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
            try verify(source, destination, rewrite: ["md", "markdown", "txt", "fountain"].contains(entry.fileExtension))

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
            let to = notes[resolved.path] ?? resolved

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
