//
//  NoteMO+CoreDataClass.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 9/24/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//
//

import Foundation

public class Note: NSObject  {
    @objc var title: String = ""
    var project: Project
    var type: NoteType = .Markdown
    var url: URL

    var content: NSMutableAttributedString = NSMutableAttributedString()
    var creationDate: Date? = Date()

    let dateFormatter = DateFormatter()
    let undoManager = UndoManager()

    public var tags = [String]()

    public var isBlocked: Bool = false

    /*
     Filename with extension ie "example.md"
     */
    public var name = String()

    /*
     Filename "example"
     */
    public var fileName = String()
    public var preview: String = ""

    public var isPinned: Bool = false
    public var modifiedLocalAt = Date()

    public var imageUrl: [URL]?
    public var attachments: [URL]?
    public var isParsed = false

    private let writeLock = NSRecursiveLock()
    private lazy var autosave = NoteAutosave(lock: writeLock)

    public var isLoaded = false
    public var isLoadedFromCache = false

    public var cacheLock: Bool = false
    public var cacheHash: UInt64?

    public var uploadPath: String?

    public var previewState: Bool = false

    private var selectedRange: NSRange?

    public var contentOffset = CGPoint()
    public var contentOffsetWeb = CGPoint()

    public var scrollPosition: Int?
    public var scrollOffset: CGFloat?

    public var codeBlockRangesCache: [NSRange]?

    // Load exist

    init(url: URL, with project: Project, modified: Date? = nil, created: Date? = nil) {
        if let modified = modified {
            modifiedLocalAt = modified
        }

        if let created = created {
            creationDate = created
        }

        self.url = url.standardized
        self.project = project
        super.init()

        self.parseURL(loadProject: false)
    }

    // Make new

    init(name: String, project: Project? = nil, type: NoteType? = nil) throws {
        let project = project ?? Storage.shared().getDefault()!

        let name = try MetadataStore.validatedNoteName(name)

        self.project = project
        self.name = name

        self.type = type ?? UserDefaultsManagement.fileFormat

        let ext = self.type.getExtension()

        url = try NameHelper.getUniqueFileName(name: name, project: project, ext: ext)

        super.init()

        self.parseURL()
        if let store = project.metadataStore {
            _ = try store.register(id: url.deletingPathExtension().lastPathComponent, name: name, folderID: project.metadataFolderID, ext: ext)
            applyMetadata()
        }
    }

    init(meta: NoteMeta, project: Project) {
        isLoadedFromCache = true

        if meta.title.count > 0 || (meta.imageUrl != nil && meta.imageUrl!.count > 0) {
            isParsed = true
        }

        url = meta.url
        attachments = meta.attachments
        imageUrl = meta.imageUrl
        title = meta.title
        preview = meta.preview
        modifiedLocalAt = meta.modificationDate
        creationDate = meta.creationDate
        isPinned = meta.pinned
        tags = meta.tags
        selectedRange = meta.selectedRange
        self.project = project

        super.init()

        parseURL(loadProject: false)
    }

