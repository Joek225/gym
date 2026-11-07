import AppKit
import WebKit

// MARK: - Per-site permissions

enum PermissionKind: String, CaseIterable {
    case location, camera, microphone, notifications, downloads

    var title: String {
        switch self {
        case .location: "Location"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        case .downloads: "Automatic downloads"
        }
    }

    var icon: String {
        switch self {
        case .location: "location"
        case .camera: "video"
        case .microphone: "mic"
        case .notifications: "bell"
        case .downloads: "arrow.down.to.line"
        }
    }
}

enum PermissionValue: String, CaseIterable {
    case ask, allow, block
    var title: String { self == .ask ? "Ask" : (self == .allow ? "Allow" : "Block") }
}

/// What you've allowed or blocked for each website, saved between launches.
enum SitePermissions {
    private static let key = "sitePermissions"
    private static var all: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func standard(_ kind: PermissionKind) -> PermissionValue {
        switch kind {
        case .downloads: .allow
        case .notifications: .block
        default: .ask
        }
    }

    static func get(_ kind: PermissionKind, _ host: String) -> PermissionValue {
        all[host]?[kind.rawValue].flatMap(PermissionValue.init(rawValue:)) ?? standard(kind)
    }

    static func isDefault(_ kind: PermissionKind, _ host: String) -> Bool { all[host]?[kind.rawValue] == nil }

    static func set(_ kind: PermissionKind, _ host: String, _ value: PermissionValue) {
        var copy = all
        copy[host, default: [:]][kind.rawValue] = value.rawValue
        all = copy
    }

    static func reset(_ host: String) {
        var copy = all
        copy[host] = nil
        all = copy
    }

    static var sites: [String] { all.keys.sorted() }

    static func summary(_ host: String) -> String {
        (all[host] ?? [:]).compactMap { kind, value in
            guard let k = PermissionKind(rawValue: kind), let v = PermissionValue(rawValue: value) else { return nil }
            return "\(k.title): \(v.title)"
        }.sorted().joined(separator: ", ")
    }
}

// MARK: - The site info panel (the button at the left of the address)

/// Chrome's site info panel: connection security, permissions, and this site's stored data.
@MainActor
final class SiteInfoPanel: NSObject, NSWindowDelegate {
    private static var current: SiteInfoPanel?

    private let panel: PopupPanel
    private let host: String
    private weak var webView: WKWebView?
    private let dataLabel = NSTextField(labelWithString: "Checking…")
    private var popups: [(PermissionKind, NSPopUpButton)] = []

    static func show(for webView: WKWebView, below anchor: NSView) {
        current?.close()
        guard let url = webView.url, let host = url.host, let window = anchor.window else { return }
        let info = SiteInfoPanel(webView: webView, host: host, secure: url.scheme == "https" && webView.hasOnlySecureContent)
        current = info
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        info.present(below: rect, in: window)
    }

    private init(webView: WKWebView, host: String, secure: Bool) {
        self.webView = webView
        self.host = host
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = Theme.appearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        build(secure: secure)
        countData()
    }

    private func build(secure: Bool) {
        let box = SolidView(color: Theme.sidebar)
        box.cornerRadius = 14
        box.borderColor = Theme.hairline
        panel.contentView = box

        let title = NSTextField(labelWithString: host)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.text
        let close = NSButton(image: Icons.symbol("xmark", size: 12, weight: .semibold) ?? NSImage(),
                             target: self, action: #selector(closeClicked(_:)))
        close.isBordered = false
        close.contentTintColor = Theme.mutedText
        let header = NSStackView(views: [title, NSView(), close])

        // Connection
        var detail = secure ? "Your information (like passwords) is private when sent to this site."
                            : "Don't enter passwords or card details on this site: the connection isn't encrypted."
        if secure, let trust = webView?.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
           let subject = SecCertificateCopySubjectSummary(leaf) as String? {
            detail += "\nCertificate issued to: \(subject)"
        }
        let connection = row(icon: secure ? "lock" : "exclamationmark.triangle",
                             title: secure ? "Connection is secure" : "Not secure", detail: detail, control: nil)

        // Permissions
        var permissionRows: [NSView] = []
        for kind in PermissionKind.allCases {
            let popup = NSPopUpButton()
            let choices: [PermissionValue] = kind == .downloads ? [.allow, .block] : PermissionValue.allCases
            for value in choices {
                let suffix = SitePermissions.standard(kind) == value ? " (default)" : ""
                popup.addItem(withTitle: value.title + suffix)
                popup.lastItem?.representedObject = value.rawValue
            }
            let current = SitePermissions.get(kind, host)
            popup.selectItem(at: choices.firstIndex(of: current) ?? 0)
            popup.target = self
            popup.action = #selector(permissionChanged(_:))
            popup.controlSize = .small
            if kind == .notifications {
                popup.isEnabled = false
                popup.toolTip = "Web notifications aren't supported by apps built on WebKit (only Safari has them)."
            }
            popups.append((kind, popup))
            permissionRows.append(row(icon: kind.icon, title: kind.title, detail: nil, control: popup))
        }
        let reset = NSButton(title: "Reset permissions", target: self, action: #selector(resetClicked(_:)))
        reset.bezelStyle = .rounded

        // Site data
        dataLabel.font = .systemFont(ofSize: 11)
        dataLabel.textColor = Theme.mutedText
        let clear = NSButton(title: "Delete", target: self, action: #selector(clearDataClicked(_:)))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        let dataRow = row(icon: "externaldrive", title: "Cookies and site data", detail: nil, control: clear)
        let settings = NSButton(title: "All site settings…", target: self, action: #selector(allSettingsClicked(_:)))
        settings.bezelStyle = .rounded

        let stack = NSStackView(views: [header, connection, separator()] + permissionRows
                                + [reset, separator(), dataRow, dataLabel, settings])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 380),
        ])
        for v in stack.arrangedSubviews where v !== reset && v !== settings && v !== dataLabel {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        dataLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 50).isActive = true
    }

    private func row(icon: String, title: String, detail: String?, control: NSView?) -> NSView {
        let image = NSImageView(image: Icons.symbol(icon, size: 15) ?? NSImage())
        image.contentTintColor = Theme.icon
        image.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        label.textColor = Theme.text
        var texts: [NSView] = [label]
        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = Theme.mutedText
            d.preferredMaxLayoutWidth = 280
            texts.append(d)
        }
        let column = NSStackView(views: texts)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        var views: [NSView] = [image, column, NSView()]
        if let control { views.append(control) }
        let r = NSStackView(views: views)
        r.alignment = detail == nil ? .centerY : .top
        r.spacing = 10
        return r
    }

