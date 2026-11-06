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
    func sidebarEditGroup(_ group: TabGroup, anchor: NSView?)
    func sidebarTogglePin(_ tab: Tab)
    func sidebarOpenTools()
    func sidebarToggleCollapse()
    func sidebarShowGroups(anchor: NSView)
    func sidebarSearchTabs()
    /// Moves a tab (from this window or another one) to a place in this window.
    func sidebarMoveTab(id: UUID, to group: TabGroup?, index: Int, pinned: Bool)
    /// Moves a whole group (from this window or another one) to a position in this window.
    func sidebarMoveGroup(id: UUID, to index: Int)
    /// A tab was dragged out of every window: open it in a new window there.
    func sidebarTearOff(id: UUID, at screenPoint: NSPoint)
    /// Clicking a turned-off group turns it back on.
    func sidebarEnableGroup(_ group: TabGroup)
    /// A group was folded up (if you were in it, move to another tab).
    func sidebarGroupCollapsed(_ group: TabGroup)
}

/// What's being dragged, written on the drag pasteboard ("tab:<id>" or "group:<id>"),
/// so tabs can also be dropped into other windows.
enum DragPayload {
    case tab(UUID)
    case group(UUID)

    var string: String {
        switch self {
        case .tab(let id): return "tab:" + id.uuidString
        case .group(let id): return "group:" + id.uuidString
        }
    }

    init?(_ info: NSDraggingInfo) {
        guard let s = info.draggingPasteboard.string(forType: .sidebarItem) else { return nil }
        if s.hasPrefix("tab:"), let id = UUID(uuidString: String(s.dropFirst(4))) { self = .tab(id) }
        else if s.hasPrefix("group:"), let id = UUID(uuidString: String(s.dropFirst(6))) { self = .group(id) }
        else { return nil }
    }
}

/// A tab container's pinned tabs, shown as a row of square tiles (like Chrome).
@MainActor
final class PinnedStrip: NSObject {
    static let columns = 4
    static let tileHeight: CGFloat = 34
    static let gap: CGFloat = 6

    weak var group: TabGroup?
    let isTopLevel: Bool
    var tabs: [Tab] = []

    init(group: TabGroup?) {
        self.group = group
        isTopLevel = group == nil
    }

    var height: CGFloat {
        let rows = max(1, (tabs.count + Self.columns - 1) / Self.columns)
        return CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.gap + 8
    }
}

