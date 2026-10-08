//
//  EditTextView+Todo.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

extension EditTextView {
    func clearCompletedTodos() {
        guard let textStorage = textStorage else { return }
        
        let text = textStorage.string as NSString
        
        undoManager?.beginUndoGrouping()
        
        var linesToRemove: [NSRange] = []
        for element in MarkdownPresentation.parse(textStorage.string).elements {
            if element.decoration == .text("☑") {
                let lineRange = text.lineRange(for: element.range)
                if !linesToRemove.contains(lineRange) { linesToRemove.append(lineRange) }
            }
        }
        
        for lineRange in linesToRemove.sorted(by: { $0.location > $1.location }) {
            if shouldChangeText(in: lineRange, replacementString: "") {
                textStorage.replaceCharacters(in: lineRange, with: "")
                didChangeText()
            }
        }
        
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Remove TODO Lines")
    }
}
