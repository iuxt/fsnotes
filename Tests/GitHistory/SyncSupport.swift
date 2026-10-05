import Foundation

// UI and settings scaffolding only; all Git operations use production wrappers.
public final class Project {
    public let url: URL
    let storage = Storage()
    var metadataFolderID: String?
    var metadataStore: MetadataStore?
    var metadataUnavailable = false
    var parent: Project?
    let settings = Settings()
    var label = "Sync test"
    var settingsKey = "fsnotes-sync-test-" + UUID().uuidString
    var commitsCache = [String: [String]]()
    var isCleanGit = false
    var gitStatus: String?
    init(url: URL) { self.url = url }
    func getSettingsKey() -> String { settingsKey }
}
final class Settings {
    var gitOrigin: String?
    var gitPrivateKey: Data?
    var gitPublicKey: Data?
    var gitPrivateKeyPassphrase: String?
    var gitCACertificates: String?
}
final class Storage {
    var gitKeysDir: URL?
    func getProjectBy(url: URL) -> Project? { nil }
    func getGitKeysDir() -> URL? { gitKeysDir }
    func refreshMetadataLibraries() {}
}
final class MetadataStore {
    let root = URL(fileURLWithPath: "/unused")
    func refresh() throws {}
    enum Failure: Error { case invalid(String) }
}
final class AppDelegate { static var gitProgress: GitProgress? }
extension FileManager {
    func directoryExists(atUrl url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
extension Date {
    func string(format: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = format
        return formatter.string(from: self)
    }
}
