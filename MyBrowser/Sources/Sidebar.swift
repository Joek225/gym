import AppKit

extension NSPasteboard.PasteboardType {
    static let sidebarItem = NSPasteboard.PasteboardType("local.mybrowser.sidebar-item")
}

/// What the sidebar asks the window to do.
@MainActor
protocol SidebarDelegate: AnyObject {
    func sidebarSelect(_ tab: Tab)
    func sidebarClose(_ tab: Tab)
    func sidebarCloseOthers(_ tab: Tab)
    func sidebarReload(_ tab: Tab)
    func sidebarUnload(_ tab: Tab)
    func sidebarNewTab(in group: TabGroup?)
    func sidebarEditGroup(_ group: TabGroup)
    func sidebarCloseGroup(_ group: TabGroup)
}

/// The vertical tab list on the left, with groups that collapse and tabs you can drag.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let view = SolidView(color: Theme.sidebar)
    weak var delegate: SidebarDelegate?

    private let store: TabStore
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var draggedItem: NSObject?
    private var isReloading = false

    init(store: TabStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Theme.sidebar
        outline.selectionHighlightStyle = .none
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 0
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.registerForDraggedTypes([.sidebarItem])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onMiddleClick = { [weak self] row in
            guard let self, let tab = self.outline.item(atRow: row) as? Tab else { return }
            self.delegate?.sidebarClose(tab)
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.sidebar
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let newTab = SolidView(color: Theme.toolbar)
        newTab.cornerRadius = 8
        let plus = NSButton(image: Icons.symbol("plus", size: 14, weight: .medium) ?? NSImage(),
                            target: self, action: #selector(newTabClicked(_:)))
        plus.isBordered = false
        plus.contentTintColor = Theme.text
        plus.toolTip = "New Tab (⌘T)"

        for v in [scroll, newTab, plus] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newTab.topAnchor, constant: -6),

            newTab.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            newTab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            newTab.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            newTab.heightAnchor.constraint(equalToConstant: 30),

            plus.leadingAnchor.constraint(equalTo: newTab.leadingAnchor),
            plus.trailingAnchor.constraint(equalTo: newTab.trailingAnchor),
            plus.topAnchor.constraint(equalTo: newTab.topAnchor),
            plus.bottomAnchor.constraint(equalTo: newTab.bottomAnchor),
        ])
    }

    // MARK: Refreshing

    func reload() {
        isReloading = true
        outline.reloadData()
        for group in store.groups {
            if group.isCollapsed { outline.collapseItem(group) } else { outline.expandItem(group) }
        }
        outline.sizeLastColumnToFit()
        isReloading = false
        if let selected = store.selected {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
    }

    /// Updates one tab's row (title, icon) without rebuilding the list.
    func refresh(_ tab: Tab) {
        let row = outline.row(forItem: tab)
        guard row >= 0 else { return }
        if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
            cell.configure(tab, selected: tab === store.selected)
        }
    }

    // MARK: Clicks

    @objc private func newTabClicked(_ sender: Any?) { delegate?.sidebarNewTab(in: nil) }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let group = item as? TabGroup {
            group.isCollapsed.toggle()
            if group.isCollapsed { outline.collapseItem(group) } else { outline.expandItem(group) }
            if let cell = outline.view(atColumn: 0, row: outline.row(forItem: group), makeIfNecessary: false) as? GroupCellView {
                cell.configure(group)
            }
            store.scheduleSave()
        } else if let tab = item as? Tab {
            delegate?.sidebarSelect(tab)
        }
    }

    @objc fileprivate func closeClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let tab = outline.item(atRow: row) as? Tab else { return }
        delegate?.sidebarClose(tab)
    }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return store.items.count }
        return (item as? TabGroup)?.tabs.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? TabGroup { return group.tabs[index] }
        return store.items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is TabGroup }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? TabGroup {
            let cell = outlineView.makeView(withIdentifier: GroupCellView.id, owner: nil) as? GroupCellView ?? GroupCellView()
            cell.configure(group)
            return cell
        }
        guard let tab = item as? Tab else { return nil }
        let cell = outlineView.makeView(withIdentifier: TabCellView.id, owner: nil) as? TabCellView
            ?? TabCellView(target: self, closeAction: #selector(closeClicked(_:)))
        cell.configure(tab, selected: tab === store.selected)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.isGroupHeader = item is TabGroup
        row.isSelectedTab = (item as? Tab) === store.selected
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is TabGroup ? 28 : 30
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineViewItemDidExpand(_ notification: Notification) { syncCollapse(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { syncCollapse(notification, collapsed: true) }

    private func syncCollapse(_ notification: Notification, collapsed: Bool) {
        guard !isReloading, let group = notification.userInfo?["NSObject"] as? TabGroup,
              group.isCollapsed != collapsed else { return }
        group.isCollapsed = collapsed
        store.scheduleSave()
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let p = NSPasteboardItem()
        p.setString("item", forType: .sidebarItem)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedItem = draggedItems.first as? NSObject
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedItem = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let dragged = draggedItem else { return [] }

        if dragged is TabGroup {
            // Groups can only be moved between other top-level entries.
            if let target = item as? NSObject {
                let top: NSObject = (target as? Tab)?.group ?? target
                guard let i = store.items.firstIndex(of: top) else { return [] }
                outlineView.setDropItem(nil, dropChildIndex: i)
            } else if index == NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(nil, dropChildIndex: store.items.count)
            }
            return .move
        }

        guard dragged is Tab else { return [] }
        if item == nil {
            if index == NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(nil, dropChildIndex: store.items.count)
            }
            return .move
        }
        if let group = item as? TabGroup {
            if index == NSOutlineViewDropOnItemIndex {   // dropped on the group's header: add at the end
                outlineView.setDropItem(group, dropChildIndex: group.tabs.count)
            }
            return .move
        }
        if let tab = item as? Tab, let loc = store.location(of: tab) {   // dropped on a tab: go before it
            outlineView.setDropItem(loc.group, dropChildIndex: loc.index)
            return .move
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let dragged = draggedItem else { return false }
        if let group = dragged as? TabGroup {
            store.move(group, to: index < 0 ? store.items.count : index)
        } else if let tab = dragged as? Tab {
            let group = item as? TabGroup
            store.move(tab, to: group, index: index < 0 ? (group?.tabs.count ?? store.items.count) : index)
        }
        return true
    }

    // MARK: Right-click menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else {
            add(menu, "New Tab", #selector(menuNewTab(_:)), nil)
            return
        }
        if let tab = item as? Tab {
            add(menu, "Reload", #selector(menuReload(_:)), tab)
            add(menu, "Unload Tab (Free Memory)", #selector(menuUnload(_:)), tab).isEnabled = tab.isLoaded
            menu.addItem(.separator())
            add(menu, "Add Tab to New Group", #selector(menuNewGroup(_:)), tab)
            let others = store.groups.filter { $0 !== tab.group }
            if !others.isEmpty {
                let sub = NSMenu()
                for g in others {
                    let mi = add(sub, g.name.isEmpty ? "Unnamed group" : g.name, #selector(menuAddToGroup(_:)), [tab, g])
                    mi.image = g.color.swatch()
                }
                let parent = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            if tab.group != nil {
                add(menu, "Remove from Group", #selector(menuRemoveFromGroup(_:)), tab)
            }
            menu.addItem(.separator())
            add(menu, "Close Tab", #selector(menuClose(_:)), tab)
            add(menu, "Close Other Tabs", #selector(menuCloseOthers(_:)), tab)
        } else if let group = item as? TabGroup {
            add(menu, "New Tab in Group", #selector(menuNewTabInGroup(_:)), group)
            add(menu, "Name and Color…", #selector(menuEditGroup(_:)), group)
            let colors = NSMenu()
            for c in GroupColor.allCases {
                let mi = add(colors, c.name, #selector(menuSetColor(_:)), [group, c.rawValue as NSString])
                mi.image = c.swatch()
                mi.state = c == group.color ? .on : .off
            }
            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            menu.addItem(.separator())
            add(menu, "Ungroup", #selector(menuUngroup(_:)), group)
            add(menu, "Close Group", #selector(menuCloseGroup(_:)), group)
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        menu.addItem(item)
        return item
    }

    @objc private func menuNewTab(_ sender: NSMenuItem) { delegate?.sidebarNewTab(in: nil) }
    @objc private func menuReload(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarReload(v) } }
    @objc private func menuUnload(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarUnload(v) } }
    @objc private func menuClose(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarClose(v) } }
    @objc private func menuCloseOthers(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarCloseOthers(v) } }

    @objc private func menuNewGroup(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        let group = store.makeGroup(with: tab)
        delegate?.sidebarEditGroup(group)
    }

    @objc private func menuAddToGroup(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [NSObject],
              let tab = pair.first as? Tab, let group = pair.last as? TabGroup else { return }
        store.add(tab, to: group)
    }

    @objc private func menuRemoveFromGroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Tab { store.removeFromGroup(v) }
    }

    @objc private func menuNewTabInGroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TabGroup { delegate?.sidebarNewTab(in: v) }
    }

    @objc private func menuEditGroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TabGroup { delegate?.sidebarEditGroup(v) }
    }

    @objc private func menuSetColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [NSObject], let group = pair.first as? TabGroup,
              let raw = pair.last as? String, let color = GroupColor(rawValue: raw) else { return }
        group.color = color
        store.changed()
    }

    @objc private func menuUngroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TabGroup { store.ungroup(v) }
    }

    @objc private func menuCloseGroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TabGroup { delegate?.sidebarCloseGroup(v) }
    }
}

// MARK: - Views

/// The list itself, without the usual disclosure triangles and indentation.
final class SidebarOutlineView: NSOutlineView {
    var onMiddleClick: ((Int) -> Void)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let f = super.frameOfCell(atColumn: column, row: row)
        return NSRect(x: 0, y: f.minY, width: bounds.width, height: f.height)
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClick?(row) } else { super.otherMouseDown(with: event) }
    }
}

/// One row's background: highlighted when it's the current tab or under the mouse.
final class SidebarRowView: NSTableRowView {
    var isGroupHeader = false
    var isSelectedTab = false { didSet { update() } }
    private var isHovered = false { didSet { update() } }
    private let pill = SolidView(color: .clear)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.cornerRadius = 8
        addSubview(pill, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        pill.frame = bounds.insetBy(dx: 6, dy: 0)
    }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        update()
    }

    private func update() {
        if isGroupHeader {
            pill.fillColor = .clear
        } else {
            pill.fillColor = isSelectedTab ? Theme.selectedTab : (isHovered ? Theme.hoverTab : .clear)
        }
        // Find our tab cell directly (asking the table for a column is unsafe while the row is being built).
        for case let cell as TabCellView in subviews { cell.showsClose = isSelectedTab || isHovered }
    }
}

/// A tab row: group color line, site icon, title, and a close button.
final class TabCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("tab")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let groupLine = SolidView(color: .clear)

    var showsClose = false { didSet { closeButton.isHidden = !showsClose } }

    init(target: AnyObject, closeAction: Selector) {
        super.init(frame: .zero)
        identifier = Self.id

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = Icons.symbol("xmark", size: 10, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.mutedText
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.target = target
        closeButton.action = closeAction
        closeButton.isHidden = true
        groupLine.cornerRadius = 1

        for v in [groupLine, icon, label, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            groupLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            groupLine.widthAnchor.constraint(equalToConstant: 2),
            groupLine.topAnchor.constraint(equalTo: topAnchor, constant: -1),
            groupLine.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ tab: Tab, selected: Bool) {
        icon.image = tab.favicon ?? Icons.globe
        icon.contentTintColor = Theme.mutedText
        label.stringValue = tab.displayTitle
        // Unloaded (sleeping) tabs are shown slightly dimmer.
        label.textColor = (tab.isLoaded || selected) ? Theme.text : Theme.mutedText
        if let group = tab.group {
            groupLine.fillColor = group.color.color
            groupLine.isHidden = false
        } else {
            groupLine.isHidden = true
        }
        let sleeping = tab.isLoaded ? "" : "\n(Unloaded to save memory — click to reload)"
        toolTip = "\(tab.displayTitle)\n\(tab.displayURL?.absoluteString ?? "")\(sleeping)"
    }
}

/// A group's header: a colored bar with the group's name, like Chrome.
final class GroupCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("group")
    private let chip = SolidView(color: .clear)
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        chip.cornerRadius = 7
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = Theme.sidebar
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.contentTintColor = Theme.sidebar

        for v in [chip, label, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            chip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -6),
            chevron.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ group: TabGroup) {
        chip.fillColor = group.color.color
        let count = group.tabs.count
        let countText = "\(count) tab\(count == 1 ? "" : "s")"
        if group.name.isEmpty {
            label.stringValue = group.isCollapsed ? countText : ""
        } else {
            label.stringValue = group.isCollapsed ? "\(group.name)  ·  \(countText)" : group.name
        }
        chevron.image = Icons.symbol(group.isCollapsed ? "chevron.down" : "chevron.up", size: 11, weight: .semibold)
        toolTip = "Click to \(group.isCollapsed ? "expand" : "collapse"). Right-click to rename, recolor or ungroup."
    }
}

/// The thin invisible strip between the sidebar and the page; drag it to resize.
final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}
