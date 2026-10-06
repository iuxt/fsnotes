//
//  AppDelegate.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/20/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import UserNotifications

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var prefsWindowController: PrefsWindowController?
    var aboutWindowController: AboutWindowController?
    var statusItem: NSStatusItem?
    private var isSwitchingWorkspace = false
    private var isRestarting = false
    private var restartCleanup: (() -> Void)?

    public var urls: [URL]? = nil
    public var url: URL? = nil
    public var newName: String? = nil
    public var newContent: String? = nil
    public var folderName: String? = nil
    public var newWindow: Bool = false

    public static var mainWindowController: MainWindowController?
    public static var noteWindows = [NSWindowController]()

    public static var appTitle: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return name ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
    }

    public static var gitProgress: GitProgress?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restore sandbox access before checking the chosen workspace. Storage must
        // not initialize until the user has selected an accessible directory.
        SandboxBookmark.sharedInstance().load()
        var workspaceReady = false
        if let url = UserDefaultsManagement.storageUrl {
            do {
                try RepositoryManager().prepareWorkspace(at: url)
                UserDefaultsManagement.storageType = .custom
                workspaceReady = true
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        while !workspaceReady {
            guard let url = WorkspaceDirectory.choose() else { exit(EXIT_SUCCESS) }
            do {
                try WorkspaceDirectory.save(url)
                workspaceReady = true
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        loadDockIcon()

        if UserDefaultsManagement.showInMenuBar {
            constructMenu()
        }

        if !UserDefaultsManagement.showDockIcon {
            let transformState = ProcessApplicationTransformState(kProcessTransformToUIElementApplication)
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
            TransformProcessType(&psn, transformState)

            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Ensure the font panel is closed when the app starts, in case it was
        // left open when the app quit.
        NSFontManager.shared.fontPanel(false)?.orderOut(self)

        applyAppearance()

        #if CLOUD_RELATED_BLOCK
        if let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents").standardized {

            if (!FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: nil)) {
                do {
                    try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Home directory creation: \(error)")
                }
            }
        }
        #endif

        let storyboard = NSStoryboard(name: "Main", bundle: nil)

        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            fatalError("Error getting main window controller")
        }

        AppDelegate.mainWindowController = mainWC
        mainWC.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (!flag) {
            AppDelegate.mainWindowController?.makeNew()
        }

        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaultsManagement.crashedLastTime = false

        if !isSwitchingWorkspace { AppDelegate.saveWindowsState() }

        Storage.shared().saveUploadPaths()

        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        let printDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Print")
        try? FileManager.default.removeItem(at: printDir)

        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("ThumbnailsBig")
        try? FileManager.default.removeItem(at: temporary)

        if let origin = AppDelegate.mainWindowController?.window?.frame.origin {
            UserDefaultsManagement.lastScreenX = Int(origin.x)
            UserDefaultsManagement.lastScreenY = Int(origin.y)
        }

        Storage.shared().saveProjectsCache()

        print("Termination end, crash status: \(UserDefaultsManagement.crashedLastTime)")

        // Reset only after normal persistence, so shutdown cannot recreate it.
        restartCleanup?()
    }

    func restart(afterTermination cleanup: (() -> Void)? = nil) {
        guard !isRestarting, !isSwitchingWorkspace else { return }
        isRestarting = true
        let controller = ViewController.shared()
        controller?.stopPull()
        controller?.snapshotsTimer.invalidate()
        DispatchQueue.global(qos: .userInitiated).async {
            ViewController.gitQueue.waitUntilAllOperationsAreFinished()
            Storage.shared().plainWriter.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async {
                do {
                    try ApplicationRelaunch.schedule()
                    self.restartCleanup = cleanup
                    NSApp.terminate(nil)
                } catch {
                    self.isRestarting = false
                    controller?.schedulePull()
                    controller?.scheduleSnapshots()
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    private static func saveWindowsState() {
        var result = [[String: Any]]()

        let noteWindows = self.noteWindows.sorted(by: { $0.window!.orderedIndex > $1.window!.orderedIndex })
        for windowController in noteWindows {
            if let frame = windowController.window?.frame,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: frame, requiringSecureCoding: true),
               let controller = windowController.contentViewController as? NoteViewController,
                   let note = controller.editor.note {

                let key = windowController.window?.isKeyWindow == true

                result.append(["frame": data, "preview": controller.editor.isPreviewEnabled(), "url": note.url, "main": false, "key": key])
            }
        }

        // Main frame
        if let vc = ViewController.shared(), let note = vc.editor?.note, let mainFrame = vc.view.window?.frame,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: mainFrame, requiringSecureCoding: true) {

            let key = vc.view.window?.isKeyWindow == true

            result.append(["frame": data, "preview": vc.editor.isPreviewEnabled(), "url": note.url, "main": true, "key": key])
        }

        let projectsData = try? NSKeyedArchiver.archivedData(withRootObject: result, requiringSecureCoding: true)
        if let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? projectsData?.write(to: documentDir.appendingPathComponent("editors.settings"))
        }
    }

    private func applyAppearance() {
        if UserDefaultsManagement.appearanceType == .Dark {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.darkAqua)
            UserDataService.instance.isDark = true
        }

        if UserDefaultsManagement.appearanceType == .Light {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.aqua)
            UserDataService.instance.isDark = false
        }

        if UserDefaultsManagement.appearanceType == .System, NSApp.effectiveAppearance.isDark {
            UserDataService.instance.isDark = true
        }
    }

    func switchWorkspace(to url: URL) {
        // Stop producers before draining their queues and changing the root path.
        guard !isSwitchingWorkspace, !isRestarting else { return }
        let previousPath = UserDefaultsManagement.customStoragePath
        let previousType = UserDefaultsManagement.storageType
        let previousBookmarks = SandboxBookmark.sharedInstance().bookmarks
        let controller = ViewController.shared()
        controller?.stopPull()
        controller?.snapshotsTimer.invalidate()
        prefsWindowController?.window?.title = NSLocalizedString("Switching Workspace…", comment: "")
        isSwitchingWorkspace = true
        DispatchQueue.global(qos: .userInitiated).async {
            ViewController.gitQueue.waitUntilAllOperationsAreFinished()
            Storage.shared().plainWriter.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async {
                do {
                    try WorkspaceDirectory.save(url)
                    // A new workspace must not restore windows pointing into the old one.
                    if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                        try? FileManager.default.removeItem(at: support.appendingPathComponent("editors.settings"))
                    }
                    try ApplicationRelaunch.schedule()
                    NSApp.terminate(nil)
                } catch {
                    self.isSwitchingWorkspace = false
                    UserDefaultsManagement.customStoragePath = previousPath
                    UserDefaultsManagement.storageType = previousType
                    let bookmarks = SandboxBookmark.sharedInstance()
                    bookmarks.bookmarks = previousBookmarks
                    bookmarks.save()
                    self.prefsWindowController?.window?.title = NSLocalizedString("Settings", comment: "")
                    controller?.schedulePull()
                    controller?.scheduleSnapshots()
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    func constructMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button, let image = NSImage(named: "menuBar") {
            image.size.width = 20
            image.size.height = 20
            button.image = image
        }

        statusItem?.button?.action = #selector(AppDelegate.clickStatusBarItem(sender:))
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    public func attachMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("New Note", comment: ""), action: #selector(AppDelegate.new(_:)), keyEquivalent: "n"))

        let newWindow = NSMenuItem(title: NSLocalizedString("New Note in New Window", comment: ""), action: #selector(AppDelegate.createInNewWindow(_:)), keyEquivalent: "n")
        var modifier = NSEvent.modifierFlags
        modifier.insert(.command)
        modifier.insert(.shift)
        newWindow.keyEquivalentModifierMask = modifier
        menu.addItem(newWindow)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Search and create", comment: ""), action: #selector(AppDelegate.searchAndCreate(_:)), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings", comment: ""), action: #selector(AppDelegate.openPreferences(_:)), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit FSNotes", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc func clickStatusBarItem(sender: NSStatusItem) {
        let event = NSApp.currentEvent!

        if event.type == NSEvent.EventType.leftMouseUp {

            // Hide active not hidden and not miniaturized
            if !NSApp.isHidden && NSApp.isActive {
                if let mainWindow = AppDelegate.mainWindowController?.window, !mainWindow.isMiniaturized {
                    NSApp.hide(nil)
                    return
                }
            }

            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)

            AppDelegate.mainWindowController?.window?.makeKeyAndOrderFront(nil)
            ViewController.shared()?.search.becomeFirstResponder()

            return
        }

        attachMenu()

        DispatchQueue.main.async {
            if let statusItem = self.statusItem, let button = statusItem.button {
                statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: button.frame.origin.x, y: button.frame.height + 10), in: button)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    // MARK: IBActions

    @IBAction func openMainWindow(_ sender: Any) {
        AppDelegate.mainWindowController?.makeNew()
    }

    @IBAction func openHelp(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/wiki")!)
    }

    @IBAction func openBugReports(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/issues/new?template=bug_report.yml")!)
    }

    @IBAction func openSite(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://fsnot.es")!)
    }

    @IBAction func openPreferences(_ sender: Any?) {
        if prefsWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            prefsWindowController = storyboard.instantiateController(withIdentifier: "Preferences") as? PrefsWindowController
        }

        guard let prefsWindowController = prefsWindowController else { return }

        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(prefsWindowController)

        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func new(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.fileMenuNewNote(self)
    }

    @IBAction func createInNewWindow(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.createInNewWindow(self)
    }

    @IBAction func searchAndCreate(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)

        guard let vc = ViewController.shared() else { return }

        DispatchQueue.main.async {
            vc.search.window?.makeFirstResponder(vc.search)
        }
    }

    @IBAction func removeMenuBar(_ sender: Any?) {
        guard let statusItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @IBAction func addMenuBar(_ sender: Any?) {
        constructMenu()
    }

    @IBAction func showAboutWindow(_ sender: AnyObject) {
        if aboutWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)

            aboutWindowController = storyboard.instantiateController(withIdentifier: "About") as? AboutWindowController
        }

        guard let aboutWindowController = aboutWindowController else { return }

        aboutWindowController.showWindow(nil)
        aboutWindowController.window?.makeKeyAndOrderFront(aboutWindowController)

        NSApp.activate(ignoringOtherApps: true)
    }

    public func loadDockIcon() {
        let appDockTile = NSApplication.shared.dockTile

        // Only the classic icon needs a custom Dock tile. For the default icon
        // the tile is left to the system, so it follows the Dark/Clear/Tinted
        // icon style on macOS 26+.
        if #available(OSX 10.12, *) {
            if UserDefaultsManagement.dockIcon == 1, let image = NSImage(named: "AppIconClassic") {
                appDockTile.contentView = NSImageView(image: image)
            } else {
                appDockTile.contentView = nil
            }
        }

        appDockTile.display()
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {

        ViewController.shared()?.restoreUserActivityState(userActivity)

        return true
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {

        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    public static func getEditTextViews() -> [EditTextView] {
        var views = getOpenedEditTextViews()

        if let controller = mainWindowController?.contentViewController as? ViewController {
            views.append(controller.editor)
        }

        return views
    }

    public static func getOpenedEditTextViews() -> [EditTextView] {
        var views = [EditTextView]()

        for window in noteWindows {
            if let controller = window.contentViewController as? NoteViewController {
                views.append(controller.editor)
            }
        }

        return views
    }
}