    public func fileSize(atPath path: String) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                return fileSize
            }
        } catch {
            print("Error retrieving file size: \(error.localizedDescription)")
        }
        return nil
    }

    public func isValidForCaching() -> Bool {
        return isLoaded || title.count > 0 || imageUrl != nil
    }

    func getMeta() -> NoteMeta {
        let date = creationDate ?? Date()
        return NoteMeta(
            url: url,
            attachments: attachments,
            imageUrl: imageUrl,
            title: title,
            preview: preview,
            modificationDate: modifiedLocalAt,
            creationDate: date,
            pinned: isPinned,
            tags: tags, 
            selectedRange: selectedRange
        )
    }

    public func getURL() -> URL {
        return url
    }

    public func loadProject() {
        let sharedStorage = Storage.shared()

        if let project = sharedStorage.getProjectByNote(url: url) {
            self.project = project
        }
    }

    public func forceLoad(skipCreateDate: Bool = false, loadTags: Bool = true) {
        invalidateCache()
        load(tags: loadTags)

        if !skipCreateDate {
            loadCreationDate()
        }

        loadModifiedLocalAt()
    }

    public func setCreationDate(string: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let userDate = formatter.date(from: string)
        let attributes = [FileAttributeKey.creationDate: userDate]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = userDate

            return true
        } catch {
            print(error)
            return false
        }
    }

    public func setCreationDate(date: Date) -> Bool {
        let attributes = [FileAttributeKey.creationDate: date]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = date

            return true
        } catch {
            return false
        }
    }

    public func uiLoad() {
        if metadataStore != nil { load(tags: true); return }
        if let size = fileSize(atPath: self.url.path), size > 100000 {
            loadFileName()

            loadTitle()
            if let handle = FileHandle(forReadingAtPath: url.path) {
                defer { handle.closeFile() }
                let data = handle.readData(ofLength: 1024)
                preview = String(decoding: data, as: UTF8.self).trimMDSyntax().condenseWhitespace()
            }

            return
        }

        load(tags: true)
    }

    func load(tags: Bool = true) {
        #if SHARE_EXT
            return
        #endif

        if let attributedString = getContent() {
            cacheHash = nil
            content = attributedString.loadAttachments(self)
        }

        loadFileName()
        loadPreviewInfo()

        if !isTrash() && tags {
            loadTags()
        }

        isLoaded = true
    }

    func reload() -> Bool {
        guard let modifiedAt = getFileModifiedDate() else { return false }

        if (modifiedAt != modifiedLocalAt) {
            if let attributedString = getContent() {
                cacheHash = nil
                content = attributedString.loadAttachments(self)
                cacheCodeBlocks()
            }

            loadModifiedLocalAt()
            return true
        }

        return false
    }

    public func forceReload() {
        if let attributedString = getContent() {
            cacheHash = nil
            content = attributedString.loadAttachments(self)
        }
    }

    public func loadModifiedLocalAt() {
        modifiedLocalAt = getFileModifiedDate() ?? Date.distantPast
    }

    public func loadCreationDate() {
        creationDate = getFileCreationDate() ?? Date.distantPast
    }

    public func getFileModifiedDate() -> Date? {
        let url = getURL()

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.modificationDate] as? Date
            } catch {
                print("Note modification date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
    }

    public func getFileCreationDate() -> Date? {
        let url = getURL()

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.creationDate] as? Date
            } catch {
                print("Note creation date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate
    }

    func move(to: URL, project: Project? = nil, forceRewrite: Bool = false) -> Bool {
        if metadataStore != nil {
            let destination = project ?? self.project.storage.getProjectBy(url: to.deletingLastPathComponent())
            if let destination = destination {
                if destination.isTrash {
                    _ = removeMetadataFile()
                    return metadataEntry?.trashed == true
                }
                do {
                    if try moveMetadata(to: destination) { return true }
                    // A move between repositories retains the UUID; Git histories remain in their repositories.
                    if destination.metadataStore != nil {
                        let oldStore = metadataStore
                        let oldID = metadataEntry?.id
                        let moved = try self.project.storage.importMetadataFile(url, to: destination, name: fileName, id: oldID)
                        try FileManager.default.removeItem(at: url)
                        if let id = oldID { try oldStore?.delete(id: id) }
                        if let duplicate = self.project.storage.getBy(url: moved), duplicate !== self { self.project.storage.removeBy(note: duplicate) }
                        overwrite(url: moved)
                        forceLoad()
                        return true
                    }
                } catch { NSLog("%@", error.localizedDescription) }
            }
            return false
        }
        let sharedStorage = Storage.shared()
        if let destination = project ?? sharedStorage.getProjectBy(url: to.deletingLastPathComponent()), destination.metadataStore != nil {
            do {
                let imported = try sharedStorage.importMetadataFile(url, to: destination, name: fileName)
                try FileManager.default.removeItem(at: url)
                if let duplicate = sharedStorage.getBy(url: imported), duplicate !== self { sharedStorage.removeBy(note: duplicate) }
                overwrite(url: imported)
                forceLoad()
                return true
            } catch { NSLog("%@", error.localizedDescription); return false }
        }

        do {
            var destination = to

            if FileManager.default.fileExists(atPath: to.path) && !forceRewrite {
                guard let project = project ?? sharedStorage.getProjectByNote(url: to) else { return false }

                let ext = url.pathExtension
                destination = try NameHelper.getUniqueFileName(name: title, project: project, ext: ext)
            }

            try FileManager.default.moveItem(at: url, to: destination)
            removeCacheForPreviewImages()

            #if os(OSX)
                let restorePin = isPinned
                if isPinned {
                    removePin()
                }

                overwrite(url: destination)

                if restorePin {
                    addPin()
                }
            #endif

            print("File moved from \"\(url.deletingPathExtension().lastPathComponent)\" to \"\(destination.deletingPathExtension().lastPathComponent)\"")
        } catch {
            Swift.print(error)
            return false
        }

        return true
    }

    func getNewURL(name: String) -> URL {
        let escapedName = name
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")

        var newUrl = url.deletingLastPathComponent()
        newUrl.appendPathComponent(escapedName + "." + url.pathExtension)
        return newUrl
    }

    @discardableResult public func remove() -> Bool {
        guard !isTrash() else { return false }
        return removeFile() != nil
    }

    func deletePermanently() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try deleteMetadataPermanently()
        autosave.discardPending()
    }

    public func isEmpty() -> Bool {
        return content.length == 0
    }

    // Logical trash retains the physical URL; the mapping is used for undo.
    func removeFile() -> [URL]? {
        return removeMetadataFile()
    }

    public func getAttachPrefix(url: URL? = nil) -> String {
        if let url = url, !url.isImage {
            return "files/"
        }

        return "i/"
    }

    public func move(from imageURL: URL, imagePath: String, to project: Project, copy: Bool = false) {
        let dstPrefix = getAttachPrefix(url: imageURL)
        let dest = project.noteStorageURL.appendingPathComponent(dstPrefix, isDirectory: true)

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)

            if let data = "true".data(using: .utf8) {
                try? dest.setExtendedAttribute(data: data, forName: "es.fsnot.hidden.dir")
            }
        }

        do {
            if copy {
                try FileManager.default.copyItem(at: imageURL, to: dest)
            } else {
                try FileManager.default.moveItem(at: imageURL, to: dest)
            }
        } catch {
            if let fileName = ImagesProcessor.getFileName(from: imageURL, to: dest, ext: imageURL.pathExtension) {
                let dest = dest.appendingPathComponent(fileName)

                if copy {
                    try? FileManager.default.copyItem(at: imageURL, to: dest)
                } else {
                    try? FileManager.default.moveItem(at: imageURL, to: dest)
                }

                let prefix = "]("
                let postfix = ")"

                let imagePath = imagePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imagePath

                let find = prefix + imagePath + postfix
                let replace = prefix + dstPrefix + fileName + postfix

                guard find != replace else { return }

                while content.mutableString.contains(find) {
                    let range = content.mutableString.range(of: find)
                    content.replaceCharacters(in: range, with: replace)
                }
            }
        }
    }

    public func moveImages(to project: Project) {
        if metadataStore != nil && project.metadataStore != nil { return }
        if type == .Markdown {
            let imagesMeta = content.getImagesAndFiles()
            for imageMeta in imagesMeta {
                let imagePath = project.url.appendingPathComponent(imageMeta.path).path
                project.storage.hideImages(directory: imagePath, srcPath: imagePath)

                // Copy if image used more then one time on project
                let copy = self.project.countNotes(contains: imageMeta.url) > 0
                move(from: imageMeta.url, imagePath: imageMeta.path, to: project, copy: copy)
            }

            if imagesMeta.count > 0 {
                if save() {
                    Storage.shared().add(self)
                }
            }
        }
    }

    public func getPreviewLabel(with text: String? = nil) -> String {
        var preview: String = ""
        let content = text ?? self.content.string
        let length = text?.count ?? self.content.string.count

        if length > 250 {
            if text == nil {
                let startIndex = content.index((content.startIndex), offsetBy: 0)
                let endIndex = content.index((content.startIndex), offsetBy: 250)
                preview = String(content[startIndex...endIndex])
            } else {
                preview = String(content.prefix(250))
            }
        } else {
            preview = content
        }

        preview = preview.replacingOccurrences(of: "\n", with: " ")
        if (
            UserDefaultsManagement.horizontalOrientation
                && content.hasPrefix(" – ") == false
            ) {
            preview = " – " + preview
        }

        preview = preview.condenseWhitespace()

        if preview.starts(with: "![") {
            return ""
        }

        return preview
    }

    @objc func getDateForLabel() -> String {
        guard !UserDefaultsManagement.hideDate else { return String() }

        let date = self.project.storage.getSortByState() == .creationDate
            ? creationDate
            : modifiedLocalAt

        guard let date = date else { return String() }

        if NSCalendar.current.isDateInToday(date) {
            return dateFormatter.formatTimeForDisplay(date)
        } else {
            return dateFormatter.formatDateForDisplay(date)
        }
    }

    @objc func getCreationDateForLabel() -> String? {
        guard let creationDate = self.creationDate else { return nil }
        guard !UserDefaultsManagement.hideDate else { return nil }

        let calendar = NSCalendar.current
        if calendar.isDateInToday(creationDate) {
            return dateFormatter.formatTimeForDisplay(creationDate)
        }
        else {
            return dateFormatter.formatDateForDisplay(creationDate)
        }
    }

    func getContent() -> NSMutableAttributedString? {
        guard let url = getContentFileURL() else { return nil }

        do {
            return try NSMutableAttributedString(url: url, options: [
                .documentType : NSAttributedString.DocumentType.plain,
                .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
            ], documentAttributes: nil)
        } catch {
            if let data = try? Data(contentsOf: url) {
                let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)

                return try? NSMutableAttributedString(url: url, options: [
                    .documentType : NSAttributedString.DocumentType.plain,
                    .characterEncoding : NSNumber(value: encoding)
                ], documentAttributes: nil)
            }
        }

        return nil
    }

    func isMarkdown() -> Bool {
        return type == .Markdown
    }

    func addPin(cloudSave: Bool = true) {
        isPinned = true

        if cloudSave {
            Storage.shared().saveCloudPins()
        }
    }

    func removePin(cloudSave: Bool = true) {
        if isPinned {
            isPinned = false

            if cloudSave {
                Storage.shared().saveCloudPins()
            }
        }
    }

    func togglePin() {
        if !isPinned {
            addPin()
        } else {
            removePin()
        }
    }

    func cleanMetaData(content: String) -> String {
        var extractedTitle = String()
        var author = String()
        var date = String()

        if (content.hasPrefix("---\n")) {
            let searchStart = content.index(content.startIndex, offsetBy: 4)

            if let closingRange = content.range(of: "\n---\n", range: searchStart..<content.endIndex) {
                let yamlBlock = String(content[searchStart..<closingRange.lowerBound])
                let remainingContent = String(content[closingRange.upperBound...])

                let headerList = yamlBlock.components(separatedBy: "\n")
                for header in headerList {
                    if header.hasPrefix("title:") {
                        extractedTitle = header.replacingOccurrences(of: "title:", with: "").trim()

                        if extractedTitle.hasPrefix("\"") && extractedTitle.hasSuffix("\""){
                            extractedTitle = String(extractedTitle.dropFirst(1))
                            extractedTitle = String(extractedTitle.dropLast(1))
                        }
                    }

                    if header.hasPrefix("author:") {
                        author = header.replacingOccurrences(of: "author:", with: "").trim()

                        if author.hasPrefix("\"") && author.hasSuffix("\""){
                            author = String(author.dropFirst(1))
                            author = String(author.dropLast(1))
                        }
                    }

                    if header.hasPrefix("date:") {
                        date = header.replacingOccurrences(of: "date:", with: "").trim()

                        if date.hasPrefix("\"") && date.hasSuffix("\""){
                            date = String(date.dropFirst(1))
                            date = String(date.dropLast(1))
                        }
                    }
                }

                var result = String()

                if (extractedTitle.count > 0) {
                    result = "<h1 class=\"no-border\">" + extractedTitle + "</h1>\n\n"
                }

                if (author.count > 0) {
                    result += "_" + author + "_\n\n"
                }

                if (date.count > 0) {
                    result += "_" + date + "_\n\n"
                }

                if result.count > 0 {
                    result += "<hr>\n\n"
                }

                result += remainingContent

                return result
            }
        }

        return content
    }

    func getPrettifiedContent() -> String {
        #if IOS_APP || os(OSX)
            let mutable = NotesTextProcessor.convertAppTags(in: self.content.unloadAttachments(), codeBlockRanges: codeBlockRangesCache)
        let content = NotesTextProcessor.convertAppLinks(in: mutable, codeBlockRanges: codeBlockRangesCache)
            let result = cleanMetaData(content: content.string)
            let prettifiedContent = replaceHorizontalRulesOutsideCodeBlocks(in: result)

            return prettifiedContent
        #else
            return cleanMetaData(content: self.content.string)
        #endif
    }

    public func overwrite(url: URL) {
        self.url = url

        parseURL()
    }

    func parseURL(loadProject: Bool = true) {
        if (url.pathComponents.count > 0) {
            name = url.lastPathComponent

            type = .withExt(rawValue: url.pathExtension)

            loadTitle()
            loadFileName()
        }

        if loadProject {
            self.loadProject()
        }
        applyMetadata()
    }

    private func loadTitle() {
        if let entry = metadataEntry { title = entry.name; return }
        title = url.deletingPathExtension().lastPathComponent
    }

    private func loadFileName() {
        if let entry = metadataEntry { fileName = entry.name; return }
        fileName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    public func getFileName() -> String {
        return fileName
    }

    public func save(attributed: NSAttributedString) {
        guard let copy = attributed.copy() as? NSAttributedString else {
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        content = NSMutableAttributedString(attributedString: copy)
        modifiedLocalAt = Date()
        isBlocked = true
        autosave.enqueue(copy, on: Storage.shared().plainWriter, write: { [weak self] snapshot in
            guard let self = self else { return }
            if self.write(attributedString: NSMutableAttributedString(attributedString: snapshot).unloadAttachments()) {
                Storage.shared().add(self)
            }
        }, didFinish: { [weak self] in self?.isBlocked = false })
    }

    public func save(content: NSMutableAttributedString) {
        writeLock.lock()
        defer { writeLock.unlock() }
        autosave.discardPending()
        self.content = content

        let copy = content.unloadAttachments()
        modifiedLocalAt = Date()

        if write(attributedString: copy) {
            Storage.shared().add(self)
        }
    }

    public func replace(tag: String, with string: String) {
        content.replaceTag(name: tag, with: string)
        _ = save()
    }

    public func delete(tag: String) {
        content.replaceTag(name: tag, with: "")
        _ = save()
    }

    public func save() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        autosave.discardPending()
        let attributedString = self.content.unloadAttachments()

        return write(attributedString: attributedString)
    }

    private func write(attributedString: NSAttributedString) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }

        if project.metadataUnavailable || (metadataStore != nil && metadataEntry == nil) { return false }
        let attributes = getFileAttributes()

        do {
            let fileWrapper = getFileWrapper(attributedString: attributedString)

            let contentSrc: URL? = getContentFileURL()
            let dst = contentSrc ?? getContentSaveURL()

            var originalContentsURL: URL? = nil
            if let contentSrc = contentSrc {
                originalContentsURL = contentSrc
            }

            try fileWrapper.write(to: dst, options: .atomic, originalContentsURL: originalContentsURL)
            try FileManager.default.setAttributes(attributes, ofItemAtPath: dst.path)

        } catch {
            NSLog("Write error: %@", error.localizedDescription)
            return false
        }

        return true
    }

    private func getContentSaveURL() -> URL {
        return url
    }

    public func getContentFileURL() -> URL? {
        let url = getURL()

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        return nil
    }

    func getFileAttributes() -> [FileAttributeKey: Any] {
        let sourceURL = getContentFileURL() ?? url

        var attributes: [FileAttributeKey: Any] = [
            .modificationDate: modifiedLocalAt
        ]

        if let creationDate = creationDate {
            attributes[.creationDate] = creationDate
        }

        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
            return attributes
        }

        if let creationDate = sourceAttributes[.creationDate] {
            attributes[.creationDate] = creationDate
        }

        if let permissions = sourceAttributes[.posixPermissions] {
            attributes[.posixPermissions] = permissions
        }

        return attributes
    }

    func getFileWrapper(attributedString: NSAttributedString, forcePlain: Bool = false) -> FileWrapper {
        do {
            let range = NSRange(location: 0, length: attributedString.length)

            return try attributedString.fileWrapper(from: range, documentAttributes: [
                .documentType : NSAttributedString.DocumentType.plain,
                .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
            ])
        } catch {
            return FileWrapper()
        }
    }

    func getTitleWithoutLabel() -> String {
        if let entry = metadataEntry { return entry.name }
        let title = url.deletingPathExtension().pathComponents.last!
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")

        return title
    }

    func isTrash() -> Bool {
        return project.isTrash
    }

    public func contains<S: StringProtocol>(terms: [S]) -> Bool {
        return fileName.localizedStandardContains(terms) || content.string.localizedStandardContains(terms)
    }

    public func loadTags() {
        if UserDefaultsManagement.inlineTags {
            _ = scanContentTags()
        }
    }

    public func scanContentTags() -> ([String], [String]) {
        if !isLoaded {
            cacheCodeBlocks()
        }

        var added = [String]()
        var removed = [String]()

        let matchingOptions = NSRegularExpression.MatchingOptions(rawValue: 0)
        let options: NSRegularExpression.Options = [
            .allowCommentsAndWhitespace,
            .anchorsMatchLines
        ]

        var tags = [String]()

        do {
            let range = NSRange(content.string.startIndex..., in: content.string)
            let re = try NSRegularExpression(pattern: FSParser.tagsPattern, options: options)

            re.enumerateMatches(
                in: content.string,
                options: matchingOptions,
                range: range,
                using: { (result, flags, stop) -> Void in

                    guard var range = result?.range(at: 1) else { return }
                    let cleanTag = content.mutableString.substring(with: range)

                    range = NSRange(location: range.location - 1, length: range.length + 1)

                    if let codeBlockRangesCache = codeBlockRangesCache {
                        for codeRange in codeBlockRangesCache {
                            if NSIntersectionRange(codeRange, range).length > 0 {
                                return
                            }
                        }
                    }

                    let spanBlock = FSParser.getSpanCodeBlockRange(content: content, range: range)

                    if spanBlock == nil && isValid(tag: cleanTag) {

                        let parRange = content.mutableString.paragraphRange(for: range)
                        let par = content.mutableString.substring(with: parRange)
                        if par.starts(with: "    ") || par.starts(with: "\t") {
                            return
                        }

                        if cleanTag.last == "/" {
                            tags.append(String(cleanTag.dropLast()))
                        } else {
                            tags.append(cleanTag)
                        }
                    }
                }
            )
        } catch {
            print("Tags parsing: \(error)")
        }

        if tags.contains("notags") {
            removed = self.tags

            self.tags.removeAll()
            return (added, removed)
        }

        for noteTag in self.tags {
            if !tags.contains(noteTag) {
                removed.append(noteTag)
            }
        }

        for tag in tags {
            if !self.tags.contains(tag) {
                added.append(tag)
            }
        }

        self.tags = tags

        return (added, removed)
    }

    private var excludeRanges = [NSRange]()

    public func isValid(tag: String) -> Bool {
        if tag.isNumber {
            return false
        }

        if tag.isHexColor() {
            return false
        }

        return true
    }

    public func getAttachmentFileUrl(name: String) -> URL? {
        if name.count == 0 {
            return nil
        }

        if name.starts(with: "http://") || name.starts(with: "https://") {
            return URL(string: name)
        }

        return getURL().deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL
    }

    #if os(OSX)
    public func getDupeName() -> String? {
        var url = self.url
        let ext = url.pathExtension
        url.deletePathExtension()

        var name = url.lastPathComponent
        url.deleteLastPathComponent()

        let regex = try? NSRegularExpression(pattern: "(.+)\\sCopy\\s(\\d)+$", options: .caseInsensitive)
        if let result = regex?.firstMatch(in: name, range: NSRange(0..<name.count)) {
            if let range = Range(result.range(at: 1), in: name) {
                name = String(name[range])
            }
        }

        var endName = name
        if !endName.hasSuffix(" Copy") {
            endName += " Copy"
        }

        guard let dstUrl = try? NameHelper.getUniqueFileName(name: endName, project: project, ext: ext) else { return nil }

        return dstUrl.deletingPathExtension().lastPathComponent
    }
    #endif

    public func loadPreviewInfo() {
        if let entry = metadataEntry {
            title = entry.name
            fileName = entry.name
            if isLoadedFromCache && !isLoaded && isParsed { return }
            preview = getPreviewLabel()
            imageUrl = getImagesFromContent()
            isParsed = true
            return
        }
        guard !isParsed || title.isEmpty && (imageUrl?.isEmpty ?? true) else { return }

        defer {
            imageUrl = getImagesFromContent()
            isParsed = true
        }

        loadTitle()
        preview = getPreviewLabel()
    }

    public func getImagesFromContent() -> [URL] {
        var urls = [URL]()

        let range = NSRange(location: 0, length: content.length)
        content.enumerateAttribute(.attachment, in: range) { (value, vRange, _) in
            guard let meta = content.getMeta(at: vRange.location) else { return }

            if meta.url.isMedia {
                urls.append(meta.url)
            }
        }

        return urls
    }

    public func invalidateCache() {
        self.imageUrl = nil
        self.preview = String()
        self.title = String()
        self.isParsed = false
    }

    public func isEqualURL(url: URL) -> Bool {
        return url.path == self.url.path
    }

    public func append(string: NSMutableAttributedString) {
        content.append(string)
    }

    public func append(image data: Data, url: URL? = nil) {
        guard let path = ImagesProcessor.writeFile(data: data, url: url, note: self) else { return }

        var prefix = "\n\n"
        if content.length == 0 {
            prefix = String()
        }

        let markdown = NSMutableAttributedString(string: "\(prefix)![](\(path))")
        append(string: markdown)
    }

    @objc public func getName() -> String {
        return getFileName()
    }

    public func getCacheForPreviewImage(at url: URL) -> URL? {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            temporary.appendPathComponent("Preview")

        if let filePath = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {

            return temporary.appendingPathComponent(filePath)
        }

        return nil
    }

    public func removeCacheForPreviewImages() {
        loadPreviewInfo()

        guard let imageURLs = imageUrl else { return }

        for url in imageURLs {
            if let imageURL = getCacheForPreviewImage(at: url) {
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    try? FileManager.default.removeItem(at: imageURL)
                }
            }
        }
    }

    public func cleanOut() {
        isParsed = false
        imageUrl = nil
        cacheHash = nil
        content = NSMutableAttributedString(string: String())
        preview = String()
        title = String()
    }

    public func showIconInList() -> Bool {
        return (isPinned || isPublished())
    }

    public func getShortTitle() -> String {
        return getFileName()
    }

    public func getTitle() -> String? {
        let name = getFileName()
        return name.isEmpty ? nil : name
    }

    public func rename(to name: String) {
        if metadataStore != nil {
            do { try renameMetadata(to: name) } catch { NSLog("%@", error.localizedDescription) }
            return
        }
        var name = name
        var i = 1

        while project.fileExist(fileName: name, ext: url.pathExtension) {

            // disables renaming loop
            if fileName.startsWith(string: name) {
                return
            }

            let items = name.split(separator: " ")

            if let last = items.last, let position = Int(last) {
                let full = items.dropLast()

                name = full.joined(separator: " ") + " " + String(position + 1)

                i = position + 1
            } else {
                name = name + " " + String(i)

                i += 1
            }
        }

        let isPinned = self.isPinned
        let dst = getNewURL(name: name)

        removePin()

        if move(to: dst) {
            url = dst
            parseURL()
        }

        if isPinned {
            addPin()
        }
    }

    public func getCursorPosition() -> Int? {
        var position: Int?

        if let data = try? url.extendedAttribute(forName: "co.fluder.fsnotes.cursor") {
            position = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                ptr.load(as: Int.self)
            }

            return position
        }

        return nil
    }

    public func addTag(_ name: String) {
        guard !tags.contains(name) else { return }

        let lastParRange = content.mutableString.paragraphRange(for: NSRange(location: content.length, length: 0))
        let string = content.attributedSubstring(from: lastParRange).string.trim()

        if string.count != 0 && (
            !string.starts(with: "#") || string.starts(with: "# ")
        ) {
            let newLine = NSAttributedString(string: "\n\n")
            content.append(newLine)
        }

        var prefix = String()
        if string.starts(with: "#") {
            prefix += " "
        }

        content.append(NSAttributedString(string: prefix + "#" + name))
        if save() {
            Storage.shared().add(self)
        }
    }

    public func resetAttributesCache() {
        cacheHash = nil
    }

    public func getLatinName() -> String {
        let name = (self.fileName as NSString)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? self.fileName

        return name.replacingOccurrences(of: " ", with: "_")
    }

    public func isPublished() -> Bool {
        return uploadPath != nil
    }

    public func setSelectedRange(range: NSRange? = nil) {
        selectedRange = range
    }

    public func getSelectedRange() -> NSRange? {
        return selectedRange
    }

    public func setContentOffset(contentOffset: CGPoint) {
        self.contentOffset = contentOffset
    }

    public func getContentOffset() -> CGPoint {
        return contentOffset
    }

    public func getRelatedPath() -> String {
        if let store = metadataStore { return store.root.path.md5 + "/" + url.deletingPathExtension().lastPathComponent }
        return project.getNestedPath() + "/" + name
    }

    public func loadPreviewState() {
        previewState = project.settings.notesPreview.contains(name)
    }

    public func cacheCodeBlocks() {
    #if !SHARE_EXT
        let ranges = CodeBlockDetector.shared.findCodeBlocks(in: content)
        codeBlockRangesCache = ranges
    #endif
    }

    public func isInCodeBlockRange(range: NSRange) -> Bool {
        guard let codeBlockRangesCache = codeBlockRangesCache else { return false }

        for codeRange in codeBlockRangesCache {
            if NSIntersectionRange(range, codeRange).length > 0 {
                return true
            }
        }

        return false
    }

    public func save(data: Data, preferredName: String? = nil) -> (String, URL)? {
        // Get attach dir
        let attachDir = getAttachDirectory(data: data)

        // Create if not exist
        if !FileManager.default.fileExists(atPath: attachDir.path, isDirectory: nil) {
            try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true, attributes: nil)
        }

        guard let fileName = getFileName(dst: attachDir, preferredName: preferredName) else { return nil }

        let fileUrl = attachDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            print("Attachment error: \(error)")
            return nil
        }

        if metadataStore != nil {
            return ("../images/" + fileUrl.lastPathComponent, fileUrl)
        }
        return (fileUrl.deletingLastPathComponent().lastPathComponent + "/" + fileUrl.lastPathComponent, fileUrl)
    }

    public func getAttachDirectory(data: Data) -> URL {

        if let store = metadataStore { return store.imagesURL }

        let prefix = data.getFileType() != .unknown ? "i" : "files"

        return project.url.appendingPathComponent(prefix, isDirectory: true)
    }

    public func getFileName(dst: URL, preferredName: String? = nil) -> String? {
        var name = preferredName ?? UUID().uuidString.lowercased()
        let ext = (name as NSString).pathExtension

        while true {
            let destination = dst.appendingPathComponent(name)
            let icloud = destination.appendingPathExtension("icloud")

            if FileManager.default.fileExists(atPath: destination.path) || FileManager.default.fileExists(atPath: icloud.path) {
                let newBase = UUID().uuidString.lowercased()
                if ext.isEmpty {
                    name = newBase
                } else {
                    name = "\(newBase).\(ext)"
                }
                continue
            }

            return name
        }
    }

    public func saveSimple() -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        autosave.discardPending()
        return write(attributedString: content)
    }

    #if os(macOS)
    public func cache() {
        if cacheLock { return }

        let hash = content.string.fnv1a
        cacheLock = true

        if let copy = content.mutableCopy() as? NSMutableAttributedString {
            NotesTextProcessor.highlight(attributedString: copy)
            cacheCodeBlocks()

            if content.string.fnv1a == copy.string.fnv1a {
                content = copy
                cacheHash = hash
            }
        }

        cacheLock = false
    }
    #endif
}
