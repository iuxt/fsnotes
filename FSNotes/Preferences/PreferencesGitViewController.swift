//
//  PreferencesGitViewController.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 9/8/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class PreferencesGitViewController: SettingsViewController {

    override func updateButtons(isActive: Bool? = nil) {
        super.updateButtons(isActive: isActive)
        guard let project = gitProject else { return }
        let title: String
        switch project.getRepositoryState() {
        case .initCommit: title = "Create Git History"
        case .clonePush: title = "Clone & Sync"
        case .commit: title = "Save Snapshot"
        case .pullPush: title = "Sync Now"
        }
        cloneButton.title = NSLocalizedString(title, comment: "")
        let busy = isActive ?? project.isActiveGit
        cloneButton.isEnabled = !busy
        removeButton.isEnabled = project.hasRepository() && !busy
    }

    @IBOutlet weak var repositoryInfoLabel: NSTextField!
    @IBOutlet weak var snapshotsTextField: NSTextField!
    @IBOutlet weak var minutes: NSTextField!
    @IBOutlet weak var backupManually: NSButton!
    @IBOutlet weak var backupBySchedule: NSButton!
    @IBOutlet weak var pullInterval: NSTextField!
    @IBOutlet weak var askCommitMessage: NSButton!

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = NSSize(width: 550, height: 525)

        if let project = Storage.shared().getDefault() { loadGit(project: project) }
        repositoryInfoLabel.stringValue = NSLocalizedString("Git history: .git/", comment: "")
        origin.placeholderString = "git@github.com:you/notes.git"

        snapshotsTextField.stringValue = String(UserDefaultsManagement.snapshotsInterval)
        minutes.stringValue = String(UserDefaultsManagement.snapshotsIntervalMinutes)
        backupManually.state = UserDefaultsManagement.backupManually ? .on : .off
        backupBySchedule.state = UserDefaultsManagement.backupManually ? .off : .on
        pullInterval.stringValue = String(UserDefaultsManagement.pullInterval)
        askCommitMessage.state = UserDefaultsManagement.askCommitMessage ? .on : .off
        updateScheduleFields()
    }

    @IBAction func showFinder(_ sender: Any) {
        guard let project = gitProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    @IBAction func showTerminal(_ sender: Any) {
        guard let project = gitProject,
              let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([project.url], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @IBAction func backupMethod(_ sender: NSButton) {
        guard let ident = sender.identifier?.rawValue else { return }
        
        let isManualBackup = ident == "manual"
        
        UserDefaultsManagement.backupManually = isManualBackup
        backupManually.state = isManualBackup ? .on : .off
        backupBySchedule.state = isManualBackup ? .off : .on
        
        guard let vc = ViewController.shared() else { return }
        if backupBySchedule.state == .on {
            vc.schedulePull()
            vc.scheduleSnapshots()
        } else {
            vc.stopPull()
            vc.snapshotsTimer.invalidate()
        }
        updateScheduleFields()
    }

    @IBAction func changeSnapshotIntervalByHours(_ sender: NSTextField) {
        let interval = max(1, Int(sender.stringValue) ?? 1)
        sender.integerValue = interval
        UserDefaultsManagement.snapshotsInterval = interval

        guard let vc = ViewController.shared() else { return }
        vc.scheduleSnapshots()
    }

    @IBAction func changeSnapshotsIntervalByMinutes(_ sender: NSTextField) {
        let interval = min(59, max(0, Int(sender.stringValue) ?? 0))
        sender.integerValue = interval
        UserDefaultsManagement.snapshotsIntervalMinutes = interval

        guard let vc = ViewController.shared() else { return }
        vc.scheduleSnapshots()
    }

    @IBAction func pullInterval(_ sender: NSTextField) {
        let interval = max(10, Int(sender.stringValue) ?? 10)
        sender.integerValue = interval
        UserDefaultsManagement.pullInterval = interval

        guard let vc = ViewController.shared() else { return }
        vc.schedulePull()
    }
    
    @IBAction func askCommitMessage(_ sender: NSButton) {
        UserDefaultsManagement.askCommitMessage = sender.state == .on
    }
    private func updateScheduleFields() {
        let enabled = !UserDefaultsManagement.backupManually
        snapshotsTextField.isEnabled = enabled
        minutes.isEnabled = enabled
        pullInterval.isEnabled = enabled
    }

}
