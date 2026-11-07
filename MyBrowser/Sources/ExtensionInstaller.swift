import AppKit
import WebKit

/// The screens for adding extensions: from Chrome, or from any extension folder.
@available(macOS 15.4, *)
@MainActor
enum ExtensionInstaller {
    private static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Step 1: you confirm Chrome's Extensions folder. Step 2: you tick which extensions to copy.
    static func importFromChrome(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Folder"
        panel.message = "This is Chrome's settings folder. Just click “Use This Folder” — extensions from all your Chrome profiles will be listed."
        panel.directoryURL = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        run(panel, window: window) { url in
            let found = ExtensionManager.scanChrome(url)
            guard !found.isEmpty else {
                tell("No extensions found", "No Chrome extensions were found there. Pick the folder called “Chrome” (inside Library → Application Support → Google).", window)
                return
            }
            choose(from: found, window: window)
        }
    }

    /// For an unpacked extension folder (one that contains manifest.json).
    static func addFolder(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Extension"
        panel.message = "Choose an extension's folder (the one containing “manifest.json”)."
        run(panel, window: window) { url in
            install([ExtensionManager.ChromeExtension(name: url.lastPathComponent, version: "", profile: "", folder: url)], window: window)
        }
    }

    private static func choose(from found: [ExtensionManager.ChromeExtension], window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Import Chrome Extensions"
        alert.informativeText = "Tick the ones you want. Each running extension uses some memory (often 10–40 MB), so only pick ones you use."
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        var boxes: [NSButton] = []
        for ext in found {
            let profile = ext.profile.isEmpty ? "" : "  — \(ext.profile)"
            let box = NSButton(checkboxWithTitle: ext.name + profile,
                               target: nil, action: nil)
            box.state = .off
            list.addArrangedSubview(box)
            boxes.append(box)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(300, CGFloat(found.count) * 26 + 10)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: CGFloat(found.count) * 26 + 10))
        list.frame = doc.bounds
        list.autoresizingMask = [.width, .height]
        doc.addSubview(list)
        scroll.documentView = doc
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let picked = zip(found, boxes).filter { $0.1.state == .on }.map(\.0)
            if !picked.isEmpty { install(picked, window: window) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private static func install(_ items: [ExtensionManager.ChromeExtension], window: NSWindow?) {
        Task { @MainActor in
            var lines: [String] = []
            for item in items {
                if let failure = await ExtensionManager.shared.install(from: item.folder) {
                    lines.append("✗ \(item.name): \(failure)")
                } else if let context = ExtensionManager.shared.contexts.last {
                    let warnings = ExtensionManager.warnings(of: context)
                    lines.append(warnings.isEmpty
                                 ? "✓ \(ExtensionManager.name(of: context))"
                                 : "✓ \(ExtensionManager.name(of: context)), but some parts may not work: \(warnings.joined(separator: "; "))")
                }
            }
            tell("Extensions", lines.joined(separator: "\n\n") + "\n\nFor safety, new extensions only work on a site after you click them (puzzle menu or toolbar). To let one work everywhere: puzzle → Manage Extensions → the extension → Can read and change sites → On all sites.\n\nTo make sure they work on every tab, quit the browser (⌘Q) and open it again.", window)
        }
    }

    private static func run(_ panel: NSOpenPanel, window: NSWindow?, then: @escaping (URL) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { then(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func tell(_ title: String, _ text: String, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }
}

/// Keeps the "Extensions" menu up to date each time it opens.
@MainActor
final class ExtensionsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ExtensionsMenuDelegate()
    var fixedItemCount = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > fixedItemCount { menu.removeItem(at: fixedItemCount) }
        appendItems(to: menu)
    }

    /// Adds one line per installed extension (each with Options, Details and Remove).
    func appendItems(to menu: NSMenu) {
        guard #available(macOS 15.4, *) else {
            let note = NSMenuItem(title: "Extensions need macOS 15.4 or newer", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            return
        }
        let contexts = ExtensionManager.active?.contexts ?? []
        if contexts.isEmpty {
            let note = NSMenuItem(title: "No extensions installed", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        // Click an extension to use it (like Chrome's puzzle menu). 📌 = shown in the toolbar.
        for context in contexts {
            let run = NSMenuItem(title: ExtensionManager.name(of: context),
                                 action: #selector(BrowserWindowController.runExtension(_:)), keyEquivalent: "")
            run.representedObject = context
            run.image = Self.icon(context)
            if ExtensionPins.isPinned(context.uniqueIdentifier) { run.title += "  📌" }
            menu.addItem(run)
        }
        guard !contexts.isEmpty else { return }
        menu.addItem(.separator())

        let pins = NSMenu()
        for context in contexts {
            let pin = NSMenuItem(title: ExtensionManager.name(of: context),
                                 action: #selector(BrowserWindowController.togglePinExtension(_:)), keyEquivalent: "")
            pin.representedObject = context
            pin.image = Self.icon(context)
            pin.state = ExtensionPins.isPinned(context.uniqueIdentifier) ? .on : .off
            pins.addItem(pin)
        }
        let pinItem = NSMenuItem(title: "Pin to Toolbar", action: nil, keyEquivalent: "")
        pinItem.submenu = pins
        menu.addItem(pinItem)

        let manage = NSMenu()
        for context in contexts {
            let item = NSMenuItem(title: ExtensionManager.name(of: context), action: nil, keyEquivalent: "")
            item.image = Self.icon(context)
            let sub = NSMenu()
            let options = NSMenuItem(title: "Options…", action: #selector(BrowserWindowController.openExtensionOptions(_:)), keyEquivalent: "")
            options.representedObject = context
            options.isEnabled = context.optionsPageURL != nil
            sub.addItem(options)
            let details = NSMenuItem(title: "Problems & Details…", action: #selector(BrowserWindowController.showExtensionDetails(_:)), keyEquivalent: "")
            details.representedObject = context
            sub.addItem(details)
            sub.addItem(.separator())
            let access = NSMenuItem(title: "Can read and change sites", action: nil, keyEquivalent: "")
            let accessMenu = NSMenu()
            for (title, mode) in [("On all sites", ExtensionManager.SiteAccess.allSites),
                                  ("Only when you click it", .onClick)] {
                let choice = NSMenuItem(title: title, action: #selector(BrowserWindowController.setExtensionSiteAccess(_:)), keyEquivalent: "")
                choice.representedObject = [context, mode.rawValue] as [Any]
                choice.state = ExtensionManager.siteAccess(for: context.uniqueIdentifier) == mode ? .on : .off
                accessMenu.addItem(choice)
            }
            access.submenu = accessMenu
            sub.addItem(access)
            sub.addItem(.separator())
            let remove = NSMenuItem(title: "Remove", action: #selector(BrowserWindowController.removeExtension(_:)), keyEquivalent: "")
            remove.representedObject = context
            sub.addItem(remove)
            item.submenu = sub
            manage.addItem(item)
        }
        let manageItem = NSMenuItem(title: "Manage Extensions", action: nil, keyEquivalent: "")
        manageItem.submenu = manage
        menu.addItem(manageItem)
    }

    @available(macOS 15.4, *)
    private static func icon(_ context: WKWebExtensionContext) -> NSImage? {
        let image = context.webExtension.icon(for: CGSize(width: 16, height: 16))?.copy() as? NSImage
        image?.size = NSSize(width: 16, height: 16)
        return image
    }
}

/// Which extensions you've pinned to the toolbar (the rest live in the puzzle-piece menu).
enum ExtensionPins {
    private static let key = "pinnedExtensions"
    static func isPinned(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id) }
    static func toggle(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        UserDefaults.standard.set(list, forKey: key)
    }
}
