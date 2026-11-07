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
        shelfWidth.priority = NSLayoutConstraint.Priority(490)   // a wish only: never holds the window open
        shelfWidth.isActive = true
        let wide = box.widthAnchor.constraint(equalToConstant: 620)
        wide.priority = NSLayoutConstraint.Priority(490)
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

extension NSPasteboard.PasteboardType {
    static let bookmarkItem = NSPasteboard.PasteboardType("local.mybrowser.bookmark")
}

/// Your bookmarks and folders, shown above the search box on the new tab page.
/// Click a bookmark to open it, click a folder to see what's inside, right-click to edit,
/// and drag to rearrange (drop on a folder to move a bookmark into it).
final class BookmarkShelf: NSView {
    var onOpen: ((BookmarkNode) -> Void)?
    private var chips: [BookmarkChip] = []
    private var height: NSLayoutConstraint!
    private let hint = NSTextField(labelWithString: "Bookmark pages with ⌘D or the ☆ in the address bar — they'll show up here.")
    private let dropMarker = SolidView(color: Theme.accent)
    private var dropIndex: Int?
    private weak var dropFolder: BookmarkChip?
    private static let rowHeight: CGFloat = 32
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
        dropMarker.cornerRadius = 1
        dropMarker.isHidden = true
        addSubview(dropMarker)
        registerForDraggedTypes([.bookmarkItem])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What's shown: the Bookmarks Bar folder's items, then "Other Bookmarks" if it has any.
    private var nodes: [BookmarkNode] {
        var list = BookmarkStore.shared.bar.children ?? []
        if !(BookmarkStore.shared.other.children ?? []).isEmpty { list.append(BookmarkStore.shared.other) }
        return list
    }

    func reload() {
        chips.forEach { $0.removeFromSuperview() }
        chips = nodes.map { node in
            let chip = BookmarkChip(node: node)
            chip.onClick = { [weak self] chip in self?.clicked(chip) }
            addSubview(chip, positioned: .below, relativeTo: dropMarker)
            return chip
        }
        hint.isHidden = !chips.isEmpty
        needsLayout = true
    }

