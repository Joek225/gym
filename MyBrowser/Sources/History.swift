import AppKit

/// Pages you've visited (not in private windows). Kept in a small file;
/// the newest 10,000 visits are remembered.
@MainActor
final class HistoryStore: NSObject {
    static let shared = HistoryStore()
    static let file = Storage.folder.appendingPathComponent("history.json")

    struct Entry: Codable {
        var url: URL
        var title: String
        var date: Date
        var visits: Int
    }

    private(set) var entries: [Entry] = []   // newest first

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func record(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        var visits = 1
        if let i = entries.firstIndex(where: { $0.url == url }) {
            visits = entries[i].visits + 1
            entries.remove(at: i)
        }
        entries.insert(Entry(url: url, title: title, date: Date(), visits: visits), at: 0)
        if entries.count > 10_000 { entries.removeLast(entries.count - 10_000) }
        scheduleSave()
    }

    func updateTitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let i = entries.firstIndex(where: { $0.url == url }), entries[i].title != title else { return }
        entries[i].title = title
        scheduleSave()
    }

    func delete(_ url: URL) {
        entries.removeAll { $0.url == url }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    /// Best matches for the new tab page: often- and recently-visited pages first.
    func matches(_ text: String, limit: Int) -> [Entry] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        let hits = entries.prefix(3000).filter { entry in
            let hay = (entry.title + " " + entry.url.absoluteString).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let now = Date()
        return Array(hits.sorted { a, b in
            func score(_ e: Entry) -> Double { Double(e.visits) / (1 + now.timeIntervalSince(e.date) / 86_400) }
            return score(a) > score(b)
        }.prefix(limit))
    }

    private func scheduleSave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(save), object: nil)
        perform(#selector(save), with: nil, afterDelay: 20)   // also saved when you quit
    }

    @objc func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.file, options: .atomic) }
    }
}

/// The History panel (⌘Y): search, open, delete.
@MainActor
enum HistoryOverlay {
    static func show(in window: NSWindow, open: @escaping (URL) -> Void) {
        Overlay.show(title: "History", content: HistoryView(open: open), size: NSSize(width: 760, height: 600), in: window)
    }
}

final class HistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let open: (URL) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private var shown: [HistoryStore.Entry] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(open: @escaping (URL) -> Void) {
        self.open = open
        super.init(frame: .zero)
        search.placeholderString = "Search history"
        search.delegate = self
        for (id, title, width) in [("when", "When", 170.0), ("title", "Page", 330.0), ("site", "Site", 190.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.toolbar
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let openButton = NSButton(title: "Open in New Tab", target: self, action: #selector(openClicked(_:)))
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteClicked(_:)))
        let clearButton = NSButton(title: "Clear All History…", target: self, action: #selector(clearClicked(_:)))
        for b in [openButton, deleteButton, clearButton] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [openButton, deleteButton, NSView(), clearButton])
        let stack = NSStackView(views: [search, scroll, buttons])
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
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func reload() {
        let text = search.stringValue
        shown = text.isEmpty ? Array(HistoryStore.shared.entries.prefix(2000))
                             : HistoryStore.shared.entries.filter {
                                 ($0.title + " " + $0.url.absoluteString).localizedCaseInsensitiveContains(text)
                             }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let e = shown[row]
        switch tableColumn?.identifier.rawValue {
        case "when": return formatter.string(from: e.date)
        case "title": return e.title.isEmpty ? e.url.absoluteString : e.title
        default: return e.url.host ?? ""
        }
    }

    @objc private func openClicked(_ sender: Any?) {
        for row in table.selectedRowIndexes where row < shown.count { open(shown[row].url) }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        for row in table.selectedRowIndexes where row < shown.count { HistoryStore.shared.delete(shown[row].url) }
        reload()
    }

    @objc private func clearClicked(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This removes every page from your history. It can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.clear()
            self?.reload()
        }
    }
}
