import AppKit
import WebKit

/// Settings (⌘,): colors and themes, search engine, memory options, default browser.
@MainActor
enum SettingsOverlay {
    static func show(in window: NSWindow) {
        Overlay.show(title: "Settings", content: SettingsView(), size: NSSize(width: 620, height: 700), in: window)
    }
}

final class SettingsView: NSView {
    private let restartNote = NSTextField(labelWithString: "")
    private let searchPopup = NSPopUpButton()
    private let unloadPopup = NSPopUpButton()
    private let adsBox = NSButton(checkboxWithTitle: "Block ads and trackers (makes pages lighter)", target: nil, action: nil)
    private let memoryBox = NSButton(checkboxWithTitle: "Show memory use in the toolbar", target: nil, action: nil)
    private let groupsPopup = NSPopUpButton()
    private let groupChoices: [(String, Int)] = [("10 minutes", 10), ("30 minutes", 30), ("1 hour", 60),
                                                 ("3 hours", 180), ("Never", 0)]
    private let unloadChoices: [(String, Int)] = [("1 minute", 1), ("3 minutes", 3), ("5 minutes", 5),
                                                  ("10 minutes", 10), ("30 minutes", 30), ("Never", 0)]

    init() {
        super.init(frame: .zero)

        // Accent: the four colors from your calendar.
        let swatches = NSStackView(views: ThemeColors.Accent.allCases.map { accent in
            let b = NSButton(title: accent.name, image: Self.swatch(accent.color, chosen: accent == ThemeColors.accentChoice),
                             target: self, action: #selector(accentChosen(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(accent.rawValue)
            b.isBordered = false
            b.imagePosition = .imageAbove
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = Theme.text
            return b
        })
        swatches.spacing = 18
        restartNote.textColor = Theme.accent
        restartNote.font = .systemFont(ofSize: 12)

        // Browsing
        Preferences.SearchEngine.allCases.forEach { searchPopup.addItem(withTitle: $0.rawValue) }
        searchPopup.selectItem(withTitle: Preferences.searchEngine.rawValue)
        searchPopup.target = self
        searchPopup.action = #selector(searchChanged(_:))

        // Memory
        unloadChoices.forEach { unloadPopup.addItem(withTitle: $0.0) }
        unloadPopup.selectItem(at: unloadChoices.firstIndex { $0.1 == Preferences.unloadMinutes } ?? 2)
        unloadPopup.target = self
        unloadPopup.action = #selector(unloadChanged(_:))
        adsBox.state = Preferences.blocksAds ? .on : .off
        adsBox.target = self
        adsBox.action = #selector(adsChanged(_:))
        memoryBox.state = Preferences.showsMemory ? .on : .off
        memoryBox.target = self
        memoryBox.action = #selector(memoryChanged(_:))

        groupChoices.forEach { groupsPopup.addItem(withTitle: $0.0) }
        groupsPopup.selectItem(at: groupChoices.firstIndex { $0.1 == Preferences.disableGroupsMinutes } ?? 1)
        groupsPopup.target = self
        groupsPopup.action = #selector(groupsChanged(_:))

        let clearButton = button("Clear Browsing Data…", #selector(clearDataClicked(_:)))
        let touchBox = toggle("Ask for Touch ID before filling a saved password", "touchID", Preferences.touchIDBeforeFill)
        let quitBox = toggle("Delete cookies, site data and history every time I quit", "clearOnQuit", Preferences.clearOnQuit)
        let devBox = toggle("Developer tools (right-click → Inspect Element; for new tabs)", "devTools", Preferences.developerTools)

        let defaultButton = button("Make beababrowser Your Default Browser", #selector(defaultClicked(_:)))

        let stack = NSStackView(views: [
            heading("Accent color"), swatches,
            heading("Search"), row("Search with", searchPopup),
            heading("Memory"), row("Unload tabs I haven't used for", unloadPopup),
            row("Turn off groups I haven't used for", groupsPopup), adsBox, memoryBox,
            heading("Privacy & security"), securityNote(), touchBox, quitBox, devBox, clearButton, restartNote,
            heading("Default browser"), defaultButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for h in stack.arrangedSubviews where (h as? NSTextField)?.font?.pointSize == 15 {
            stack.setCustomSpacing(6, after: h)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = Theme.text
        return l
    }

    private func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textColor = Theme.text
        return l
    }

    private func row(_ text: String, _ control: NSView) -> NSStackView {
        let r = NSStackView(views: [label(text), control])
        r.spacing = 8
        return r
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private static func swatch(_ color: NSColor, chosen: Bool) -> NSImage {
        NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            if chosen {
                Theme.text.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            return true
        }
    }

    @objc private func accentChosen(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let accent = ThemeColors.Accent(rawValue: raw),
              accent != ThemeColors.accentChoice else { return }
        ThemeColors.accentChoice = accent
        AppDelegate.shared.rebuildWindows(thenShowSettings: true)   // applies straight away
    }

    @objc private func groupsChanged(_ sender: NSPopUpButton) {
        Preferences.disableGroupsMinutes = groupChoices[max(0, sender.indexOfSelectedItem)].1
    }

    private func toggle(_ title: String, _ id: String, _ on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
        box.identifier = NSUserInterfaceItemIdentifier(id)
        box.state = on ? .on : .off
        return box
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.identifier?.rawValue {
        case "touchID": Preferences.touchIDBeforeFill = on
        case "clearOnQuit": Preferences.clearOnQuit = on
        case "devTools": Preferences.developerTools = on
        default: break
        }
    }

    private func securityNote() -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: "Always on: warnings for scam and malware sites, secure (https) connections first, ad and tracker blocking, cross-site tracking protection, passwords kept in your Keychain, and a check before downloading files that can run programs, downloads marked so macOS checks them before they open, extensions that only work where you allow them, a question before a site opens another app, and passwords that are only filled after you click into the box.")
        note.textColor = Theme.mutedText
        note.font = .systemFont(ofSize: 12)
        note.preferredMaxLayoutWidth = 560
        return note
    }

    @objc private func clearDataClicked(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear browsing data"
        alert.informativeText = "Choose what to delete from all time."
        let history = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
        let cookies = NSButton(checkboxWithTitle: "Cookies and site data (signs you out of sites)", target: nil, action: nil)
        let cache = NSButton(checkboxWithTitle: "Cached images and files", target: nil, action: nil)
        [history, cache].forEach { $0.state = .on }
        let stack = NSStackView(views: [history, cookies, cache])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if history.state == .on { HistoryStore.shared.clear() }
            var types = Set<String>()
            if cookies.state == .on { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes()) }
            if cache.state == .on { types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) }
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
                self?.restartNote.stringValue = "Cleared."
            }
        }
    }

