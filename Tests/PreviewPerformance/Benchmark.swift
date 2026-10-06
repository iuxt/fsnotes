// Appended only to a temporary Release build by run.py.
// Exercises the production editor, MPreviewView, HTML template and renderer.
import Darwin

final class PreviewPerformance {
    static let shared = PreviewPerformance()
    final class WeakPreview {
        weak var view: MPreviewView?
        init(_ view: MPreviewView) { self.view = view }
    }
    var views = [WeakPreview]()
    var notes = [String: Note]()
    var controller: ViewController!
    var stage = "startup"
    var latencies = [Double]()
    var syncLatencies = [Double]()
    var generation = 0
    var heartbeat: Timer?
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var maxMainThreadDelay = 0.0
    var failures = [String]()
    var webKitPIDs = Set<Int>()
    final class WeakEditor {
        weak var controller: NoteViewController?
        weak var editor: EditTextView?
        weak var processor: TextStorageProcessor?
        init(_ controller: NoteViewController) {
            self.controller = controller
            editor = controller.editor
            processor = controller.editor.textStorageProcessor
        }
    }
    var closedEditors = [WeakEditor]()

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["FSNOTES_PREVIEW_BENCHMARK"] == "1"
    }

    static func configure() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preview-benchmark-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaultsManagement.customStoragePath = root.path
        UserDefaultsManagement.storageType = .custom
        UserDefaultsManagement.mathJaxPreview = false
        UserDefaultsManagement.isFirstLaunch = false
        UserDefaultsManagement.preview = false
    }

    func track(_ view: MPreviewView) { views.append(WeakPreview(view)) }

    func emit(_ event: String, _ data: [String: Any] = [:]) {
        autoreleasepool { emitInPool(event, data) }
    }

    private func emitInPool(_ event: String, _ data: [String: Any]) {
        var row = data
        row["event"] = event
        row["stage"] = stage
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        row["live_previews"] = views.filter { $0.view != nil }.count
        row["live_preview_indices"] = views.indices.filter { views[$0].view != nil }
        row["live_preview_addresses"] = views.compactMap { entry in
            entry.view.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) }
        }
        row["created_previews"] = views.count
        row["live_closed_editors"] = closedEditors.filter { $0.controller != nil }.count
        row["live_closed_text_views"] = closedEditors.filter { $0.editor != nil }.count
        row["live_closed_processors"] = closedEditors.filter { $0.processor != nil }.count
        for entry in views {
            guard let view = entry.view else { continue }
            // Diagnostic copy only. Identify actual WebKit children rather than
            // attributing unrelated browser processes by launch time.
            for key in ["_webProcessIdentifier", "_gpuProcessIdentifier"] {
                if view.responds(to: NSSelectorFromString(key)),
                   let value = view.value(forKey: key) as? NSNumber, value.intValue > 0 {
                    webKitPIDs.insert(value.intValue)
                }
            }
            let store = view.configuration.websiteDataStore
            let key = "_networkProcessIdentifier"
            if store.responds(to: NSSelectorFromString(key)),
               let value = store.value(forKey: key) as? NSNumber, value.intValue > 0 {
                webKitPIDs.insert(value.intValue)
            }
        }
        row["webkit_pids"] = webKitPIDs.sorted()
        let encoded = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("BENCH ".utf8) + encoded + Data("\n".utf8))
    }

    func after(_ seconds: Double, _ block: @escaping () -> Void) {
        // Timer-driven tests may not receive an AppKit event that drains the
        // outer pool. Drain each action before inspecting weak references.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            autoreleasepool(invoking: block)
        }
    }

    func advanceAppKitEventLoop() {
        // Programmatic window.close() runs in a dispatch callback, unlike a
        // user's close event. Wake nextEvent so AppKit drains its own pool too.
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
        NSApp.postEvent(event, atStart: false)
    }

    func start() {
        guard let controller = ViewController.shared(), let project = controller.storage.getDefault() else {
            emit("fatal", ["reason": "Main editor or project unavailable"])
            exit(1)
        }
        self.controller = controller
        controller.view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.stopPull()
        controller.snapshotsTimer.invalidate()
        let paragraph = "## Section\n\nMarkdown **bold**, *emphasis*, [link](https://example.com), and 中文笔记。 "
            + String(repeating: "Plain text for layout and rendering. ", count: 12) + "\n\n"
        let code = "```swift\n" + (0..<30).map { "let value\($0) = \($0) * 2 // example" }.joined(separator: "\n") + "\n```\n\n"
        let diagram = "```mermaid\ngraph LR\nA[Input] --> B[Parse]\nB --> C[Render]\nC --> D[Preview]\nB --> E[Cache]\n```\n\n"
        let workloads = [
            "small": "# Small note\n\n" + String(repeating: paragraph, count: 8) + code,
            "long": "# Long note\n\n" + String(repeating: paragraph, count: 1000),
            "code": "# Code note\n\n" + String(repeating: code, count: 120),
            "diagrams": "# Diagrams\n\n" + String(repeating: diagram, count: 20),
        ]
        for (name, content) in workloads {
            let url = project.url.appendingPathComponent(name + ".md")
            // Synthetic in-memory notes, no writes to the user's library.
            let note = Note(url: url, with: project)
            note.content = NSMutableAttributedString(string: content)
            note.isLoaded = true
            notes[name] = note
        }
        for index in 0..<10 {
            let note = Note(url: project.url.appendingPathComponent("small-\(index).md"), with: project)
            note.content = NSMutableAttributedString(string: workloads["small"]! + "\nVariant \(index)\n")
            note.isLoaded = true
            notes["small-\(index)"] = note
        }
        emit("environment", ["pid": getpid(), "bundle": Bundle.main.bundleIdentifier ?? "",
                              "workload_bytes": workloads.mapValues { $0.utf8.count },
                              "mathjax": UserDefaultsManagement.mathJaxPreview])
        lastBeat = ProcessInfo.processInfo.systemUptime
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.maxMainThreadDelay = max(self.maxMainThreadDelay, max(0, now - self.lastBeat - 0.02))
            self.lastBeat = now
        }
        begin("baseline_editor")
        controller.editor.changePreviewState(false)
        controller.editor.fill(note: notes["small"]!, force: true)
        after(3) { self.finish(); self.coldPreview() }
    }

    func begin(_ name: String) {
        stage = name
        latencies = []
        syncLatencies = []
        maxMainThreadDelay = 0
        emit("begin")
    }

    func finish() {
        emit("end", ["render_ms": latencies, "sync_fill_ms": syncLatencies,
                     "max_main_thread_delay_ms": maxMainThreadDelay * 1000,
                     "failures": failures])
    }

    func preview(_ name: String, editor: EditTextView? = nil, done: @escaping () -> Void) {
        generation += 1
        let token = generation
        let start = ProcessInfo.processInfo.systemUptime
        let activeEditor = editor ?? controller.editor!
        let note = notes[name]!
        let originalContent = note.content
        note.content = NSMutableAttributedString(attributedString: originalContent)
        note.content.append(NSAttributedString(string: "\n\n<span id=\"preview-benchmark-ready-\(token)\"></span>\n"))
        activeEditor.changePreviewState(true)
        activeEditor.fill(note: note, force: true)
        note.content = originalContent
        syncLatencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        guard let web = activeEditor.markdownView?.webView else {
            failures.append(stage + ": preview missing")
            done(); return
        }
        // didFinish is not sufficient for asynchronous Mermaid rendering.
        let ready = """
            (() => {
                if (document.readyState !== 'complete') return false;
                if (!document.getElementById('preview-benchmark-ready-\(token)')) return false;
                if (!document.body || !document.body.textContent.includes('\(name == "diagrams" ? "Diagrams" : name == "long" ? "Long note" : name == "code" ? "Code note" : "Small note")')) return false;
                const blocks = [...document.querySelectorAll('pre > code:not(.language-mermaid)')];
                if (blocks.some(code => !code.classList.contains('hljs'))) return false;
                if (blocks.some(code => code.parentElement.querySelectorAll('button.copyCode').length !== 1)) return false;
                return \(name == "diagrams" ? "document.querySelectorAll('pre svg').length >= 20" : "true");
            })()
            """
        func poll() {
            guard token == self.generation else { return }
            web.evaluateJavaScript(ready) { value, error in
                if let ready = value as? Bool, ready {
                    // Wait two animation frames so layout has reached a paint opportunity.
                    web.callAsyncJavaScript("""
                        const outcome = await Promise.race([
                            new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve('frames')))),
                            new Promise(resolve => setTimeout(() => resolve('timeout'), 1000))
                        ]);
                        return outcome;
                        """, arguments: [:], in: nil, in: .page) { result in
                        switch result {
                        case .failure:
                            self.after(0.02, poll)
                            return
                        case .success(let value):
                            if value as? String != "frames" {
                                self.failures.append(self.stage + ": animation frames timed out")
                            }
                        }
                        self.latencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                        self.emit("render", ["note": name, "render_ms": self.latencies.last!])
                        done()
                    }
                } else if ProcessInfo.processInfo.systemUptime - start > 30 {
                    self.failures.append(self.stage + ": render timeout " + (error?.localizedDescription ?? ""))
                    self.emit("timeout", ["note": name])
                    done()
                } else {
                    self.after(0.02, poll)
                }
            }
        }
        after(0.02, poll)
    }

    func coldPreview() {
        begin("small_first_open")
        preview("small") { self.after(3) { self.finish(); self.switchNotes(0) } }
    }

    func switchNotes(_ index: Int) {
        if index == 0 { begin("switch_50_small_notes") }
        if index == 50 {
            after(3) { self.finish(); self.stressSwitchNotes(0) }
            return
        }
        preview("small-\(index % 10)") {
            self.emit("iteration", ["iteration": index + 1])
            self.after(0.03) { self.switchNotes(index + 1) }
        }
    }

    func stressSwitchNotes(_ index: Int) {
        if index == 0 { begin("switch_200_more_small_notes") }
        if index == 200 {
            after(5) { self.finish(); self.togglePreview(0) }
            return
        }
        preview("small-\(index % 10)") {
            self.emit("iteration", ["iteration": index + 1])
            self.after(0.03) { self.stressSwitchNotes(index + 1) }
        }
    }

    func togglePreview(_ index: Int) {
        if index == 0 { begin("toggle_30_previews") }
        controller.disablePreview()
        if index == 30 {
            after(5) { self.finish(); self.workload("long", next: "code") }
            return
        }
        after(0.15) {
            self.emit("released", ["iteration": index + 1])
            self.preview("small") {
                self.emit("iteration", ["iteration": index + 1])
                self.after(0.05) { self.togglePreview(index + 1) }
            }
        }
    }

    func workload(_ name: String, next: String?) {
        begin(name + "_preview")
        func repeatLoad(_ index: Int) {
            if index == 5 {
                self.after(3) {
                    self.finish()
                    if let next = next { self.workload(next, next: next == "code" ? "diagrams" : nil) }
                    else { self.closeWindows(0) }
                }
                return
            }
            self.preview(name) { self.after(0.1) { repeatLoad(index + 1) } }
        }
        repeatLoad(0)
    }

    func closeWindows(_ index: Int) {
        if index == 0 {
            controller.disablePreview()
            begin("close_5_preview_windows")
        }
        if index == 5 {
            after(5) { self.checkReleasedWindows(); self.finish(); self.sameNoteWindows() }
            return
        }
        let name = "small-\(index)"
        controller.openInNewWindow(note: notes[name]!, frame: nil, preview: true)
        guard let window = AppDelegate.noteWindows.first,
              let editor = window.contentViewController as? NoteViewController else {
            failures.append(stage + ": note window missing")
            closeWindows(index + 1)
            return
        }
        closedEditors.append(WeakEditor(editor))
        // Lifetime measurement does not wait for animation frames: a newly
        // opened note window can have a zero-size web view before layout.
        after(1) {
            self.emit("window_opened", ["iteration": index + 1,
                                        "preview_attached": editor.editor.markdownView != nil])
            window.close()
            self.advanceAppKitEventLoop()
            self.after(0.5) {
                self.emit("window_closed", ["iteration": index + 1,
                                            "registered_note_windows": AppDelegate.noteWindows.count])
                self.closeWindows(index + 1)
            }
        }
    }

    func checkReleasedWindows(requireNoPreviews: Bool = false) {
        if closedEditors.contains(where: { $0.controller != nil || $0.editor != nil || $0.processor != nil }) {
            failures.append(stage + ": closed window retained its controller, editor or processor")
        }
        // AppKit/WebKit can defer the most recent view until another event.
        // Check all web views after the final editor transition and cooldown.
        if requireNoPreviews && views.contains(where: { $0.view != nil }) {
            failures.append(stage + ": closed preview remained alive")
        }
    }

    func sameNoteWindows() {
        begin("same_note_and_edit_timers")
        let note = notes["small"]!
        controller.openInNewWindow(note: note, frame: nil, preview: true)
        guard let first = AppDelegate.noteWindows.first,
              let firstEditor = first.contentViewController as? NoteViewController else {
            failures.append(stage + ": first window missing"); cooldown(); return
        }
        closedEditors.append(WeakEditor(firstEditor))
        controller.openInNewWindow(note: note, frame: nil, preview: false)
        guard let second = AppDelegate.noteWindows.first,
              let secondEditor = second.contentViewController as? NoteViewController else {
            failures.append(stage + ": second window missing"); cooldown(); return
        }
        closedEditors.append(WeakEditor(secondEditor))
        after(1) {
            first.window?.close()
            if AppDelegate.noteWindows.count != 1 || AppDelegate.noteWindows.first !== second {
                self.failures.append(self.stage + ": closing one note removed another window")
            }
            // Exercise the real edit handler and tag timer in the isolated note library.
            secondEditor.textDidChange(Notification(name: NSText.didChangeNotification, object: secondEditor.editor))
            secondEditor.editor.scheduleTagScan(for: note)
            if !secondEditor.breakUndoTimer.isValid || secondEditor.editor.tagsTimer?.isValid != true {
                self.failures.append(self.stage + ": edit timers did not start")
            }
            second.window?.close()
            self.advanceAppKitEventLoop()
            if secondEditor.breakUndoTimer.isValid || secondEditor.editor.tagsTimer?.isValid == true {
                self.failures.append(self.stage + ": close did not invalidate edit timers")
            }
            if self.controller.tagsScannerQueue.contains(where: { $0 === note }) {
                self.failures.append(self.stage + ": close lost the pending tag scan")
            }
            self.after(5) {
                self.checkReleasedWindows()
                self.finish()
                self.cooldown()
            }
        }
    }

    func cooldown() {
        begin("closed_preview_10s")
        controller.disablePreview()
        controller.editor.fill(note: notes["small"]!, force: true)
        advanceAppKitEventLoop()
        after(10) {
            self.checkReleasedWindows(requireNoPreviews: true)
            self.finish()
            self.heartbeat?.invalidate()
            self.emit("complete", ["failures": self.failures])
            // Allow the external runner to collect a leaks report before exit.
            self.after(20) { exit(self.failures.isEmpty ? 0 : 1) }
        }
    }
}
