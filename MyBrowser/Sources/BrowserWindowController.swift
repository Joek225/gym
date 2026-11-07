import AppKit
import WebKit

/// The browser window: toolbar and bookmarks bar on top, tab sidebar on the left,
/// and the current page on the right.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                     NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate,
                                     SidebarDelegate, GroupEditorActions, NewTabDelegate {
    /// A private window (like Chrome's Incognito) keeps nothing after it closes.
    let isPrivate: Bool
    /// A private window's own throwaway cookie and cache storage.
    private let privateStore: WKWebsiteDataStore?
    private let findBar = FindBar()
    /// Covers the whole window in black after 5 idle minutes on a new tab.
    private let dimmer = SolidView(color: .black)
    /// Pulsing dots shown while an unloaded tab wakes up.
    private let loadingDots = LoadingDots()
    private var progressObservation: NSKeyValueObservation?
    private var sleptAt = Date.distantPast
    /// Becomes true once the window has appeared (see `showWindow`).
    private var isOnScreen = false
    private var memoryReadout: MemoryReadout?

    let store: TabStore
    private let sidebar: SidebarController
    private let toolbar = ToolbarView()
    private let bookmarksBar = BookmarksBarView()
    private let resizeHandle = ResizeHandle()
    private let webContainer = SolidView(color: Theme.background)
    private let errorView = ErrorView()
    private let newTabPage = NewTabView()
    private var sidebarWidth: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    private var unloadTimer: Timer?
    private let logLoads = CommandLine.arguments.contains("--log-loads")

    private var showsBookmarksBar: Bool {
        get { UserDefaults.standard.object(forKey: "showBookmarksBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showBookmarksBar") }
    }

    /// Opens a window with saved tabs, or a fresh one. `adopting` moves an
    /// existing group (with its open pages) into the new window.
    init(session: SavedSession?, adopting group: TabGroup? = nil, adoptingTab: Tab? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.privateStore = isPrivate ? WKWebsiteDataStore.nonPersistent() : nil
        let store = TabStore()
        self.store = store
        self.sidebar = SidebarController(store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.sidebar
        window.title = isPrivate ? "Private Window" : "beababrowser"
        window.tabbingMode = .disallowed        // tabs live in our sidebar instead
        window.minSize = NSSize(width: 600, height: 360)
        window.center()
        if AppDelegate.shared.controllers.isEmpty { window.setFrameAutosaveName("MainWindow") }
        super.init(window: window)
        window.delegate = self

        buildLayout(in: window)
        wireUp()

        if let session { store.restore(from: session) }
        if let group {
            store.adopt(group)
            for tab in group.tabs { if let webView = tab.webView { install(webView, for: tab) } }
        }
        if let adoptingTab {
            store.insert(adoptingTab, at: 0, in: nil)
            if let webView = adoptingTab.webView { install(webView, for: adoptingTab) }
        }
        if store.allTabs.isEmpty { store.insert(Tab(url: nil), at: 0, in: nil) }
        sidebar.reload()
        bookmarksBar.reload()
        select(store.selected ?? group?.tabs.first ?? adoptingTab ?? store.allTabs[0])
        if isPrivate { newTabPage.showPrivateNote() }
        startUnloadTimer()
        refreshExtensionButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !isOnScreen else { return }
        isOnScreen = true
        // Now that the window is on screen (at your screen's real sharpness), load the current tab.
        window?.displayIfNeeded()
        if let tab = store.selected { select(tab) }
    }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        let content: NSView = Theme.arcStyle ? ArcBackgroundView() : SolidView(color: Theme.toolbar)
        window.contentView = content
        let side = sidebar.view
        // Arc style: the page sits on a rounded card with a small margin.
        let margin: CGFloat = Theme.arcStyle ? 8 : 0
        if Theme.arcStyle {
            for card in [webContainer, newTabPage] { card.cornerRadius = 10 }
            errorView.wantsLayer = true
            errorView.layer?.cornerRadius = 10
            errorView.layer?.masksToBounds = true
        }

        for v in [toolbar, bookmarksBar, side, webContainer, errorView, newTabPage, findBar, resizeHandle, loadingDots, dimmer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        errorView.isHidden = true

        let savedWidth = UserDefaults.standard.double(forKey: "sidebarWidth")
        sidebarWidth = side.widthAnchor.constraint(equalToConstant: savedWidth > 0 ? savedWidth : 250)
        barHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: showsBookmarksBar ? BookmarksBarView.height : 0)
        bookmarksBar.isHidden = !showsBookmarksBar

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: ToolbarView.height),

            bookmarksBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            barHeight,

            side.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,

            webContainer.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),

            loadingDots.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            loadingDots.centerYAnchor.constraint(equalTo: webContainer.centerYAnchor),
            loadingDots.widthAnchor.constraint(equalToConstant: 56),
            loadingDots.heightAnchor.constraint(equalToConstant: 16),

            dimmer.topAnchor.constraint(equalTo: content.topAnchor),
            dimmer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dimmer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dimmer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            errorView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            findBar.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -16),
            findBar.heightAnchor.constraint(equalToConstant: 40),

            newTabPage.topAnchor.constraint(equalTo: webContainer.topAnchor),
            newTabPage.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            newTabPage.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            newTabPage.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            resizeHandle.centerXAnchor.constraint(equalTo: side.trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
            resizeHandle.topAnchor.constraint(equalTo: side.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: side.bottomAnchor),
        ])
    }

    private func wireUp() {
        toolbar.backButton.target = self
        toolbar.backButton.action = #selector(goBack(_:))
        toolbar.forwardButton.target = self
        toolbar.forwardButton.action = #selector(goForward(_:))
        toolbar.reloadButton.target = self
        toolbar.reloadButton.action = #selector(reloadOrStop(_:))
        toolbar.starButton.target = self
        toolbar.starButton.action = #selector(bookmarkThisPage(_:))
        newTabPage.delegate = self
        dimmer.isHidden = true
        findBar.isHidden = true
        findBar.webView = { [weak self] in self?.store.selected?.webView }
        findBar.onClose = { [weak self] in self?.window?.makeFirstResponder(self?.store.selected?.webView) }
        toolbar.downloadsButton.target = self
        toolbar.downloadsButton.action = #selector(showDownloads(_:))
        toolbar.menuButton.target = self
        toolbar.menuButton.action = #selector(showMainMenu(_:))
        toolbar.siteButton.target = self
        toolbar.siteButton.action = #selector(showSiteInfo(_:))
        memoryReadout = MemoryReadout(label: toolbar.memoryLabel) {
            AppDelegate.shared.controllers.flatMap { $0.store.allTabs.compactMap(\.webView) }
        }
        memoryReadout?.update()
        NotificationCenter.default.addObserver(forName: MemoryReadout.didToggle, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryReadout?.update() }
        }
        NotificationCenter.default.addObserver(forName: DownloadManager.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self }
        }

        sidebar.delegate = self
        store.onChange = { [weak self] in
            self?.sidebar.reload()
            self?.bookmarksBar.reload()
        }
        bookmarksBar.groups = { [weak self] in self?.store.groups ?? [] }
        bookmarksBar.closedGroups = { GroupLibrary.shared.closed }
        toolbar.onExtensionClicked = { [weak self] id in self?.extensionButtonClicked(id) }
        toolbar.sidebarButton.target = self
        toolbar.sidebarButton.action = #selector(toggleSidebar(_:))
        toolbar.puzzleButton.target = self
        toolbar.puzzleButton.action = #selector(showExtensionsMenu(_:))
        applySidebarVisibility()

        resizeHandle.onDrag = { [weak self] x in
            self?.sidebarWidth.constant = min(max(x, 160), 480)
        }
        resizeHandle.onDragEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.sidebarWidth.constant), forKey: "sidebarWidth")
        }

        NotificationCenter.default.addObserver(forName: BookmarkStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bookmarksBar.reload()
                self?.newTabPage.bookmarksChanged()
                self?.updateToolbar()
            }
        }
        NotificationCenter.default.addObserver(forName: GroupLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bookmarksBar.reload() }
        }
        if #available(macOS 15.4, *) {
            NotificationCenter.default.addObserver(forName: ExtensionManager.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExtensionButtons() }
            }
        }
    }

    // MARK: Tabs

    var selectedTab: Tab? { store.selected }

    func select(_ tab: Tab) {
        let previous = store.selected
        progressObservation = nil
        if let old = previous, old !== tab { old.lastActive = Date(); old.group?.lastActive = Date() }
        if let group = tab.group {
            group.isDisabled = false      // opening a tab turns its group back on
            group.lastActive = Date()
            group.lastTabID = tab.id
        }
        store.selected = tab
        tab.lastActive = Date()
        if let group = tab.group, group.isCollapsed { group.isCollapsed = false }   // like Chrome
        // Pages only start loading once the window is really on screen: a page that starts
        // before that is told the screen is low-resolution, and canvas-drawn text
        // (Google Docs, Sheets, Figma…) then stays blurry for good.
        if isOnScreen, tab.webView == nil, tab.url != nil || tab.savedState != nil { wake(tab) }
        show(tab)
        sidebar.reload()
        updateToolbar()
        store.scheduleSave()
        if previous !== tab { ExtensionEvents.tabActivated(tab, previous: previous) }
        memoryReadout?.refreshSoon()
        refreshExtensionButtons()
        if isBlank(tab) {
            newTabPage.reset()
        } else {
            window?.makeFirstResponder(tab.webView)
        }
    }

    /// A new tab that hasn't gone anywhere yet shows the search page.
    private func isBlank(_ tab: Tab) -> Bool { tab.webView == nil && tab.url == nil && tab.savedState == nil }

    /// Puts the tab's page in the content area.
    private func show(_ tab: Tab) {
        newTabPage.isHidden = !isBlank(tab)
        if let webView = tab.webView { attach(webView) }
        // Other loaded tabs stay in the window, just hidden, so pages keep drawing
        // at your screen's sharpness (and WebKit pauses hidden pages by itself).
        for view in webContainer.subviews { view.isHidden = view !== tab.webView }
    }

    /// Puts a page in the window (hidden) before it starts loading. Pages that start
    /// loading off-screen think the screen is low-resolution, which makes canvas-drawn
    /// text (like Google Docs) look grainy.
    private func attach(_ webView: WKWebView) {
        guard webView.superview !== webContainer else { return }
        webView.frame = webContainer.bounds
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = true
        webContainer.addSubview(webView)
    }

    /// Re-creates an unloaded tab's page (restoring its back/forward history).
    private func wake(_ tab: Tab) {
        let webView = WebKitEnvironment.makeWebView(store: privateStore)
        install(webView, for: tab)
        attach(webView)
        tab.isWaking = true
        if let state = tab.savedState {
            webView.interactionState = state
            tab.savedState = nil
        } else if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
    }

    private func install(_ webView: WKWebView, for tab: Tab) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let observations = [
            webView.observe(\.title) { [weak self, weak tab] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    tab.title = webView.title ?? ""
                    self.tabDidChange(tab)
                }
            },
            webView.observe(\.url) { [weak self, weak tab] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let tab else { return }
                    if let url = webView.url { tab.url = url }
                    self.tabDidChange(tab)
                }
            },
            webView.observe(\.canGoBack) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated { if let tab, tab === self?.store.selected { self?.updateToolbar() } }
            },
            webView.observe(\.canGoForward) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated { if let tab, tab === self?.store.selected { self?.updateToolbar() } }
            },
            webView.observe(\.isLoading) { [weak self, weak tab] _, _ in
                MainActor.assumeIsolated { if let tab, tab === self?.store.selected { self?.updateToolbar() } }
            },
        ]
        tab.attach(webView, observations: observations)
        ExtensionEvents.tabOpened(tab)
    }

    private func tabDidChange(_ tab: Tab) {
        sidebar.refresh(tab)
        if tab === store.selected { updateToolbar() }
        store.scheduleSave()
    }

    func openInNewTab(_ url: URL, background: Bool, after source: Tab? = nil) {
        let tab = Tab(url: url)
        store.insert(tab, after: source ?? store.selected)
        // Background tabs stay unloaded (no memory) until you click them.
        if !background { select(tab) }
    }

    /// Opens a URL given at launch.
    func openFromLaunch(_ url: URL) {
        if let tab = store.selected, tab.url == nil { load(url) } else { openInNewTab(url, background: false) }
    }

    func close(_ tab: Tab) {
        let wasSelected = tab === store.selected
        let order = store.allTabs
        let index = order.firstIndex(of: tab) ?? 0
        if let url = tab.webView?.url ?? tab.url {
            store.recentlyClosed.append(.init(url: url, title: tab.title,
                                              state: tab.webView?.interactionState ?? tab.savedState,
                                              icon: tab.faviconPNG, groupID: tab.group?.id))
            if store.recentlyClosed.count > 25 { store.recentlyClosed.removeFirst() }
        }
        ExtensionEvents.tabClosed(tab)
        tab.unload()
        tab.savedState = nil
        store.remove(tab)
        let remaining = store.allTabs
        if remaining.isEmpty {
            window?.performClose(nil)   // closing the last tab closes the window, like Chrome
            return
        }
        if wasSelected { select(remaining[min(index, remaining.count - 1)]) }
    }

    // MARK: Unloading idle tabs

    private func startUnloadTimer() {
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIdleTabs() }
        }
        unloadTimer?.tolerance = 20
    }

    /// Any mouse movement, click or key press (called for every window).
    func userActed() {
        // Ignore the first moment after Sleep is clicked (the mouse is still moving from the click).
        guard !dimmer.isHidden, Date().timeIntervalSince(sleptAt) > 1 else { return }
        setDimmed(false)
    }

    /// The Sleep button (top right): the window goes black until you move the mouse or press a key.
    @objc func sleepWindow(_ sender: Any?) { newTabSleep() }

    func newTabSleep() {
        sleptAt = Date()
        setDimmed(true)
    }

    private func setDimmed(_ dimmed: Bool) {
        dimmer.isHidden = !dimmed
        // Mouse movement is only tracked while blacked out (to wake up); otherwise it costs energy.
        window?.acceptsMouseMovedEvents = dimmed
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = dimmed
        }
    }

    /// Turns a group off: closes all its pages (freeing their memory), greys it out
    /// and folds it up. Its tabs stay listed; click the group to turn it back on.
    func disableGroup(_ group: TabGroup) {
        leave(group)
        group.tabs.forEach { $0.unload() }
        group.isDisabled = true
        group.isCollapsed = true
        store.changed()
    }

    /// If you're on a tab in this group, switch to a tab outside it (a visible one if possible),
    /// or to a new tab if there's nothing else.
    private func leave(_ group: TabGroup) {
        guard store.selected?.group === group else { return }
        let outside = store.allTabs.filter { $0.group !== group }
        if let next = outside.first(where: { !($0.group?.isCollapsed ?? false) }) ?? outside.first {
            select(next)
        } else {
            let blank = Tab(url: nil)
            store.insert(blank, at: store.items.count, in: nil)
            select(blank)
        }
    }

    func sidebarGroupCollapsed(_ group: TabGroup) { leave(group) }

    /// Turns a group back on and opens only the tab you were last on in it.
    func sidebarEnableGroup(_ group: TabGroup) {
        group.isDisabled = false
        group.isCollapsed = false
        let tab = group.tabs.first { $0.id == group.lastTabID } ?? group.tabs.first
        store.changed()
        if let tab { select(tab) }
    }

    private func unloadIdleTabs() {
        let now = Date()
        // Turn off groups you haven't used for a while (Settings).
        let minutes = Preferences.disableGroupsMinutes
        if minutes > 0 {
            for group in store.groups where !group.isDisabled && store.selected?.group !== group
                && now.timeIntervalSince(group.lastActive) > TimeInterval(minutes * 60) {
                disableGroup(group)
            }
        }
        for tab in store.allTabs where tab !== store.selected && tab.isLoaded
            && Preferences.unloadMinutes > 0
            && now.timeIntervalSince(tab.lastActive) > TimeInterval(Preferences.unloadMinutes * 60) {
            guard let webView = tab.webView,
                  webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            // Never unload a tab that's playing sound or video.
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                guard let self, let tab, state != .playing, tab !== self.store.selected else { return }
                tab.unload()
                self.sidebar.refresh(tab)
                self.turnOffIfAllUnloaded(tab.group)
            }
        }
    }

    // MARK: Toolbar

    /// Shows the dots while the current tab is waking up, until its page is mostly loaded.
    private func updateLoadingDots() {
        guard let tab = store.selected, tab.isWaking, let webView = tab.webView else {
            loadingDots.stop()
            progressObservation = nil
            return
        }
        if webView.estimatedProgress >= 0.7 || !webView.isLoading {
            tab.isWaking = false
            loadingDots.stop()
            progressObservation = nil
            return
        }
        loadingDots.start()
        if progressObservation == nil {
            progressObservation = webView.observe(\.estimatedProgress) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateLoadingDots() }
            }
        }
    }

    private func updateToolbar() {
        updateLoadingDots()
        guard let tab = store.selected else { return }
        let webView = tab.webView
        toolbar.backButton.isEnabled = webView?.canGoBack ?? false
        toolbar.forwardButton.isEnabled = webView?.canGoForward ?? false
        toolbar.setLoading(webView?.isLoading ?? false)
        toolbar.setStarred(BookmarkStore.shared.isBookmarked(tab.url))
        toolbar.showAddress(tab.displayURL)
        window?.title = tab.displayTitle
        if let message = tab.errorMessage {
            errorView.show(message: message, address: tab.failedURL?.host ?? "")
            if let insecure = Security.insecureFallback(for: tab.failedURL) {
                errorView.offer("Continue to insecure site") { [weak self, weak tab] in
                    guard let self, let tab, let host = insecure.host else { return }
                    Security.allowInsecure(host)
                    self.load(insecure, in: tab)
                }
            } else {
                errorView.offer(nil, action: nil)
            }
        } else {
            errorView.isHidden = true
        }
    }

    private var isEditingAddress: Bool {
        guard let editor = toolbar.addressField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    // MARK: Actions (buttons, menu items, keyboard shortcuts)

    func load(_ url: URL) {
        guard let tab = store.selected else { openInNewTab(url, background: false); return }
        load(url, in: tab)
    }

    func load(_ url: URL, in tab: Tab) {
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.savedState = nil
        if tab.webView == nil { install(WebKitEnvironment.makeWebView(store: privateStore), for: tab) }
        if let webView = tab.webView { attach(webView) }
        tab.url = url
        if tab === store.selected { show(tab) }
        if url.isFileURL {
            tab.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView?.load(URLRequest(url: url))
        }
        updateToolbar()
        sidebar.refresh(tab)
    }

    /// ⌘L: typing only happens on the new tab page. On a blank tab it puts the cursor
    /// in the search box; on any other tab it opens a new tab to search from.
    @objc func focusAddressBar(_ sender: Any?) {
        if let tab = store.selected, isBlank(tab) { newTabPage.focus() } else { newTab(sender) }
    }

    func newTabOpen(_ url: URL) {
        load(url)
        window?.makeFirstResponder(store.selected?.webView)
    }

    func newTabImportFromChrome() { importFromChrome(nil) }

    func newTabOpenBookmark(_ node: BookmarkNode) {
        if let url = node.url { newTabOpen(url) }
    }

    @objc func importFromChrome(_ sender: Any?) {
        if let window { ChromeImportOverlay.show(in: window) }
    }

    @objc func newTab(_ sender: Any?) {
        let tab = Tab(url: nil)
        store.insert(tab, at: store.items.count, in: nil)
        select(tab)
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = store.selected { close(tab) }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = store.recentlyClosed.popLast() else { return }
        let tab = Tab(url: closed.url, title: closed.title)
        tab.savedState = closed.state
        tab.faviconPNG = closed.icon
        tab.favicon = closed.icon.flatMap(Favicons.image(fromPNG:))
        if let group = store.groups.first(where: { $0.id == closed.groupID }) {
            store.insert(tab, at: group.tabs.count, in: group)
        } else {
            store.insert(tab, at: store.items.count, in: nil)
        }
        select(tab)
    }

    @objc func selectNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    private func selectTab(offset: Int) {
        let tabs = store.allTabs
        guard let current = store.selected, let i = tabs.firstIndex(of: current), tabs.count > 1 else { return }
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }

    /// ⌘1–⌘8 pick that tab; ⌘9 picks the last one.
    @objc func selectTabNumber(_ sender: NSMenuItem) {
        let tabs = store.allTabs
        if sender.tag == 9, let last = tabs.last { select(last); return }
        if sender.tag - 1 < tabs.count { select(tabs[sender.tag - 1]) }
    }

    @objc func selectTabItem(_ sender: NSMenuItem) {
        if let tab = sender.representedObject as? Tab { select(tab) }
    }

    @objc func addTabToNewGroup(_ sender: Any?) {
        guard let tab = store.selected else { return }
        sidebarEditGroup(store.makeGroup(with: tab), anchor: nil)
    }

    @objc func togglePinCurrentTab(_ sender: Any?) {
        if let tab = store.selected { store.setPinned(tab, !tab.pinned) }
    }

    /// The group of the tab you're on (or the first group).
    private var currentGroup: TabGroup? { store.selected?.group ?? store.groups.first }

    @objc func newTabInCurrentGroup(_ sender: Any?) {
        guard let group = store.selected?.group else { NSSound.beep(); return }
        sidebarNewTab(in: group)
    }

    @objc func closeCurrentGroup(_ sender: Any?) {
        guard let group = store.selected?.group else { NSSound.beep(); return }
        closeGroup(group, keepSaved: true)
    }

    /// ⌥1–⌥8 pick that tab inside the current group; ⌥9 picks its last tab.
    @objc func selectGroupTabNumber(_ sender: NSMenuItem) {
        guard let tabs = currentGroup?.tabs, !tabs.isEmpty else { NSSound.beep(); return }
        if sender.tag == 9, let last = tabs.last { select(last); return }
        if sender.tag - 1 < tabs.count { select(tabs[sender.tag - 1]) } else { NSSound.beep() }
    }

    @objc func openTools(_ sender: Any?) {
        if let window { ToolsOverlay.show(in: window) }
    }

    /// Chrome's ⋮ menu.
    @objc func showMainMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }
        add("New Tab", #selector(newTab(_:)), "t")
        add("New Window", #selector(AppDelegate.newWindow(_:)), "n")
        add("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift])
        menu.addItem(.separator())
        add("History", #selector(showHistory(_:)), "y")
        add("Downloads", #selector(showDownloads(_:)), "j", [.command, .shift])
        add("Passwords", #selector(openPasswords(_:)), "p", [.command, .option])
        add("Bookmark This Page…", #selector(bookmarkThisPage(_:)), "d")
        add("Extensions…", #selector(importFromChrome(_:)))
        add("Import from Chrome…", #selector(importFromChrome(_:)))
        menu.addItem(.separator())
        add("Find…", #selector(findInPage(_:)), "f")
        add("Print…", #selector(printPage(_:)), "p")
        add("Zoom In", #selector(zoomInPage(_:)), "=")
        add("Zoom Out", #selector(zoomOutPage(_:)), "-")
        add("Tools", #selector(openTools(_:)))
        menu.addItem(.separator())
        add("Page Info", #selector(showPageInfo(_:)))
        add("Settings", #selector(openSettings(_:)), ",")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func showSiteInfo(_ sender: Any?) {
        guard let webView = store.selected?.webView else { NSSound.beep(); return }
        SiteInfoPanel.show(for: webView, below: toolbar.siteButton)
    }

    @objc func openSettings(_ sender: Any?) {
        if let window { SettingsOverlay.show(in: window) }
    }

    @objc func showHistory(_ sender: Any?) {
        guard let window else { return }
        HistoryOverlay.show(in: window) { [weak self] url in self?.openInNewTab(url, background: false) }
    }

    @objc func showDownloads(_ sender: Any?) {
        if let window { DownloadsOverlay.show(in: window) }
    }

    @objc func findInPage(_ sender: Any?) {
        guard store.selected?.webView != nil else { NSSound.beep(); return }
        findBar.open()
    }

    @objc func findNext(_ sender: Any?) {
        if findBar.isHidden { findInPage(sender) } else { findBar.find() }
    }

    @objc func findPrevious(_ sender: Any?) {
        if findBar.isHidden { findInPage(sender) } else { findBar.find(backwards: true) }
    }

    @objc func printPage(_ sender: Any?) {
        guard let webView = store.selected?.webView, let window else { NSSound.beep(); return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func duplicateTab(_ sender: Any?) {
        guard let tab = store.selected, let url = tab.webView?.url ?? tab.url else { return }
        let copy = Tab(url: url, title: tab.title)
        copy.favicon = tab.favicon
        copy.faviconPNG = tab.faviconPNG
        copy.savedState = tab.webView?.interactionState ?? tab.savedState
        store.insert(copy, after: tab)
        select(copy)
    }

    @objc func copyPageAddress(_ sender: Any?) {
        guard let url = store.selected?.displayURL else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: Moving tabs between windows

    /// Hands a tab over to another window (keeping its page open).
    func giveAway(_ tab: Tab) {
        let wasSelected = tab === store.selected
        let index = store.allTabs.firstIndex(of: tab) ?? 0
        tab.webView?.removeFromSuperview()
        store.remove(tab)
        let remaining = store.allTabs
        if remaining.isEmpty {
            window?.performClose(nil)
        } else if wasSelected {
            select(remaining[min(index, remaining.count - 1)])
        }
    }

    func sidebarMoveTab(id: UUID, to group: TabGroup?, index: Int, pinned: Bool) {
        guard let found = AppDelegate.shared.findTab(id) else { return }
        let (tab, source) = found
        if source === self {
            tab.pinned = pinned
            store.move(tab, to: group, index: index)
            return
        }
        guard source.isPrivate == isPrivate else { NSSound.beep(); return }   // private tabs stay private
        source.giveAway(tab)
        tab.pinned = pinned
        store.insert(tab, at: index, in: group)
        if let webView = tab.webView { install(webView, for: tab) }
        window?.makeKeyAndOrderFront(nil)
        select(tab)
    }

    func sidebarMoveGroup(id: UUID, to index: Int) {
        guard let found = AppDelegate.shared.findGroup(id) else { return }
        let (group, source) = found
        if source === self {
            store.move(group, to: index)
            return
        }
        guard source.isPrivate == isPrivate else { NSSound.beep(); return }
        let wasShowing = source.store.selected?.group === group
        source.store.take(group)
        group.tabs.forEach { $0.webView?.removeFromSuperview() }
        if source.store.allTabs.isEmpty {
            source.window?.performClose(nil)
        } else if wasShowing, let next = source.store.allTabs.first {
            source.select(next)
        }
        store.adopt(group, at: index)
        group.tabs.forEach { if let webView = $0.webView { install(webView, for: $0) } }
        window?.makeKeyAndOrderFront(nil)
        if let first = group.tabs.first { select(first) }
    }

    /// Dragging a tab out of every window opens it in a new window there, like Chrome.
    func sidebarTearOff(id: UUID, at screenPoint: NSPoint) {
        let overAWindow = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
        guard !overAWindow, let found = AppDelegate.shared.findTab(id), found.1 === self,
              store.allTabs.count > 1 else { return }
        let tab = found.0
        giveAway(tab)
        tab.pinned = false
        let controller = BrowserWindowController(session: nil, adoptingTab: tab, isPrivate: isPrivate)
        AppDelegate.shared.open(controller)
        controller.window?.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 120, y: screenPoint.y + 20))
    }

    @objc func openPasswords(_ sender: Any?) {
        if let window { PasswordsOverlay.show(in: window) }
    }

    @objc func searchTabs(_ sender: Any?) { sidebarSearchTabs() }

    @objc func toggleSidebar(_ sender: Any?) { sidebarToggleCollapse() }

    private var sidebarHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "sidebarHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarHidden") }
    }

    private func applySidebarVisibility() {
        let hidden = sidebarHidden
        sidebar.view.isHidden = hidden
        resizeHandle.isHidden = hidden
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        sidebarWidth.constant = hidden ? 0 : (saved > 0 ? saved : 250)
        toolbar.sidebarButton.isHidden = !hidden
    }

    @objc func goBack(_ sender: Any?) { store.selected?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { store.selected?.webView?.goForward() }

    @objc func reloadPage(_ sender: Any?) {
        guard let tab = store.selected else { return }
        if let failed = tab.failedURL { load(failed) } else { tab.webView?.reload() }
    }

    @objc func reloadOrStop(_ sender: Any?) {
        if let webView = store.selected?.webView, webView.isLoading { webView.stopLoading() } else { reloadPage(sender) }
    }

    @objc func zoomInPage(_ sender: Any?) { if let w = store.selected?.webView { w.pageZoom = min(w.pageZoom + 0.1, 3) } }
    @objc func zoomOutPage(_ sender: Any?) { if let w = store.selected?.webView { w.pageZoom = max(w.pageZoom - 0.1, 0.3) } }
    /// ⌘0: back to normal size, undoing both ⌘+/⌘- zoom and trackpad pinch-zoom.
    @objc func actualSize(_ sender: Any?) {
        store.selected?.webView?.pageZoom = 1
        store.selected?.webView?.magnification = 1
    }

    /// Numbers that help track down display problems (like blurry text).
    @objc func showPageInfo(_ sender: Any?) {
        guard let webView = store.selected?.webView, let window else { NSSound.beep(); return }
        let js = "[window.devicePixelRatio, window.innerWidth, (window.visualViewport ? window.visualViewport.scale : 1), window.outerWidth].join(',')"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            let parts = ((result as? String) ?? "?,?,?").split(separator: ",").map(String.init)
            let alert = NSAlert()
            alert.messageText = "Page Info"
            alert.informativeText = """
            Screen sharpness (window): \(window.backingScaleFactor)x
            Screen sharpness (page sees): \(parts.first ?? "?")x
            Pinch-zoom: \(String(format: "%.2f", webView.magnification))x
            Page zoom (⌘+/⌘-): \(String(format: "%.2f", webView.pageZoom))x
            Page pinch scale: \(parts.count > 2 ? parts[2] : "?")
            Page width: \(parts.count > 1 ? parts[1] : "?") points (window width the page sees: \(parts.count > 3 ? parts[3] : "?"))
            Arc-style background: \(Theme.arcStyle ? "on" : "off")
            """
            self?.present(alert) { _ in }
        }
    }

    // MARK: Bookmarks

    @objc func bookmarkThisPage(_ sender: Any?) {
        guard let tab = store.selected, let url = tab.url, url.absoluteString != "about:blank" else {
            NSSound.beep()
            return
        }
        let bookmarks = BookmarkStore.shared
        if let existing = bookmarks.bookmark(for: url) {
            BookmarkEditor.edit(existing, in: window, isNew: false)
        } else {
            let node = BookmarkNode(title: tab.displayTitle, url: url)
            node.icon = tab.faviconPNG
            bookmarks.add(node, to: bookmarks.bar)
            BookmarkEditor.edit(node, in: window, isNew: true)
        }
    }

    /// Bookmarks open in the current tab only if it's a blank new tab; otherwise in a new tab
    /// (a tab's address is never changed by typing or picking something else).
    @objc func openBookmarkItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode, let url = node.url else { return }
        if let tab = store.selected, isBlank(tab) {
            load(url)
        } else {
            openInNewTab(url, background: NSEvent.modifierFlags.contains(.command))
        }
    }

    @objc func openBookmarkInNewTab(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode, let url = node.url else { return }
        openInNewTab(url, background: false)
    }

    @objc func openAllBookmarks(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? BookmarkNode else { return }
        var after = store.selected
        for node in folder.children ?? [] {
            guard let url = node.url else { continue }
            let tab = Tab(url: url, title: node.title)
            store.insert(tab, after: after)
            after = tab
        }
    }

    @objc func editBookmarkItem(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? BookmarkNode { BookmarkEditor.edit(node, in: window, isNew: false) }
    }

    @objc func deleteBookmarkItem(_ sender: NSMenuItem) {
        if let node = sender.representedObject as? BookmarkNode { BookmarkStore.shared.remove(node) }
    }

    @objc func newBookmarkFolder(_ sender: Any?) {
        let folder = BookmarkNode(folder: "New Folder")
        BookmarkStore.shared.add(folder, to: BookmarkStore.shared.bar)
        BookmarkEditor.edit(folder, in: window, isNew: false)
    }

    @objc func importChromeBookmarks(_ sender: Any?) { importFromChrome(sender) }

    @objc func toggleBookmarksBar(_ sender: Any?) {
        showsBookmarksBar.toggle()
        barHeight.constant = showsBookmarksBar ? BookmarksBarView.height : 0
        bookmarksBar.isHidden = !showsBookmarksBar
    }

    // MARK: Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return store.selected?.webView?.canGoBack ?? false
        case #selector(goForward(_:)): return store.selected?.webView?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !store.recentlyClosed.isEmpty
        case #selector(printPage(_:)), #selector(findInPage(_:)), #selector(copyPageAddress(_:)):
            return store.selected?.webView != nil
        case #selector(duplicateTab(_:)):
            return store.selected?.url != nil
        case #selector(togglePinCurrentTab(_:)):
            item.title = store.selected?.pinned == true ? "Unpin Tab" : "Pin Tab"
            return store.selected != nil
        case #selector(newTabInCurrentGroup(_:)), #selector(closeCurrentGroup(_:)):
            return store.selected?.group != nil
        case #selector(toggleBookmarksBar(_:)):
            item.title = showsBookmarksBar ? "Hide Groups Bar" : "Show Groups Bar"
            return true
        default: return true
        }
    }

    // Esc in the address bar puts back the current page's address.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === toolbar.addressField, selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        toolbar.showAddress(store.selected?.displayURL)
        if let webView = store.selected?.webView { window?.makeFirstResponder(webView) }
        return true
    }

    // MARK: Sidebar requests

    func sidebarSelect(_ tab: Tab) { select(tab) }
    func sidebarClose(_ tab: Tab) { close(tab) }

    func sidebarCloseOthers(_ tab: Tab) {
        for other in store.allTabs where other !== tab && !other.pinned { close(other) }
        select(tab)
    }

    func sidebarTogglePin(_ tab: Tab) { store.setPinned(tab, !tab.pinned) }
    func sidebarOpenTools() { openTools(nil) }

    func sidebarToggleCollapse() {
        sidebarHidden.toggle()
        applySidebarVisibility()
    }

    /// The grid button: every tab group (open and closed), like Chrome's.
    func sidebarShowGroups(anchor: NSView) {
        let menu = NSMenu()
        let open = store.groups
        let closed = GroupLibrary.shared.closed
        if open.isEmpty && closed.isEmpty {
            let none = NSMenuItem(title: "No tab groups yet. Right-click a tab → Add Tab to New Group.", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for group in open {
            let item = NSMenuItem(title: (group.name.isEmpty ? "Unnamed group" : group.name) + "  (\(group.tabs.count))",
                                  action: #selector(selectTabItem(_:)), keyEquivalent: "")
            item.representedObject = group.tabs.first
            item.image = group.color.swatch()
            menu.addItem(item)
        }
        if !closed.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Closed groups", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for saved in closed {
                let item = NSMenuItem(title: (saved.name.isEmpty ? "Unnamed group" : saved.name) + "  (\(saved.tabs.count))",
                                      action: #selector(reopenSavedGroup(_:)), keyEquivalent: "")
                item.representedObject = saved.id
                item.image = saved.color.swatch()
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    func sidebarSearchTabs() {
        guard let window else { return }
        let side = sidebar.view
        let rect = side.isHidden ? toolbar.addressField.convert(toolbar.addressField.bounds, to: nil)
                                 : side.convert(NSRect(x: 8, y: side.bounds.height - 48, width: 10, height: 10), to: nil)
        TabSearch.show(anchor: window.convertToScreen(rect), in: window)
    }

    func sidebarReload(_ tab: Tab) {
        if tab.webView == nil { select(tab) } else { tab.webView?.reload() }
    }

    func sidebarUnload(_ tab: Tab) {
        if tab === store.selected { return }   // the tab you're looking at stays loaded
        tab.unload()
        sidebar.refresh(tab)
        turnOffIfAllUnloaded(tab.group)
    }

    /// When every tab in a group has been unloaded, the group turns off by itself.
    private func turnOffIfAllUnloaded(_ group: TabGroup?) {
        guard let group, !group.isDisabled, store.selected?.group !== group,
              group.tabs.allSatisfy({ !$0.isLoaded }) else { return }
        group.isDisabled = true
        group.isCollapsed = true
        store.changed()
    }

    func sidebarNewTab(in group: TabGroup?) {
        let tab = Tab(url: nil)
        if let group { store.insert(tab, at: group.tabs.count, in: group) } else { store.insert(tab, at: store.items.count, in: nil) }
        select(tab)
    }

    /// Closes all of a group's tabs. With `keepSaved`, the group stays on the
    /// bookmarks bar (like Chrome) so you can reopen it later.
    func closeGroup(_ group: TabGroup, keepSaved: Bool) {
        if keepSaved {
            GroupLibrary.shared.add(TabStore.savedGroup(group))
        } else {
            GroupLibrary.shared.remove(id: group.id)
        }
        for tab in group.tabs { close(tab) }
    }

    func moveGroupToNewWindow(_ group: TabGroup) {
        guard store.allTabs.contains(where: { $0.group !== group }) else {
            NSSound.beep()   // it's the only thing in this window already
            return
        }
        let wasShowingGroup = store.selected?.group === group
        store.take(group)
        for tab in group.tabs { tab.webView?.removeFromSuperview() }
        AppDelegate.shared.open(BrowserWindowController(session: nil, adopting: group))
        if wasShowingGroup, let next = store.allTabs.first { select(next) }
    }

    /// Shows the Chrome-style group editor next to the group's header.
    func sidebarEditGroup(_ group: TabGroup, anchor: NSView?) {
        guard let window else { return }
        // Use the group's row on screen right now (the one you clicked, or its current row).
        var anchorView: NSView? = anchor?.window != nil ? anchor : nil
        if anchorView == nil {
            sidebar.reload()
            anchorView = sidebar.rowView(for: group)
        }
        let rect: NSRect
        if let anchorView, anchorView.window != nil {
            rect = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        } else {
            // Fallback: just below the top of the sidebar (always on screen).
            let side = sidebar.view
            rect = window.convertToScreen(side.convert(NSRect(x: 8, y: side.bounds.height - 80, width: side.bounds.width - 16, height: 28), to: nil))
        }
        GroupEditor.show(for: group, actions: self, anchor: rect, in: window)
    }

    // MARK: Saved (closed) groups

    @objc func reopenSavedGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let saved = GroupLibrary.shared.group(id: id) else { return }
        GroupLibrary.shared.remove(id: id)
        let group = TabStore.makeGroup(saved)
        group.isCollapsed = false
        store.adopt(group)
        if let first = group.tabs.first { select(first) }
    }

    @objc func deleteSavedGroup(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { GroupLibrary.shared.remove(id: id) }
    }

    // MARK: Extensions

    private func refreshExtensionButtons() {
        guard #available(macOS 15.4, *), let manager = ExtensionManager.active else {
            toolbar.setExtensionButtons([])
            return
        }
        let tab = store.selected
        // Only pinned extensions get a toolbar button; the rest are in the puzzle-piece menu.
        let pinned = manager.contexts.filter { ExtensionPins.isPinned($0.uniqueIdentifier) }
        let buttons = pinned.map { context -> ToolbarView.ExtensionButton in
            let action = context.action(for: tab)
            let size = CGSize(width: 16, height: 16)
            return ToolbarView.ExtensionButton(
                id: context.uniqueIdentifier,
                icon: action?.icon(for: size) ?? context.webExtension.icon(for: size),
                label: action?.label.isEmpty == false ? action!.label : ExtensionManager.name(of: context),
                badge: action?.badgeText ?? "")
        }
        toolbar.setExtensionButtons(buttons)
    }

    private func extensionButtonClicked(_ id: String) {
        guard #available(macOS 15.4, *),
              let context = ExtensionManager.active?.contexts.first(where: { $0.uniqueIdentifier == id }) else { return }
        ExtensionManager.allowOnClick(context, url: store.selected?.webView?.url)
        context.performAction(for: store.selected)
        refreshExtensionButtons()
    }

    @available(macOS 15.4, *)
    func showExtensionPopover(_ popover: NSPopover, for context: WKWebExtensionContext) {
        popover.appearance = Theme.appearance
        let anchor = toolbar.extensionButton(id: context.uniqueIdentifier) ?? toolbar.puzzleButton
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Opens a tab when an extension asks for one.
    func openTabForExtension(_ url: URL?, active: Bool) -> Tab {
        let tab = Tab(url: url)
        store.insert(tab, after: store.selected)
        if active || url == nil { select(tab) } else if let url { load(url, in: tab) }
        return tab
    }

    /// The puzzle-piece button: installed extensions and ways to add more.
    @objc func showExtensionsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Import from Chrome…", action: #selector(importFromChrome(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Add Extension from Folder…", action: #selector(addExtensionFolder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        ExtensionsMenuDelegate.shared.appendItems(to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func importChromeExtensions(_ sender: Any?) { importFromChrome(sender) }

    @objc func addExtensionFolder(_ sender: Any?) {
        guard #available(macOS 15.4, *) else { showNeedsNewerMac(); return }
        ExtensionInstaller.addFolder(window: window)
    }

    @objc func runExtension(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let context = sender.representedObject as? WKWebExtensionContext else { return }
        ExtensionManager.allowOnClick(context, url: store.selected?.webView?.url)
        context.performAction(for: store.selected)
    }

    @objc func setExtensionSiteAccess(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let pair = sender.representedObject as? [Any],
              let context = pair.first as? WKWebExtensionContext, let raw = pair.last as? String,
              let mode = ExtensionManager.SiteAccess(rawValue: raw) else { return }
        ExtensionManager.setSiteAccess(mode, for: context.uniqueIdentifier)
        ExtensionManager.applySiteAccess(context)
        store.selected?.webView?.reload()
    }

    @objc func togglePinExtension(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let context = sender.representedObject as? WKWebExtensionContext else { return }
        ExtensionPins.toggle(context.uniqueIdentifier)
        for controller in AppDelegate.shared.controllers { controller.refreshExtensionButtonsNow() }
    }

    func refreshExtensionButtonsNow() { refreshExtensionButtons() }

    @objc func openExtensionOptions(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let context = sender.representedObject as? WKWebExtensionContext,
              let url = context.optionsPageURL else { NSSound.beep(); return }
        openInNewTab(url, background: false)
    }

    @objc func showExtensionDetails(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let context = sender.representedObject as? WKWebExtensionContext else { return }
        let alert = NSAlert()
        alert.messageText = ExtensionManager.name(of: context)
        let warnings = ExtensionManager.warnings(of: context)
        alert.informativeText = warnings.isEmpty
            ? "Loaded with no problems reported."
            : "Loaded, but WebKit reported these problems (the parts mentioned may not work):\n\n• " + warnings.joined(separator: "\n• ")
        present(alert) { _ in }
    }

    @objc func removeExtension(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let context = sender.representedObject as? WKWebExtensionContext else { return }
        ExtensionManager.shared.remove(context)
    }

    private func showNeedsNewerMac() {
        let alert = NSAlert()
        alert.messageText = "Extensions need macOS 15.4 or newer"
        alert.informativeText = "Update macOS in System Settings → General → Software Update to use extensions."
        present(alert) { _ in }
    }

    // MARK: Window

    // In full screen the red/yellow/green buttons are hidden, so use that space.
    func windowWillEnterFullScreen(_ notification: Notification) { toolbar.leadingInset = 12 }

    func windowDidBecomeKey(_ notification: Notification) { ExtensionEvents.windowFocused(self) }

    func windowWillClose(_ notification: Notification) {
        unloadTimer?.invalidate()
        GroupEditor.closeAny()
        Overlay.closeCurrent()
        AppDelegate.shared.windowDidClose(self)
    }
    func windowWillExitFullScreen(_ notification: Notification) { toolbar.leadingInset = 78 }

    // MARK: Page loading

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            let host = navigationAction.request.url?.host ?? webView.url?.host ?? ""
            decisionHandler(SitePermissions.get(.downloads, host) == .block ? .cancel : .download)
            return
        }
        // Links that open another app (zoom:, mailto:, slack:, …): ask first, like Chrome.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file", "webkit-extension", "javascript"].contains(scheme) {
            decisionHandler(.cancel)
            confirmExternalApp(url, from: webView.url?.host)
            return
        }
        // HTTPS-first: always try the secure version of a site before an insecure one.
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url,
           let secure = Security.secureVersion(of: url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: secure))
            return
        }
        // ⌘-click or middle-click a link: open it in a new tab (⇧⌘-click switches to it).
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2,
           let url = navigationAction.request.url {
            openInNewTab(url, background: !navigationAction.modifierFlags.contains(.shift), after: store.tab(for: webView))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func confirmExternalApp(_ url: URL, from host: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url), let window else { return }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let key = "allowedApps.\(host ?? "")"
        if (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open \(appName)?"
        alert.informativeText = "\(host ?? "This page") wants to open the \(appName) app."
        alert.addButton(withTitle: "Open \(appName)")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow \(host ?? "this site") to open this kind of link"
        alert.beginSheetModal(for: window) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on, let scheme = url.scheme {
                UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []) + [scheme], forKey: key)
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// Files the browser can't show (zips, installers, "download" links) are saved to Downloads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || (navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")) {
            // Downloads can be blocked per site (site info panel → Automatic downloads).
            let host = webView.url?.host ?? navigationResponse.response.url?.host ?? ""
            decisionHandler(SitePermissions.get(.downloads, host) == .block ? .cancel : .download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = store.tab(for: webView) else { return }
        tab.errorMessage = nil
        if tab === store.selected { errorView.isHidden = true }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = store.tab(for: webView) else { return }
        tab.failedURL = nil
        tab.errorMessage = nil
        if tab.faviconHost != webView.url?.host {
            tab.favicon = nil
            tab.faviconPNG = nil
            tab.faviconHost = nil
            sidebar.refresh(tab)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = store.tab(for: webView) else { return }
        if logLoads {   // used by the automatic test
            let address = webView.url?.absoluteString ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak webView] in
                webView?.evaluateJavaScript("document.title + ' | dpr ' + window.devicePixelRatio + ', outerWidth ' + window.outerWidth + ', innerWidth ' + window.innerWidth") { title, _ in
                    let text = (title as? String) ?? ""
                    NSLog("MyBrowser loaded: %@ — title: %@ (window scale %.1f)", address,
                          String(text.split(separator: "|").first ?? "").trimmingCharacters(in: .whitespaces),
                          webView?.window?.backingScaleFactor ?? 0)
                    NSLog("MyBrowser page sharpness: %@", String(text.split(separator: "|").last ?? ""))
                }
            }
        }
        if tab === store.selected { refreshExtensionButtons() }
        if !isPrivate, let url = webView.url { HistoryStore.shared.record(url, title: webView.title ?? "") }
        Favicons.fetch(for: tab, in: webView) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.sidebar.refresh(tab)
            self.store.scheduleSave()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        // Ignore "cancelled" (you clicked stop or a new link) and
        // "interrupted" (a file download — handled in stage 5).
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        guard let tab = store.tab(for: webView) else { return }
        tab.failedURL = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? tab.failedURL
        tab.errorMessage = e.localizedDescription
        if Security.insecureFallback(for: tab.failedURL) != nil {
            tab.errorMessage = "This site doesn't support a secure (encrypted) connection, so it wasn't opened.\nOnly continue if you trust it — anyone on your network could see or change what you send."
        }
        if logLoads { NSLog("MyBrowser failed: %@", e.localizedDescription) }
        if tab === store.selected { updateToolbar() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A page crashed or was killed by macOS to save memory: reload it if you're looking at it.
        if let tab = store.tab(for: webView), tab === store.selected { webView.reload() }
    }

    // MARK: Page requests (new windows, alerts, file pickers)

    /// Links and pop-ups that want a new window open as a new tab instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let source = store.tab(for: webView)
        if navigationAction.modifierFlags.contains(.command), let url = navigationAction.request.url {
            openInNewTab(url, background: !navigationAction.modifierFlags.contains(.shift), after: source)
            return nil
        }
        let tab = Tab(url: navigationAction.request.url)
        let newWebView = WebKitEnvironment.makeWebView(configuration: configuration)
        install(newWebView, for: tab)
        store.insert(tab, after: source)
        select(tab)
        return newWebView
    }

    /// WebKit asks this to fill in `window.outerWidth/outerHeight` for pages. Without an
    /// answer they're 0, and Google Docs/Sheets/Slides then draw their text at a fraction of
    /// your screen's sharpness (blurry). We answer with the page's own area (plus a toolbar's
    /// height), so pages also don't mistake the sidebar for browser zoom.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        guard let window = webView.window else { completionHandler(.zero); return }
        var frame = window.convertToScreen(webView.convert(webView.bounds, to: nil))
        frame.size.height += 80
        completionHandler(frame)
    }

    /// A site wants the camera and/or microphone: follow your choice for that site, or ask.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kinds: [PermissionKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        askPermission(kinds, host: origin.host, decisionHandler: decisionHandler)
    }

    /// A site wants your location (WebKit asks apps through this hidden hook).
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webViewRequestsLocation(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        askPermission([.location], host: origin.host, decisionHandler: decisionHandler)
    }

    private func askPermission(_ kinds: [PermissionKind], host: String,
                               decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let values = kinds.map { SitePermissions.get($0, host) }
        if values.contains(.block) { decisionHandler(.deny); return }
        if values.allSatisfy({ $0 == .allow }) { decisionHandler(.grant); return }
        let alert = NSAlert()
        alert.messageText = "\(host) wants to use your \(kinds.map { $0.title.lowercased() }.joined(separator: " and "))"
        alert.informativeText = "Your choice is remembered for this site. Change it any time with the button at the left of the address."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        present(alert) { response in
            let value: PermissionValue = response == .alertFirstButtonReturn ? .allow : .block
            kinds.forEach { SitePermissions.set($0, host, value) }
            decisionHandler(value == .allow ? .grant : .deny)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = store.tab(for: webView) { close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(prompt, frame)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func makeAlert(_ message: String, _ frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host.map { "\($0) says:" } ?? "This page says:"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