/// The vertical tab list on the left, with groups that collapse and tabs you can drag.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let view = SolidView(color: Theme.sidebarFill)
    weak var delegate: SidebarDelegate?

    private let store: TabStore
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var draggedItem: NSObject?
    private var isReloading = false
    private var strips: [String: PinnedStrip] = [:]
    /// Where among the pinned tiles a dragged tab would land.
    private var pendingTileIndex = 0

    init(store: TabStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Theme.arcStyle ? .clear : Theme.sidebar
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
        outline.setDraggingSourceOperationMask([], forLocal: false)   // dragged outside the app = new window
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onGroupRightClick = { [weak self] row in
            guard let self, let group = self.outline.item(atRow: row) as? TabGroup else { return }
            self.delegate?.sidebarEditGroup(group, anchor: self.outline.rowView(atRow: row, makeIfNecessary: false))
        }
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
        scroll.drawsBackground = !Theme.arcStyle
        scroll.backgroundColor = Theme.sidebar
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        // An invisible guide for the width of the bottom row (there's no + button: use ⌘T).
        let newTab = NSView()

        // Bottom row: Tools (left half) and a placeholder (right half).
        let tools = SolidView(color: Theme.buttonFill)
        tools.cornerRadius = 8
        let toolsButton = NSButton(title: "Tools", target: self, action: #selector(toolsClicked(_:)))
        toolsButton.isBordered = false
        toolsButton.attributedTitle = NSAttributedString(string: "Tools", attributes: [
            .foregroundColor: Theme.text, .font: NSFont.systemFont(ofSize: 12)])
        toolsButton.toolTip = "File converter and background remover"
        let placeholder = SolidView(color: Theme.hoverTab)
        placeholder.cornerRadius = 8
        let placeholderLabel = NSTextField(labelWithString: "Coming soon")
        placeholderLabel.font = .systemFont(ofSize: 11)
        placeholderLabel.textColor = Theme.mutedText

        // Top: hide-sidebar button on the left; tab groups and tab search on the right (like Chrome).
        let collapse = headerButton("sidebar.leading", "Hide the tab sidebar (⌃⌘S)", #selector(collapseClicked(_:)))
        let groupsPill = SolidView(color: Theme.buttonFill)
        groupsPill.cornerRadius = 9
        let searchPill = SolidView(color: Theme.buttonFill)
        searchPill.cornerRadius = 9
        let groupsButton = headerButton("square.grid.2x2", "Tab groups", #selector(groupsClicked(_:)))
        let searchButton = headerButton("text.magnifyingglass", "Search tabs (⇧⌘A)", #selector(searchClicked(_:)))
        let headerLine = SolidView(color: Theme.buttonFill)

        for v in [collapse, groupsPill, searchPill, groupsButton, searchButton, headerLine,
                  scroll, newTab, tools, toolsButton, placeholder, placeholderLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            collapse.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            collapse.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            searchPill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchPill.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            searchPill.widthAnchor.constraint(equalToConstant: 34),
            searchPill.heightAnchor.constraint(equalToConstant: 30),
            groupsPill.trailingAnchor.constraint(equalTo: searchPill.leadingAnchor, constant: -2),
            groupsPill.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            groupsPill.widthAnchor.constraint(equalToConstant: 34),
            groupsPill.heightAnchor.constraint(equalToConstant: 30),
            groupsButton.centerXAnchor.constraint(equalTo: groupsPill.centerXAnchor),
            groupsButton.centerYAnchor.constraint(equalTo: groupsPill.centerYAnchor),
            searchButton.centerXAnchor.constraint(equalTo: searchPill.centerXAnchor),
            searchButton.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            headerLine.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            headerLine.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            headerLine.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newTab.topAnchor, constant: -6),

            newTab.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            newTab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            newTab.bottomAnchor.constraint(equalTo: tools.topAnchor),
            newTab.heightAnchor.constraint(equalToConstant: 0),

            tools.leadingAnchor.constraint(equalTo: newTab.leadingAnchor),
            tools.widthAnchor.constraint(equalTo: newTab.widthAnchor, multiplier: 0.5, constant: -3),
            tools.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            tools.heightAnchor.constraint(equalToConstant: 30),
            toolsButton.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            toolsButton.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
            toolsButton.topAnchor.constraint(equalTo: tools.topAnchor),
            toolsButton.bottomAnchor.constraint(equalTo: tools.bottomAnchor),

            placeholder.trailingAnchor.constraint(equalTo: newTab.trailingAnchor),
            placeholder.widthAnchor.constraint(equalTo: tools.widthAnchor),
            placeholder.topAnchor.constraint(equalTo: tools.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: tools.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: placeholder.centerYAnchor),

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
        if tab.pinned {
            if let strip = strips[tab.group?.id.uuidString ?? "top"] { outline.reloadItem(strip) }
            return
        }
        let row = outline.row(forItem: tab)
        guard row >= 0 else { return }
        if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
            cell.configure(tab, selected: tab === store.selected)
        }
    }

    // MARK: Clicks

    @objc private func newTabClicked(_ sender: Any?) { delegate?.sidebarNewTab(in: nil) }
    @objc private func toolsClicked(_ sender: Any?) { delegate?.sidebarOpenTools() }
    @objc private func collapseClicked(_ sender: Any?) { delegate?.sidebarToggleCollapse() }
    @objc private func groupsClicked(_ sender: NSButton) { delegate?.sidebarShowGroups(anchor: sender) }
    @objc private func searchClicked(_ sender: Any?) { delegate?.sidebarSearchTabs() }

    private func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: Icons.symbol(symbol, size: 15) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = Theme.icon
        b.toolTip = tip
        return b
    }

    /// The row showing a group's header (used to position the group editor).
    func rowView(for group: TabGroup) -> NSView? {
        let row = outline.row(forItem: group)
        return row >= 0 ? outline.rowView(atRow: row, makeIfNecessary: false) : nil
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let group = item as? TabGroup, group.isDisabled {
            delegate?.sidebarEnableGroup(group)
        } else if let group = item as? TabGroup {
            group.isCollapsed.toggle()
            if group.isCollapsed { outline.collapseItem(group) } else { outline.expandItem(group) }
            if let cell = outline.view(atColumn: 0, row: outline.row(forItem: group), makeIfNecessary: false) as? GroupCellView {
                cell.configure(group)
            }
            store.scheduleSave()
            if group.isCollapsed { delegate?.sidebarGroupCollapsed(group) }
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

    private func strip(for group: TabGroup?) -> PinnedStrip {
        let key = group?.id.uuidString ?? "top"
        if let existing = strips[key] { return existing }
        let made = PinnedStrip(group: group)
        strips[key] = made
        return made
    }

    private func entries(of group: TabGroup?) -> [NSObject] {
        group.map { $0.tabs as [NSObject] } ?? store.items
    }

    private func pinnedCount(_ group: TabGroup?) -> Int {
        entries(of: group).filter { ($0 as? Tab)?.pinned == true }.count
    }

    /// What the list shows inside a container: one row of tiles for the pinned tabs, then the rest.
    private func children(of group: TabGroup?) -> [NSObject] {
        let all = entries(of: group)
        let pinned = all.compactMap { $0 as? Tab }.filter(\.pinned)
        let rest = all.filter { ($0 as? Tab)?.pinned != true }
        guard !pinned.isEmpty else { return rest }
        let row = strip(for: group)
        row.tabs = pinned
        return [row] + rest
    }

    /// The tile row takes one line in the list but stands for several tabs in the store.
    private func storeIndex(_ listIndex: Int, in group: TabGroup?) -> Int {
        let p = pinnedCount(group)
        return p == 0 ? listIndex : max(listIndex - 1, 0) + p
    }

    private func listIndex(_ storeIndex: Int, in group: TabGroup?) -> Int {
        let p = pinnedCount(group)
        return p == 0 ? storeIndex : max(storeIndex - p, 0) + 1
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return children(of: nil).count }
        if let group = item as? TabGroup { return children(of: group).count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? TabGroup)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is TabGroup }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let strip = item as? PinnedStrip {
            let cell = outlineView.makeView(withIdentifier: PinnedStripCellView.id, owner: nil) as? PinnedStripCellView
                ?? PinnedStripCellView()
            cell.configure(strip, selected: store.selected, actions: tileActions)
            return cell
        }
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
        row.isGroupHeader = item is TabGroup || item is PinnedStrip
        row.isSelectedTab = (item as? Tab) === store.selected
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let strip = item as? PinnedStrip { return strip.height }
        return item is TabGroup ? 28 : 30
    }

    private var tileActions: PinnedTile.Actions {
        PinnedTile.Actions(
            select: { [weak self] tab in self?.delegate?.sidebarSelect(tab) },
            close: { [weak self] tab in self?.delegate?.sidebarClose(tab) },
            tearOff: { [weak self] tab, point in self?.delegate?.sidebarTearOff(id: tab.id, at: point) },
            menu: { [weak self] tab in
                let menu = NSMenu()
                self?.fillTabMenu(menu, for: tab)
                return menu
            })
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
        if let tab = item as? Tab { p.setString(DragPayload.tab(tab.id).string, forType: .sidebarItem) }
        else if let group = item as? TabGroup { p.setString(DragPayload.group(group.id).string, forType: .sidebarItem) }
        else { return nil }   // pinned tiles start their own drags
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedItem = draggedItems.first as? NSObject
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [], let tab = draggedItem as? Tab { delegate?.sidebarTearOff(id: tab.id, at: screenPoint) }
        draggedItem = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let payload = DragPayload(info) else { return [] }
        let afterTiles = 1   // list position just below a row of pinned tiles

        if case .group = payload {
            // Groups can only be moved between other top-level entries.
            if let strip = item as? PinnedStrip, strip.isTopLevel {
                outlineView.setDropItem(nil, dropChildIndex: afterTiles)
            } else if let target = item as? NSObject {
                let top: NSObject = (target as? Tab)?.group ?? (target as? PinnedStrip)?.group ?? target
                guard let i = store.items.firstIndex(of: top) else { return [] }
                outlineView.setDropItem(nil, dropChildIndex: listIndex(i, in: nil))
            } else if index == NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(nil, dropChildIndex: children(of: nil).count)
            } else if index == 0, pinnedCount(nil) > 0 {
                outlineView.setDropItem(nil, dropChildIndex: afterTiles)
            }
            return .move
        }

        // A tab.
        if let strip = item as? PinnedStrip {   // over the pinned tiles: pin it at that spot
            pendingTileIndex = tileIndex(in: strip, at: info.draggingLocation)
            outlineView.setDropItem(strip, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        if item == nil {
            if index == NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(nil, dropChildIndex: children(of: nil).count)
            } else if index == 0, pinnedCount(nil) > 0 {
                outlineView.setDropItem(nil, dropChildIndex: afterTiles)
            }
            return .move
        }
        if let group = item as? TabGroup {
            if index == NSOutlineViewDropOnItemIndex {   // dropped on the group's header: add at the end
                outlineView.setDropItem(group, dropChildIndex: children(of: group).count)
            } else if index == 0, pinnedCount(group) > 0 {
                outlineView.setDropItem(group, dropChildIndex: afterTiles)
            }
            return .move
        }
        if let tab = item as? Tab, let loc = store.location(of: tab) {   // dropped on a tab: go before it
            outlineView.setDropItem(loc.group, dropChildIndex: listIndex(loc.index, in: loc.group))
            return .move
        }
        return []
    }

    /// Which tile position (0 = first) a point over a row of pinned tiles is closest to.
    private func tileIndex(in strip: PinnedStrip, at windowPoint: NSPoint) -> Int {
        let row = outline.row(forItem: strip)
        guard row >= 0 else { return strip.tabs.count }
        let rect = outline.rect(ofRow: row)
        let p = outline.convert(windowPoint, from: nil)
        let columns = PinnedStrip.columns
        let tileWidth = (rect.width - 16) / CGFloat(columns)
        let column = min(columns - 1, max(0, Int((p.x - rect.minX - 8 + tileWidth / 2) / tileWidth)))
        // the outline is flipped: y grows downward
        let line = max(0, Int((p.y - rect.minY - 4) / (PinnedStrip.tileHeight + PinnedStrip.gap)))
        return min(strip.tabs.count, line * columns + column)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let payload = DragPayload(info) else { return false }
        switch payload {
        case .group(let id):
            delegate?.sidebarMoveGroup(id: id, to: index < 0 ? store.items.count : storeIndex(index, in: nil))
        case .tab(let id):
            if let strip = item as? PinnedStrip {
                delegate?.sidebarMoveTab(id: id, to: strip.isTopLevel ? nil : strip.group, index: pendingTileIndex, pinned: true)
            } else {
                let group = item as? TabGroup
                let end = group?.tabs.count ?? store.items.count
                delegate?.sidebarMoveTab(id: id, to: group, index: index < 0 ? end : storeIndex(index, in: group), pinned: false)
            }
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
        if let tab = item as? Tab { fillTabMenu(menu, for: tab) }
    }

    /// The right-click menu for a tab (also used by pinned tiles).
    func fillTabMenu(_ menu: NSMenu, for tab: Tab) {
        do {
            add(menu, tab.pinned ? "Unpin Tab" : "Pin Tab", #selector(menuTogglePin(_:)), tab)
            add(menu, "Reload", #selector(menuReload(_:)), tab)
            add(menu, "Duplicate", #selector(menuDuplicate(_:)), tab)
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
    @objc private func menuTogglePin(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarTogglePin(v) } }
    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        delegate?.sidebarSelect(tab)
        NSApp.sendAction(#selector(BrowserWindowController.duplicateTab(_:)), to: nil, from: nil)
    }
    @objc private func menuReload(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarReload(v) } }
    @objc private func menuUnload(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarUnload(v) } }
    @objc private func menuClose(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarClose(v) } }
    @objc private func menuCloseOthers(_ sender: NSMenuItem) { if let v = sender.representedObject as? Tab { delegate?.sidebarCloseOthers(v) } }

    @objc private func menuNewGroup(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        let group = store.makeGroup(with: tab)
        delegate?.sidebarEditGroup(group, anchor: nil)
    }

    @objc private func menuAddToGroup(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [NSObject],
              let tab = pair.first as? Tab, let group = pair.last as? TabGroup else { return }
        store.add(tab, to: group)
    }

    @objc private func menuRemoveFromGroup(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Tab { store.removeFromGroup(v) }
    }





}

// MARK: - Views

/// The list itself, without the usual disclosure triangles and indentation.
final class SidebarOutlineView: NSOutlineView {
    var onMiddleClick: ((Int) -> Void)?
    var onGroupRightClick: ((Int) -> Void)?

    /// Right-clicking a group header opens the group editor instead of a menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, item(atRow: row) is TabGroup {
            onGroupRightClick?(row)
            return nil
        }
        return super.menu(for: event)
    }

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
    private let pinIcon = NSImageView()
    private var isPinned = false

    var showsClose = false { didSet { updateTrailing() } }

    private func updateTrailing() {
        // Pinned tabs show a pin; hovering shows the close button instead.
        closeButton.isHidden = !showsClose
        pinIcon.isHidden = !isPinned || showsClose
    }

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

        pinIcon.image = Icons.symbol("pin.fill", size: 10)
        pinIcon.contentTintColor = Theme.mutedText
        pinIcon.isHidden = true
        for v in [groupLine, icon, label, closeButton, pinIcon] as [NSView] {
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
            pinIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            pinIcon.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
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
        isPinned = tab.pinned
        updateTrailing()
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
        label.textColor = Theme.sidebarText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.contentTintColor = Theme.sidebarText

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
        // A turned-off group is grey until you click it.
        chip.fillColor = group.isDisabled ? group.color.offColor : group.color.color
        label.textColor = group.isDisabled ? group.color.color : Theme.sidebarText
        chevron.contentTintColor = label.textColor
        let count = group.tabs.count
        let countText = "\(count) tab\(count == 1 ? "" : "s")"
        if group.isDisabled {
            label.stringValue = (group.name.isEmpty ? countText : group.name) + "  ·  off"
        } else if group.name.isEmpty {
            label.stringValue = group.isCollapsed ? countText : ""
        } else {
            label.stringValue = group.isCollapsed ? "\(group.name)  ·  \(countText)" : group.name
        }
        chevron.image = Icons.symbol(group.isCollapsed ? "chevron.down" : "chevron.up", size: 11, weight: .semibold)
        toolTip = group.isDisabled ? "Turned off to save memory. Click to turn it back on."
            : "Click to \(group.isCollapsed ? "expand" : "collapse"). Right-click to edit or turn off the group."
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

/// The row that shows pinned tabs as square tiles, four across.
final class PinnedStripCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("pinned")
    private var tiles: [PinnedTile] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ strip: PinnedStrip, selected: Tab?, actions: PinnedTile.Actions) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = strip.tabs.map { tab in
            let tile = PinnedTile(tab: tab, selected: tab === selected, groupColor: strip.group?.color.color, actions: actions)
            addSubview(tile)
            return tile
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let gap = PinnedStrip.gap
        let columns = CGFloat(PinnedStrip.columns)
        let width = (bounds.width - inset * 2 - gap * (columns - 1)) / columns
        for (i, tile) in tiles.enumerated() {
            let row = i / PinnedStrip.columns
            let column = i % PinnedStrip.columns
            let top = 4 + CGFloat(row) * (PinnedStrip.tileHeight + gap)
            tile.frame = NSRect(x: inset + CGFloat(column) * (width + gap),
                                y: bounds.height - top - PinnedStrip.tileHeight,
                                width: width, height: PinnedStrip.tileHeight)
        }
    }
}

/// One pinned tab: a rounded tile with the site's icon. Click to open,
/// right-click for options, middle-click to close.
final class PinnedTile: SolidView, NSDraggingSource {
    struct Actions {
        let select: (Tab) -> Void
        let close: (Tab) -> Void
        let tearOff: (Tab, NSPoint) -> Void
        let menu: (Tab) -> NSMenu
    }
    private var mouseDownAt: NSPoint?
    private var isDragging = false

    private let tab: Tab
    private let actions: Actions
    private let isSelected: Bool

    init(tab: Tab, selected: Bool, groupColor: NSColor?, actions: Actions) {
        self.tab = tab
        self.actions = actions
        self.isSelected = selected
        super.init(color: selected ? Theme.selectedTab : Theme.tileFill)
        cornerRadius = 10
        borderWidth = 1.5
        borderColor = groupColor?.blended(withFraction: 0.45, of: Theme.sidebar) ?? NSColor(hex: 0x4A4C62)
        let icon = NSImageView(image: tab.favicon ?? Icons.globe ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.mutedText
        icon.alphaValue = (tab.isLoaded || selected) ? 1 : 0.55   // dimmer when unloaded
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        toolTip = tab.displayTitle + (tab.isLoaded ? "" : "\n(Unloaded to save memory — click to reload)")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { if !isSelected { fillColor = Theme.hoverTab } }
    override func mouseExited(with event: NSEvent) { if !isSelected { fillColor = Theme.tileFill } }
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        isDragging = false
    }

    /// Dragging a tile moves the tab: within the tiles, into the list (unpins it),
    /// into another window, or out of every window (opens a new window).
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, !isDragging,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        isDragging = true
        let item = NSPasteboardItem()
        item.setString(DragPayload.tab(tab.id).string, forType: .sidebarItem)
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
        if !isDragging, bounds.contains(convert(event.locationInWindow, from: nil)) { actions.select(tab) }
        mouseDownAt = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] { actions.tearOff(tab, screenPoint) }
        isDragging = false
    }

    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) { actions.close(tab) }
    override func menu(for event: NSEvent) -> NSMenu? { actions.menu(tab) }
}
