import Cocoa
import WebKit

private func gitLabel(_ key: String) -> String { NSLocalizedString(key, comment: "Git changes") }

final class GitChangesViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case section(GitChange.Area, Int), file(GitChange) }
    private var project: Project
    private let projects: [Project]
    private let closePanel: () -> Void
    private let repositoryPicker = NSPopUpButton()
    private let repositoryPath = NSTextField(labelWithString: "")
    private var statusRequest = UUID()
    private var pendingRefresh: DispatchWorkItem?
    private var lastError: String?
    private let preferredPath: String?
    private let synchronize: (Project) -> Void
    private var snapshot: GitChangeSnapshot?
    private var rows = [Row]()
    private var isFiltering = false
    private var isRefreshing = false
    private var isPerforming = false
    private var isClosed = false
    private var diffRequest = UUID()
    private var previewHTML = ""
    private var timer: Timer?
    private var currentDiff: GitChangeDiff?

    private let search = NSSearchField()
    private let table = NSTableView()
    private let branch = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let comparisonField = NSTextField(labelWithString: "")
    private let message = NSTextField()
    private let commitButton = NSButton()
    private let refreshButton = NSButton()
    private let syncButton = NSButton()
    private let pushButton = NSButton()
    private let progress = NSProgressIndicator()
    private let mode = NSSegmentedControl(labels: [gitLabel("Side by side"), gitLabel("Unified")], trackingMode: .selectOne, target: nil, action: nil)
    private let preview: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    init(project: Project, projects: [Project], preferredPath: String?, synchronize: @escaping (Project) -> Void, close: @escaping () -> Void) {
        self.project = project
        self.projects = projects
        self.preferredPath = preferredPath
        self.synchronize = synchronize
        self.closePanel = close
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        buildInterface()
    }

    func start() {
        guard timer == nil else { refresh(); return }
        isClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(fileDidChange(_:)), name: .workspaceFileDidChange, object: nil)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func focusFilter() {
        view.window?.makeFirstResponder(search)
    }

    func stop() {
        isClosed = true
        statusRequest = UUID()
        diffRequest = UUID()
        pendingRefresh?.cancel()
        timer?.invalidate()
        timer = nil
        preview.stopLoading()
        NotificationCenter.default.removeObserver(self)
    }

    deinit { timer?.invalidate(); pendingRefresh?.cancel(); NotificationCenter.default.removeObserver(self) }

    @objc private func fileDidChange(_ notification: Notification) {
        guard let url = notification.object as? URL,
              url.standardizedFileURL.path.hasPrefix(project.url.standardizedFileURL.path + "/") else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func buildInterface() {
        let root = view
        repositoryPicker.addItems(withTitles: projects.map { $0.label })
        repositoryPicker.selectItem(at: projects.firstIndex { $0 === project } ?? 0)
        repositoryPicker.target = self
        repositoryPicker.action = #selector(repositoryChanged)
        repositoryPicker.setAccessibilityLabel(gitLabel("Repository"))
        repositoryPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repositoryPath.stringValue = project.url.path
        repositoryPath.toolTip = project.url.path
        repositoryPath.font = .systemFont(ofSize: 10)
        repositoryPath.textColor = .secondaryLabelColor
        repositoryPath.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView(image: NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Git")!)
        icon.contentTintColor = .controlAccentColor
        branch.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        branch.textColor = .secondaryLabelColor
        branch.lineBreakMode = .byTruncatingMiddle
        configure(refreshButton, title: gitLabel("Refresh"), symbol: "arrow.clockwise", action: #selector(refreshClicked))
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = [.command]
        configure(pushButton, title: gitLabel("Push"), symbol: "arrow.up", action: #selector(pushClicked))
        configure(syncButton, title: gitLabel("Sync"), symbol: "arrow.triangle.2.circlepath", action: #selector(syncClicked))
        syncButton.toolTip = gitLabel("Sync: pull, commit and push")
        let repoRow = NSStackView(views: [icon, repositoryPicker])
        repoRow.spacing = 8
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let actions = NSStackView(views: [refreshButton, pushButton, syncButton])
        actions.spacing = 6
        let header = NSStackView(views: [repoRow, repositoryPath, branch, actions])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        for field in [repoRow, repositoryPath, branch] { field.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true }
        for control in [refreshButton, pushButton, syncButton] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11)
            control.setContentHuggingPriority(.required, for: .horizontal)
        }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebar = NSView(), detail = NSView()
        split.addArrangedSubview(detail)
        split.addArrangedSubview(sidebar)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 350).isActive = true

        search.placeholderString = gitLabel("Filter changed files")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(gitLabel("Filter changed files"))
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change")))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(gitLabel("Changed files"))
        listScroll.documentView = table
        message.placeholderString = gitLabel("Commit message")
        message.delegate = self
        message.setAccessibilityLabel(gitLabel("Commit message"))
        configure(commitButton, title: gitLabel("Commit staged changes"), symbol: "checkmark", action: #selector(commitClicked))
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        let hint = NSTextField(wrappingLabelWithString: gitLabel("Only staged changes will be committed."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let commitArea = NSStackView(views: [message, commitButton, hint])
        commitArea.orientation = .vertical
        commitArea.alignment = .leading
        commitArea.spacing = 10
        for view in [message, commitButton, hint] {
            view.widthAnchor.constraint(equalTo: commitArea.widthAnchor).isActive = true
        }
        let divider = NSBox()
        divider.boxType = .separator
        add([header, search, listScroll, divider, commitArea], to: sidebar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            commitArea.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 14),
            divider.topAnchor.constraint(equalTo: commitArea.bottomAnchor, constant: 12),
            listScroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            commitArea.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            commitArea.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16)
        ])

        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        comparisonField.font = .systemFont(ofSize: 11)
        comparisonField.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [titleField, comparisonField])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 5
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setContentHuggingPriority(.required, for: .horizontal)
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: gitLabel("Back to notes"))!, target: self, action: #selector(closeClicked))
        back.isBordered = false
        back.toolTip = gitLabel("Back to notes")
        back.setAccessibilityLabel(gitLabel("Back to notes"))
        back.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let toolbar = NSStackView(views: [back, titles, mode])
        toolbar.spacing = 12
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 16)
        preview.setAccessibilityLabel(gitLabel("File differences"))
        add([toolbar, preview], to: detail)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: detail.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 64),
            preview.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        ])

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let footer = NSStackView(views: [progress, status])
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        add([split, footer], to: root)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14)
        ])
        let rightWidth = sidebar.widthAnchor.constraint(equalToConstant: 280)
        rightWidth.priority = .defaultHigh
        rightWidth.isActive = true
        showMessage(gitLabel("Loading changes…"), detail: project.url.path)
        updateActions()
    }

    private func add(_ views: [NSView], to parent: NSView) {
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view) }
    }

    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private var selectedChange: GitChange? {
        guard rows.indices.contains(table.selectedRow), case .file(let change) = rows[table.selectedRow] else { return nil }
        return change
    }

    private var writable: Bool {
        snapshot != nil && !isRefreshing && !isPerforming && !project.isActiveGit && !project.gitMergePending
            && snapshot?.operationPending == false && snapshot?.changes.contains(where: { $0.kind == .conflicted }) == false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return 38 }
        return 54
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(let area, let count):
            let label = NSTextField(labelWithString: gitLabel(area == .staged ? "Staged changes" : "Changes") + "  \(count)")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let all = NSButton(title: gitLabel(area == .staged ? "Unstage all" : "Stage all"), target: self, action: #selector(stageAll(_:)))
            all.bezelStyle = .inline
            all.font = .systemFont(ofSize: 11)
            all.tag = area == .staged ? 1 : 0
            all.isEnabled = writable && count > 0
            let stack = NSStackView(views: [label, NSView(), all])
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
            return stack
        case .file(let change):
            let cell = GitChangeCell()
            cell.name.stringValue = displayName(for: change)
            let directory = (change.path as NSString).deletingLastPathComponent
            cell.path.stringValue = directory.isEmpty ? gitLabel("Repository root") : directory
            cell.badge.stringValue = change.kind.rawValue
            cell.badge.textColor = change.kind == .added ? .systemGreen : change.kind == .deleted || change.kind == .conflicted ? .systemRed : .systemOrange
            cell.action.image = NSImage(systemSymbolName: change.area == .staged ? "minus.circle" : "plus.circle", accessibilityDescription: gitLabel(change.area == .staged ? "Unstage" : "Stage"))
            cell.action.target = self
            cell.action.action = #selector(stageRow(_:))
            cell.action.tag = row
            cell.action.toolTip = gitLabel(change.area == .staged ? "Unstage" : "Stage")
            cell.action.isEnabled = writable && change.canStage
            cell.toolTip = change.kind == .renamed ? change.oldPath + " → " + change.path : change.path
            cell.setAccessibilityLabel(change.path + ", " + gitLabel(change.kind.title))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isFiltering { loadDiff(showLoading: true) }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { filter() }
        else { updateActions() }
    }

    private func filter() {
        let previous = selectedChange?.identity
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows.removeAll()
        for area in [GitChange.Area.staged, .unstaged] {
            let changes = (snapshot?.changes ?? []).filter { $0.area == area }
            rows.append(.section(area, changes.count))
            rows.append(contentsOf: changes.filter {
                query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
                    || $0.oldPath.localizedCaseInsensitiveContains(query)
                    || displayName(for: $0).localizedCaseInsensitiveContains(query)
            }.map(Row.file))
        }
        isFiltering = true
        table.reloadData()
        let files = rows.indices.filter { if case .file = rows[$0] { return true }; return false }
        let selection = files.first { if case .file(let change) = rows[$0] { return change.identity == previous }; return false } ?? files.first { if case .file(let change) = rows[$0] { return change.path == preferredPath }; return false } ?? files.first
        if let selection = selection { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        isFiltering = false
        loadDiff(showLoading: previous != selectedChange?.identity)
    }

    private func refresh() {
        guard !isClosed, !isRefreshing, !isPerforming else { return }
        guard !project.isActiveGit else {
            status.stringValue = gitLabel("Git operation in progress…")
            progress.startAnimation(nil)
            updateActions()
            table.reloadData()
            return
        }
        isRefreshing = true
        progress.startAnimation(nil)
        refreshButton.isEnabled = false
        let project = self.project
        let token = statusRequest
        ViewController.gitQueue.addOperation { [weak self] in
            Storage.shared().plainWriter.waitUntilAllOperationsAreFinished()
            let result = Result { try GitChanges.snapshot(in: project.getRepository()) }
            DispatchQueue.main.async {
                guard let self = self, !self.isClosed, self.statusRequest == token else { return }
                self.isRefreshing = false
                self.progress.stopAnimation(nil)
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.branch.stringValue = "⑂ " + snapshot.branch
                    let staged = snapshot.changes.filter { $0.area == .staged }.count
                    self.status.stringValue = snapshot.operationPending || project.gitMergePending
                        ? gitLabel("Resolve the pending Git operation before staging or committing.")
                        : snapshot.changes.contains(where: { $0.kind == .conflicted }) ? gitLabel("Resolve conflicts before staging or committing.")
                        : String(format: gitLabel("%d unstaged · %d staged"), snapshot.changes.count - staged, staged)
                    if let last = snapshot.lastCommit {
                        let date = DateFormatter.localizedString(from: last.date, dateStyle: .short, timeStyle: .short)
                        self.status.toolTip = gitLabel("Latest commit") + ": " + date + " · " + last.summary
                    }
                    if let error = self.lastError { self.status.stringValue = error }
                    self.filter()
                case .failure(let error):
                    self.snapshot = nil
                    self.filter()
                    self.status.stringValue = self.errorMessage(error)
                    self.showMessage(gitLabel("Unable to load changes"), detail: self.errorMessage(error))
                }
                self.updateActions()
            }
        }
    }

    private func loadDiff(showLoading: Bool) {
        diffRequest = UUID()
        let token = diffRequest
        updateActions()
        guard let change = selectedChange else {
            currentDiff = nil
            titleField.stringValue = gitLabel("File differences")
            comparisonField.stringValue = ""
            if search.stringValue.isEmpty && snapshot?.changes.isEmpty == true {
                let last = snapshot?.lastCommit.map {
                    let date = DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .short)
                    return "\(gitLabel("Latest commit")): \(date) · \($0.summary)"
                } ?? ""
                showMessage(gitLabel("No uncommitted changes"), detail: gitLabel("All saved files match the current commit.") + "\n" + last, symbol: "✓")
            } else {
                showMessage(gitLabel("No matching files"), detail: gitLabel("Select a changed file to review its differences."))
            }
            return
        }
        titleField.stringValue = displayName(for: change)
        titleField.toolTip = change.path
        comparisonField.stringValue = gitLabel(change.kind.title) + " · " + (change.area == .staged ? "HEAD → " + gitLabel("Index") : gitLabel("Index") + " → " + gitLabel("Working tree"))
        if showLoading { currentDiff = nil; showMessage(gitLabel("Loading differences…"), detail: change.path) }
        let project = self.project
        ViewController.gitQueue.addOperation { [weak self] in
            let result = Result { try GitChanges.diff(for: change, in: project.getRepository()) }
            DispatchQueue.main.async {
                guard let self = self, !self.isClosed, self.diffRequest == token else { return }
                switch result {
                case .success(let diff): self.currentDiff = diff; self.renderDiff()
                case .failure(let error): self.currentDiff = nil; self.showMessage(gitLabel("Unable to compare file"), detail: self.errorMessage(error))
                }
            }
        }
    }

    private var dark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private func renderDiff() {
        guard let diff = currentDiff, let change = selectedChange else { return }
        display(GitDiffPage.render(diff, change: change, sideBySide: mode.selectedSegment == 0, dark: dark))
    }
    private func showMessage(_ title: String, detail: String, symbol: String = "◇") {
        display(GitDiffPage.message(title, detail: detail, symbol: symbol, dark: dark))
    }
    private func display(_ html: String) {
        guard html != previewHTML else { return }
        previewHTML = html
        preview.loadHTMLString(html, baseURL: nil)
    }

    private func updateActions() {
        refreshButton.isEnabled = !isRefreshing && !isPerforming && !project.isActiveGit
        pushButton.isEnabled = writable && project.getGitOrigin() != nil
        syncButton.isEnabled = !isPerforming && !project.isActiveGit && project.getGitOrigin() != nil
        commitButton.isEnabled = writable && snapshot?.changes.contains(where: { $0.area == .staged }) == true
            && !message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        repositoryPicker.isEnabled = !isPerforming
        message.isEnabled = !isPerforming
        mode.isEnabled = selectedChange != nil
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func modeChanged() { renderDiff() }
    @objc private func syncClicked() {
        guard syncButton.isEnabled else { return }
        synchronize(project)
        updateActions()
        table.reloadData()
    }
    @objc private func pushClicked() {
        guard pushButton.isEnabled else { return }
        let project = self.project
        perform(title: gitLabel("Pushing…")) { try project.push() }
    }
    @objc private func stageRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .file(let change) = rows[sender.tag] else { return }
        stage([change])
    }
    @objc private func stageAll(_ sender: NSButton) {
        let area: GitChange.Area = sender.tag == 1 ? .staged : .unstaged
        stage((snapshot?.changes ?? []).filter { $0.area == area && $0.canStage })
    }
    private func stage(_ changes: [GitChange]) {
        guard writable, let first = changes.first else { return }
        let project = self.project
        perform(title: gitLabel(first.area == .staged ? "Unstaging…" : "Staging…")) {
            let repository = try project.getRepository()
            if first.area == .staged { try GitChanges.unstage(changes, in: repository) }
            else { try GitChanges.stage(changes, in: repository) }
        }
    }
    @objc private func commitClicked() {
        guard commitButton.isEnabled else { return }
        let text = message.stringValue
        let project = self.project
        perform(title: gitLabel("Committing…"), committed: true) {
            try GitChanges.commit(message: text, signature: project.getSign(), in: project.getRepository())
            project.cacheHistory()
        }
    }

    private func perform(title: String, committed: Bool = false, operation: @escaping () throws -> Void) {
        guard writable else { return }
        isPerforming = true
        project.isActiveGit = true
        diffRequest = UUID()
        status.stringValue = title
        progress.startAnimation(nil)
        updateActions()
        table.reloadData()
        let project = self.project
        ViewController.gitQueue.addOperation { [weak self] in
            ViewController.gitQueueOperationDate = Date()
            ViewController.gitQueueBusy = true
            Storage.shared().plainWriter.waitUntilAllOperationsAreFinished()
            let result = Result {
                guard !project.gitMergePending else { throw GitError.invalidSpec(spec: "Resolve sync conflicts first") }
                guard !project.metadataUnavailable else { throw MetadataStore.Failure.invalid("Metadata loading failed") }
                try operation()
            }
            ViewController.gitQueueOperationDate = nil
            ViewController.gitQueueBusy = false
            DispatchQueue.main.async {
                project.isActiveGit = false
                guard let self = self, !self.isClosed else { return }
                self.isPerforming = false
                self.progress.stopAnimation(nil)
                if case .success = result, committed { self.message.stringValue = "" }
                switch result {
                case .success: self.lastError = nil
                case .failure(let error): self.lastError = self.errorMessage(error)
                }
                self.refresh()
            }
        }
    }

    private func displayName(for change: GitChange) -> String {
        Storage.shared().getBy(url: project.url.appendingPathComponent(change.path))?.getFileName()
            ?? (change.path as NSString).lastPathComponent
    }

    @objc private func closeClicked() { closePanel() }

    @objc private func repositoryChanged() {
        guard !isPerforming, projects.indices.contains(repositoryPicker.indexOfSelectedItem) else { return }
        project = projects[repositoryPicker.indexOfSelectedItem]
        repositoryPath.stringValue = project.url.path
        repositoryPath.toolTip = project.url.path
        statusRequest = UUID()
        diffRequest = UUID()
        snapshot = nil
        currentDiff = nil
        isRefreshing = false
        message.stringValue = ""
        lastError = nil
        filter()
        refresh()
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? GitError)?.associatedValue() ?? error.localizedDescription
    }
}

private extension GitChange.Kind {
    var title: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .typeChanged: return "Type changed"
        case .conflicted: return "Conflicted"
        case .unreadable: return "Unreadable"
        }
    }
}

private final class GitChangeCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let action = NSButton()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        textField = name
        name.lineBreakMode = .byTruncatingMiddle
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        action.isBordered = false
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        for view in [labels, badge, action] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            path.widthAnchor.constraint(equalTo: labels.widthAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -8),
            action.widthAnchor.constraint(equalToConstant: 22),
            action.heightAnchor.constraint(equalToConstant: 24),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
