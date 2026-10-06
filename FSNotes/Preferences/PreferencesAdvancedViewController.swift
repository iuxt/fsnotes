//
//  PreferencesAdvancedViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/17/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class PreferencesAdvancedViewController: NSViewController {
    override func viewWillAppear() {
        super.viewWillAppear()
    }

    @IBOutlet weak var languagePopUp: NSPopUpButton!
    @IBOutlet weak var version: NSTextField!
    @IBOutlet weak var appearance: NSPopUpButton!
    @IBOutlet weak var appearanceLabel: NSTextField!

    @IBOutlet weak var dockIconFirst: NSButton!
    @IBOutlet weak var dockIconSecond: NSButton!

    @IBAction func appearanceClick(_ sender: NSPopUpButton) {
        if let type = AppearanceType(rawValue: sender.indexOfSelectedItem) {
            UserDefaultsManagement.appearanceType = type
        }

        restart()
    }

    override func viewDidAppear() {
        let languages = [
            LanguageType(rawValue: 0),
            LanguageType(rawValue: 1),
            LanguageType(rawValue: 2),
            LanguageType(rawValue: 5),
            LanguageType(rawValue: 6),
            LanguageType(rawValue: 18),
            LanguageType(rawValue: 15),
            LanguageType(rawValue: 3),
            LanguageType(rawValue: 9),
            LanguageType(rawValue: 8),
            LanguageType(rawValue: 12),
            LanguageType(rawValue: 16),
            LanguageType(rawValue: 11),
            LanguageType(rawValue: 13),
            LanguageType(rawValue: 7),
            LanguageType(rawValue: 10),
            LanguageType(rawValue: 14),
            LanguageType(rawValue: 4),
            LanguageType(rawValue: 17)
        ]

        languagePopUp.removeAllItems()
        for language in languages {
            if let lang = language?.description, let id = language?.rawValue {
                languagePopUp.addItem(withTitle: lang)
                languagePopUp.lastItem?.state = (id == UserDefaultsManagement.defaultLanguage) ? .on : .off

                if id == UserDefaultsManagement.defaultLanguage {
                    languagePopUp.selectItem(withTitle: lang)
                }
            }
        }

        if #available(OSX 10.14, *) {
            appearance.selectItem(at: UserDefaultsManagement.appearanceType.rawValue)
        } else {
            appearanceLabel.isHidden = true
            appearance.isHidden = true
        }

        if let dictionary = Bundle.main.infoDictionary,
            let ver = dictionary["CFBundleShortVersionString"] as? String,
            let build = dictionary["CFBundleVersion"] as? String {
            version.stringValue = "v\(ver) build \(build)"
        }

        switch UserDefaultsManagement.dockIcon {
        case 0:
            dockIconFirst.state = .on
            break
        case 1:
            dockIconSecond.state = .on
            break
        default:
            dockIconFirst.state = .on
        }
    }

    @IBAction func languagePopUp(_ sender: NSPopUpButton) {
        let type = LanguageType.withName(rawValue: sender.title)

        UserDefaultsManagement.defaultLanguage = type.rawValue

        UserDefaults.standard.set([type.code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()

        restart()
    }

    private func restart(afterTermination cleanup: (() -> Void)? = nil) {
        (NSApp.delegate as? AppDelegate)?.restart(afterTermination: cleanup)
    }

    @IBAction func dockIcon(_ sender: NSButton) {
        UserDefaultsManagement.dockIcon = sender.tag

        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.loadDockIcon()
    }

    @IBAction func resetCaches(_ sender: Any) {
        restart(afterTermination: Self.removeCaches)
    }

    private static func removeCaches() {
        if let sidebarTreeURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("sidebarTree") {
            try? FileManager.default.removeItem(at: sidebarTreeURL)
        }
        
        let projects = Storage.shared().getProjects()
        for project in projects {
            if let cacheUrl = project.getCacheURL() {
                try? FileManager.default.removeItem(at: cacheUrl)
            }
        }
    }
    
    @IBAction func resetSettings(_ sender: Any) {
        restart(afterTermination: Self.removeSettings)
    }

    private static func removeSettings() {
        let store = NSUbiquitousKeyValueStore.default
        for (key, _) in store.dictionaryRepresentation {
            store.removeObject(forKey: key)
        }
        store.synchronize()
        
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
        
        if let editorsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("editors.settings") {
            try? FileManager.default.removeItem(at: editorsURL)
        }
        
        if let notesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("notes.settings") {
            try? FileManager.default.removeItem(at: notesURL)
        }
        
        if let bookmarkUrls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Bookmarks.dict") {
            try? FileManager.default.removeItem(at: bookmarkUrls)
        }
    }
}
