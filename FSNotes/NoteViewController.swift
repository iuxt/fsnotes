//
//  NoteViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 25.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

class NoteViewController: EditorViewController, NSWindowDelegate {

    @IBOutlet weak var shareButton: NSButton!

    @IBOutlet weak var titleLabel: TitleTextField!
    @IBOutlet weak var editor: EditTextView!
    @IBOutlet weak var editorScrollView: EditorScrollView!
    @IBOutlet weak var titleBarView: TitleBarView!

    @IBOutlet weak var nonSelectedLabel: NSTextField!

    public func initWindow() {
        view.window?.title = "New note"
        view.window?.titleVisibility = .hidden
        view.window?.titlebarAppearsTransparent = true
        view.window?.backgroundColor = NSColor(named: "background_win")
        view.window?.delegate = self
        view.window?.setFrameOriginToPositionWindowInCenterOfScreen()

        editor.initTextStorage()
        editor.editorViewController = self
        editor.configure()

        vcEditor = editor
        vcTitleLabel = titleLabel
        vcNonSelectedLabel = nonSelectedLabel
        vcEditorScrollView = editorScrollView

        editor.updateTextContainerInset()

        super.initView()
    }

    func windowDidResize(_ notification: Notification) {
        editor.updateTextContainerInset()

        super.viewDidResize()
    }

    func windowWillClose(_ notification: Notification) {
        if editor.tagsTimer?.isValid == true {
            editor.scanTags()
        }
        // Scheduled timers retain their targets until invalidated.
        stopEditorTimers()
        editor.markdownView?.webView.stopLoading()
        editor.markdownView?.webView.removeFromSuperview()
        editor.markdownView?.removeFromSuperview()
        editor.markdownView = nil
        AppDelegate.noteWindows.removeAll(where: { $0.contentViewController === self })
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let cell = window.firstResponder as? TableCellTextView {
            return cell.tableView?.owner?.editorViewController?.editorUndoManager
        }
        if let fr = window.firstResponder,
            fr.isKind(of: EditTextView.self),
            editor.isEditable {
            return editor.editorViewController?.editorUndoManager
        }

        return nil
    }
}
