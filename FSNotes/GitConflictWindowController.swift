import Cocoa
import CryptoKit

private final class GitConflictBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class GitConflictWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private static var windows = [String: GitConflictWindowController]()
    private struct Draft: Codable {
        var choices: [GitConflictDocument.Choice?]
        var version: GitConflictDocument.Choice?
        var manualText: String?
        var placeholders: [String]?
        var confirmed = false
    }
    private struct Saved: Codable {
        let fingerprint: String
        let drafts: [Draft]
        let file: Int
        let block: Int
    }
    private struct Snapshot { let drafts: [Draft]; let file: Int; let block: Int }
    private let project: Project
    private let session: GitMergeSession
    private let resume: ([GitMergeSession.Resolution], @escaping (Error?) -> Void) -> Void
    private let dismiss: () -> Void
    private var drafts: [Draft]
    private var file = 0, block = 0
    private var history = [Snapshot]()
    private var busy = false, changingText = false, changingSelection = false, editingCheckpoint = false
    private var runningModal = false
    private var saveTimer: Timer?
    private let table = NSTableView()
    private let filename = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let fileStatus = NSTextField(labelWithString: "")
    private let conflictStatus = NSTextField(labelWithString: "")
    private let conflictPicker = NSSegmentedControl()
    private let conflictMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previous = NSButton(), next = NSButton()
    private let localPreview = NSTextView(), remotePreview = NSTextView(), result = NSTextView()
    private let localButton = NSButton(), remoteButton = NSButton(), bothButton = NSButton()
    private let resultStatus = NSTextField(labelWithString: "")
    private let manualNote = NSTextField(labelWithString: "")
    private let resetManual = NSButton()
    private let selectionStatus = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let confirm = NSButton(), finish = NSButton(), later = NSButton(), undoButton = NSButton()
    private let count = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator(), spinner = NSProgressIndicator()

    private static func localized(_ value: String) -> String { NSLocalizedString(value, comment: "Git conflicts") }
    private var identity: String { project.getRepositoryUrl().standardizedFileURL.path }

    static func reveal(project: Project) -> Bool {
        guard let controller = windows[project.getRepositoryUrl().standardizedFileURL.path] else { return false }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    static func open(project: Project, session: GitMergeSession,
                     resume: @escaping ([GitMergeSession.Resolution], @escaping (Error?) -> Void) -> Void,
                     dismiss: @escaping () -> Void) {
        if reveal(project: project) { return }
        let controller = GitConflictWindowController(project: project, session: session, resume: resume, dismiss: dismiss)
        windows[controller.identity] = controller
        project.gitMergePending = true
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(project: Project, session: GitMergeSession,
                 resume: @escaping ([GitMergeSession.Resolution], @escaping (Error?) -> Void) -> Void,
                 dismiss: @escaping () -> Void) {
        self.project = project; self.session = session; self.resume = resume; self.dismiss = dismiss
        drafts = session.files.map { Draft(choices: Array(repeating: nil, count: $0.document?.hunks.count ?? 0)) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Self.localized("Resolve sync conflicts")
        window.minSize = NSSize(width: 900, height: 760)
        window.isReleasedWhenClosed = false
        window.contentView = GitConflictBackgroundView(frame: window.contentView?.bounds ?? .zero)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("GitConflictWorkbench")
        buildInterface()
        loadDrafts()
        reloadFiles(selectCurrent: true)
        showFile()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: Self.localized(text))
        label.font = .systemFont(ofSize: size)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func button(_ button: NSButton, title: String, action: Selector, symbol: String? = nil) {
        button.title = Self.localized(title); button.target = self; button.action = action
        button.bezelStyle = .rounded; button.controlSize = .regular
        if let symbol = symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        button.setAccessibilityLabel(button.title)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal
        stack.alignment = .centerY; stack.spacing = spacing; stack.distribution = .fill
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = spacing; stack.distribution = .fill
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func configureText(_ text: NSTextView, editable: Bool) -> NSScrollView {
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.backgroundColor = .textBackgroundColor; text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        let scroll = NSScrollView(); scroll.documentView = text
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        return scroll
    }
    private func sourcePanel(title: String, subtitle: String, preview: NSTextView, button: NSButton) -> NSBox {
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.borderColor = .separatorColor; box.fillColor = .textBackgroundColor
        box.cornerRadius = 7; box.contentViewMargins = NSSize(width: 12, height: 10)
        let heading = label(title, size: 13); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = column([heading, label(subtitle, size: 11, secondary: true)], spacing: 3)
        let scroll = configureText(preview, editable: false)
        preview.setAccessibilityLabel(Self.localized(title))
        let stack = column([header, separator(), scroll, button], spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                         stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        for item in [header, scroll, button] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 75).isActive = true
        return box
    }
    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let bannerTitle = label("Some notes need your confirmation", size: 14)
        bannerTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let banner = row([column([bannerTitle, label("Choose the content to keep, then review the merged result.", secondary: true)], spacing: 3),
                          spacer(), label("Sync paused", secondary: true)])
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        let split = NSSplitViewController()
        split.splitView.autosaveName = "GitConflictWorkbenchSplit"
        let sidebar = NSViewController(); sidebar.view = NSVisualEffectView()
        (sidebar.view as? NSVisualEffectView)?.material = .sidebar
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.minimumThickness = 210; item.maximumThickness = 300; item.canCollapse = false
        split.addSplitViewItem(item)
        let detail = NSViewController(); detail.view = NSView()
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        let title = label("Conflicted files", size: 12, secondary: true)
        let branch = label(session.localBranch + " ← " + session.remoteBranch, size: 11, secondary: true)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.headerView = nil; table.rowHeight = 70; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self; table.style = .sourceList
        table.backgroundColor = .clear; table.setAccessibilityLabel(Self.localized("Conflicted files"))
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.autohidesScrollers = true; list.drawsBackground = false
        for view in [title, list, branch] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.view.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor, constant: 16), title.topAnchor.constraint(equalTo: sidebar.view.topAnchor, constant: 16),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12), list.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor), list.bottomAnchor.constraint(equalTo: branch.topAnchor, constant: -14),
            branch.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor, constant: 16), branch.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: -16),
            branch.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor, constant: -16)
        ])
        filename.font = .systemFont(ofSize: 17, weight: .semibold); filename.lineBreakMode = .byTruncatingMiddle
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileStatus.font = .systemFont(ofSize: 11); fileStatus.textColor = .systemOrange
        path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor; path.lineBreakMode = .byTruncatingMiddle
        let heading = column([row([filename, spacer(), fileStatus]), path], spacing: 4)
        button(previous, title: "", action: #selector(previousConflict), symbol: "chevron.up")
        button(next, title: "", action: #selector(nextConflict), symbol: "chevron.down")
        previous.setAccessibilityLabel(Self.localized("Previous conflict")); next.setAccessibilityLabel(Self.localized("Next conflict"))
        conflictStatus.font = .systemFont(ofSize: 12)
        conflictPicker.target = self; conflictPicker.action = #selector(selectConflict)
        conflictPicker.segmentStyle = .rounded; conflictPicker.trackingMode = .selectOne
        conflictPicker.setAccessibilityLabel(Self.localized("Select conflict"))
        conflictMenu.target = self; conflictMenu.action = #selector(selectConflictMenu)
        conflictMenu.setAccessibilityLabel(Self.localized("Select conflict"))
        conflictMenu.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let navigation = row([conflictStatus, conflictPicker, conflictMenu, spacer(), previous, next], spacing: 8)
        button(localButton, title: "Use local", action: #selector(useLocal))
        button(remoteButton, title: "Use remote", action: #selector(useRemote))
        button(bothButton, title: "Keep both", action: #selector(keepBoth), symbol: "arrow.triangle.merge")
        localButton.setButtonType(.pushOnPushOff); remoteButton.setButtonType(.pushOnPushOff)
        bothButton.setButtonType(.pushOnPushOff)
        let localSubtitle = session.localBranch + " · " + (session.includesLocalEdits ? Self.localized("Working copy") : String(session.localSHA.prefix(7)))
        let localBox = sourcePanel(title: "Local version", subtitle: localSubtitle, preview: localPreview, button: localButton)
        let remoteBox = sourcePanel(title: "Remote version", subtitle: session.remoteBranch + " · " + String(session.remoteSHA.prefix(7)), preview: remotePreview, button: remoteButton)
        let sources = row([localBox, remoteBox], spacing: 12); sources.distribution = .fillEqually
        sources.heightAnchor.constraint(equalToConstant: 200).isActive = true
        selectionStatus.font = .systemFont(ofSize: 11); selectionStatus.textColor = .secondaryLabelColor
        let choices = row([bothButton, spacer(), selectionStatus])
        let resultTitle = label("Merged result", size: 13); resultTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        resultStatus.font = .systemFont(ofSize: 11); resultStatus.textColor = .secondaryLabelColor
        let resultHeader = row([resultTitle, spacer(), resultStatus])
        let resultScroll = configureText(result, editable: true)
        resultScroll.borderType = .bezelBorder; resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        result.delegate = self; result.allowsUndo = true; result.setAccessibilityLabel(Self.localized("Edit merged result"))
        manualNote.font = .systemFont(ofSize: 11); manualNote.textColor = .secondaryLabelColor
        manualNote.lineBreakMode = .byTruncatingTail
        button(resetManual, title: "Restore version choices", action: #selector(restoreChoices))
        resetManual.controlSize = .small
        let manualRow = row([manualNote, spacer(), resetManual]); manualRow.identifier = NSUserInterfaceItemIdentifier("manualRow")
        message.font = .systemFont(ofSize: 11); message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail; message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button(confirm, title: "Mark resolved", action: #selector(confirmFile), symbol: "checkmark")
        let mark = row([message, spacer(), confirm])
        let main = column([heading, navigation, sources, choices, resultHeader, resultScroll, manualRow, mark], spacing: 8)
        main.translatesAutoresizingMaskIntoConstraints = false; detail.view.addSubview(main)
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 20), main.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -20),
                                     main.topAnchor.constraint(equalTo: detail.view.topAnchor, constant: 18), main.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor, constant: -16)])
        for view in main.arrangedSubviews { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
        let countStack = column([count, progress], spacing: 5)
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = Double(session.files.count)
        progress.widthAnchor.constraint(equalToConstant: 110).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        button(undoButton, title: "Undo last action", action: #selector(undoAction), symbol: "arrow.uturn.backward")
        button(later, title: "Resolve later", action: #selector(resolveLater))
        button(finish, title: "Continue sync", action: #selector(continueSync), symbol: "arrow.right")
        finish.keyEquivalent = "\r"
        let footer = row([countStack, spacer(), spinner, undoButton, later, finish])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        let topLine = separator(), bottomLine = separator()
        for view in [banner, topLine, split.view, bottomLine, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor), banner.leadingAnchor.constraint(equalTo: root.leadingAnchor), banner.trailingAnchor.constraint(equalTo: root.trailingAnchor), banner.heightAnchor.constraint(equalToConstant: 62),
            topLine.topAnchor.constraint(equalTo: banner.bottomAnchor), topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: topLine.bottomAnchor), split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.view.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor), bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor), bottomLine.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 60)
        ])
        // Retain the controller hierarchy for split-view resizing and persistence.
        let rootController = NSViewController()
        rootController.view = root; rootController.addChild(split)
        window?.contentViewController = rootController
    }

    private func displayName(_ item: GitMergeSession.File) -> String {
        let url = URL(fileURLWithPath: item.path)
        if item.path == "metadata.json" { return Self.localized("Library metadata") }
        if let entry = project.metadataStore?.entry(id: url.deletingPathExtension().lastPathComponent) {
            return entry.name + "." + entry.fileExtension
        }
        return url.lastPathComponent
    }
    private func resolution(for index: Int) -> GitMergeSession.Resolution? {
        let draft = drafts[index], item = session.files[index]
        if let document = item.document {
            if draft.manualText == nil && draft.choices.contains(where: { $0 == nil }) { return nil }
            let text = draft.manualText ?? document.render(choices: draft.choices)
            let pending = draft.placeholders?.contains(where: { text.contains($0) }) ?? false
            return GitConflictDocument.containsMarkers(text) || pending ? nil : .text(text)
        }
        switch draft.version { case .local: return .local; case .remote: return .remote; default: return nil }
    }
    private func resultText() -> String {
        let draft = drafts[file], item = session.files[file]
        if let document = item.document {
            return draft.manualText ?? document.render(choices: draft.choices, unresolvedPlaceholder: { Self.placeholder($0) + "\n" })
        }
        switch draft.version {
        case .local: return versionText(item.local)
        case .remote: return versionText(item.remote)
        default: return Self.localized("Choose the local or remote version to keep.")
        }
    }
    private static func placeholder(_ index: Int) -> String {
        String(format: localized("〔Conflict %d: choose the content to keep〕"), index + 1)
    }
    private func versionText(_ version: GitMergeSession.Version?) -> String {
        guard let version = version else { return Self.localized("File deleted in this version") }
        if let text = version.text { return text }
        return String(format: Self.localized("Binary file · %@ bytes\n%@"),
                      NumberFormatter.localizedString(from: NSNumber(value: version.data.count), number: .decimal), version.path)
    }
    private func preview(_ text: String, line: Int, other: String, color: NSColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let otherLines = Set(GitConflictDocument.lines(other))
        for (offset, item) in GitConflictDocument.lines(text).enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]
            if !otherLines.contains(item) { attributes[.backgroundColor] = color.withAlphaComponent(0.12) }
            output.append(NSAttributedString(string: "\(line + offset)  \(item)", attributes: attributes))
        }
        return output
    }
    private func showFile() {
        guard session.files.indices.contains(file) else { return }
        editingCheckpoint = false
        let item = session.files[file], hunks = item.document?.hunks ?? []
        block = min(block, max(0, hunks.count - 1))
        filename.stringValue = displayName(item); path.stringValue = item.path
        conflictPicker.segmentCount = min(hunks.count, 6); conflictPicker.isHidden = hunks.count < 2 || hunks.count > 6
        conflictMenu.isHidden = hunks.count <= 6
        conflictMenu.removeAllItems()
        if hunks.count > 6 { conflictMenu.addItems(withTitles: hunks.indices.map { "\($0 + 1) / \(hunks.count)" }); conflictMenu.selectItem(at: block) }
        for number in 0..<min(hunks.count, 6) { conflictPicker.setLabel("\(number + 1)", forSegment: number); conflictPicker.setWidth(30, forSegment: number) }
        if !hunks.isEmpty {
            if hunks.count <= 6 { conflictPicker.selectedSegment = block }
            let hunk = hunks[block]
            conflictStatus.stringValue = String(format: Self.localized("Conflict %d / %d · line %d"), block + 1, hunks.count, hunk.line)
            localPreview.textStorage?.setAttributedString(preview(hunk.local, line: hunk.line, other: hunk.remote, color: .systemBlue))
            remotePreview.textStorage?.setAttributedString(preview(hunk.remote, line: hunk.remoteLine, other: hunk.local, color: .systemGreen))
        } else {
            conflictStatus.stringValue = Self.localized("Whole-file conflict")
            localPreview.string = versionText(item.local); remotePreview.string = versionText(item.remote)
        }
        for text in [localPreview, remotePreview] { text.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        changingText = true; result.string = resultText(); changingText = false
        result.undoManager?.removeAllActions()
        updateActions()
    }
    private func updateActions() {
        let draft = drafts[file], item = session.files[file], hunks = item.document?.hunks ?? []
        let manual = draft.manualText != nil
        let locked = busy || draft.confirmed || session.completed
        let choice = !hunks.isEmpty ? draft.choices[block] : draft.version
        localButton.title = Self.localized(item.local == nil ? "Use local deletion" : "Use local")
        remoteButton.title = Self.localized(item.remote == nil ? "Use remote deletion" : "Use remote")
        localButton.isEnabled = !locked && !manual; remoteButton.isEnabled = !locked && !manual
        bothButton.isEnabled = !locked && !manual && !hunks.isEmpty
        localButton.state = !manual && choice == .local ? .on : .off
        remoteButton.state = !manual && choice == .remote ? .on : .off
        bothButton.state = !manual && choice == .both ? .on : .off
        result.isEditable = !locked && item.document != nil
        fileStatus.stringValue = Self.localized(draft.confirmed ? "Resolved" : manual || draft.choices.contains(where: { $0 != nil }) || draft.version != nil ? "In progress" : "Not started")
        fileStatus.textColor = draft.confirmed ? .systemGreen : .systemOrange
        previous.isEnabled = !busy && block > 0; next.isEnabled = !busy && block + 1 < hunks.count
        conflictPicker.isEnabled = !busy; conflictMenu.isEnabled = !busy; table.isEnabled = !busy
        confirm.title = Self.localized(draft.confirmed ? "Edit again" : "Mark resolved")
        confirm.isEnabled = !busy && !session.completed && (draft.confirmed || resolution(for: file) != nil)
        selectionStatus.stringValue = Self.localized(manual ? "Manually editing the whole file" : choice == .both ? "Both versions kept; review the result" : choice == .local ? "Local content selected" : choice == .remote ? "Remote content selected" : "Choose the content to keep")
        resultStatus.stringValue = Self.localized(draft.confirmed || session.completed ? "Confirmed · read only" : item.document == nil ? "Whole-file choice" : "Whole note · editable")
        manualNote.stringValue = Self.localized("Manual edits are preserved when switching files.")
        resetManual.isEnabled = !locked; resetManual.isHidden = !manual
        (resetManual.superview as? NSStackView)?.isHidden = !manual || locked
        let pending = draft.choices.filter { $0 == nil }.count
        message.stringValue = Self.localized(draft.confirmed ? "This file has been confirmed." : manual && resolution(for: file) == nil ? "Remove every conflict marker before confirming." : pending > 0 && !manual ? "Choose a version for every conflict." : "Review the result, then mark this file resolved.")
        let completed = drafts.filter { $0.confirmed }.count
        count.stringValue = String(format: Self.localized("Resolved %d / %d files"), completed, drafts.count)
        progress.doubleValue = Double(completed)
        finish.title = Self.localized(session.completed ? "Retry sync" : "Continue sync")
        finish.isEnabled = !busy && completed == drafts.count
        later.isEnabled = !busy; undoButton.isEnabled = !busy && !history.isEmpty && !session.completed
    }

    private func reloadFiles(selectCurrent: Bool = false) {
        changingSelection = true
        table.reloadData()
        if selectCurrent { table.selectRowIndexes(IndexSet(integer: file), byExtendingSelection: false) }
        changingSelection = false
    }
    private func checkpoint() {
        history.append(Snapshot(drafts: drafts, file: file, block: block))
        if history.count > 20 { history.removeFirst() }
    }
    private func choose(_ choice: GitConflictDocument.Choice) {
        guard !busy, !drafts[file].confirmed, drafts[file].manualText == nil else { return }
        checkpoint()
        if let document = session.files[file].document {
            if document.hunks.isEmpty { drafts[file].manualText = (choice == .remote ? session.files[file].remote : session.files[file].local)?.text }
            else { drafts[file].choices[block] = choice }
        } else { drafts[file].version = choice }
        showFile(); reloadFiles(); saveDrafts()
    }
    @objc private func useLocal() { choose(.local) }
    @objc private func useRemote() { choose(.remote) }
    @objc private func keepBoth() { choose(.both) }
    @objc private func previousConflict() { block -= 1; showFile(); saveDrafts() }
    @objc private func nextConflict() { block += 1; showFile(); saveDrafts() }
    @objc private func selectConflict() { guard conflictPicker.selectedSegment >= 0 else { return }; block = conflictPicker.selectedSegment; showFile(); saveDrafts() }
    @objc private func selectConflictMenu() { guard conflictMenu.indexOfSelectedItem >= 0 else { return }; block = conflictMenu.indexOfSelectedItem; showFile(); saveDrafts() }
    @objc private func restoreChoices() { checkpoint(); drafts[file].manualText = nil; drafts[file].placeholders = nil; showFile(); reloadFiles(); saveDrafts() }
    @objc private func undoAction() {
        guard let last = history.popLast() else { return }
        drafts = last.drafts; file = last.file; block = last.block
        reloadFiles(selectCurrent: true)
        showFile(); saveDrafts()
    }
    @objc private func confirmFile() {
        if drafts[file].confirmed { checkpoint(); drafts[file].confirmed = false; showFile(); reloadFiles(); saveDrafts(); return }
        guard let resolution = resolution(for: file) else { return }
        do { try session.validate(resolution, file: file) }
        catch { showError(error); return }
        checkpoint(); drafts[file].confirmed = true
        if let next = drafts.firstIndex(where: { !$0.confirmed }) { file = next; block = 0 }
        reloadFiles(selectCurrent: true)
        showFile(); saveDrafts()
    }
    @objc private func continueSync() {
        let resolutions = drafts.indices.compactMap { resolution(for: $0) }
        guard !busy, drafts.allSatisfy({ $0.confirmed }), resolutions.count == drafts.count else { return }
        busy = true; spinner.startAnimation(nil); updateActions(); saveDrafts()
        resume(resolutions) { [weak self] error in
            guard let self = self else { return }
            self.busy = false; self.spinner.stopAnimation(nil)
            if self.runningModal { NSApp.stopModal() }
            if let error = error { self.updateActions(); self.showError(error) }
            else { self.removeDrafts(); self.close() }
        }
        // Keep other note windows from starting new edits while the merged files
        // are installed and their cached editor contents are reloaded.
        if busy, let window = window {
            runningModal = true
            NSApp.runModal(for: window)
            runningModal = false
        }
    }
    @objc private func resolveLater() { saveDrafts(); close() }
    private func showError(_ error: Error) {
        guard let window = window else { return }
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = Self.localized("Unable to continue sync")
        alert.informativeText = (error as? GitError)?.associatedValue() ?? error.localizedDescription
        alert.beginSheetModal(for: window)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { session.files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = session.files[row], draft = drafts[row]
        let title = label(displayName(item), size: 13); title.font = .systemFont(ofSize: 13, weight: .medium)
        let state = Self.localized(draft.confirmed ? "Resolved" : draft.manualText != nil || draft.version != nil || draft.choices.contains(where: { $0 != nil }) ? "In progress" : "Not started")
        let status = label(state, size: 11, secondary: true)
        if draft.confirmed { status.textColor = .systemGreen }
        let view = column([title, status, label(item.path, size: 10, secondary: true)], spacing: 2)
        view.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 12)
        view.toolTip = item.path
        return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !busy, !changingSelection, table.selectedRow >= 0 else { return }
        file = table.selectedRow; block = 0; showFile(); saveDrafts()
    }
    func textDidChange(_ notification: Notification) {
        guard !changingText, !busy, !drafts[file].confirmed else { return }
        if !editingCheckpoint { checkpoint(); editingCheckpoint = true }
        if drafts[file].manualText == nil {
            drafts[file].placeholders = drafts[file].choices.indices.filter { drafts[file].choices[$0] == nil }.map(Self.placeholder)
        }
        drafts[file].manualText = result.string
        updateActions(); reloadFiles()
        saveTimer?.invalidate(); saveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.saveDrafts() }
    }
    func textDidEndEditing(_ notification: Notification) { editingCheckpoint = false; saveDrafts() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        saveTimer?.invalidate()
        if session.completed { removeDrafts() } else { saveDrafts() }
        project.gitMergePending = false
        Self.windows.removeValue(forKey: identity)
        dismiss()
    }

    private var draftURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let key = SHA256.hash(data: Data((identity + ":" + session.fingerprint).utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("FSNotes/MergeDrafts", isDirectory: true).appendingPathComponent(key + ".json")
    }
    private func saveDrafts() {
        guard !session.completed, let url = draftURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Saved(fingerprint: session.fingerprint, drafts: drafts, file: file, block: block))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message.stringValue = Self.localized("Unable to save the merge draft: ") + error.localizedDescription }
    }
    private func loadDrafts() {
        guard let url = draftURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.fingerprint == session.fingerprint,
              saved.drafts.count == drafts.count, saved.drafts.enumerated().allSatisfy({ $0.element.choices.count == drafts[$0.offset].choices.count }) else { return }
        drafts = saved.drafts
        file = drafts.indices.contains(saved.file) ? saved.file : 0; block = max(0, saved.block)
        for index in drafts.indices where drafts[index].confirmed {
            guard let choice = resolution(for: index), (try? session.validate(choice, file: index)) != nil else { drafts[index].confirmed = false; continue }
        }
    }
    private func removeDrafts() { if let url = draftURL { try? FileManager.default.removeItem(at: url) } }
}
