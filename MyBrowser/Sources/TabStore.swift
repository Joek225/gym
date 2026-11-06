import AppKit
import WebKit

/// All tabs and groups, in sidebar order, plus saving/restoring them.
/// `items` holds top-level entries: each is either a Tab or a TabGroup
/// (and a group holds its own tabs).
@MainActor
final class TabStore: NSObject {
    private(set) var items: [NSObject] = []
    var selected: Tab?
    /// Called whenever tabs or groups are added, removed, moved or renamed.
    var onChange: (() -> Void)?

    struct ClosedTab {
        let url: URL?
        let title: String
        let state: Any?
        let icon: Data?
        let groupID: UUID?
    }
    var recentlyClosed: [ClosedTab] = []

    var allTabs: [Tab] {
        items.flatMap { item -> [Tab] in
            if let group = item as? TabGroup { return group.tabs }
            if let tab = item as? Tab { return [tab] }
            return []
        }
    }

    var groups: [TabGroup] { items.compactMap { $0 as? TabGroup } }

    func tab(for webView: WKWebView) -> Tab? { allTabs.first { $0.webView === webView } }

    /// Where a tab lives: its group (nil = top level) and its position there.
    func location(of tab: Tab) -> (group: TabGroup?, index: Int)? {
        if let group = tab.group, let i = group.tabs.firstIndex(of: tab) { return (group, i) }
        if let i = items.firstIndex(of: tab) { return (nil, i) }
        return nil
    }

    // MARK: Changing tabs

    func insert(_ tab: Tab, at index: Int, in group: TabGroup?) {
        if let group {
            tab.group = group
            group.tabs.insert(tab, at: max(0, min(index, group.tabs.count)))
        } else {
            tab.group = nil
            items.insert(tab, at: max(0, min(index, items.count)))
        }
        changed()
    }

    /// Chrome-style: a tab opened from another goes right after it, in the same group.
    func insert(_ tab: Tab, after neighbor: Tab?) {
        guard let neighbor, let loc = location(of: neighbor) else {
            insert(tab, at: items.count, in: nil)
            return
        }
        insert(tab, at: loc.index + 1, in: loc.group)
    }

    func remove(_ tab: Tab) {
        guard let loc = location(of: tab) else { return }
        if let group = loc.group { group.tabs.remove(at: loc.index) } else { items.remove(at: loc.index) }
        tab.group = nil
        if selected === tab { selected = nil }
        removeEmptyGroups()
        changed()
    }

    /// Moves a tab to a position inside a group, or at the top level (group nil).
    func move(_ tab: Tab, to group: TabGroup?, index: Int) {
        guard let from = location(of: tab) else { return }
        var index = index
        if from.group === group && from.index < index { index -= 1 }
        if let g = from.group { g.tabs.remove(at: from.index) } else { items.remove(at: from.index) }
        if let group, items.contains(group) {
            tab.group = group
            group.tabs.insert(tab, at: max(0, min(index, group.tabs.count)))
        } else {
            tab.group = nil
            items.insert(tab, at: max(0, min(index, items.count)))
        }
        removeEmptyGroups()
        changed()
    }

    func move(_ group: TabGroup, to index: Int) {
        guard let from = items.firstIndex(of: group) else { return }
        var index = index
        if from < index { index -= 1 }
        items.remove(at: from)
        items.insert(group, at: max(0, min(index, items.count)))
        changed()
    }

    // MARK: Groups

