import AppKit

/// A bookmark (has a URL) or a folder (has children).
final class BookmarkNode: Codable {
    var id = UUID()
    var title: String
    var url: URL?
    var children: [BookmarkNode]?
    /// The site's small icon, saved with the bookmark.
    var icon: Data?

    var isFolder: Bool { children != nil }

    init(title: String, url: URL?) {
        self.title = title
        self.url = url
    }

    init(folder title: String, children: [BookmarkNode] = []) {
        self.title = title
        self.children = children
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host ?? "Untitled"
    }

    /// Number of bookmarks (not folders) inside, at any depth.
    var bookmarkCount: Int {
        guard let children else { return 1 }
        return children.reduce(0) { $0 + $1.bookmarkCount }
    }
}

/// All bookmarks: the Bookmarks Bar folder and an Other Bookmarks folder, like Chrome.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore()
    static let didChange = Notification.Name("MyBrowserBookmarksDidChange")

    private(set) var bar: BookmarkNode
    private(set) var other: BookmarkNode
    private var savedURLs: Set<String> = []

    private struct File: Codable {
        var bar: BookmarkNode
        var other: BookmarkNode
    }

    private init() {
        if let data = try? Data(contentsOf: Storage.bookmarks),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            bar = file.bar
            other = file.other
        } else {
            bar = BookmarkNode(folder: "Bookmarks Bar")
            other = BookmarkNode(folder: "Other Bookmarks")
        }
        rebuildIndex()
    }

    // MARK: Looking things up

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return savedURLs.contains(url.absoluteString)
    }

    func bookmark(for url: URL) -> BookmarkNode? {
        find(in: [bar, other]) { $0.url?.absoluteString == url.absoluteString }
    }

    func parent(of node: BookmarkNode) -> BookmarkNode? {
        find(in: [bar, other]) { folder in folder.children?.contains { $0 === node } == true }
    }

    /// Every folder, with how deep it is (for the folder picker).
    func allFolders(excluding excluded: BookmarkNode? = nil) -> [(folder: BookmarkNode, depth: Int)] {
        var result: [(folder: BookmarkNode, depth: Int)] = []
        func walk(_ node: BookmarkNode, _ depth: Int) {
            guard node.isFolder, node !== excluded else { return }
            result.append((folder: node, depth: depth))
            node.children?.forEach { walk($0, depth + 1) }
        }
        walk(bar, 0)
        walk(other, 0)
        return result
    }

    private func find(in nodes: [BookmarkNode], where match: (BookmarkNode) -> Bool) -> BookmarkNode? {
        for node in nodes {
            if match(node) { return node }
            if let children = node.children, let hit = find(in: children, where: match) { return hit }
        }
        return nil
    }

    // MARK: Changing things

    func add(_ node: BookmarkNode, to folder: BookmarkNode) {
        folder.children = (folder.children ?? []) + [node]
        changed()
    }

    func remove(_ node: BookmarkNode) {
        guard let parent = parent(of: node) else { return }
        parent.children?.removeAll { $0 === node }
        changed()
    }

    func update(_ node: BookmarkNode, title: String, url: URL?, folder: BookmarkNode?) {
        node.title = title
        if !node.isFolder, let url { node.url = url }
        if let folder, let current = parent(of: node), current !== folder {
            current.children?.removeAll { $0 === node }
            folder.children = (folder.children ?? []) + [node]
        }
        changed()
    }

    /// Adds Chrome's bookmarks. If your bar is empty they go straight onto it,
    /// otherwise into a folder called "Imported from Chrome".
    func importChrome(bar chromeBar: [BookmarkNode], other chromeOther: [BookmarkNode], mobile: [BookmarkNode]) {
        if (bar.children ?? []).isEmpty {
            bar.children = chromeBar
            other.children = (other.children ?? []) + chromeOther
        } else {
            var imported = chromeBar
            if !chromeOther.isEmpty { imported.append(BookmarkNode(folder: "Other Bookmarks", children: chromeOther)) }
            bar.children = (bar.children ?? []) + [BookmarkNode(folder: "Imported from Chrome", children: imported)]
        }
        if !mobile.isEmpty {
            other.children = (other.children ?? []) + [BookmarkNode(folder: "Mobile Bookmarks", children: mobile)]
        }
        changed()
    }

    private func changed() {
        rebuildIndex()
        if let data = try? JSONEncoder().encode(File(bar: bar, other: other)) {
            try? data.write(to: Storage.bookmarks, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func rebuildIndex() {
        var urls = Set<String>()
        func walk(_ node: BookmarkNode) {
            if let url = node.url { urls.insert(url.absoluteString) }
            node.children?.forEach(walk)
        }
        walk(bar)
        walk(other)
        savedURLs = urls
    }
}

// MARK: - Menus

/// Builds menus listing bookmarks (used by the menu bar and bookmark-bar folders).
/// Clicking an item goes to the browser window via `openBookmarkItem(_:)`.
@MainActor
enum BookmarkMenus {
    /// Every bookmark (not folders), for search suggestions.
    static func allBookmarks() -> [BookmarkNode] {
        var result: [BookmarkNode] = []
        func walk(_ node: BookmarkNode) {
            if node.url != nil { result.append(node) }
            node.children?.forEach(walk)
        }
        walk(BookmarkStore.shared.bar)
        walk(BookmarkStore.shared.other)
        return result
    }

    static func menu(for folder: BookmarkNode) -> NSMenu {
        let menu = NSMenu(title: folder.title)
        let children = folder.children ?? []
        append(children, to: menu)
        if children.isEmpty {
            let empty = NSMenuItem(title: "(Empty)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let links = children.filter { $0.url != nil }.count
        if links > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem(title: "Open All (\(links)) in New Tabs",
                                 action: #selector(BrowserWindowController.openAllBookmarks(_:)), keyEquivalent: "")
            all.representedObject = folder
            menu.addItem(all)
        }
        return menu
    }

    static func append(_ nodes: [BookmarkNode], to menu: NSMenu) {
        for node in nodes {
            var title = node.displayTitle
            if title.count > 60 { title = String(title.prefix(57)) + "…" }
            let item = NSMenuItem(title: title,
                                  action: node.isFolder ? nil : #selector(BrowserWindowController.openBookmarkItem(_:)),
                                  keyEquivalent: "")
            item.representedObject = node
            item.toolTip = node.url?.absoluteString
            if node.isFolder {
                item.image = Icons.folder
                item.submenu = BookmarkMenus.menu(for: node)
            } else {
                item.image = Favicons.cached(for: node.url) ?? Icons.globe
            }
            menu.addItem(item)
        }
    }
}

/// Keeps the "Bookmarks" menu in the menu bar up to date each time it opens.
@MainActor
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = BookmarksMenuDelegate()
    /// How many fixed items (Bookmark This Page… etc.) sit above the bookmarks.
    var fixedItemCount = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > fixedItemCount { menu.removeItem(at: fixedItemCount) }
        let store = BookmarkStore.shared
        BookmarkMenus.append(store.bar.children ?? [], to: menu)
        if !(store.other.children ?? []).isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Other Bookmarks", action: nil, keyEquivalent: "")
            item.image = Icons.folder
            item.submenu = BookmarkMenus.menu(for: store.other)
            menu.addItem(item)
        }
    }
}

// MARK: - Edit box

@MainActor
enum BookmarkEditor {
    /// The box for naming a bookmark/folder, changing its address, and picking its folder.
    /// `isNew` makes it look like Chrome's "Bookmark added" bubble.
    static func edit(_ node: BookmarkNode, in window: NSWindow?, isNew: Bool) {
        let store = BookmarkStore.shared
        let alert = NSAlert()
        alert.messageText = node.isFolder ? "Edit Folder" : (isNew ? "Bookmark Added" : "Edit Bookmark")

        let nameField = NSTextField(string: node.title)
        nameField.placeholderString = node.isFolder ? "Folder name" : "No name (shows just the icon)"
        let urlField = NSTextField(string: node.url?.absoluteString ?? "")
        let folderPopup = NSPopUpButton()
        let currentParent = store.parent(of: node)
        for entry in store.allFolders(excluding: node) {
            folderPopup.addItem(withTitle: String(repeating: "    ", count: entry.depth) + entry.folder.displayTitle)
            folderPopup.lastItem?.representedObject = entry.folder
            folderPopup.lastItem?.image = Icons.folder
            if entry.folder === currentParent { folderPopup.select(folderPopup.lastItem) }
        }

        var rows: [[NSView]] = [[label("Name"), nameField]]
        if !node.isFolder { rows.append([label("Address"), urlField]) }
        rows.append([label("Folder"), folderPopup])
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        urlField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        alert.addButton(withTitle: isNew ? "Done" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.window.initialFirstResponder = nameField

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                let url = node.isFolder ? nil : AddressParser.url(from: urlField.stringValue)
                let folder = folderPopup.selectedItem?.representedObject as? BookmarkNode
                store.update(node, title: nameField.stringValue, url: url, folder: folder)
            case .alertThirdButtonReturn:
                store.remove(node)
            default:
                break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }
}

// MARK: - Chrome bookmarks

enum ChromeBookmarks {
    /// Reads Chrome's "Bookmarks" file. Returns (bar, other, mobile) or nil if it can't be read.
    static func read(_ url: URL) -> (bar: [BookmarkNode], other: [BookmarkNode], mobile: [BookmarkNode])? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return nil }
        let bar = (roots["bookmark_bar"] as? [String: Any]).map(convert)?.children ?? []
        let other = (roots["other"] as? [String: Any]).map(convert)?.children ?? []
        let mobile = (roots["synced"] as? [String: Any]).map(convert)?.children ?? []
        return (bar, other, mobile)
    }

    private static func convert(_ dict: [String: Any]) -> BookmarkNode {
        let name = dict["name"] as? String ?? ""
        if dict["type"] as? String == "folder" || dict["children"] != nil {
            let children = (dict["children"] as? [[String: Any]] ?? []).map(convert)
            return BookmarkNode(folder: name, children: children)
        }
        return BookmarkNode(title: name, url: URL(string: dict["url"] as? String ?? ""))
    }
}
