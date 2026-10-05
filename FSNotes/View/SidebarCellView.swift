//
//  SidebarCellView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/7/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class SidebarCellView: NSTableCellView {
    @IBOutlet weak var icon: NSImageView!
    @IBOutlet weak var label: NSTextField!

    public var type: SidebarItemType?
    public var storage = Storage.shared()

    @IBAction func projectName(_ sender: NSTextField) {
        let cell = sender.superview as? SidebarCellView

        guard let project = cell?.objectValue as? Project else { return }
        
        if project.metadataFolderID != nil {
            do {
                try project.renameMetadataFolder(to: sender.stringValue)
                ViewController.shared()?.sidebarOutlineView.reloadSidebar()
            } catch {
                sender.stringValue = project.label
                let alert = NSAlert()
                alert.messageText = error.localizedDescription
                alert.runModal()
            }
            return
        }
        let src = project.url
        let dst = project.url.deletingLastPathComponent().appendingPathComponent(sender.stringValue, isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                sender.stringValue = project.url.lastPathComponent
                return
            }

            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            sender.stringValue = project.url.lastPathComponent
            let alert = NSAlert()
            alert.messageText = error.localizedDescription
            alert.runModal()
        }
    }
}