    /// Puts a tab into a brand-new group, where the tab was.
    @discardableResult
    func makeGroup(with tab: Tab) -> TabGroup {
        let used = Set(groups.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) } ?? .grey
        let group = TabGroup(name: "", color: color)
        let anchor: Int
        if let old = tab.group, let gi = items.firstIndex(of: old) {
            anchor = gi + 1
        } else {
            anchor = items.firstIndex(of: tab) ?? items.count
        }
        if let loc = location(of: tab) {
            if let g = loc.group { g.tabs.remove(at: loc.index) } else { items.remove(at: loc.index) }
        }
        tab.group = group
        group.tabs = [tab]
        items.insert(group, at: max(0, min(anchor, items.count)))
        removeEmptyGroups()
        changed()
        return group
    }

    func add(_ tab: Tab, to group: TabGroup) {
        move(tab, to: group, index: group.tabs.count)
    }

    func removeFromGroup(_ tab: Tab) {
        guard let group = tab.group, let gi = items.firstIndex(of: group) else { return }
        move(tab, to: nil, index: gi + 1)
    }

    /// Dissolves a group, leaving its tabs where they were.
    func ungroup(_ group: TabGroup) {
        guard let gi = items.firstIndex(of: group) else { return }
        items.remove(at: gi)
        group.tabs.forEach { $0.group = nil }
        items.insert(contentsOf: group.tabs as [NSObject], at: gi)
        group.tabs = []
        changed()
    }

    // MARK: Pinning and moving groups between windows

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        tab.pinned = pinned
        changed()
    }

    /// Removes a whole group from this window (to move it to another).
    func take(_ group: TabGroup) {
        items.removeAll { $0 === group }
        if selected?.group === group { selected = nil }
        changed()
    }

    /// Adds a whole group at the end of this window.
    func adopt(_ group: TabGroup) {
        items.append(group)
        group.tabs.forEach { $0.group = group }
        changed()
    }

    private func removeEmptyGroups() {
        items.removeAll { ($0 as? TabGroup)?.tabs.isEmpty == true }
    }

    /// Pinned tabs always sit at the top of their group (or of the sidebar).
    private func keepPinnedFirst() {
        func pinnedTab(_ item: NSObject) -> Bool { (item as? Tab)?.pinned == true }
        items = items.filter(pinnedTab) + items.filter { !pinnedTab($0) }
        for group in groups {
            group.tabs = group.tabs.filter(\.pinned) + group.tabs.filter { !$0.pinned }
        }
    }

    func changed() {
        keepPinnedFirst()
        onChange?()
        scheduleSave()
    }

    // MARK: Saving and restoring

    func scheduleSave() { SessionSaver.shared.scheduleSave() }
    func saveNow() { SessionSaver.shared.saveNow() }

    /// This window's tabs and groups, ready to be written to disk.
    func snapshot() -> SavedSession {
        let saveItems: [SavedItem] = items.compactMap { item in
            if let g = item as? TabGroup {
                let saved = Self.savedGroup(g)
                return saved.tabs.isEmpty ? nil : SavedItem(tab: nil, group: saved)
            }
            guard let tab = item as? Tab, let st = Self.savedTab(tab) else { return nil }
            return SavedItem(tab: st, group: nil)
        }
        return SavedSession(items: saveItems, selected: selected?.id)
    }

    /// Brings back saved tabs and groups. Tabs come back unloaded
    /// (using no memory) and only load when you click them.
    func restore(from session: SavedSession) {
        items = session.items.compactMap { item in
            if let sg = item.group { return Self.makeGroup(sg) }
            return item.tab.map(Self.makeTab)
        }
        removeEmptyGroups()
        keepPinnedFirst()
        selected = allTabs.first { $0.id == session.selected }
    }

    static func savedTab(_ t: Tab) -> SavedTab? {
        guard let url = t.webView?.url ?? t.url, url.absoluteString != "about:blank" else { return nil }
        return SavedTab(id: t.id, url: url, title: t.title, icon: t.faviconPNG, pinned: t.pinned ? true : nil)
    }

    static func savedGroup(_ g: TabGroup) -> SavedGroup {
        SavedGroup(id: g.id, name: g.name, color: g.color, collapsed: g.isCollapsed, tabs: g.tabs.compactMap(savedTab))
    }

    static func makeTab(_ s: SavedTab) -> Tab {
        let tab = Tab(id: s.id, url: s.url, title: s.title)
        tab.pinned = s.pinned ?? false
        if let icon = s.icon {
            tab.faviconPNG = icon
            tab.favicon = Favicons.image(fromPNG: icon)
            tab.faviconHost = s.url?.host
        }
        return tab
    }

    static func makeGroup(_ sg: SavedGroup) -> TabGroup {
        let group = TabGroup(id: sg.id, name: sg.name, color: sg.color, isCollapsed: sg.collapsed)
        group.tabs = sg.tabs.map(makeTab)
        group.tabs.forEach { $0.group = group }
        return group
    }
}

struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String
    var icon: Data?
    var pinned: Bool?
}

struct SavedGroup: Codable {
    var id: UUID
    var name: String
    var color: GroupColor
    var collapsed: Bool
    var tabs: [SavedTab]
}

struct SavedItem: Codable {
    var tab: SavedTab?
    var group: SavedGroup?
}

struct SavedSession: Codable {
    var items: [SavedItem]
    var selected: UUID?
}