    private func separator() -> NSView {
        let line = SolidView(color: Theme.hairline)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func present(below anchor: NSRect, in parent: NSWindow) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard SiteInfoPanel.current === self else { return }
        SiteInfoPanel.current = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
    @objc private func closeClicked(_ sender: Any?) { close() }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let kind = popups.first(where: { $0.1 === sender })?.0,
              let raw = sender.selectedItem?.representedObject as? String,
              let value = PermissionValue(rawValue: raw) else { return }
        SitePermissions.set(kind, host, value)
    }

    @objc private func resetClicked(_ sender: Any?) {
        SitePermissions.reset(host)
        for (kind, popup) in popups {
            let choices: [PermissionValue] = kind == .downloads ? [.allow, .block] : PermissionValue.allCases
            popup.selectItem(at: choices.firstIndex(of: SitePermissions.standard(kind)) ?? 0)
        }
    }

    /// The site's main name (e.g. "google.com" for "docs.google.com"), which is how WebKit groups stored data.
    private var siteName: String {
        let parts = host.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    private func records(_ done: @escaping ([WKWebsiteDataRecord]) -> Void) {
        guard let store = webView?.configuration.websiteDataStore else { done([]); return }
        let name = siteName
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { all in
            done(all.filter { $0.displayName == name || $0.displayName.hasSuffix("." + name) })
        }
    }

    private func countData() {
        records { [weak self] found in
            let kinds = Set(found.flatMap(\.dataTypes))
            self?.dataLabel.stringValue = found.isEmpty ? "Nothing stored for this site."
                : "Stored: \(kinds.contains(WKWebsiteDataTypeCookies) ? "cookies" : "no cookies"), plus \(kinds.count) kind\(kinds.count == 1 ? "" : "s") of site data. Deleting signs you out of this site."
        }
    }

    @objc private func clearDataClicked(_ sender: Any?) {
        guard let store = webView?.configuration.websiteDataStore else { return }
        records { [weak self] found in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: found) {
                self?.dataLabel.stringValue = "Deleted. Reload the page to start fresh."
            }
        }
    }

    @objc private func allSettingsClicked(_ sender: Any?) {
        guard let window = panel.parent else { return }
        close()
        Overlay.show(title: "Site Settings", content: SiteSettingsView(), size: NSSize(width: 620, height: 480), in: window)
    }
}

/// Every site you've changed permissions for, with a button to reset each.
final class SiteSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var sites = SitePermissions.sites

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("site", "Website", 220.0), ("perms", "Your choices", 340.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.background
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let note = NSTextField(wrappingLabelWithString: "Sites start with: location, camera and microphone = Ask; notifications = Blocked; downloads = Allowed. Change a site from the button at the left of its address.")
        note.textColor = Theme.mutedText
        note.font = .systemFont(ofSize: 12)
        let reset = NSButton(title: "Reset Selected Site", target: self, action: #selector(resetClicked(_:)))
        reset.bezelStyle = .rounded
        let stack = NSStackView(views: [note, scroll, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        tableColumn?.identifier.rawValue == "site" ? sites[row] : SitePermissions.summary(sites[row])
    }

    @objc private func resetClicked(_ sender: Any?) {
        guard table.selectedRow >= 0, table.selectedRow < sites.count else { return }
        SitePermissions.reset(sites[table.selectedRow])
        sites = SitePermissions.sites
        table.reloadData()
    }
}

// MARK: - Loading animation

/// Three dots whose colors pulse one after another while a tab wakes up.
/// It's a Core Animation effect (drawn by the graphics chip), and only runs while showing.
final class LoadingDots: NSView {
    private var dots: [CALayer] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        wantsLayer = true
        for i in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(i) * 22, y: 2, width: 12, height: 12)
            dot.cornerRadius = 6
            dot.backgroundColor = Theme.hairline.cgColor
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 16) }

    func start() {
        guard isHidden else { return }
        isHidden = false
        let now = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            let pulse = CABasicAnimation(keyPath: "backgroundColor")
            pulse.fromValue = Theme.hairline.cgColor
            pulse.toValue = Theme.accent.cgColor
            pulse.duration = 0.45
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = now + Double(i) * 0.18
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }

    func stop() {
        guard !isHidden else { return }
        isHidden = true
        dots.forEach { $0.removeAllAnimations() }   // nothing keeps running once hidden
    }
}
