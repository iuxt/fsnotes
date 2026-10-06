import Foundation

@main struct RestartTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else {
            throw NSError(domain: "RestartTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        // Reset settings can leave no workspace until the user chooses one.
        // Creating an empty FSEvent stream previously trapped on a nil reference.
        let emptyWatcher = FileWatcher([])
        emptyWatcher.start()
        emptyWatcher.start()
        emptyWatcher.stop()
        try expect(true, "an empty watch list can start and stop without crashing")

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("fsnotes-restart-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDirectory = manager.currentDirectoryPath
        defer {
            manager.changeCurrentDirectoryPath(originalDirectory)
            try? manager.removeItem(at: root)
        }
        manager.changeCurrentDirectoryPath(root.path)

        var events = [String]()
        let watcher = FileWatcher([root.path]) { events.append($0.path) }
        let watchedFile = root.appendingPathComponent("watched.md")
        watcher.start()
        watcher.start()
        try "first".write(to: watchedFile, atomically: false, encoding: .utf8)
        try expect(waitForEvent(watchedFile, events: { events }), "a valid watch list still receives file events")
        watcher.stop()
        events.removeAll()
        watcher.start()
        try "second".write(to: watchedFile, atomically: false, encoding: .utf8)
        try expect(waitForEvent(watchedFile, events: { events }), "file watching resumes after stop and restart")
        watcher.stop()

        let result = root.appendingPathComponent("result")
        let launcher = root.appendingPathComponent("test launcher ' 中文")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellQuote(result.path) + "\n"
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        defer {
            if oldProcess.isRunning { oldProcess.terminate(); oldProcess.waitUntilExit() }
        }

        // A literal path must not become shell source or a percent-encoded URL.
        let app = root.appendingPathComponent("FS Notes 中文 ' $(touch INJECTED); %.app")
        let relaunch = try ApplicationRelaunch.schedule(appURL: app, after: oldProcess.processIdentifier,
                                                       launcherURL: launcher)
        defer { if relaunch.isRunning { relaunch.terminate() } }
        Thread.sleep(forTimeInterval: 0.3)
        try expect(relaunch.isRunning, "relaunch helper survives while the old app is running")
        try expect(!manager.fileExists(atPath: result.path), "launcher is not invoked before the old app exits")

        oldProcess.terminate()
        oldProcess.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while relaunch.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        try expect(!relaunch.isRunning, "helper launches after the old app exits")
        relaunch.waitUntilExit()
        try expect(relaunch.terminationStatus == 0, "launcher finishes successfully")
        let arguments = try String(contentsOf: result, encoding: .utf8)
        try expect(arguments == "-n\n" + app.path + "\n", "launcher receives a new-instance flag and exact filesystem path")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("INJECTED").path),
                   "shell metacharacters in the app path are not executed")
        print("Restart integration: \(checks) checks passed")
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func waitForEvent(_ url: URL, events: () -> [String]) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if events().contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }) {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
