import AppKit

/// The menu bar at the top of the screen, with Chrome's keyboard shortcuts.
/// Menu items without a fixed target go to whatever is active (the window,
/// the web page, or the address bar), which is how Mac apps normally work.
@MainActor
enum MainMenu {
    private typealias W = BrowserWindowController

    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "MyBrowser")
        app.addItem(withTitle: "About MyBrowser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MyBrowser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit MyBrowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(W.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(W.reopenClosedTab(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Open Location…", action: #selector(W.focusAddressBar(_:)), keyEquivalent: "l")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(W.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = [.command, .shift]

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Hide Bookmarks Bar", action: #selector(W.toggleBookmarksBar(_:)), keyEquivalent: "b")
            .keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Reload Page", action: #selector(W.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(W.actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(W.zoomInPage(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: #selector(W.zoomOutPage(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let history = submenu(in: main, title: "History")
        history.addItem(withTitle: "Back", action: #selector(W.goBack(_:)), keyEquivalent: "[")
        history.addItem(withTitle: "Forward", action: #selector(W.goForward(_:)), keyEquivalent: "]")
        history.addItem(.separator())
        history.addItem(withTitle: "Reopen Closed Tab", action: #selector(W.reopenClosedTab(_:)), keyEquivalent: "")

        let bookmarks = submenu(in: main, title: "Bookmarks")
        bookmarks.addItem(withTitle: "Bookmark This Page…", action: #selector(W.bookmarkThisPage(_:)), keyEquivalent: "d")
        bookmarks.addItem(withTitle: "Add Folder…", action: #selector(W.newBookmarkFolder(_:)), keyEquivalent: "")
        bookmarks.addItem(withTitle: "Import Bookmarks from Chrome…", action: #selector(W.importChromeBookmarks(_:)), keyEquivalent: "")
        bookmarks.addItem(.separator())
        BookmarksMenuDelegate.shared.fixedItemCount = bookmarks.items.count
        bookmarks.delegate = BookmarksMenuDelegate.shared

        let tab = submenu(in: main, title: "Tab")
        tab.addItem(withTitle: "Select Next Tab", action: #selector(W.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        hidden(tab, "Select Next Tab", #selector(W.selectNextTab(_:)), "}", [.command])
        hidden(tab, "Select Next Tab", #selector(W.selectNextTab(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        tab.addItem(withTitle: "Select Previous Tab", action: #selector(W.selectPreviousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        hidden(tab, "Select Previous Tab", #selector(W.selectPreviousTab(_:)), "{", [.command])
        hidden(tab, "Select Previous Tab", #selector(W.selectPreviousTab(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        tab.addItem(.separator())
        for n in 1...9 {
            let item = tab.addItem(withTitle: n == 9 ? "Select Last Tab" : "Select Tab \(n)",
                                   action: #selector(W.selectTabNumber(_:)), keyEquivalent: "\(n)")
            item.tag = n
        }
        tab.addItem(.separator())
        tab.addItem(withTitle: "Add Tab to New Group", action: #selector(W.addTabToNewGroup(_:)), keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .shift]

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    /// A shortcut that works but doesn't take up a line in the menu.
    private static func hidden(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }
}
