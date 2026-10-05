//
//  NameTextField.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 10/9/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class NameTextField: NSTextField, NSTextFieldDelegate {
    private var renameCompletion: ((String?) -> Void)?
    private var displayName = ""
    private var displayTextColor: NSColor?
    private weak var restoreResponder: NSResponder?

    var isRenaming: Bool { renameCompletion != nil }

    func beginRenaming(name: String, restoringFocusTo responder: NSResponder, completion: @escaping (String?) -> Void) {
        guard !isRenaming else { return }

        displayName = stringValue
        displayTextColor = textColor
        restoreResponder = responder
        renameCompletion = completion
        delegate = self
        stringValue = name
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor

        window?.makeFirstResponder(self)
        guard let editor = currentEditor() else {
            cancelRenaming()
            return
        }
        editor.selectedRange = NSRange(location: 0, length: name.utf16.count)
    }

    func cancelRenaming() {
        finishRenaming(with: nil)
    }

    private func finishRenaming(with value: String?) {
        guard let completion = renameCompletion else { return }
        let shouldRestoreFocus = currentEditor().map { window?.firstResponder === $0 } ?? false
        renameCompletion = nil
        abortEditing()
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textColor = displayTextColor
        stringValue = displayName
        if shouldRestoreFocus {
            window?.makeFirstResponder(restoreResponder)
        }
        completion(value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishRenaming(with: stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRenaming()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            finishRenaming(with: textView.string)
        default:
            return false
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let status = super.becomeFirstResponder()

        self.textColor = isRenaming ? .textColor : NSColor.init(named: "mainText")

        return status
    }
}
