import Foundation

enum ApplicationRelaunch {
    // Launch Services must see the old process exit before opening the app again.
    // Pass paths as arguments so spaces and shell metacharacters remain literal.
    @discardableResult
    static func schedule(appURL: URL = Bundle.main.bundleURL,
                         after processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
                         launcherURL: URL = URL(fileURLWithPath: "/usr/bin/open")) throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec \"$3\" -n \"$2\"",
            "fsnotes-restart", String(processIdentifier), appURL.path, launcherURL.path
        ]
        try task.run()
        return task
    }
}
