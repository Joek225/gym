import AppKit

/// Chrome's "Search tabs": type to find any open tab in any window, then press Return.
@MainActor
final class TabSearch: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: TabSearch?

    private struct Result {
        let tab: Tab
        let window: BrowserWindowController
    }

    private let panel: PopupPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var results: [Result] = []

    static func show(anchor: NSRect, in parent: NSWindow) {
        current?.close()
        let search = TabSearch()
        current = search
        search.present(anchor: anchor, in: parent)
    }

    private override init() {
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = Theme.appearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let box = SolidView(color: Theme.sidebar)
        box.cornerRadius = 14
        box.borderColor = Theme.toolbar
        panel.contentView = box

        field.placeholderString = "Search tabs"
        field.delegate = self
        let column = NSTableColumn(identifier: .init("tab"))
        column.width = 340
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 34
        table.backgroundColor = Theme.sidebar
        table.target = self
        table.action = #selector(rowClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        for v in [field, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        update()
    }

    private func present(anchor: NSRect, in parent: NSWindow) {
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - panel.frame.height - 4)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard TabSearch.current === self else { return }
        TabSearch.current = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func update() {
        let words = field.stringValue.lowercased().split(separator: " ")
        results = AppDelegate.shared.controllers.flatMap { window in
            window.store.allTabs.map { Result(tab: $0, window: window) }
        }.filter { result in
            let text = (result.tab.displayTitle + " " + (result.tab.displayURL?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    // Up/Down move through the list; Return opens the tab.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): open(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked(_ sender: Any?) { open(table.clickedRow) }

    private func open(_ row: Int) {
        guard row >= 0, row < results.count else { return }
        let result = results[row]
        close()
        result.window.window?.makeKeyAndOrderFront(nil)
        result.window.select(result.tab)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = results[row].tab
        let cell = NSTableCellView()
        let icon = NSImageView(image: tab.favicon ?? Icons.globe ?? NSImage())
        let title = NSTextField(labelWithString: tab.displayTitle)
        title.font = .systemFont(ofSize: 13)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        let host = NSTextField(labelWithString: tab.displayURL?.host ?? "")
        host.font = .systemFont(ofSize: 11)
        host.textColor = Theme.mutedText
        for v in [icon, title, host] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            host.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            host.topAnchor.constraint(equalTo: title.bottomAnchor),
        ])
        return cell
    }
}