    /// Lays the chips out in centered rows (up to 4 rows; the rest are in the Bookmarks menu).
    override func layout() {
        super.layout()
        hint.frame = NSRect(x: 0, y: 8, width: bounds.width, height: 18)
        var rows: [[BookmarkChip]] = [[]]
        var lineWidth: CGFloat = 0
        for chip in chips {
            let w = chip.preferredWidth
            if lineWidth + w > bounds.width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                lineWidth = 0
            }
            rows[rows.count - 1].append(chip)
            lineWidth += w + 8
        }
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.preferredWidth } + CGFloat(max(0, row.count - 1)) * 8
            var x = ((bounds.width - total) / 2).rounded()
            for chip in row {
                chip.isHidden = index >= Self.maxRows
                chip.frame = NSRect(x: x, y: y, width: chip.preferredWidth, height: Self.rowHeight - 4)
                x += chip.preferredWidth + 8
            }
            if index < Self.maxRows { y += Self.rowHeight }
        }
        let wanted = chips.isEmpty ? Self.rowHeight : y
        if height.constant != wanted { height.constant = wanted }
    }

    private func clicked(_ chip: BookmarkChip) {
        if chip.node.isFolder {
            BookmarkMenus.menu(for: chip.node).popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 4), in: chip)
        } else {
            onOpen?(chip.node)
        }
    }

    // MARK: Dropping (rearranging)

    private func draggedNode(_ info: NSDraggingInfo) -> BookmarkNode? {
        guard let id = info.draggingPasteboard.string(forType: .bookmarkItem) else { return nil }
        return chips.first { $0.node.id.uuidString == id }?.node
    }

    /// Works out where a drop would go: onto a folder (middle of a folder chip), or between chips.
    private func target(at point: NSPoint, dragging: BookmarkNode) {
        dropFolder?.isDropTarget = false
        dropFolder = nil
        dropIndex = nil
        let visible = chips.filter { !$0.isHidden }
        if let folder = visible.first(where: { $0.node.isFolder && $0.node !== dragging
                                               && $0.frame.insetBy(dx: $0.frame.width * 0.25, dy: 0).contains(point) }) {
            folder.isDropTarget = true
            dropFolder = folder
            dropMarker.isHidden = true
            return
        }
        // Nearest gap: before the first chip on this row whose middle is right of the pointer.
        let rowChips = visible.filter { point.y >= $0.frame.minY - 4 && point.y <= $0.frame.maxY + 4 }
        guard let last = (rowChips.isEmpty ? visible : rowChips).last else { dropIndex = 0; return }
        let before = rowChips.first { point.x < $0.frame.midX }
        let anchor = before ?? last
        let x = before == nil ? last.frame.maxX + 4 : anchor.frame.minX - 4
        dropMarker.frame = NSRect(x: x - 1, y: anchor.frame.minY, width: 2, height: anchor.frame.height)
        dropMarker.isHidden = false
        let barCount = BookmarkStore.shared.bar.children?.count ?? 0
        let chipIndex = chips.firstIndex { $0 === anchor } ?? barCount
        dropIndex = min(before == nil ? chipIndex + 1 : chipIndex, barCount)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let node = draggedNode(sender) else { return [] }
        target(at: convert(sender.draggingLocation, from: nil), dragging: node)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropState() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropState() }
        guard let node = draggedNode(sender) else { return false }
        let store = BookmarkStore.shared
        if let folder = dropFolder?.node {
            store.move(node, to: folder, at: folder.children?.count ?? 0)
        } else if let index = dropIndex {
            store.move(node, to: store.bar, at: index)
        }
        return true
    }

    private func clearDropState() {
        dropFolder?.isDropTarget = false
        dropFolder = nil
        dropIndex = nil
        dropMarker.isHidden = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let node = chips.first(where: { !$0.isHidden && $0.frame.contains(point) })?.node,
           node !== BookmarkStore.shared.other {
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

/// One bookmark or folder: icon and name centered together, with even padding.
/// Click to open; drag to move it.
final class BookmarkChip: SolidView, NSDraggingSource {
    let node: BookmarkNode
    var onClick: ((BookmarkChip) -> Void)?
    var isDropTarget = false { didSet { borderColor = isDropTarget ? Theme.accent : nil } }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var mouseDownAt: NSPoint?
    private var isDragging = false
    private static let padding: CGFloat = 12
    private static let iconSize: CGFloat = 16
    private static let gap: CGFloat = 7

    init(node: BookmarkNode) {
        self.node = node
        super.init(color: Theme.pageBoxFill)
        cornerRadius = 9
        borderWidth = 2
        icon.image = node.isFolder ? Icons.folder
            : (node.icon.flatMap(Favicons.image(fromPNG:)) ?? Favicons.cached(for: node.url) ?? Icons.globe)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.icon
        label.stringValue = node.isFolder ? node.displayTitle : node.title
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        toolTip = node.url?.absoluteString ?? node.displayTitle
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var labelWidth: CGFloat {
        // The text's real width plus the few points a label needs around it (or it cuts off with "…").
        label.stringValue.isEmpty ? 0 : min(ceil(label.attributedStringValue.size().width) + 6, 156)
    }

    /// Padding + icon + gap + name + padding (a chip with no name is a neat square).
    var preferredWidth: CGFloat {
        labelWidth == 0 ? Self.iconSize + 2 * 9 : Self.padding * 2 + Self.iconSize + Self.gap + labelWidth
    }

    /// Icon and name are placed as one block in the exact middle of the chip.
    override func layout() {
        super.layout()
        let content = labelWidth == 0 ? Self.iconSize : Self.iconSize + Self.gap + labelWidth
        let start = ((bounds.width - content) / 2).rounded()
        icon.frame = NSRect(x: start, y: ((bounds.height - Self.iconSize) / 2).rounded(),
                            width: Self.iconSize, height: Self.iconSize)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: start + Self.iconSize + Self.gap, y: ((bounds.height - labelHeight) / 2).rounded(),
                             width: labelWidth, height: labelHeight)
        label.isHidden = labelWidth == 0
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, !isDragging, node !== BookmarkStore.shared.other,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        isDragging = true
        let item = NSPasteboardItem()
        item.setString(node.id.uuidString, forType: .bookmarkItem)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        var picture = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            picture = NSImage(size: bounds.size)
            picture.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(bounds, contents: picture)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(self) }
        mouseDownAt = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
    }
}