    @objc private func searchChanged(_ sender: NSPopUpButton) {
        if let engine = Preferences.SearchEngine(rawValue: sender.titleOfSelectedItem ?? "") { Preferences.searchEngine = engine }
    }

    @objc private func unloadChanged(_ sender: NSPopUpButton) {
        Preferences.unloadMinutes = unloadChoices[max(0, sender.indexOfSelectedItem)].1
    }

    @objc private func adsChanged(_ sender: NSButton) {
        Preferences.blocksAds = sender.state == .on
        restartNote.stringValue = "Ad blocking changes apply to pages you open from now on."
        if Preferences.blocksAds { ContentBlocker.prepare() }
    }

    @objc private func memoryChanged(_ sender: NSButton) {
        Preferences.showsMemory = sender.state == .on
        NotificationCenter.default.post(name: MemoryReadout.didToggle, object: nil)
    }

    @objc private func defaultClicked(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
        }
    }
}

/// Keeps the toolbar's memory label up to date (only while it's switched on).
@MainActor
final class MemoryReadout {
    static let didToggle = Notification.Name("MyBrowserMemoryReadoutToggled")
    private var timer: Timer?
    private var refreshPending = false
    private let label: NSTextField
    private let pages: () -> [WKWebView]

    init(label: NSTextField, pages: @escaping () -> [WKWebView]) {
        self.label = label
        self.pages = pages
    }

    func update() {
        timer?.invalidate()
        timer = nil
        label.isHidden = !Preferences.showsMemory
        guard Preferences.showsMemory else { return }
        refresh()
        // Every 30 seconds (and when you switch tabs) is plenty, and costs almost nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 10
    }

    /// Updates the number a couple of seconds after a tab change (once the page has loaded).
    func refreshSoon() {
        guard Preferences.showsMemory, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        let app = MemoryUse.appMegabytes()
        let views = pages()
        let pageSizes = views.compactMap(MemoryUse.pageMegabytes)
        if pageSizes.count == views.count, !views.isEmpty {
            label.stringValue = "\(app + pageSizes.reduce(0, +)) MB"
            label.toolTip = "Browser: \(app) MB + \(views.count) open page\(views.count == 1 ? "" : "s"): \(pageSizes.reduce(0, +)) MB (unloaded tabs use none)"
        } else {
            label.stringValue = "\(app) MB · \(views.count) loaded"
            label.toolTip = "Memory used by the browser app itself, and how many tabs are loaded (unloaded tabs use none). macOS doesn't let the app measure each page's own WebKit process."
        }
    }
}
