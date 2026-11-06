import AppKit

/// The bar under the toolbar. On the left: your tab groups as colored chips
/// (like Chrome's saved groups). Then your bookmarks and folders.
/// Items that don't fit go into a » menu on the right.
@MainActor
final class BookmarksBarView: NSView {
    static let height: CGFloat = 30

    /// Supplies the current tab groups.
    var groups: () -> [TabGroup] = { [] }

    private enum Entry {
        case group(TabGroup)
        case node(BookmarkNode)
    }

    private let background = SolidView(color: Theme.toolbar)
    private var entries: [(button: NSButton, entry: Entry)] = []
    private let overflowButton = NSButton()
    private let emptyHint = NSTextField(labelWithString: "Bookmark pages with ⌘D or the ☆ star. Import from Chrome in the Bookmarks menu.")

    init() {
        super.init(frame: .zero)
        addSubview(background)
        overflowButton.image = Icons.symbol("chevron.right.2", size: 11)
        overflowButton.isBordered = false
        overflowButton.contentTintColor = Theme.icon
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow(_:))
        overflowButton.toolTip = "More bookmarks"
        addSubview(overflowButton)
        emptyHint.font = .systemFont(ofSize: 11.5)
        emptyHint.textColor = Theme.mutedText
        addSubview(emptyHint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        entries.forEach { $0.button.removeFromSuperview() }
        entries = []
        for group in groups() { entries.append((makeChip(group), .group(group))) }
        for node in BookmarkStore.shared.bar.children ?? [] { entries.append((makeButton(node), .node(node))) }
        entries.forEach { addSubview($0.button) }
        emptyHint.isHidden = !entries.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let h: CGFloat = 22
        let y = (bounds.height - h) / 2
        let limit = bounds.width - 34
        var x: CGFloat = 10
        var overflowing = false
        for (button, entry) in entries {
            button.sizeToFit()
            var w = min(button.frame.width, 180)
            if case .group = entry { w += 14 } else { w += 8 }
            if overflowing || x + w > limit {
                overflowing = true
                button.isHidden = true
            } else {
                button.isHidden = false
                button.frame = NSRect(x: x, y: y, width: w, height: h)
                x += w + 4
            }
        }
        overflowButton.isHidden = !overflowing
        overflowButton.frame = NSRect(x: bounds.width - 30, y: y, width: 22, height: h)
        emptyHint.sizeToFit()
        emptyHint.frame.origin = NSPoint(x: 12, y: (bounds.height - emptyHint.frame.height) / 2)
    }

    // MARK: Buttons

    private func makeButton(_ node: BookmarkNode) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: node.displayTitle, attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12)])
        button.image = node.isFolder ? Icons.folder : (Favicons.cached(for: node.url) ?? Icons.globe)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = Theme.icon
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = node.url?.absoluteString ?? node.displayTitle
        return button
    }

    private func makeChip(_ group: TabGroup) -> NSButton {
        let title = group.name.isEmpty ? "\(group.tabs.count) tabs" : group.name
        let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: group.color.color, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        button.wantsLayer = true
        button.layer?.backgroundColor = group.color.dimColor.cgColor
        button.layer?.cornerRadius = 6
        button.toolTip = "Tab group: click to see its tabs"
        return button
    }

    private func entry(for button: NSButton) -> Entry? {
        entries.first { $0.button === button }?.entry
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let entry = entry(for: sender) else { return }
        switch entry {
        case .node(let node):
            if node.isFolder {
                BookmarkMenus.menu(for: node).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
            } else {
                open(node)
            }
        case .group(let group):
            groupMenu(group).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
        }
    }

    private func open(_ node: BookmarkNode) {
        let item = NSMenuItem()
        item.representedObject = node
        NSApp.sendAction(#selector(BrowserWindowController.openBookmarkItem(_:)), to: nil, from: item)
    }

    private func groupMenu(_ group: TabGroup) -> NSMenu {
        let menu = NSMenu()
        for tab in group.tabs {
            let item = NSMenuItem(title: tab.displayTitle, action: #selector(BrowserWindowController.selectTabItem(_:)), keyEquivalent: "")
            item.representedObject = tab
            item.image = tab.favicon ?? Icons.globe
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showOverflow(_ sender: NSButton) {
        let menu = NSMenu()
        for (button, entry) in entries where button.isHidden {
            switch entry {
            case .node(let node):
                BookmarkMenus.append([node], to: menu)
            case .group(let group):
                let item = NSMenuItem(title: group.name.isEmpty ? "Tab group" : group.name, action: nil, keyEquivalent: "")
                item.image = group.color.swatch()
                item.submenu = groupMenu(group)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    // MARK: Right-click

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let hit = entries.first(where: { !$0.button.isHidden && $0.button.frame.contains(point) }),
           case .node(let node) = hit.entry {
            let edit = NSMenuItem(title: node.isFolder ? "Edit Folder…" : "Edit…",
                                  action: #selector(BrowserWindowController.editBookmarkItem(_:)), keyEquivalent: "")
            edit.representedObject = node
            menu.addItem(edit)
            let delete = NSMenuItem(title: "Delete", action: #selector(BrowserWindowController.deleteBookmarkItem(_:)), keyEquivalent: "")
            delete.representedObject = node
            menu.addItem(delete)
            if !node.isFolder {
                let newTab = NSMenuItem(title: "Open in New Tab", action: #selector(BrowserWindowController.openBookmarkInNewTab(_:)), keyEquivalent: "")
                newTab.representedObject = node
                menu.insertItem(newTab, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Add Folder…", action: #selector(BrowserWindowController.newBookmarkFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Import Bookmarks from Chrome…", action: #selector(BrowserWindowController.importChromeBookmarks(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Bookmarks Bar", action: #selector(BrowserWindowController.toggleBookmarksBar(_:)), keyEquivalent: "")
        return menu
    }
}
