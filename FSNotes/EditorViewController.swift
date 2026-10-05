//
//  EditorViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 26.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit
import WebKit
import UserNotifications

class EditorViewController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {

    public var alert: NSAlert?
    public var noteLoading: ProgressState = .none

    public var vcEditor: EditTextView?
    public var vcTitleLabel: TitleTextField?
    public var vcNonSelectedLabel: NSTextField?

    public var vcPreviewButton: NSButton?
    public var vcShareButton: NSButton?
    public var vcEditorScrollView: EditorScrollView?

    public var previewResizeTimer = Timer()
    public var rowUpdaterTimer = Timer()
    public var editorUndoManager = UndoManager()

    public var breakUndoTimer = Timer()

    // git
    public var snapshotsTimer = Timer()
    public var lastSnapshot: Int?
    public var pullTimer = Timer()

    public var encCompletionHandler: ((String) -> Void)?

    public func initView() {
        guard let editor = vcEditor else { return }
        editor.delegate = self

        initScrollObserver()

        editor.isGrammarCheckingEnabled = UserDefaultsManagement.grammarChecking
        editor.isContinuousSpellCheckingEnabled = UserDefaultsManagement.continuousSpellChecking
        editor.smartInsertDeleteEnabled = UserDefaultsManagement.smartInsertDelete
        editor.isAutomaticSpellingCorrectionEnabled = UserDefaultsManagement.automaticSpellingCorrection
        editor.isAutomaticQuoteSubstitutionEnabled = UserDefaultsManagement.automaticQuoteSubstitution
        editor.isAutomaticDataDetectionEnabled = UserDefaultsManagement.automaticDataDetection
        editor.isAutomaticLinkDetectionEnabled = UserDefaultsManagement.automaticLinkDetection
        editor.isAutomaticTextReplacementEnabled = UserDefaultsManagement.automaticTextReplacement
        editor.isAutomaticDashSubstitutionEnabled = UserDefaultsManagement.automaticDashSubstitution
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let vc = ViewController.shared() else { return false}

        // Current note
        var note = vc.editor.note

        if note == nil {
            note = vc.getSelectedNotes()?.first
        }

        let ident = menuItem.identifier?.rawValue

        if let title = menuItem.menu?.identifier?.rawValue {
            switch title {
            case "fileMenu":
                return vc.processFileMenuItems(menuItem, menuId: title)
            case "shareMenu":
                return vc.processShareMenuItems(menuItem, menuId: title)
            case "folderMenu":
                return vc.processLibraryMenuItems(menuItem, menuId: title)
            case "findMenu":
                guard let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
                      evc.vcEditor?.note != nil else { return false }

                if evc.vcEditor?.markdownView == nil {
                    if ["findMenu.find",
                        "findMenu.findAndReplace",
                        "findMenu.next",
                        "findMenu.prev",
                        "findMenu.selectionToFind"
                    ].contains(menuItem.identifier?.rawValue) {
                        return true
                    }
                } else {
                    if ["findMenu.find",
                        "findMenu.next",
                        "findMenu.prev",
                        "findMenu.selectionToFind"
                    ].contains(menuItem.identifier?.rawValue) {
                        return true
                    }
                }

                return false
            case "viewSortBy":
                let iconName = UserDefaultsManagement.sortDirection ? "arrow.down" : "arrow.up"

                switch menuItem.tag {
                case 1:
                    if UserDefaultsManagement.sort == .modificationDate {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                case 2:
                    if UserDefaultsManagement.sort == .creationDate {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                case 3:
                    if UserDefaultsManagement.sort == .title {
                        if #available(macOS 11.0, *) {
                            menuItem.image = NSImage.init(systemSymbolName: iconName, accessibilityDescription: nil)
                            menuItem.state = .off
                        } else {
                            menuItem.state = .on
                            menuItem.image = NSImage()
                        }
                    } else {
                        menuItem.state = .off
                        menuItem.image = NSImage()
                    }
                default:
                    break
                }
            case "showInSidebar":
                switch menuItem.tag {
                case 1:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityInbox ? .on : .off
                case 2:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityNotes ? .on : .off
                case 3:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityTodo ? .on : .off
                case 5:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityTrash ? .on : .off
                case 6:
                    menuItem.state = UserDefaultsManagement.sidebarVisibilityUntagged ? .on : .off
                default:
                    break
                }
            case "viewMenu":

                switch ident {
                case "previewMathJax":
                    menuItem.state = UserDefaultsManagement.mathJaxPreview ? .on : .off
                    break

                case "viewMenu.historyBack":
                    if vc.notesTableView.historyPosition == 0 {
                        return false
                    }
                    break

                case "viewMenu.historyForward":
                    if vc.notesTableView.historyPosition == vc.notesTableView.history.count - 1 {
                        return false
                    }
                    break

                case "view.toggleNoteList":
                    menuItem.title = vc.isVisibleNoteList()
                    ? NSLocalizedString("Hide Note List", comment: "")
                    : NSLocalizedString("Show Note List", comment: "")
                    break

                case "view.toggleSidebar":
                    menuItem.title = vc.isVisibleSidebar()
                    ? NSLocalizedString("Hide Sidebar", comment: "")
                    : NSLocalizedString("Show Sidebar", comment: "")
                    break

                case "viewMenu.actualSize":
                    return UserDefaultsManagement.fontSize != UserDefaultsManagement.DefaultFontSize

                default:
                    break
                }

            default:
                break
            }
        }

        return true
    }

    public func getSelectedNotes() -> [Note]? {
        // Opened window
        if NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true,
           let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
           let note = evc.vcEditor?.note {
            return [note]
        }

        // Active main window
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self),
           let vc = ViewController.shared(),
           let selected = vc.notesTableView.getSelectedNotes() {
            return selected
        }

        return nil
    }

