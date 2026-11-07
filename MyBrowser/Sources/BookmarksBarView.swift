import AppKit

/// The bar under the toolbar. On the left: your tab groups as colored chips
/// (like Chrome's saved groups). Then your bookmarks and folders.
/// Items that don't fit go into a » menu on the right.
@MainActor
final class BookmarksBarView: NSView {
    static let height: CGFloat = 30

    /// Supplies the current tab groups.
    var groups: () -> [TabGroup] = { [] }
    /// Supplies groups you've closed (kept so you can reopen them).
    var closedGroups: () -> [SavedGroup] = { [] }

    private enum Entry {
        case group(TabGroup)
        case closedGroup(SavedGroup)
        case node(BookmarkNode)
    }

    private let background = SolidView(color: Theme.chromeFill)
    private var entries: [(button: NSButton, entry: Entry)] = []
    private let overflowButton = NSButton()
    private let emptyHint = NSTextField(labelWithString: "Bookmark pages with ⌘D or the ☆ star. To bring over Chrome's, choose Import from Chrome in the ⋮ menu.")

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
        for saved in closedGroups() { entries.append((makeClosedChip(saved), .closedGroup(saved))) }
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
            if case .node = entry { w += 8 } else { w += 14 }
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
        // A bookmark with no name shows just its icon (like Chrome).
        let title = node.isFolder ? node.displayTitle : node.title
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12)])
        button.image = node.isFolder ? Icons.folder
            : (node.icon.flatMap(Favicons.image(fromPNG:)) ?? Favicons.cached(for: node.url) ?? Icons.globe)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = Theme.icon
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = node.url?.absoluteString ?? node.displayTitle
        return button
    }

    /// Colors for a group chip that are easy to read on both light and dark themes:
    /// a solid group-colored chip with dark text (like the sidebar), a darker chip with
    /// white text when the group is turned off, and an outline for closed groups.
    private func chipStyle(_ color: GroupColor, disabled: Bool, closed: Bool) -> (fill: NSColor, text: NSColor, border: NSColor?) {
        if closed {
            let ink = Theme.isDark ? color.color : (color.color.blended(withFraction: 0.55, of: .black) ?? color.color)
            return (.clear, ink, ink)
        }
        if disabled { return (color.offColor, NSColor(white: 1, alpha: 0.92), nil) }
        return (color.color, Theme.sidebarText, nil)
    }

    private func styledChip(title: String, style: (fill: NSColor, text: NSColor, border: NSColor?), tip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: style.text, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        button.wantsLayer = true
        button.layer?.backgroundColor = style.fill.cgColor
        button.layer?.borderColor = style.border?.cgColor
        button.layer?.borderWidth = style.border == nil ? 0 : 1.5
        button.layer?.cornerRadius = 6
        button.toolTip = tip
        return button
    }

    private func makeChip(_ group: TabGroup) -> NSButton {
        let title = group.name.isEmpty ? "\(group.tabs.count) tabs" : group.name
        return styledChip(title: title, style: chipStyle(group.color, disabled: group.isDisabled, closed: false),
                          tip: group.isDisabled ? "Turned-off tab group: click to see its tabs" : "Tab group: click to see its tabs")
    }

    /// A closed group: an outline in the group's color instead of a fill.
    private func makeClosedChip(_ saved: SavedGroup) -> NSButton {
        let title = saved.name.isEmpty ? "\(saved.tabs.count) tabs" : saved.name
        return styledChip(title: title, style: chipStyle(saved.color, disabled: false, closed: true),
                          tip: "Closed tab group: click to reopen")
    }

    private func closedGroupMenu(_ saved: SavedGroup) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Group", action: #selector(BrowserWindowController.reopenSavedGroup(_:)), keyEquivalent: "")
        open.representedObject = saved.id
        menu.addItem(open)
        menu.addItem(.separator())
        for tab in saved.tabs {
            let item = NSMenuItem(title: tab.title.isEmpty ? (tab.url?.host ?? "Tab") : tab.title, action: nil, keyEquivalent: "")
            item.image = tab.icon.flatMap(Favicons.image(fromPNG:)) ?? Icons.globe
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Group", action: #selector(BrowserWindowController.deleteSavedGroup(_:)), keyEquivalent: "")
        delete.representedObject = saved.id
        menu.addItem(delete)
        return menu
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
        case .closedGroup(let saved):
            closedGroupMenu(saved).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
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
            case .closedGroup(let saved):
                let item = NSMenuItem(title: saved.name.isEmpty ? "Closed group" : saved.name, action: nil, keyEquivalent: "")
                item.image = saved.color.swatch()
                item.submenu = closedGroupMenu(saved)
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
        menu.addItem(withTitle: "Import from Chrome…", action: #selector(BrowserWindowController.importChromeBookmarks(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Bookmarks Bar", action: #selector(BrowserWindowController.toggleBookmarksBar(_:)), keyEquivalent: "")
        return menu
    }
}
