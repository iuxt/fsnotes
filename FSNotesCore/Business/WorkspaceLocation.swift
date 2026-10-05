import Foundation

/// A library is portable: its notes, manifest, attachments and Git history share a root.
enum WorkspaceLocation {
    static func repositoryURL(for root: URL) -> URL {
        root.appendingPathComponent(".git", isDirectory: true)
    }

    static func validate(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values.isDirectory == true, values.isPackage != true,
              FileManager.default.isReadableFile(atPath: root.path),
              FileManager.default.isWritableFile(atPath: root.path),
              root.lastPathComponent != ".git" else {
            throw NSError(domain: "WorkspaceLocation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("Choose a readable and writable folder for your workspace.", comment: "")
            ])
        }
        return root
    }
}
