//
//  TitleTextField.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 5/10/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import Carbon.HIToolbox

class TitleTextField: NSTextField {
    public var restoreResponder: NSResponder?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command)
            && event.characters?.unicodeScalars.first == "c"
            && !event.modifierFlags.contains(.shift)
            && !event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.option) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(self.stringValue, forType: NSPasteboard.PasteboardType.string)
        }

        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        if let vc = ViewController.shared(),
            let note = vc.editor.note {
            stringValue = note.getFileName()
        }

        return super.becomeFirstResponder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        guard let vc = ViewController.shared(),
            let note = vc.editor.note
        else { return }

        let currentTitle = stringValue
        let currentName = note.getFileName()

        defer {
            updateNotesTableView()
            editModeOff()
        }

        if currentName != currentTitle {
            rename(currentTitle: currentTitle, note: note)
            return
        }

        vc.updateTitle(note: note)
        self.resignFirstResponder()
        updateNotesTableView()
        vc.titleLabel.isEditable = false
        vc.titleLabel.isEnabled = false
    }

    public func rename(currentTitle: String, note: Note) {
        ViewController.shared()?.rename(note: note, to: currentTitle)
        ViewController.shared()?.updateTitle(note: note)
    }

    public func editModeOn() {
        self.isEnabled = true
        self.isEditable = true

        MainWindowController.shared()?.makeFirstResponder(self)
    }

    public func editModeOff() {
        self.isEnabled = false
        self.isEditable = false

        guard let vc = ViewController.shared(),
              let note = vc.editor.note else { return }

        vc.updateTitle(note: note)
    }

    public func updateNotesTableView() {
        guard let vc = ViewController.shared(), let note = vc.editor.note else { return }

        if !note.project.settings.isFirstLineAsTitle() {
            vc.notesTableView.reloadRow(note: note)
        }

        if let responder = restoreResponder {
            window?.makeFirstResponder(responder)
        }
    }
}
