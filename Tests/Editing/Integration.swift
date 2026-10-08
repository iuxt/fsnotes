import Foundation
import AppKit

@main struct EditingTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw NSError(domain: "EditingTests", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("fsnotes-editing-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try testRemoteShell(in: root)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        let lockA = NSRecursiveLock(), lockB = NSRecursiveLock()
        let a = NoteAutosave(lock: lockA), b = NoteAutosave(lock: lockB)
        var writesA = [String](), writesB = [String](), finishesA = 0, finishesB = 0
        let writeA: (NSAttributedString) -> Void = { writesA.append($0.string) }
        let writeB: (NSAttributedString) -> Void = { writesB.append($0.string) }
        let finishA = { finishesA += 1 }, finishB = { finishesB += 1 }
        a.enqueue(NSAttributedString(string: "A first"), on: queue, write: writeA, didFinish: finishA)
        a.enqueue(NSAttributedString(string: "A final"), on: queue, write: writeA, didFinish: finishA)
        b.enqueue(NSAttributedString(string: "B final"), on: queue, write: writeB, didFinish: finishB)
        queue.isSuspended = false
        queue.waitUntilAllOperationsAreFinished()
        try expect(writesA == ["A final"], "switching notes retains A's final edit and coalesces obsolete snapshots")
        try expect(writesB == ["B final"], "B is saved independently")
        try expect(finishesA == 1 && finishesB == 1, "both notes leave the blocked state")

        queue.isSuspended = true
        a.enqueue(NSAttributedString(string: "obsolete"), on: queue, write: writeA, didFinish: finishA)
        lockA.lock()
        a.discardPending()
        writesA.append("synchronous restore")
        lockA.unlock()
        queue.isSuspended = false
        queue.waitUntilAllOperationsAreFinished()
        try expect(writesA == ["A final", "synchronous restore"], "a synchronous restore supersedes queued text")
        try expect(finishesA == 2, "discarded work still finishes its lifecycle")
        a.enqueue(NSAttributedString(string: "after restore"), on: queue, write: writeA, didFinish: finishA)
        queue.waitUntilAllOperationsAreFinished()
        try expect(writesA.last == "after restore" && finishesA == 3, "saving resumes after a restore")

        // Enqueue from inside a running write to exercise the pending-work handoff
        // deterministically, without depending on operation timing or sleeps.
        let handoff = NoteAutosave(lock: NSRecursiveLock())
        var handoffWrites = [String](), handoffFinishes = 0
        handoff.enqueue(NSAttributedString(string: "running"), on: queue, write: { snapshot in
            handoffWrites.append(snapshot.string)
            if snapshot.string == "running" {
                handoff.enqueue(NSAttributedString(string: "newer"), on: queue,
                                write: { _ in fatalError("must use the existing worker") }, didFinish: {})
            }
        }, didFinish: { handoffFinishes += 1 })
        queue.waitUntilAllOperationsAreFinished()
        try expect(handoffWrites == ["running", "newer"] && handoffFinishes == 1,
                   "edits arriving during a write are drained before unblocking")

        let checkbox = NSMutableAttributedString(attachment: NSTextAttachment())
        checkbox.addAttribute(.todo, value: 1, range: NSRange(location: 0, length: 1))
        checkbox.append(NSAttributedString(string: " done"))
        let taskSource = checkbox.unloadTasks()
        try expect(taskSource.string == "- [x] done", "checkbox expands into editable Markdown")
        try expect(taskSource.attribute(.attachment, at: 0, effectiveRange: nil) == nil && taskSource.attribute(.todo, at: 0, effectiveRange: nil) == nil,
                   "unloaded source does not inherit attachment or task attributes")
        try expect(checkbox.length == 6 && checkbox.attribute(.attachment, at: 0, effectiveRange: nil) != nil,
                   "source expansion preserves original note storage")

        let notes = root.appendingPathComponent("notes")
        let export = root.appendingPathComponent("preview")
        let first = root.appendingPathComponent("images/a/共享 图.png")
        let second = root.appendingPathComponent("images/b/共享 图.png")
        for directory in [notes, first.deletingLastPathComponent(), second.deletingLastPathComponent()] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let dataA = Data([0x89, 0x50, 0x4e, 0x47, 1]), dataB = Data([0x89, 0x50, 0x4e, 0x47, 2])
        try dataA.write(to: first); try dataB.write(to: second)
        let pathA = "../images/a/共享 图.png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let pathB = "../images/b/共享 图.png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let html = "<img alt='🖼' src='\(pathA)'><img SRC=\"\(pathB)\"><img src='\(pathA)'>"
            + "<img src='https://example.com/a.png'><img src='data:image/png;base64,AAAA'>"
        let preview = PreviewImages.render(html, relativeTo: notes, exportDirectory: export, forWeb: false)
        try expect(preview.contains("data:image/png;base64," + dataA.base64EncodedString()), "parent-relative image is embedded")
        try expect(preview.contains("data:image/png;base64," + dataB.base64EncodedString()), "second image is embedded independently")
        try expect(!preview.contains("../images/"), "preview needs no access outside its temporary directory")
        try expect(preview.contains("https://example.com/a.png") && preview.contains("data:image/png;base64,AAAA"),
                   "remote and inline images remain valid")
        try expect(!manager.fileExists(atPath: export.path), "ordinary preview creates no outside copies")
        let webpage = PreviewImages.render(html.replacingOccurrences(of: pathB, with: pathA),
                                           relativeTo: notes, exportDirectory: export, forWeb: true)
        let assets = try manager.contentsOfDirectory(at: export.appendingPathComponent("i"), includingPropertiesForKeys: nil)
        let exportedData = try assets.map { try Data(contentsOf: $0) }
        try expect(assets.count == 1 && exportedData.contains(dataA),
                   "web export copies a repeated image once using the upload filename")
        for asset in assets {
            try expect(webpage.contains("i/" + asset.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!), "web image source points inside the export directory")
        }
        let missing = PreviewImages.render("<img src='../images/missing.png' alt='missing'>", relativeTo: notes,
                                           exportDirectory: export, forWeb: false)
        try expect(missing == "<img src='' alt='missing'>", "missing local image retains alt text without an invalid outside path")
        let body = NSMutableAttributedString(url: first, title: "image", path: "../images/shared.png")
        let secondNote = NSMutableAttributedString(attributedString: body)
        body.saveData(in: NSRange(location: 0, length: 1))
        let undoSnapshot = body.attributedSubstring(from: NSRange(location: 0, length: 1))
        body.deleteCharacters(in: NSRange(location: 0, length: 1))
        try expect(manager.fileExists(atPath: first.path), "deleting an attachment reference preserves its shared file")
        try expect(secondNote.getMeta(at: 0)?.url == first, "second note retains its attachment metadata")
        try expect(undoSnapshot.attribute(.attachmentSave, at: 0, effectiveRange: nil) as? Data == dataA,
                   "deleted token retains bytes for undo")
        body.append(undoSnapshot)
        try expect(body.getData(at: 0) == dataA, "undo can retrieve the attachment bytes")
        let task = NSMutableAttributedString(attachment: NSTextAttachment())
        task.addAttribute(.todo, value: 0, range: NSRange(location: 0, length: 1))
        task.append(NSAttributedString(string: " task\n"))
        task.append(secondNote)
        let markdown = "- [ ] task\n![image](../images/shared.png)"
        let current = task.unloadAttachments().string
        try expect(current == markdown, "history compares checkboxes and images in their stored Markdown form")
        try expect(HistoryDiff.lines(from: markdown, to: current).allSatisfy { $0.kind == .unchanged },
                   "an unchanged rendered note has no false history differences")
        print("Editing integration: \(checks) checks passed")
    }
    static func testRemoteShell(in root: URL) throws {
        let manager = FileManager.default
        let marker = root.appendingPathComponent("INJECTED")
        let literal = "-option ' 中文 $(touch \(marker.path)); `touch \(marker.path)`\nnext"
        func run(_ command: String) throws {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", command]; task.currentDirectoryURL = root
            try task.run(); task.waitUntilExit()
            try expect(task.terminationStatus == 0, "remote filesystem command succeeds with a literal path")
        }
        try run(RemoteShell.makeDirectory(literal))
        let directory = root.appendingPathComponent(literal)
        try expect(manager.fileExists(atPath: directory.path), "spaces, quotes, newlines and shell syntax remain literal")
        try expect(!manager.fileExists(atPath: marker.path), "path command substitutions are never executed")
        let file = directory.appendingPathComponent("index.html")
        try Data("page".utf8).write(to: file)
        try run(RemoteShell.remove(file.path, recursively: false))
        try expect(!manager.fileExists(atPath: file.path) && manager.fileExists(atPath: directory.path), "file removal affects only its literal argument")
        try run(RemoteShell.remove(literal, recursively: true))
        try expect(!manager.fileExists(atPath: directory.path) && !manager.fileExists(atPath: marker.path), "recursive removal cannot interpret options or commands in a path")
    }
}
