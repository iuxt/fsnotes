//
//  PreferencesGeneralViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/17/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import CoreData

class PreferencesGeneralViewController: NSViewController, NSTextFieldDelegate {
    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = NSSize(width: 550, height: 481)
    }

    @IBOutlet var externalEditorApp: NSTextField!
    @IBOutlet var newNoteshortcutView: ShortcutRecorderView!
    @IBOutlet var searchNotesShortcut: ShortcutRecorderView!
    @IBOutlet var activateShortcut: ShortcutRecorderView!
    @IBOutlet weak var quickNote: ShortcutRecorderView!
    @IBOutlet weak var defaultStoragePath: NSPathControl!
    @IBOutlet weak var workspacePathLabel: NSTextField!
    @IBOutlet weak var searchFocusOnESC: NSButton!
    @IBOutlet weak var defaultExtension: NSPopUpButton!
    @IBOutlet weak var automaticConflictsResolution: NSButton!
    @IBOutlet weak var textMatchAutoSelection: NSButton!
    @IBOutlet weak var hideOnDeactivate: NSButton!

    //MARK: global variables

    override func viewDidLoad() {
        super.viewDidLoad()
        workspacePathLabel.stringValue = NSLocalizedString("Workspace Folder", comment: "")
        defaultStoragePath.isEditable = false
        defaultStoragePath.toolTip = NSLocalizedString("One folder for your notes and their history.", comment: "")
        initShortcuts()
    }

    override func viewDidAppear() {
        self.view.window!.title = NSLocalizedString("Settings", comment: "")

        externalEditorApp.stringValue = UserDefaultsManagement.externalEditor

        if let url = UserDefaultsManagement.storageUrl {
            defaultStoragePath.url = url
        }

        searchFocusOnESC.state = UserDefaultsManagement.shouldFocusSearchOnESCKeyDown ? .on : .off


        let ext = UserDefaultsManagement.noteExtension
        defaultExtension.selectItem(withTitle: "." + ext)

        automaticConflictsResolution.state = UserDefaultsManagement.automaticConflictsResolution ? .on : .off

        externalEditorApp.delegate = self

        textMatchAutoSelection.state = UserDefaultsManagement.textMatchAutoSelection ? .on : .off

        hideOnDeactivate.state = UserDefaultsManagement.hideOnDeactivate ? .on : .off
    }

    @IBAction func textMatchAutoSelection(_ sender: NSButton) {
        UserDefaultsManagement.textMatchAutoSelection = (sender.state == .on)
    }

    @IBAction func changeDefaultStorage(_ sender: Any) {
        guard let url = WorkspaceDirectory.choose(switching: true),
              url != UserDefaultsManagement.storageUrl?.resolvingSymlinksInPath() else { return }
        (NSApp.delegate as? AppDelegate)?.switchWorkspace(to: url)
    }

    @IBAction func externalEditor(_ sender: Any) {
        UserDefaultsManagement.externalEditor = externalEditorApp.stringValue
    }

    @IBAction func searchFocusOnESC(_ sender: NSButton) {
        UserDefaultsManagement.shouldFocusSearchOnESCKeyDown = sender.state == .on
    }

    @IBAction func defaultExtension(_ sender: NSPopUpButton) {
        let ext = sender.title.replacingOccurrences(of: ".", with: "")

        UserDefaultsManagement.noteExtension = ext
        UserDefaultsManagement.fileFormat = .Markdown
    }

    @IBAction func automaticConflictsResolution(_ sender: NSButton) {
        UserDefaultsManagement.automaticConflictsResolution = sender.state == .on
    }

    @IBAction func changeHideOnDeactivate(_ sender: NSButton) {
        UserDefaultsManagement.hideOnDeactivate = sender.state == .on

        // We don't need to set the user defaults value here as the checkbox is
        // bound to it. We do need to update each window's hideOnDeactivate.
        for window in NSApplication.shared.windows {
            if window.className == "NSStatusBarWindow" {
                continue
            }

            window.hidesOnDeactivate = UserDefaultsManagement.hideOnDeactivate
        }
    }

    func initShortcuts() {
        guard let vc = ViewController.shared() else { return }

        let monitor = GlobalShortcutMonitor.shared()

        newNoteshortcutView.shortcutValue = UserDefaultsManagement.newNoteShortcut
        searchNotesShortcut.shortcutValue = UserDefaultsManagement.searchNoteShortcut
        quickNote.shortcutValue = UserDefaultsManagement.quickNoteShortcut
        activateShortcut.shortcutValue = UserDefaultsManagement.activateShortcut

        newNoteshortcutView.shortcutValidator.allowAnyShortcutWithOptionModifier = true
        searchNotesShortcut.shortcutValidator.allowAnyShortcutWithOptionModifier = true
        quickNote.shortcutValidator.allowAnyShortcutWithOptionModifier = true
        activateShortcut.shortcutValidator.allowAnyShortcutWithOptionModifier = true

        newNoteshortcutView.shortcutValueChange = { (sender) in
            if ((self.newNoteshortcutView.shortcutValue) != nil) {
                monitor.unregisterShortcut(UserDefaultsManagement.newNoteShortcut)

                let keyCode = self.newNoteshortcutView.shortcutValue.keyCode
                let modifierFlags = self.newNoteshortcutView.shortcutValue.modifierFlags

                UserDefaultsManagement.newNoteShortcut = GlobalShortcut(keyCode: keyCode, modifierFlags: modifierFlags)

                GlobalShortcutMonitor.shared().register(self.newNoteshortcutView.shortcutValue, withAction: {
                    vc.makeNoteShortcut()
                })
            } else {
                monitor.unregisterShortcut(UserDefaultsManagement.newNoteShortcut)

                UserDefaultsManagement.newNoteShortcut = nil
            }
        }

        searchNotesShortcut.shortcutValueChange = { (sender) in
            if ((self.searchNotesShortcut.shortcutValue) != nil) {
                monitor.unregisterShortcut(UserDefaultsManagement.searchNoteShortcut)

                let keyCode = self.searchNotesShortcut.shortcutValue.keyCode
                let modifierFlags = self.searchNotesShortcut.shortcutValue.modifierFlags

                UserDefaultsManagement.searchNoteShortcut = GlobalShortcut(keyCode: keyCode, modifierFlags: modifierFlags)

                GlobalShortcutMonitor.shared().register(self.searchNotesShortcut.shortcutValue, withAction: {
                    vc.searchShortcut()
                })
            } else {
                monitor.unregisterShortcut(UserDefaultsManagement.searchNoteShortcut)

                UserDefaultsManagement.searchNoteShortcut = nil
            }
        }

        quickNote.shortcutValueChange = { (sender) in
            monitor.unregisterShortcut(UserDefaultsManagement.quickNoteShortcut)

            if ((self.quickNote.shortcutValue) != nil) {
                let keyCode = self.quickNote.shortcutValue.keyCode
                let modifierFlags = self.quickNote.shortcutValue.modifierFlags

                UserDefaultsManagement.quickNoteShortcut = GlobalShortcut(keyCode: keyCode, modifierFlags: modifierFlags)

                GlobalShortcutMonitor.shared().register(self.quickNote.shortcutValue, withAction: {
                    vc.quickNote(self)
                })
            } else {
                UserDefaultsManagement.quickNoteShortcut = nil
            }
        }

        activateShortcut.shortcutValueChange = { (sender) in
            monitor.unregisterShortcut(UserDefaultsManagement.activateShortcut)

            if ((self.activateShortcut.shortcutValue) != nil) {
                let keyCode = self.activateShortcut.shortcutValue.keyCode
                let modifierFlags = self.activateShortcut.shortcutValue.modifierFlags

                UserDefaultsManagement.activateShortcut = GlobalShortcut(keyCode: keyCode, modifierFlags: modifierFlags)

                GlobalShortcutMonitor.shared().register(self.activateShortcut.shortcutValue, withAction: {
                    vc.searchShortcut(activate: true)
                })
            } else {
                UserDefaultsManagement.activateShortcut = nil
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }

        if textField.identifier?.rawValue == "openInExternalEditor" {
            UserDefaultsManagement.externalEditor = externalEditorApp.stringValue
        }
    }
}
