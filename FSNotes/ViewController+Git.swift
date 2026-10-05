//
//  ViewController+Git.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 9/10/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

private var gitRestoringNotes = Set<ObjectIdentifier>()

extension EditorViewController {

    @IBAction func saveRevision(_ sender: NSMenuItem) {
        guard let gitProject = getGitProject() else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.informativeText = NSLocalizedString("Please init git repository before (Preferences -> Git -> Init/commit)", comment: "")
            alert.messageText = NSLocalizedString("Repository not found", comment: "")
            alert.runModal()
            return
        }

        guard let window = self.view.window else { return }
        if UserDefaultsManagement.askCommitMessage {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 60))
            if let lastMessage = UserDefaultsManagement.lastCommitMessage {
                field.stringValue = lastMessage
            }
            
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Commit message:", comment: "")
            alert.accessoryView = field
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
                if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                    let commitMessage: String? = field.stringValue.count > 0 ? field.stringValue : nil
                    
                    if field.stringValue.count > 0 {
                        UserDefaultsManagement.lastCommitMessage = commitMessage
                    }
                    
                    self.saveRevision(project: gitProject, commitMessage: commitMessage)
                }
            }
            
            field.becomeFirstResponder()
            return
        }
        
        saveRevision(project: gitProject, commitMessage: nil)
    }
    
    private func saveRevision(project: Project, commitMessage: String? = nil) {
        guard let window = self.view.window else { return }

        ViewController.gitQueue.addOperation({
            ViewController.gitQueueOperationDate = Date()

            defer {
                ViewController.gitQueueOperationDate = nil
            }

            do {
                try project.saveRevision(commitMessage: commitMessage)
            } catch GitError.noAddedFiles {
                // pass
            } catch {
                var message = String()
                if let error = error as? GitError {
                    message = error.associatedValue()
                } else {
                    message = error.localizedDescription
                }

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.informativeText = message
                    alert.messageText = NSLocalizedString("Git error", comment: "")
                    alert.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in }
                }
            }
        })
    }

    @objc func showNoteHistory(_ sender: NSMenuItem) {
        guard let note = sender.representedObject as? Note else { return }
        openHistory(for: note)
    }

    func openHistory(for note: Note) {
        guard note.hasGitRepository(), !note.isEncrypted() else { return }
        NoteHistoryWindowController.open(note: note) { commit, window, completion in
            self.confirmGitRestore(note: note, commit: commit, in: window, completion: completion)
        }
    }

    private func confirmGitRestore(note: Note, commit: Commit, in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let identity = ObjectIdentifier(note)
        guard !gitRestoringNotes.contains(identity) else { completion(false); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Restore “%@”?", comment: "Git history"), note.name)
        alert.informativeText = "\(commit.getDate())\n\(commit.oid.sha() ?? "")\n\(commit.summary)\n\n"
            + NSLocalizedString("This replaces the current file contents. Other files and staged changes are preserved.", comment: "Git history")
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: "Git history"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !gitRestoringNotes.contains(identity) else { completion(false); return }
            gitRestoringNotes.insert(identity)
            ViewController.shared()?.tagsScannerQueue.removeAll { $0 === note }
            let editors = AppDelegate.getEditTextViews().filter { $0.note == note }
            let editability = editors.map { $0.isEditable }
            editors.forEach { $0.isEditable = false }
            note.isBlocked = true
            ViewController.gitQueue.addOperation {
                // Finish pending autosaves before restoring, so they cannot overwrite it.
                Storage.shared().plainWriter.waitUntilAllOperationsAreFinished()
                note.isBlocked = true
                ViewController.gitQueueOperationDate = Date()
                defer { ViewController.gitQueueOperationDate = nil }
                do {
                    try note.restoreGitCommit(commit)
                    DispatchQueue.main.async {
                        note.forceReload()
                        note.cacheCodeBlocks()
                        note.loadModifiedLocalAt()
                        if UserDefaultsManagement.inlineTags {
                            let changes = note.scanContentTags()
                            ViewController.shared()?.sidebarOutlineView.removeTags(changes.1)
                            ViewController.shared()?.sidebarOutlineView.addTags(changes.0)
                        }
                        NotesTextProcessor.highlight(attributedString: note.content)
                        for (editor, editable) in zip(editors, editability) {
                            editor.undoManager?.removeAllActions()
                            editor.isEditable = editable
                        }
                        note.isBlocked = false
                        gitRestoringNotes.remove(identity)
                        self.reloadAllOpenedWindows(note: note)
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                        completion(true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        for (editor, editable) in zip(editors, editability) { editor.isEditable = editable }
                        note.isBlocked = false
                        gitRestoringNotes.remove(identity)
                        self.showGitHistoryError(error, in: window)
                        completion(false)
                    }
                }
            }
        }
    }

    private func showGitHistoryError(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("Git error", comment: "")
        alert.informativeText = (error as? GitError)?.associatedValue() ?? error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @IBAction private func makeFullSnapshot(_ sender: Any) {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: Date())
        let minute = cal.component(.minute, from: Date())

        if let lastSnapshot = self.lastSnapshot {
            if minute == lastSnapshot {
                return
            } else {
                self.lastSnapshot = nil
            }
        }

        guard UserDefaultsManagement.snapshotsInterval != 0 && (
            hour == UserDefaultsManagement.snapshotsInterval || (
                hour != 0 && hour % UserDefaultsManagement.snapshotsInterval == 0
            )
        ) else { return }

        guard UserDefaultsManagement.snapshotsIntervalMinutes == minute else { return }
        
        lastSnapshot = minute

        ViewController.gitQueue.addOperation({
            ViewController.gitQueueOperationDate = Date()

            defer {
                ViewController.gitQueueOperationDate = nil
            }

            let storage = Storage.shared()
            guard let projects = storage.getGitProjects() else { return }

            for project in projects {
                do {
                    if project.hasRepository()  {
                        try project.commit()
                        try project.pull()
                        try project.push()
                    }
                } catch {
                    print(error)
                }
            }
        })
    }
    
    @IBAction private func pull(_ sender: Any) {

        // Restart queue if operation stucked more then 2 minutes
        if let date = ViewController.gitQueueOperationDate {
            let diff = Int(Date().timeIntervalSince1970) - Int(date.timeIntervalSince1970)
            let isBusy = ViewController.gitQueueBusy

            if diff > 120 && !isBusy {

                ViewController.gitQueue = OperationQueue()
                ViewController.gitQueue.maxConcurrentOperationCount = 1

                print("Git queue restart")
            } else {
                print("Git pull skipped")
                return
            }
        }

        ViewController.gitQueue.addOperation({
            ViewController.gitQueueOperationDate = Date()

            defer {
                ViewController.gitQueueOperationDate = nil
            }

            Storage.shared().pullAll()
        })
    }

    public func scheduleSnapshots() {
        guard !UserDefaultsManagement.backupManually else { return }

        DispatchQueue.main.async {
            self.snapshotsTimer.invalidate()
            self.snapshotsTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.makeFullSnapshot), userInfo: nil, repeats: true)
        }
    }
    
    public func schedulePull() {
        guard !UserDefaultsManagement.backupManually else { return }

        let interval = UserDefaultsManagement.pullInterval
        
        pullTimer.invalidate()
        pullTimer = Timer.scheduledTimer(timeInterval: TimeInterval(interval), target: self, selector: #selector(pull), userInfo: nil, repeats: true)
    }
    
    public func stopPull() {
        pullTimer.invalidate()
    }
    
    public func getGitProject() -> Project? {
        guard let vc = ViewController.shared() else { return nil }
        
        if let project = vc.getSelectedNote()?.project.getGitProject() {
            return project
        }

        if let project = vc.sidebarOutlineView.getSelectedProject()?.getGitProject() {
            return project
        }

        return Storage.shared().getDefault()?.getGitProject()
    }

}
