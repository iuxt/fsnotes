import Cocoa
import WebKit

/// A read-only browser. Restoring is delegated to the editor's existing restore flow.
final class NoteHistoryWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, WKNavigationDelegate {
    private static var windows = [ObjectIdentifier: NoteHistoryWindowController]()

    private struct Version {
        let commit: Commit
        let date: String
        let sha: String
        let summary: String
        let tooltip: String
    }
    private let note: Note
    private let restore: (Commit, NSWindow, @escaping (Bool) -> Void) -> Void
    private var versions = [Version]()
    private var visibleVersions = [Version]()
    private struct Snapshot {
        let text: String
        let size: Int
        let html: String
    }
    private var contentCache = [String: Snapshot]()
    private var selectedContent: String?
    private var request = UUID()
    private var rendering = UUID()
    private var isRestoring = false
    private var isFiltering = false

    private let search = NSSearchField()
    private let table = NSTableView()
    private let preview = NSTextView()
    private let renderedPreview: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let contentScroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let restoreButton = NSButton()
    private let diffSwitch = NSSwitch()
    private let commitButton = NSButton()

    static func open(note: Note, restore: @escaping (Commit, NSWindow, @escaping (Bool) -> Void) -> Void) {
        let identity = ObjectIdentifier(note)
        if let existing = windows[identity] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NoteHistoryWindowController(note: note, restore: restore)
        windows[identity] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.loadHistory()
    }

