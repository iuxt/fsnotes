import Cocoa

/// Captures the production TextKit renderer and native cell editor in both appearances.
@main struct Visual {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FSNOTES_VISUAL_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = """
        # 季度计划

        让记录更清晰，也让每一次编辑更从容。

        ## 本周重点

        我们关注 **内容的节奏**，保留必要的留白。更多细节可以查看 [项目文档](https://example.com)。

        | 项目 | 状态 | 下一步 |
        | :--- | :--- | :--- |
        | 编辑体验 | **进行中** | 细化输入与切换 |
        | 阅读排版 | 已完成 | 整理内容层次 |
        | 交互细节 | 待评审 | 收集反馈 |

        > 好的工具让人专注于内容。让复杂的事情保持清晰，给思考留一点空间。

        ## 记录与行动

        - [x] 整理本周记录
        - [ ] 和团队确认下一步
        - 持续收集反馈，逐步完善体验

        使用 `draft.save()` 保存这次修改。

        ```swift
        let draft = document.current
        draft.save()
        ```

        下周继续，保持简单。
        """
        let storage = NSTextStorage(string: source, attributes: [.font: UserDefaultsManagement.noteFont])
        let manager = LayoutManager()
        manager.delegate = manager
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 656, height: 1000), textContainer: container)
        editor.textContainerInset = NSSize(width: 28, height: 28)
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.isEditable = true
        editor.processor = TextStorageProcessor()
        editor.processor.editor = editor
        manager.processor = editor.processor
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        let plan = MarkdownPresentation.parse(source)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
                plan.applyStyles(to: storage, in: NSRange(location: 0, length: storage.length),
                    font: UserDefaultsManagement.noteFont, codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    textColor: .labelColor)
            }
            window.makeFirstResponder(nil)
            editor.refreshInlineTables()
            editor.updateTableEditors()
            manager.ensureLayout(for: container)
            editor.frame.size.height = manager.usedRect(for: container).height + 56
            func capture(_ stage: String) throws {
                RunLoop.current.run(until: Date().addingTimeInterval(0.22))
                editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                    editor.displayIfNeeded()
                }
                let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)!
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(stage)-\(name).png"))
            }
            try capture("reading")
            let table = editor.tableEditorViews.values.first!
            table.beginEditing(row: 1, column: 1)
            try capture("editing")
            table.finishEditing(returnToEditor: false)
        }
        print("Markdown editor previews: \(output.path)")
    }
}
