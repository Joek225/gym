import AppKit
import WebKit

/// The browser window: toolbar and bookmarks bar on top, tab sidebar on the left,
/// and the current page on the right.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                     NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate,
                                     SidebarDelegate {
    /// Tabs you haven't looked at for this long are unloaded to free memory.
    static let unloadAfter: TimeInterval = 5 * 60

    private let store: TabStore
    private let sidebar: SidebarController
    private let toolbar = ToolbarView()
    private let bookmarksBar = BookmarksBarView()
    private let resizeHandle = ResizeHandle()
    private let webContainer = SolidView(color: Theme.background)
    private let errorView = ErrorView()
    private var sidebarWidth: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    private var unloadTimer: Timer?
    private let logLoads = CommandLine.arguments.contains("--log-loads")

    private var showsBookmarksBar: Bool {
        get { UserDefaults.standard.object(forKey: "showBookmarksBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showBookmarksBar") }
    }

    init() {
        let store = TabStore()
        self.store = store
        self.sidebar = SidebarController(store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.toolbar
        window.tabbingMode = .disallowed        // tabs live in our sidebar instead
        window.minSize = NSSize(width: 600, height: 360)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self

        buildLayout(in: window)
        wireUp()

        store.restore()
        if store.allTabs.isEmpty { store.insert(Tab(url: nil), at: 0, in: nil) }
        sidebar.reload()
        bookmarksBar.reload()
        select(store.selected ?? store.allTabs[0])
        startUnloadTimer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func saveSession() { store.saveNow() }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        let content = SolidView(color: Theme.toolbar)
        window.contentView = content
        let side = sidebar.view

        for v in [toolbar, bookmarksBar, side, webContainer, errorView, resizeHandle] as [NSView] {
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
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            errorView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

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
        toolbar.addressField.target = self
        toolbar.addressField.action = #selector(addressEntered(_:))
        toolbar.addressField.delegate = self

        sidebar.delegate = self
        store.onChange = { [weak self] in
            self?.sidebar.reload()
            self?.bookmarksBar.reload()
        }
        bookmarksBar.groups = { [weak self] in self?.store.groups ?? [] }

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
                self?.updateToolbar()
            }
        }
    }

    // MARK: Tabs

    var selectedTab: Tab? { store.selected }

    func select(_ tab: Tab) {
        if let old = store.selected, old !== tab { old.lastActive = Date() }
        store.selected = tab
        tab.lastActive = Date()
        if let group = tab.group, group.isCollapsed { group.isCollapsed = false }   // like Chrome
        if tab.webView == nil, tab.url != nil || tab.savedState != nil { wake(tab) }
        show(tab)
        sidebar.reload()
        updateToolbar()
        store.scheduleSave()
        if tab.webView == nil {
            focusAddressBar(nil)
        } else {
            window?.makeFirstResponder(tab.webView)
        }
    }

    /// Puts the tab's page in the content area.
    private func show(_ tab: Tab) {
        for view in webContainer.subviews where view !== tab.webView { view.removeFromSuperview() }
        if let webView = tab.webView, webView.superview !== webContainer {
            webView.frame = webContainer.bounds
            webView.autoresizingMask = [.width, .height]
            webContainer.addSubview(webView)
        }
    }

    /// Re-creates an unloaded tab's page (restoring its back/forward history).
    private func wake(_ tab: Tab) {
        let webView = WebKitEnvironment.makeWebView()
        install(webView, for: tab)
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
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIdleTabs() }
        }
        unloadTimer?.tolerance = 10
    }

    private func unloadIdleTabs() {
        let now = Date()
        for tab in store.allTabs where tab !== store.selected && tab.isLoaded
            && now.timeIntervalSince(tab.lastActive) > Self.unloadAfter {
            guard let webView = tab.webView,
                  webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { continue }
            // Never unload a tab that's playing sound or video.
            webView.requestMediaPlaybackState { [weak self, weak tab] state in
                guard let self, let tab, state != .playing, tab !== self.store.selected else { return }
                tab.unload()
                self.sidebar.refresh(tab)
            }
        }
    }

    // MARK: Toolbar

    private func updateToolbar() {
        guard let tab = store.selected else { return }
        let webView = tab.webView
        toolbar.backButton.isEnabled = webView?.canGoBack ?? false
        toolbar.forwardButton.isEnabled = webView?.canGoForward ?? false
        toolbar.setLoading(webView?.isLoading ?? false)
        toolbar.setStarred(BookmarkStore.shared.isBookmarked(tab.url))
        if !isEditingAddress { toolbar.addressField.stringValue = tab.displayURL?.absoluteString ?? "" }
        window?.title = tab.displayTitle
        if let message = tab.errorMessage {
            errorView.show(message: message, address: tab.failedURL?.host ?? "")
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
        tab.errorMessage = nil
        tab.failedURL = nil
        tab.savedState = nil
        if tab.webView == nil {
            install(WebKitEnvironment.makeWebView(), for: tab)
            show(tab)
        }
        tab.url = url
        if url.isFileURL {
            tab.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView?.load(URLRequest(url: url))
        }
        updateToolbar()
        sidebar.refresh(tab)
    }

    @objc func addressEntered(_ sender: NSTextField) {
        guard let url = AddressParser.url(from: sender.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(store.selected?.webView)
    }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(toolbar.addressField)
        toolbar.addressField.currentEditor()?.selectAll(nil)
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
        sidebarEditGroup(store.makeGroup(with: tab))
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
    @objc func actualSize(_ sender: Any?) { store.selected?.webView?.pageZoom = 1 }

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
            bookmarks.add(node, to: bookmarks.bar)
            BookmarkEditor.edit(node, in: window, isNew: true)
        }
    }

    @objc func openBookmarkItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode, let url = node.url else { return }
        if NSEvent.modifierFlags.contains(.command) {
            openInNewTab(url, background: true)
        } else {
            load(url)
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

    @objc func importChromeBookmarks(_ sender: Any?) { ChromeImporter.run(window: window) }

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
        case #selector(toggleBookmarksBar(_:)):
            item.title = showsBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar"
            return true
        default: return true
        }
    }

    // Esc in the address bar puts back the current page's address.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === toolbar.addressField, selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        toolbar.addressField.stringValue = store.selected?.displayURL?.absoluteString ?? ""
        if let webView = store.selected?.webView { window?.makeFirstResponder(webView) }
        return true
    }

    // MARK: Sidebar requests

    func sidebarSelect(_ tab: Tab) { select(tab) }
    func sidebarClose(_ tab: Tab) { close(tab) }

    func sidebarCloseOthers(_ tab: Tab) {
        for other in store.allTabs where other !== tab { close(other) }
        select(tab)
    }

    func sidebarReload(_ tab: Tab) {
        if tab.webView == nil { select(tab) } else { tab.webView?.reload() }
    }

    func sidebarUnload(_ tab: Tab) {
        if tab === store.selected { return }   // the tab you're looking at stays loaded
        tab.unload()
        sidebar.refresh(tab)
    }

    func sidebarNewTab(in group: TabGroup?) {
        let tab = Tab(url: nil)
        if let group { store.insert(tab, at: group.tabs.count, in: group) } else { store.insert(tab, at: store.items.count, in: nil) }
        select(tab)
    }

    func sidebarCloseGroup(_ group: TabGroup) {
        for tab in group.tabs { close(tab) }
    }

    /// Chrome-style box for naming a group and choosing its color.
    func sidebarEditGroup(_ group: TabGroup) {
        let alert = NSAlert()
        alert.messageText = "Tab Group"
        alert.informativeText = "Name the group and pick a color."
        let field = NSTextField(string: group.name)
        field.placeholderString = "Name this group"
        let popup = NSPopUpButton()
        for color in GroupColor.allCases {
            popup.addItem(withTitle: color.name)
            popup.lastItem?.image = color.swatch()
        }
        popup.selectItem(at: GroupColor.allCases.firstIndex(of: group.color) ?? 0)
        let stack = NSStackView(views: [field, popup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            group.name = field.stringValue
            group.color = GroupColor.allCases[max(0, popup.indexOfSelectedItem)]
            self?.store.changed()
        }
    }

    // MARK: Window

    // In full screen the red/yellow/green buttons are hidden, so use that space.
    func windowWillEnterFullScreen(_ notification: Notification) { toolbar.leadingInset = 12 }
    func windowWillExitFullScreen(_ notification: Notification) { toolbar.leadingInset = 78 }

    // MARK: Page loading

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // ⌘-click a link: open it in a new tab (⇧⌘-click switches to it).
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url {
            openInNewTab(url, background: !navigationAction.modifierFlags.contains(.shift), after: store.tab(for: webView))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
        if logLoads {
            NSLog("MyBrowser loaded: %@ — %@", webView.url?.absoluteString ?? "", webView.title ?? "")
        }
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
