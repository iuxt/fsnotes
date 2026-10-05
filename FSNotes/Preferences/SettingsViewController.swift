//
//  SettingsViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 14.03.2023.
//  Copyright © 2023 Oleksandr Hlushchenko. All rights reserved.
//

import AppKit

class SettingsViewController: NSViewController, NSTextFieldDelegate {

    public var gitProject: Project?
    public var project: Project?
    public var progress: GitProgress?

    override func viewDidAppear() {
        passphrase.delegate = self
        origin.delegate = self
    }

    @IBOutlet var origin: NSTextField!
    @IBOutlet var keyStatus: NSTextField!
    @IBOutlet var logTextField: NSTextField!
    @IBOutlet var cloneButton: NSButton!
    @IBOutlet var passphrase: NSSecureTextField!
    @IBOutlet var progressIndicator: NSProgressIndicator!
    @IBOutlet var caCertificateButton: NSButton!

    @IBAction func editCACertificates(_ sender: Any) {
        guard let project = gitProject else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("CA Certificates", comment: "")
        alert.informativeText = NSLocalizedString("Paste PEM CA certificates for this library's Git LFS server. Leave empty to use default certificate verification.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.string = project.settings.gitCACertificates ?? ""
        textView.setAccessibilityLabel(NSLocalizedString("CA certificates in PEM format", comment: ""))
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let pem = try GitLFS.normalizedCACertificates(textView.string)
                project.settings.gitCACertificates = pem.isEmpty ? nil : pem
                project.saveSettings()
                updateButtons()
                return
            } catch {
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .warning
                errorAlert.messageText = NSLocalizedString("Invalid CA Certificate", comment: "")
                errorAlert.informativeText = error.localizedDescription
                errorAlert.runModal()
            }
        }
    }

    @IBAction func origin(_ sender: Any) {
        gitProject?.settings.setOrigin(origin.stringValue)
        gitProject?.saveSettings()

        updateButtons()
    }

    @IBAction func passphrase(_ sender: Any) {
        gitProject?.settings.gitPrivateKeyPassphrase = passphrase.stringValue
        gitProject?.saveSettings()
    }

    @IBAction func clonePull(_ sender: Any) {
        guard let project = self.gitProject else { return }

        if let origin = project.settings.gitOrigin, origin.startsWith(string: "https://") {
            let alert = NSAlert()
            alert.messageText = "Wrong configuration"
            alert.alertStyle = .critical
            alert.informativeText = "Please use ssh keys, https auth is not supported"
            alert.runModal()
            return
        }

        let action = project.getRepositoryState()
        updateButtons(isActive: true)

        ViewController.gitQueue.addOperation({
            defer {
                ViewController.gitQueueOperationDate = nil
                ViewController.gitQueueBusy = false
                
                DispatchQueue.main.async {
                    self.updateButtons(isActive: false)
                }
            }

            ViewController.gitQueueOperationDate = Date()
            ViewController.gitQueueBusy = true

            if let message = project.gitDo(action, progress: self.progress) {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.informativeText = message
                    alert.messageText = NSLocalizedString("git error", comment: "")
                    alert.runModal()
                }
            }
        })
    }

    @IBAction func privateKey(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseFiles = true
        openPanel.begin { (result) -> Void in
            if result == .OK {
                if openPanel.urls.count != 1 {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.informativeText = NSLocalizedString("Please select private key", comment: "")
                    alert.runModal()
                    return
                }

                self.gitProject?.settings.gitPrivateKey = try? Data(contentsOf: openPanel.urls[0])
                self.gitProject?.saveSettings()

                self.keyStatus.stringValue = "✅"
            }
        }
    }

    @IBAction func resetKey(_ sender: Any) {
        gitProject?.removeSSHKey()
        gitProject?.settings.gitPrivateKey = nil
        gitProject?.saveSettings()

        keyStatus.stringValue = ""
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }

        let id = textField.identifier?.rawValue
        
        if id == "gitOrigin" || id == "gitOriginMain" {
            gitProject?.settings.setOrigin(textField.stringValue)
            updateButtons()
        }

        if id == "gitPassphrase" || id == "gitPassphraseMain" {
            gitProject?.settings.gitPrivateKeyPassphrase = textField.stringValue
        }

        DispatchQueue.global(qos: .background).async {
            self.gitProject?.saveSettings()
        }
    }

    public func updateButtons(isActive: Bool? = nil) {
        guard let project = gitProject else { return }

        caCertificateButton.isEnabled = !(isActive ?? project.isActiveGit)
        caCertificateButton.toolTip = project.settings.gitCACertificates == nil
            ? NSLocalizedString("Default certificate verification", comment: "")
            : NSLocalizedString("Custom CA certificates configured", comment: "")

        progressIndicator.isHidden = !project.isActiveGit
        cloneButton.title = project.getRepositoryState().title

        if let isActive = isActive {
            if isActive {
                progressIndicator.startAnimation(nil)
                progressIndicator.isHidden = false
            } else {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isHidden = true
            }
        }
    }

    public func loadGit(project: Project) {
        var project = project

        if project.isVirtual  {
            if let defaultProject = Storage.shared().getDefault() {
                project = defaultProject
            }
        }

        self.gitProject = project

        origin.stringValue = project.settings.gitOrigin ?? ""
        passphrase.stringValue = project.settings.gitPrivateKeyPassphrase ?? ""
        keyStatus.stringValue = project.settings.gitPrivateKey != nil ? "✅" : ""

        updateButtons()
        progress = GitProgress(statusTextField: logTextField, project: project)

        // Global instance for libgit2 callbacks
        AppDelegate.gitProgress = progress

        if let status = project.gitStatus {
            logTextField.stringValue = status
        }
    }
}
