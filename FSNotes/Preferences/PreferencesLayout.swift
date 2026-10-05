import AppKit

enum WorkspaceDirectory {
    static func choose(switching: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose Workspace Folder", comment: "")
        panel.prompt = NSLocalizedString("Use This Folder", comment: "")
        panel.message = NSLocalizedString(switching
            ? "Switch to the selected workspace after restarting. Files in the current workspace stay where they are."
            : "Choose a folder for your notes, attachments and Git history. You can change it later in Settings.", comment: "")
        panel.directoryURL = UserDefaultsManagement.storageUrl ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        while panel.runModal() == .OK {
            guard let url = panel.url else { return nil }
            do { return try WorkspaceLocation.validate(url) }
            catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        return nil
    }

    static func save(_ url: URL) throws {
        // Persist access before the path; a failed bookmark must not switch the library.
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let manager = SandboxBookmark.sharedInstance()
        guard let bookmarkURL = manager.bookmark() else {
            throw CocoaError(.fileNoSuchFile)
        }
        var bookmarks = manager.bookmarks
        if let previous = UserDefaultsManagement.storageUrl?.resolvingSymlinksInPath(), previous != url {
            bookmarks = bookmarks.filter { $0.key.resolvingSymlinksInPath() != previous }
        }
        bookmarks[url] = bookmark
        let data = try NSKeyedArchiver.archivedData(withRootObject: bookmarks, requiringSecureCoding: false)
        try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: bookmarkURL, options: .atomic)
        manager.bookmarks = bookmarks
        UserDefaultsManagement.storageType = .custom
        UserDefaultsManagement.customStoragePath = url.path
        UserDefaultsManagement.shared?.synchronize()
    }
}
