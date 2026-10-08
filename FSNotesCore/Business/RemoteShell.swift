import Foundation

/// Keep filesystem paths literal when invoking commands through SSH.
enum RemoteShell {
    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func makeDirectory(_ path: String) -> String { "mkdir -p -- " + quote(path) }
    static func remove(_ path: String, recursively: Bool) -> String {
        (recursively ? "rm -rf -- " : "rm -f -- ") + quote(path)
    }
}