    private init(note: Note, restore: @escaping (Commit, NSWindow, @escaping (Bool) -> Void) -> Void) {
        self.note = note
        self.restore = restore
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = NSLocalizedString("History", comment: "") + " — " + note.getFileName()
        window.minSize = NSSize(width: 940, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        window.initialFirstResponder = table
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        request = UUID()
        rendering = UUID()
        renderedPreview.stopLoading()
        Self.windows.removeValue(forKey: ObjectIdentifier(note))
    }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let split = NSSplitViewController()
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let detail = NSViewController()
        detail.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 260
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultHigh
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window?.contentViewController = split
        split.view.frame = root.bounds
        split.splitView.setPosition(300, ofDividerAt: 0)

        search.placeholderString = NSLocalizedString("Search versions", comment: "Git history")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 76
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        listScroll.documentView = table
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        commitButton.title = NSLocalizedString("Open Commit…", comment: "Git history")
        commitButton.bezelStyle = .rounded
        commitButton.target = self
        commitButton.action = #selector(openCommit)
        let bottom = NSStackView(views: [countLabel, commitButton])
        bottom.distribution = .fill
        for view in [search, listScroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: -14),
            search.topAnchor.constraint(equalTo: sidebar.view.topAnchor, constant: 16),
            search.heightAnchor.constraint(equalToConstant: 30),
            listScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor, constant: 14),
            bottom.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: -14),
            bottom.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor, constant: -12)
        ])

        let title = NSTextField(labelWithString: note.getFileName())
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let diffLabel = NSTextField(labelWithString: NSLocalizedString("Show differences", comment: "Git history"))
        diffLabel.font = .systemFont(ofSize: 12)
        diffSwitch.target = self
        diffSwitch.action = #selector(toggleDifferences)
        diffSwitch.setAccessibilityLabel(diffLabel.stringValue)
        diffSwitch.toolTip = NSLocalizedString("Compare with the current note", comment: "Git history")
        copyButton.title = NSLocalizedString("Copy version", comment: "Git history")
        copyButton.target = self
        copyButton.action = #selector(copyVersion)
        restoreButton.title = NSLocalizedString("Restore this version", comment: "Git history")
        restoreButton.target = self
        restoreButton.action = #selector(restoreVersion)
        for button in [copyButton, restoreButton] { button.bezelStyle = .rounded }
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: NSLocalizedString("Close", comment: ""))!,
                             target: self, action: #selector(closeHistory))
        close.isBordered = false
        let header = NSStackView(views: [title, diffLabel, diffSwitch, copyButton, restoreButton, close])
        header.distribution = .fill
        header.spacing = 10
        for control in [diffLabel, diffSwitch, copyButton, restoreButton, close] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        close.widthAnchor.constraint(equalToConstant: 20).isActive = true
        header.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 16)
        renderedPreview.navigationDelegate = self
        renderedPreview.isHidden = true
        renderedPreview.setAccessibilityLabel(NSLocalizedString("Version content", comment: "Git history"))
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        preview.textContainerInset = NSSize(width: 28, height: 24)
        preview.font = UserDefaultsManagement.noteFont
        preview.backgroundColor = .textBackgroundColor
        preview.setAccessibilityLabel(NSLocalizedString("Version content", comment: "Git history"))
        contentScroll.documentView = preview
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for view in [header, contentScroll, renderedPreview, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 62),
            contentScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            contentScroll.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            renderedPreview.topAnchor.constraint(equalTo: contentScroll.topAnchor),
            renderedPreview.leadingAnchor.constraint(equalTo: contentScroll.leadingAnchor),
            renderedPreview.trailingAnchor.constraint(equalTo: contentScroll.trailingAnchor),
            renderedPreview.bottomAnchor.constraint(equalTo: contentScroll.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor, constant: -12)
        ])
        updateActions()
    }

    private static func version(_ commit: Commit) -> Version {
        let date = DateFormatter.localizedString(from: commit.date, dateStyle: .medium, timeStyle: .medium)
        let sha = commit.oid.sha() ?? ""
        return Version(commit: commit, date: date, sha: sha, summary: commit.summary,
                       tooltip: "\(sha)\n\(commit.author.name)\n\(commit.summary)\n\(commit.body)")
    }

    private func loadHistory() {
        showMessage(NSLocalizedString("Loading history…", comment: "Git history"))
        let note = self.note
        ViewController.gitQueue.addOperation { [weak self] in
            do {
                let versions = try note.gitHistory().map(Self.version)
                DispatchQueue.main.async {
                    guard let self = self, Self.windows[ObjectIdentifier(note)] === self else { return }
                    self.versions = versions
                    self.filterVersions()
                }
            } catch {
                DispatchQueue.main.async { self?.showError(error) }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleVersions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let version = visibleVersions[row]
        let cell = HistoryVersionCell()
        cell.dateLabel.stringValue = version.date
        let size = contentCache[version.sha].map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) + " · " } ?? ""
        cell.detailLabel.stringValue = size + String(version.sha.prefix(8)) + " · " + version.summary
        cell.toolTip = version.tooltip
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isFiltering { loadSelectedVersion() }
    }

    func controlTextDidChange(_ obj: Notification) { filterVersions() }

    private func filterVersions() {
        let previous = selectedVersion?.sha
        isFiltering = true
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleVersions = versions.filter {
            query.isEmpty || "\($0.date) \($0.sha) \($0.summary)".localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        countLabel.stringValue = String(format: NSLocalizedString("%d versions", comment: "Git history"), visibleVersions.count)
        if !visibleVersions.isEmpty {
            let row = visibleVersions.firstIndex { $0.sha == previous } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isFiltering = false
            loadSelectedVersion()
        } else {
            isFiltering = false
            request = UUID()
            selectedContent = nil
            updateActions()
            showMessage(NSLocalizedString(versions.isEmpty ? "No saved revisions" : "No matching versions", comment: "Git history"))
        }
    }

    private var selectedVersion: Version? {
        visibleVersions.indices.contains(table.selectedRow) ? visibleVersions[table.selectedRow] : nil
    }

    private func loadSelectedVersion() {
        request = UUID()
        selectedContent = nil
        updateActions()
        guard let version = selectedVersion else { return }
        if let cached = contentCache[version.sha] {
            selectedContent = cached.text
            renderContent()
            updateActions()
            return
        }
        showMessage(NSLocalizedString("Loading version…", comment: "Git history"))
        let token = request
        let note = self.note
        ViewController.gitQueue.addOperation { [weak self] in
            do {
                let data = try note.gitContent(at: version.commit)
                var converted: NSString?
                let encoding = NSString.stringEncoding(for: data, encodingOptions: nil,
                                                       convertedString: &converted, usedLossyConversion: nil)
                guard let text = String(data: data, encoding: .utf8) ?? (converted as String?)
                    ?? String(data: data, encoding: String.Encoding(rawValue: encoding)) else {
                    throw NSError(domain: "NoteHistory", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        NSLocalizedString("Unable to decode this version", comment: "Git history")])
                }
                guard let project = note.getGitProject() else { throw GitError.notFound(ref: note.name) }
                let repository = try project.getRepository()
                let commit = try repository.commitLookup(oid: version.commit.oid)
                let path = try note.gitContentPath(at: commit)
                guard let body = renderMarkdownHTML(markdown: text) else {
                    throw NSError(domain: "NoteHistory", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        NSLocalizedString("Unable to render this version", comment: "Git history")])
                }
                let html = HistoryPreview.embedImages(in: body, notePath: path) { imagePath in
                    try HistoryPreview.imageData(path: imagePath, repository: repository, commit: commit)
                }
                DispatchQueue.main.async {
                    guard let self = self, self.request == token else { return }
                    self.contentCache[version.sha] = Snapshot(text: text, size: data.count, html: html)
                    self.selectedContent = text
                    self.table.reloadData(forRowIndexes: IndexSet(integer: self.table.selectedRow), columnIndexes: IndexSet(integer: 0))
                    self.renderContent()
                    self.updateActions()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.request == token else { return }
                    self.showError(error)
                }
            }
        }
    }

    private func renderContent() {
        rendering = UUID()
        guard let text = selectedContent, let version = selectedVersion else { return }
        if diffSwitch.state == .off {
            guard let snapshot = contentCache[version.sha] else { return }
            contentScroll.isHidden = true
            renderedPreview.isHidden = false
            let style = Bundle.main.url(forResource: "MPreview", withExtension: "bundle")
                .flatMap { try? String(contentsOf: $0.appendingPathComponent("main.css"), encoding: .utf8) } ?? ""
            renderedPreview.loadHTMLString(HistoryPreview.page(body: snapshot.html, style: style,
                fontSize: UserDefaultsManagement.noteFont.pointSize), baseURL: nil)
            status.stringValue = version.date + " · " + version.sha
            status.toolTip = version.tooltip
            return
        }
        renderedPreview.stopLoading()
        renderedPreview.isHidden = true
        contentScroll.isHidden = false
        let token = rendering
        let current = note.content.unloadAttachments().string
        status.stringValue = NSLocalizedString("Saved version → current note · + added · − removed", comment: "Git history")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lines = HistoryDiff.lines(from: text, to: current)
            DispatchQueue.main.async {
                guard let self = self, self.rendering == token else { return }
                let output = NSMutableAttributedString()
                for (index, line) in lines.enumerated() {
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: UserDefaultsManagement.noteFont.pointSize, weight: .regular),
                        .foregroundColor: NSColor.textColor
                    ]
                    let prefix: String
                    switch line.kind {
                    case .unchanged: prefix = "  "
                    case .added:
                        prefix = "+ "
                        attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.16)
                    case .removed:
                        prefix = "− "
                        attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.16)
                    }
                    output.append(NSAttributedString(string: prefix + line.text + (index == lines.count - 1 ? "" : "\n"), attributes: attributes))
                }
                self.preview.textStorage?.setAttributedString(output)
                self.preview.scrollToBeginningOfDocument(nil)
            }
        }
    }

    private func showMessage(_ message: String) {
        rendering = UUID()
        renderedPreview.stopLoading()
        renderedPreview.isHidden = true
        contentScroll.isHidden = false
        preview.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        status.stringValue = message
        status.toolTip = message
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           url.absoluteString.components(separatedBy: "#").first == "about:blank" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ error: Error) {
        showMessage(NSLocalizedString("Unable to load history", comment: "Git history") + ": "
            + ((error as? GitError)?.associatedValue() ?? error.localizedDescription))
    }

    private func updateActions() {
        let ready = selectedContent != nil && selectedVersion != nil && !isRestoring
        copyButton.isEnabled = ready
        restoreButton.isEnabled = ready
        diffSwitch.isEnabled = ready
        search.isEnabled = !isRestoring
        table.isEnabled = !isRestoring
        commitButton.isEnabled = !isRestoring
    }

    @objc private func toggleDifferences() { renderContent() }

    @objc private func copyVersion() {
        guard let text = selectedContent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func restoreVersion() {
        guard !isRestoring, let version = selectedVersion, selectedContent != nil, let window = window else { return }
        isRestoring = true
        updateActions()
        restore(version.commit, window) { [weak self] success in
            guard let self = self else { return }
            self.isRestoring = false
            if success { self.close() } else { self.updateActions() }
        }
    }

    @objc private func closeHistory() { close() }

    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func openCommit() {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Open Commit…", comment: "Git history")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = NSLocalizedString("Full or abbreviated commit ID", comment: "Git history")
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let sha = field.stringValue
            let note = self.note
            ViewController.gitQueue.addOperation { [weak self] in
                do {
                    guard let project = note.getGitProject() else { throw GitError.notFound(ref: note.name) }
                    let commit = try project.getRepository().commitLookup(sha: sha)
                    // Validate content before inserting a manually requested version.
                    _ = try note.gitContent(at: commit)
                    let version = Self.version(commit)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if !self.versions.contains(where: { $0.sha == version.sha }) { self.versions.insert(version, at: 0) }
                        self.search.stringValue = ""
                        self.filterVersions()
                        if let row = self.visibleVersions.firstIndex(where: { $0.sha == version.sha }) {
                            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            self.table.scrollRowToVisible(row)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self = self, let window = self.window else { return }
                        let errorAlert = NSAlert()
                        errorAlert.messageText = NSLocalizedString("Git error", comment: "")
                        errorAlert.informativeText = (error as? GitError)?.associatedValue() ?? error.localizedDescription
                        errorAlert.beginSheetModal(for: window)
                    }
                }
            }
        }
        window.makeFirstResponder(field)
    }
}

private final class HistoryVersionCell: NSTableCellView {
    let dateLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [dateLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        textField = dateLabel
        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            detailLabel.leadingAnchor.constraint(equalTo: dateLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: dateLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 6)
        ])
        backgroundStyle = .normal
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            dateLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
            detailLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}
