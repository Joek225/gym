import AppKit

/// What the new tab page asks the window to do.
@MainActor
protocol NewTabDelegate: AnyObject {
    func newTabOpen(_ url: URL)
    func newTabImportFromChrome()
    func newTabSleep()
    func newTabOpenBookmark(_ node: BookmarkNode)
}

/// The new tab page: a search box in the middle, with suggestions underneath.
/// This is the only place you type addresses or searches. It's built from plain
/// Mac views (not a web page), so it uses almost no memory.
final class NewTabView: SolidView, NSTextFieldDelegate {
    weak var delegate: NewTabDelegate?

    private struct Suggestion {
        enum Kind { case address, search, bookmark, history }
        let kind: Kind
        let text: String
        let detail: String
        let url: URL
    }

    private let box = SolidView(color: Theme.pageBoxFill)
    private let shelf = BookmarkShelf()
    private let field = NSTextField()
    private let list = SolidView(color: Theme.background)
    private let rows = NSStackView()
    private var suggestions: [Suggestion] = []
    private var selected = 0
    private var fetch: URLSessionDataTask?
    private var listHeight: NSLayoutConstraint!

    init() {
        super.init(color: Theme.background)

        box.cornerRadius = 23
        box.borderColor = Theme.hairline
        let glass = NSImageView(image: Icons.symbol("magnifyingglass", size: 15) ?? NSImage())
        glass.contentTintColor = Theme.mutedText
        field.placeholderString = "Search Google or type a web address"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = Theme.text
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        list.cornerRadius = 14
        list.borderColor = Theme.hairline
        list.isHidden = true
        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .leading

        shelf.onOpen = { [weak self] node in self?.delegate?.newTabOpenBookmark(node) }

        for v in [shelf, box, glass, field, list, rows] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(shelf)
        addSubview(box)
        box.addSubview(glass)
        box.addSubview(field)
        addSubview(list)
        list.addSubview(rows)

        listHeight = list.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -90),
            // Never a hard size: the box shrinks in small windows and stops at 620 points,
            // so the window itself can be any size (including full screen).
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            box.heightAnchor.constraint(equalToConstant: 46),
            glass.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            glass.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: box.centerYAnchor),

            list.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8),
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            listHeight,
            rows.topAnchor.constraint(equalTo: list.topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -6),

            // Bookmarks sit above the search box.
            shelf.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -26),
            shelf.centerXAnchor.constraint(equalTo: centerXAnchor),
            shelf.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),

        ])
        let shelfWidth = shelf.widthAnchor.constraint(equalTo: box.widthAnchor, constant: 120)
        shelfWidth.priority = .defaultHigh
        shelfWidth.isActive = true
        let wide = box.widthAnchor.constraint(equalToConstant: 620)
        wide.priority = .defaultHigh
        wide.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clears the box and puts the cursor in it.
    func reset() {
        shelf.reload()
        field.stringValue = ""
        show([])
        window?.makeFirstResponder(field)
    }

    func focus() { window?.makeFirstResponder(field) }


    /// Keeps the bookmarks up to date while the page is showing.
    func bookmarksChanged() { shelf.reload() }

    /// Private windows say so on their new tab page.
    func showPrivateNote() {
        let note = NSTextField(wrappingLabelWithString: "Private window — pages you visit, cookies, passwords and tabs here aren't saved. Everything is forgotten when you close this window.")
        note.alignment = .center
        note.textColor = Theme.mutedText
        note.font = .systemFont(ofSize: 13)
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([
            note.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -24),
            note.centerXAnchor.constraint(equalTo: centerXAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }


    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        // Ask for suggestions once you pause typing (not on every key press).
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateNow), object: nil)
        perform(#selector(updateNow), with: nil, afterDelay: 0.15)
    }

    @objc private func updateNow() { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): go(); return true
        case #selector(NSResponder.cancelOperation(_:)): field.stringValue = ""; show([]); return true
        default: return false
        }
    }

    private func go() {
        if !suggestions.isEmpty, selected < suggestions.count, !list.isHidden {
            delegate?.newTabOpen(suggestions[selected].url)
        } else if let url = AddressParser.url(from: field.stringValue) {
            delegate?.newTabOpen(url)
        }
    }

    private func move(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + step + suggestions.count) % suggestions.count
        highlight()
    }

    /// Builds suggestions: the address itself (if it looks like one), matching
    /// bookmarks, then Google's suggestions (which arrive a moment later).
    private func update() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        fetch?.cancel()
        guard !text.isEmpty else { show([]); return }

        var local: [Suggestion] = []
        if let url = AddressParser.url(from: text) {
            let isSearch = Preferences.searchEngine.isResultsPage(url)
            local.append(Suggestion(kind: isSearch ? .search : .address, text: text,
                                    detail: isSearch ? "\(Preferences.searchEngine.rawValue) Search" : "Go to site", url: url))
        }
        let lower = text.lowercased()
        for entry in HistoryStore.shared.matches(text, limit: 3) where !local.contains(where: { $0.url == entry.url }) {
            local.append(Suggestion(kind: .history, text: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                    detail: entry.url.host ?? "", url: entry.url))
        }
        let bookmarks = BookmarkMenus.allBookmarks().filter {
            $0.title.lowercased().contains(lower) || ($0.url?.absoluteString.lowercased().contains(lower) ?? false)
        }
        for node in bookmarks.prefix(3) where !local.contains(where: { $0.url == node.url }) {
            if let url = node.url { local.append(Suggestion(kind: .bookmark, text: node.displayTitle, detail: url.host ?? "", url: url)) }
        }
        show(local)

        // Google's search suggestions (the same service Chrome uses for its address bar).
        var request = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        request.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: text)]
        guard let url = request.url else { return }
        fetch = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let terms = json[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self, self.field.stringValue.trimmingCharacters(in: .whitespaces) == text else { return }
                var all = local
                for term in terms.prefix(6) where term.lowercased() != lower {
                    if let searchURL = AddressParser.url(from: term) {
                        all.append(Suggestion(kind: .search, text: term, detail: "", url: searchURL))
                    }
                }
                self.show(all)
            }
        }
        fetch?.resume()
    }

    // MARK: The suggestion box

    private func show(_ items: [Suggestion]) {
        suggestions = Array(items.prefix(8))
        selected = 0
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in suggestions.enumerated() {
            let symbol: String
            switch item.kind {
            case .bookmark: symbol = "star"
            case .address: symbol = "globe"
            case .history: symbol = "clock.arrow.circlepath"
            case .search: symbol = "magnifyingglass"
            }
            let row = SuggestionRow(icon: symbol, text: item.text, detail: item.detail) { [weak self] in
                self?.selected = i
                self?.go()
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        list.isHidden = suggestions.isEmpty
        listHeight.constant = suggestions.isEmpty ? 0 : CGFloat(suggestions.count) * SuggestionRow.height + 12
        highlight()
    }

    private func highlight() {
        for (i, row) in rows.arrangedSubviews.enumerated() {
            (row as? SuggestionRow)?.isHighlighted = i == selected
        }
    }
}

/// One line in the suggestion box.
final class SuggestionRow: SolidView {
    static let height: CGFloat = 34
    private let action: () -> Void
    var isHighlighted = false { didSet { fillColor = isHighlighted ? Theme.pageBoxFill : Theme.background } }

    init(icon: String, text: String, detail: String, action: @escaping () -> Void) {
        self.action = action
        super.init(color: Theme.background)
        cornerRadius = 8
        let image = NSImageView(image: Icons.symbol(icon, size: 13) ?? NSImage())
        image.contentTintColor = Theme.mutedText
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = Theme.mutedText
        for v in [image, label, detailLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// Your bookmarks and folders, shown above the search box on the new tab page.
/// Click a bookmark to open it, click a folder to see what's inside, right-click to edit.
final class BookmarkShelf: NSView {
    var onOpen: ((BookmarkNode) -> Void)?
    private var items: [(button: NSButton, node: BookmarkNode)] = []
    private var height: NSLayoutConstraint!
    private let hint = NSTextField(labelWithString: "Bookmark pages with ⌘D or the ☆ in the address bar — they'll show up here.")
    private static let rowHeight: CGFloat = 30
    private static let maxRows = 4

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        height = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        height.isActive = true
        hint.textColor = Theme.mutedText
        hint.font = .systemFont(ofSize: 12)
        hint.alignment = .center
        addSubview(hint)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        items.forEach { $0.button.removeFromSuperview() }
        items = []
        var nodes = BookmarkStore.shared.bar.children ?? []
        if !(BookmarkStore.shared.other.children ?? []).isEmpty { nodes.append(BookmarkStore.shared.other) }
        for node in nodes {
            let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
            button.isBordered = false
            let title = node.isFolder ? node.displayTitle : node.title
            button.attributedTitle = NSAttributedString(string: title.isEmpty ? "" : " " + title, attributes: [
                .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12.5)])
            button.image = node.isFolder ? Icons.folder
                : (node.icon.flatMap(Favicons.image(fromPNG:)) ?? Favicons.cached(for: node.url) ?? Icons.globe)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.contentTintColor = Theme.icon
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.backgroundColor = Theme.pageBoxFill.cgColor
            button.layer?.cornerRadius = 8
            button.toolTip = node.url?.absoluteString ?? node.displayTitle
            addSubview(button)
            items.append((button, node))
        }
        hint.isHidden = !items.isEmpty
        needsLayout = true
    }

    /// Lays the buttons out in centered rows (up to 4 rows; the rest are in the Bookmarks menu).
    override func layout() {
        super.layout()
        hint.frame = NSRect(x: 0, y: 6, width: bounds.width, height: 18)
        var rows: [[(NSButton, CGFloat)]] = [[]]
        var lineWidth: CGFloat = 0
        for (button, _) in items {
            button.sizeToFit()
            let w = min(max(button.frame.width + 18, 34), 190)
            if lineWidth + w > bounds.width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                lineWidth = 0
            }
            rows[rows.count - 1].append((button, w))
            lineWidth += w + 8
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.1 } + CGFloat(max(0, row.count - 1)) * 8
            var x = (bounds.width - total) / 2
            for (button, w) in row {
                button.isHidden = index >= Self.maxRows
                button.frame = NSRect(x: x, y: y, width: w, height: Self.rowHeight - 4)
                x += w + 8
            }
            if index < Self.maxRows { y += Self.rowHeight }
        }
        let wanted = items.isEmpty ? Self.rowHeight : y
        if height.constant != wanted { height.constant = wanted }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let node = items.first(where: { $0.button === sender })?.node else { return }
        if node.isFolder {
            BookmarkMenus.menu(for: node).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else {
            onOpen?(node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let node = items.first(where: { !$0.button.isHidden && $0.button.frame.contains(point) })?.node {
            if !node.isFolder {
                let newTab = NSMenuItem(title: "Open in New Tab", action: #selector(BrowserWindowController.openBookmarkInNewTab(_:)), keyEquivalent: "")
                newTab.representedObject = node
                menu.addItem(newTab)
                menu.addItem(.separator())
            }
            let edit = NSMenuItem(title: node.isFolder ? "Edit Folder…" : "Edit…",
                                  action: #selector(BrowserWindowController.editBookmarkItem(_:)), keyEquivalent: "")
            edit.representedObject = node
            menu.addItem(edit)
            let delete = NSMenuItem(title: "Delete", action: #selector(BrowserWindowController.deleteBookmarkItem(_:)), keyEquivalent: "")
            delete.representedObject = node
            menu.addItem(delete)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Add Folder…", action: #selector(BrowserWindowController.newBookmarkFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Import from Chrome…", action: #selector(BrowserWindowController.importChromeBookmarks(_:)), keyEquivalent: "")
        return menu
    }
}