    public func getSelectedNote() -> Note? {
        // Opened window
        if NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true,
           let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
           let note = evc.vcEditor?.note {
            return note
        }

        // Active main window
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self),
           let vc = ViewController.shared(),
           let selected = vc.notesTableView.getSelectedNotes()?.first {

            return selected
        }

        return nil
    }

    private func isFirstResponder(responder: AnyClass) -> Bool {
        return view.window?.firstResponder?.isKind(of: responder) == true
    }

    private func isOpenedInNewWindow() -> Bool {
        return NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true
    }

    // MARK: Window bar actions

    @IBAction func textFinder(_ sender: NSMenuItem) {
        guard let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
              evc.vcEditor?.note != nil
        else { return }

        if let mView = evc.vcEditor?.markdownView {
            mView.performTextFinderAction(sender)
            return
        }

        if let editView = evc.vcEditor {
            editView.performFindPanelAction(sender)
        }
    }

    @IBAction func fsRevealItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }

        if isFirstResponder(responder: SidebarOutlineView.self) {
            vc.sidebarOutlineView.revealInFinder(sender)
            return
        }

        if isFirstResponder(responder: NotesTableView.self) ||
            isFirstResponder(responder: EditTextView.self) ||
            isOpenedInNewWindow() {
            vc.finderMenu(sender)
            return
        }
    }

    @IBAction func fsRenameItem(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }

        if isFirstResponder(responder: SidebarOutlineView.self) || isOpenedInNewWindow() {
            vc.sidebarOutlineView.renameFolderMenu(sender)
            return
        }

        if isFirstResponder(responder: NotesTableView.self) ||
            isFirstResponder(responder: EditTextView.self) {
            vc.renameMenu(sender)
            return
        }
    }

    @IBAction func openProjectViewSettings(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else {
            return
        }

        if let controller = vc.storyboard?.instantiateController(withIdentifier: "ProjectSettingsViewController")
            as? ProjectSettingsViewController {
            vc.projectSettingsViewController = controller

            if let project = vc.sidebarOutlineView.getSelectedProject() {
                vc.presentAsSheet(controller)
                controller.load(project: project)
            }
        }
    }

    @IBAction func createFolder(_ sender: Any) {
        guard let vc = ViewController.shared(),
              let sidebarOutlineView = vc.sidebarOutlineView else { return }

        // Call from menu bar
        if let sender = sender as? NSMenuItem, sender.identifier?.rawValue == "fileMenu.attach" {
            sidebarOutlineView.addRoot()
            return
        }

        // Call from popup menu or menu bar
        var project = sidebarOutlineView.getSelectedProject()

        if project == nil || project?.isVirtual == true || !isFirstResponder(responder: SidebarOutlineView.self) {
            project = Storage.shared().getDefault()
        }

        guard let project = project, let window = MainWindowController.shared() else { return }

        let alert = NSAlert()
        vc.alert = alert

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 20))
        alert.messageText = NSLocalizedString("New project", comment: "")
        alert.informativeText = NSLocalizedString("Please enter project name:", comment: "")
        alert.accessoryView = field
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Add", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
            if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                let name = field.stringValue
                guard name.count > 0 else { return }

                OperationQueue.main.addOperation {
                    _ = vc.sidebarOutlineView.createProject(in: project, with: name)
                }
            }

            NSApp.mainWindow?.makeFirstResponder(sidebarOutlineView)
            vc.alert = nil
        }

        field.becomeFirstResponder()
    }

    @IBAction func togglePreview(_ sender: Any) {
        guard let editor = vcEditor else { return }

        let firstResp = view.window?.firstResponder

        editor.togglePreviewState()

        if (editor.isPreviewEnabled()) {

            //Preview mode doesn't support text search
            cancelTextSearch()
            refillEditArea(force: true)

            if let mdView = vcEditor?.editorViewController?.vcEditor?.markdownView {
                view.window?.makeFirstResponder(mdView)
            }
        } else {
            disablePreview()
        }

        if let responder = firstResp, (
            ViewController.shared()?.search.currentEditor() == firstResp
            || responder.isKind(of: NotesTableView.self)
            || responder.isKind(of: SidebarOutlineView.self)
        ) {
            view.window?.makeFirstResponder(firstResp)
        } else {
            var responder: NSResponder? = vcEditor

            if vcEditor?.isPreviewEnabled() == true, let mView = vcEditor?.markdownView {
                responder = mView
            }

            if let responder = responder {
                view.window?.makeFirstResponder(responder)
            }
        }

        vcEditor?.userActivity?.needsSave = true

        editor.note?.project.saveNotesPreview()
    }

    @IBAction func toggleMathJax(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on

        UserDefaultsManagement.mathJaxPreview = sender.state == .on

        refillEditArea(force: true)
    }

    @IBAction func shareSheet(_ sender: NSButton) {
        if let note = vcEditor?.note {
            let sharingPicker = NSSharingServicePicker(items: [
                note.content,
                note.url
            ])
            sharingPicker.delegate = self
            sharingPicker.show(relativeTo: NSZeroRect, of: sender, preferredEdge: .minY)
        }
    }

    // MARK: File menu

    @IBAction func printNotes(_ sender: NSMenuItem) {
        guard let notes = getSelectedNotes(), let note = notes.first else { return }

        if note.isMarkdown() {
            printMarkdownPreview()
            return
        }

        let pv = NSTextView(frame: NSMakeRect(0, 0, 528, 688))
        pv.textStorage?.append(note.content)

        let printInfo = NSPrintInfo.shared
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.scalingFactor = 1
        printInfo.topMargin = 40
        printInfo.leftMargin = 40
        printInfo.rightMargin = 40
        printInfo.bottomMargin = 40

        let operation: NSPrintOperation = NSPrintOperation(view: pv, printInfo: printInfo)
        operation.printPanel.options.insert(NSPrintPanel.Options.showsPaperSize)
        operation.printPanel.options.insert(NSPrintPanel.Options.showsOrientation)
        operation.run()
    }

    @IBAction func finderMenu(_ sender: NSMenuItem) {
        guard let notes = getSelectedNotes() else { return }

        var urls = [URL]()
        for note in notes {
            urls.append(note.url)
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @IBAction func pinMenu(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }

        ViewController.shared()?.pin(selectedNotes: notes, toggle: true)
    }

    @IBAction func editorMenu(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }

        ViewController.shared()?.external(selectedNotes: notes)
    }

    @IBAction func copyURL(_ sender: Any) {
        guard let note = getSelectedNotes()?.first else { return }

        if let title = note.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {

            let identifier = note.metadataEntry?.id ?? title
            let name = "fsnotes://find?id=\(identifier)"
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(name, forType: NSPasteboard.PasteboardType.string)

            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }

                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                ) { _, _ in }
            }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("URL has been copied to clipboard", comment: "")
            content.body = name
            content.sound = .default

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    @IBAction func copyTitle(_ sender: Any) {
        guard let note = getSelectedNotes()?.first else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
        pasteboard.setString(note.title, forType: NSPasteboard.PasteboardType.string)
    }

    @IBAction func changeCreationDate(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }
        guard let note = notes.first else { return }
        guard let creationDate = note.getFileCreationDate() else { return }
        guard let window = view.window else { return }

        alert = NSAlert()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 20))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.string(from: creationDate)

        field.stringValue = date
        field.placeholderString = "2020-08-28 21:59:07"

        alert?.messageText = NSLocalizedString("Change Creation Date", comment: "Menu") + ":"
        alert?.accessoryView = field
        alert?.alertStyle = .informational
        alert?.addButton(withTitle: "OK")
        alert?.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
            if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                for note in notes {
                    if note.setCreationDate(string: field.stringValue) {
                        ViewController.shared()?.notesTableView.reloadRow(note: note)
                    }
                }
            }

            self.alert = nil
        }

        field.becomeFirstResponder()
    }

    @IBAction func createInNewWindow(_ sender: Any) {
        var content = String()

        if let inlineTags = ViewController.shared()?.sidebarOutlineView.getSelectedInlineTags() {
            content = inlineTags
        }

        if let note = createNote(content: content, openInNewWindow: true) {
            openInNewWindow(note: note)
        }
    }

    @IBAction func quickNote(_ sender: Any) {
        if let note = createNote(content: "", openInNewWindow: true) {
            NSApp.activate(ignoringOtherApps: true)

            if !NSApp.isActive {
                AppDelegate.mainWindowController?.window?.miniaturize(self)
            }

            openInNewWindow(note: note)
        }
    }

    @IBAction func historyMenu(_ sender: Any) {
        guard let note = getSelectedNotes()?.first else { return }
        openHistory(for: note)
    }

    @IBAction func duplicate(_ sender: Any) {
        guard let notes = getSelectedNotes() else { return }

        for note in notes {
            if note.metadataStore != nil {
                do {
                    let destination = try Storage.shared().importMetadataFile(note.url, to: note.project, name: note.fileName + " Copy")
                    if let copied = Storage.shared().getBy(url: destination) {
                        ViewController.shared()?.notesTableView.insertRows(notes: [copied])
                    }
                } catch { NSLog("%@", error.localizedDescription) }
                continue
            }
            let dst = NameHelper.generateCopy(file: note.url)

            let name = dst.deletingPathExtension().lastPathComponent
            let noteDupe = Note(name: name, project: note.project, type: note.type)
            noteDupe.content = NSMutableAttributedString(string: note.content.string)

            // Clone images
            if note.type == .Markdown {
                let images = note.content.getImagesAndFiles()
                for image in images {
                    noteDupe.move(from: image.url, imagePath: image.path, to: note.project, copy: true)
                }
            }

            if noteDupe.save() {
                Storage.shared().add(noteDupe)
            }

            ViewController.shared()?.notesTableView.insertRows(notes: [noteDupe])
        }
    }

    @IBAction func importNote(_ sender: NSMenuItem) {
        guard let vc = ViewController.shared() else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.begin { (result) -> Void in
            if result == NSApplication.ModalResponse.OK {
                let urls = panel.urls

                if let project = vc.sidebarOutlineView.getSelectedProject() ?? Storage.shared().getDefault() {
                    for url in urls {
                        _ = vc.copy(project: project, url: url)
                    }
                }
            }
        }
    }

    @objc func moveNote(_ sender: NSMenuItem) {
        let project = sender.representedObject as! Project

        guard let notes = getSelectedNotes() else { return }

        ViewController.shared()?.moveReq(notes: notes, project: project) { success in
            guard success else { return }

            if let cvc = NSApplication.shared.keyWindow?.contentViewController,
               cvc.isKind(of: NoteViewController.self) {
                self.updateTitle(note: notes.first!)
            }
        }
    }

    @IBAction func openWindow(_ sender: Any) {
        guard let currentNote = ViewController.shared()?.notesTableView.getSelectedNote() else { return }

        openInNewWindow(note: currentNote)
    }

    @IBAction func moveMenu(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }

        // Move menu right from notes table view

        if let cvc = NSApplication.shared.keyWindow?.contentViewController, cvc.isKind(of: ViewController.self) {
            if vc.notesTableView.selectedRow >= 0 {
                vc.loadMoveMenu()

                let moveTitle = NSLocalizedString("Move", comment: "Menu")
                let moveMenu = vc.noteMenu.item(withTitle: moveTitle)
                let view = vc.notesTableView.rect(ofRow: vc.notesTableView.selectedRow)
                let x = vc.splitView.subviews[0].frame.width + 5
                let general = moveMenu?.submenu?.item(at: 0)

                moveMenu?.submenu?.popUp(positioning: general, at: NSPoint(x: x, y: view.origin.y + 8), in: vc.notesTableView)
            }

            return

        // Move menu right from window

        } else {
            vc.loadMoveMenu()

            let moveTitle = NSLocalizedString("Move", comment: "Menu")
            let moveMenu = vc.noteMenu.item(withTitle: moveTitle)
            let general = moveMenu?.submenu?.item(at: 0)

            moveMenu?.submenu?.popUp(positioning: general, at: NSPoint(x: view.frame.width + 10, y: view.frame.height - 5), in: view)
        }
    }

    public func removeNotes(notes: [Note], rows: IndexSet? = nil) {
        guard let vc = ViewController.shared() else { return }

        let notes = notes.filter { !$0.isTrash() }
        guard !notes.isEmpty else { return }

        let currentNote = vc.editor.note
        let shouldClearEditor = currentNote != nil && notes.contains(where: { $0 === currentNote })
        UserDataService.instance.searchTrigger = true
        vc.storage.removeNotes(notes: notes) { urlMapping in
            guard let urlMapping = urlMapping else {
                UserDataService.instance.searchTrigger = false
                return
            }
            let trashedNotes = notes.filter { urlMapping[$0.url] != nil }
            vc.notesTableView.removeRows(notes: trashedNotes)
            for note in trashedNotes {
                vc.deleteAPI(note: note)
                let tags = note.tags
                note.tags.removeAll()
                vc.sidebarOutlineView.removeTags(tags)
            }
            if let md = AppDelegate.mainWindowController {
                let undoManager = md.notesListUndoManager
                if let ntv = vc.notesTableView {
                    // Register undo (restore)
                    undoManager.registerUndo(withTarget: ntv, selector: #selector(ntv.unDelete), object: urlMapping)
                    undoManager.setActionName(NSLocalizedString("Delete", comment: ""))
                }

                if let rows = rows, let minRow = rows.min(), minRow > -1 {
                    let qty = vc.notesTableView.countNotes()
                    if qty > minRow {
                        vc.notesTableView.selectRow(minRow)
                    } else {
                        vc.notesTableView.selectRow(qty - 1)
                    }
                }
            }
            UserDataService.instance.searchTrigger = false

            if shouldClearEditor && trashedNotes.contains(where: { $0 === currentNote }) {
                vc.editor.clear()
            }
        }

        // Call from window, close it!
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: NoteViewController.self) {
            DispatchQueue.main.async {
                self.view.window?.close()
            }
            return
        }

        // If is main window – focus to notes list
        if let cvc = NSApplication.shared.keyWindow?.contentViewController,
           cvc.isKind(of: ViewController.self) {
            NSApp.mainWindow?.makeFirstResponder(vc.notesTableView)
        }
    }

    @IBAction func actualSize(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: CGFloat(UserDefaultsManagement.DefaultFontSize))!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: CGFloat(UserDefaultsManagement.DefaultFontSize))!

        ViewController.shared()?.reloadFonts()
    }

    @IBAction func zoomIn(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: UserDefaultsManagement.codeFont.pointSize + 1)!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: UserDefaultsManagement.noteFont.pointSize + 1)!

        ViewController.shared()?.reloadFonts()
    }

    @IBAction func zoomOut(_ sender: Any) {
        UserDefaultsManagement.codeFont = NSFont(descriptor: UserDefaultsManagement.codeFont.fontDescriptor, size: UserDefaultsManagement.codeFont.pointSize - 1)!
        UserDefaultsManagement.noteFont = NSFont(descriptor: UserDefaultsManagement.noteFont.fontDescriptor, size: UserDefaultsManagement.noteFont.pointSize - 1)!

        ViewController.shared()?.reloadFonts()
    }

    @IBAction func showBackLinks(_ sender: NSMenuItem) {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
            let cvc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
            let note = cvc.vcEditor?.note {
            ViewController.shared()?.editor.clear()
            appDelegate.search(query: "[[" + note.title + "]]")
        }
    }

    // MARK: Dep methods

    public func openInNewWindow(note: Note, frame: NSRect? = nil, preview: Bool = false) {
        guard let windowController = NSStoryboard(name: "Main", bundle: nil)
            .instantiateController(withIdentifier: "noteWindowController") as? NSWindowController else { return }

        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(windowController)

        let viewController = windowController.contentViewController as! NoteViewController
        viewController.initWindow()

        viewController.editor.changePreviewState(preview)
        viewController.editor.fill(note: note)

        AppDelegate.noteWindows.insert(windowController, at: 0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let frame = frame {
                windowController.window?.setFrame(frame, display: true)
            }

            viewController.view.window?.makeFirstResponder(viewController.editor)
        }
    }

    func cancelTextSearch() {
        let menu = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.tag = NSTextFinder.Action.hideFindInterface.rawValue
        vcEditor?.performTextFinderAction(menu)
    }

    func disablePreview() {
        guard let textView = self.vcEditor else { return }

        textView.disablePreviewEditorAndNote()

        textView.markdownView?.getScrollPosition { point in
            self.vcEditor?.note?.contentOffsetWeb = point
        }

        textView.markdownView?.removeFromSuperview()
        textView.markdownView = nil

        textView.subviews.removeAll(where: { $0.isKind(of: MPreviewView.self) })

        refillEditArea()
    }

    public func viewDidResize() {
        guard vcEditor?.isPreviewEnabled() == true else { return }

        if noteLoading != .incomplete {
            previewResizeTimer.invalidate()
            previewResizeTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(reloadPreview), userInfo: nil, repeats: false)
        }
    }

    @objc private func reloadPreview() {
        DispatchQueue.main.async {
            MPreviewView.template = nil
            self.refillEditArea(force: true)
        }
    }

    public func updateTitle(note: Note) {
        guard let vcTitleLabel = vcTitleLabel else { return }

        var titleString = note.getFileName()

        if titleString.isValidUUID {
            titleString = String()
        }

        if titleString.count > 0 {
            vcTitleLabel.stringValue = note.project.getNestedLabel() + " › " + titleString
        } else {
            vcTitleLabel.stringValue = note.project.getNestedLabel()
        }

        vcTitleLabel.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)

        view.window?.title = vcTitleLabel.stringValue
    }

    func refillEditArea(force: Bool = false) {
        noteLoading = .incomplete
        vcPreviewButton?.state = vcEditor?.isPreviewEnabled() == true ? .on : .off

        if let note = vcEditor?.note {
            vcEditor?.fill(note: note, force: force)
        }

        noteLoading = .done
    }

    public func reloadAllOpenedWindows(note: Note) {
        let editors = AppDelegate.getEditTextViews()

        for editor in editors {
            if editor.note == note {
                editor.editorViewController?.refillEditArea(force: true)

                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    public func closeAllOpenedWindows(where note: Note) {
        for editor in AppDelegate.getOpenedEditTextViews() {
            if editor.note == note {
                editor.window?.close()
            }
        }
    }

    public func removeTags(note: Note) {
        let tags = note.tags
        note.tags = []
        ViewController.shared()?.sidebarOutlineView?.removeTags(tags)
    }

    public func dropTitle() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FSNotes"

        vcTitleLabel?.stringValue = appName
        view.window?.title = appName
    }

    func focusEditArea() {
        guard let editor = vcEditor,
              editor.note != nil,
              !editor.isPreviewEnabled() else { return }

        editor.window?.makeFirstResponder(editor)

        if let ntv = ViewController.shared()?.notesTableView, ntv.selectedRow > -1 {
            vcEditor?.isEditable = true
            vcNonSelectedLabel?.isHidden = true
        }
    }

    // Changed main edit view
    func textDidChange(_ notification: Notification) {
        guard let editor = vcEditor,
              let note = editor.note,
              let vc = ViewController.shared() else { return }

        if editor.isEditable {
            note.isBlocked = true

            editor.textStorage?.removeHighlight()
            note.save(attributed: editor.attributedString())

            updateLastEditedStatus()
            vc.reSort(note: note)
        }

        breakUndoTimer.invalidate()
        breakUndoTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(breakUndo), userInfo: nil, repeats: true)
    }

    private func updateLastEditedStatus() {
        let editors = AppDelegate.getEditTextViews()

        for editor in editors {
            editor.isLastEdited = false
        }

        vcEditor?.isLastEdited = true
    }

    @objc func breakUndo() {
        guard let editor = vcEditor else { return }

        if (
            editor.isPreviewEnabled() == false
           && editor.isEditable
        ) {
            editor.breakUndoCoalescing()
        }
    }

    public func createNote(name: String = "", content: String = "", folderName: String? = nil, openInNewWindow: Bool = false) -> Note? {
        guard let vc = ViewController.shared() else { return nil }

        var text = String()
        var project: Project?

        if let folderName = folderName {
            project = vc.sidebarOutlineView.getOrCreateProject(name: folderName)

        }

        let selectedProjects = vc.sidebarOutlineView.getSidebarProjects()
        var sidebarProject = project ?? selectedProjects?.first

        if sidebarProject == nil {
            sidebarProject = Storage.shared().getDefault()
        }

        guard let project = sidebarProject else { return nil }

        if !name.isEmpty, [.autoRename, .autoRenameNew].contains(UserDefaultsManagement.naming) && UserDefaultsManagement.autoInsertHeader {
            text.append("# " + name + "\n\n")
        }

        if !content.isEmpty {
            text.append(content)
        }

        let inlineTags = vc.sidebarOutlineView.getSelectedInlineTags()
        if !inlineTags.isEmpty {
            text.append(inlineTags)
        }

        if let type = vc.getSidebarType(), type == .Todo, content.count == 0 {
            text = "- [ ] "
        }

        let note = Note(name: name, project: project)
        note.content = NSMutableAttributedString(string: text)
        if note.save() {
            Storage.shared().add(note)
        }

        _ = note.scanContentTags()

        if folderName == nil, let selectedProjects = selectedProjects, !selectedProjects.contains(project) {
            return note
        }

        if !openInNewWindow {
            disablePreview()

            vc.notesTableView.deselectNotes()
            vc.storage.searchQuery.dropFilter()
            vc.editor.string = text
            vc.editor.note = note
            vc.search.stringValue.removeAll()
        }

        vc.updateTable() {
            if openInNewWindow {
                return
            }

            DispatchQueue.main.async {
                vc.notesTableView.saveNavigationHistory(note: note)
                if let index = vc.notesTableView.getIndex(for: note) {
                    vc.notesTableView.selectRowIndexes([index], byExtendingSelection: false)
                    vc.notesTableView.scrollRowToVisible(index)
                }

                vc.focusEditArea()

                NSApp.activate(ignoringOtherApps: true)
                self.view.window?.makeKeyAndOrderFront(self)
            }
        }

        return note
    }
}
