import AppKit

/// What the new tab page asks the window to do.
@MainActor
protocol NewTabDelegate: AnyObject {
    func newTabOpen(_ url: URL)
    func newTabImportFromChrome()
}

/// The new tab page: a search box in the middle, with suggestions underneath.
/// This is the only place you type addresses or searches. It's built from plain
/// Mac views (not a web page), so it uses almost no memory.
final class NewTabView: SolidView, NSTextFieldDelegate {
    weak var delegate: NewTabDelegate?

    private struct Suggestion {
        enum Kind { case address, search, bookmark }
        let kind: Kind
        let text: String
        let detail: String
        let url: URL
    }

    private let box = SolidView(color: Theme.field)
    private let field = NSTextField()
    private let list = SolidView(color: Theme.field)
    private let rows = NSStackView()
    private var suggestions: [Suggestion] = []
    private var selected = 0
    private var fetch: URLSessionDataTask?
    private var listHeight: NSLayoutConstraint!

    init() {
        super.init(color: Theme.background)

        box.cornerRadius = 23
        box.borderColor = Theme.toolbar
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
        list.borderColor = Theme.toolbar
        list.isHidden = true
        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .leading

        let importButton = NSButton(title: "Import bookmarks, tab groups & extensions from Chrome",
                                    target: self, action: #selector(importClicked(_:)))
        importButton.isBordered = false
        importButton.attributedTitle = NSAttributedString(string: importButton.title, attributes: [
            .foregroundColor: Theme.accent, .font: NSFont.systemFont(ofSize: 13)])

        for v in [box, glass, field, list, rows, importButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(box)
        box.addSubview(glass)
        box.addSubview(field)
        addSubview(list)
        list.addSubview(rows)
        addSubview(importButton)

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

            importButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            importButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
        ])
        let wide = box.widthAnchor.constraint(equalToConstant: 620)
        wide.priority = .defaultHigh
        wide.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clears the box and puts the cursor in it.
    func reset() {
        field.stringValue = ""
        show([])
        window?.makeFirstResponder(field)
    }

    func focus() { window?.makeFirstResponder(field) }

    @objc private func importClicked(_ sender: Any?) { delegate?.newTabImportFromChrome() }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) { update() }

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
            let isSearch = url.host == "www.google.com" && url.path == "/search"
            local.append(Suggestion(kind: isSearch ? .search : .address, text: text,
                                    detail: isSearch ? "Google Search" : "Go to site", url: url))
        }
        let lower = text.lowercased()
        let bookmarks = BookmarkMenus.allBookmarks().filter {
            $0.title.lowercased().contains(lower) || ($0.url?.absoluteString.lowercased().contains(lower) ?? false)
        }
        for node in bookmarks.prefix(3) {
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
            let symbol = item.kind == .bookmark ? "star" : (item.kind == .address ? "globe" : "magnifyingglass")
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
    var isHighlighted = false { didSet { fillColor = isHighlighted ? Theme.hoverTab : Theme.field } }

    init(icon: String, text: String, detail: String, action: @escaping () -> Void) {
        self.action = action
        super.init(color: Theme.field)
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
