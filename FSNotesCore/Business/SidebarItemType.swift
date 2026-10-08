//
//  SidebarItemType.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/7/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

enum SidebarItemType: Int {
    case Label = 0x00
    case All = 0x01
    case Trash = 0x02    
    case Tag = 0x08
    case Project = 0x09
    case Header = 0x10
    case Untagged = 0x11
#if os(macOS)
    case Git = 0x12
#endif
    case Separator = 14

    public var icon: String? {
        switch self {
        case .Label: return nil
        case .All: return "sidebar_notes"
        case .Trash: return "sidebar_trash"
        case .Tag: return "sidebar_tag"
        case .Project: return "sidebar_project"
        case .Header: return "sidebar_icloud_drive"
        case .Untagged: return "sidebar_untagged"
#if os(macOS)
        case .Git: return nil
#endif
        case .Separator: return nil
        }
    }
}
