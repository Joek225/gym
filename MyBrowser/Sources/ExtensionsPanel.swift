import AppKit
import WebKit

/// The puzzle-piece panel, like Chrome's: every extension with its icon, a pin button
/// (show it in the toolbar) and a ⋮ menu (options, site access, details, remove).
/// Grouped by what each one can see. Click an extension's name to use it.
@available(macOS 15.4, *)
@MainActor
final class ExtensionsPanel: NSObject, NSPopoverDelegate {
    private static var current: ExtensionsPanel?

    private let popover = NSPopover()
    private weak var controller: BrowserWindowController?
    private let list = NSStackView()

    static func show(from anchor: NSView, controller: BrowserWindowController) {
        current?.popover.close()
        let panel = ExtensionsPanel(controller: controller)
        current = panel
        panel.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private init(controller: BrowserWindowController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.appearance = Theme.appearance
        popover.delegate = self
        let vc = NSViewController()
        vc.view = build()
        popover.contentViewController = vc
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ExtensionManager.didChange, object: nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }

    // MARK: Building

    private func build() -> NSView {
        let title = NSTextField(labelWithString: "Extensions")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.text
        let close = iconButton("xmark", "Close") { [weak self] in self?.popover.close() }
        let header = NSStackView(views: [title, NSView(), close])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 10)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true

        let footer = NSStackView(views: [
            textButton("Import from Chrome…") { [weak self] in
                self?.popover.close(); self?.controller?.importFromChrome(nil)
            },
            textButton("Add from Folder…") { [weak self] in
                self?.popover.close(); self?.controller?.addExtensionFolder(nil)
            },
        ])
        footer.spacing = 16
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let line = SolidView(color: Theme.hairline)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let root = NSStackView(views: [header, scroll, line, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 12, right: 0)
        for v in [header, scroll, line, footer] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        root.widthAnchor.constraint(equalToConstant: 340).isActive = true
        reload()
        let rows = CGFloat(max(1, list.arrangedSubviews.count))
        scroll.heightAnchor.constraint(equalToConstant: min(440, rows * 40 + 8)).isActive = true
        return root
    }

    @objc private func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let contexts = ExtensionManager.active?.contexts ?? []
        if contexts.isEmpty {
            add(note("No extensions yet. Import them from Chrome below."))
            return
        }
        let everywhere = contexts.filter { ExtensionManager.siteAccess(for: $0.uniqueIdentifier) == .allSites }
        let onClick = contexts.filter { ExtensionManager.siteAccess(for: $0.uniqueIdentifier) == .onClick }
        if !everywhere.isEmpty {
            add(section("Full access", "These extensions can see and change information on every site."))
            everywhere.forEach { add(row($0)) }
        }
        if !onClick.isEmpty {
            add(section("Only when you click", "These can only see a site after you click them."))
            onClick.forEach { add(row($0)) }
        }
    }

    private func add(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func section(_ title: String, _ detail: String) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = Theme.text
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 12)
        d.textColor = Theme.mutedText
        d.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [t, d])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 6, right: 16)
        return stack
    }

    private func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = Theme.mutedText
        label.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [label])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return stack
    }

    /// One extension: icon + name (click to use it), pin, ⋮.
    private func row(_ context: WKWebExtensionContext) -> NSView {
        let icon = context.webExtension.icon(for: CGSize(width: 18, height: 18))?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        let name = NSButton(title: ExtensionManager.name(of: context), image: icon ?? NSImage(), target: nil, action: nil)
        name.imagePosition = .imageLeading
        name.imageHugsTitle = true
        name.isBordered = false
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: 13)
        name.contentTintColor = Theme.text
        name.toolTip = "Use \(ExtensionManager.name(of: context))"
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ClosureTarget.attach(to: name) { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.popover.close()
            let item = NSMenuItem()
            item.representedObject = context
            controller.runExtension(item)
        }

        let pinned = ExtensionPins.isPinned(context.uniqueIdentifier)
        let pin = iconButton(pinned ? "pin.fill" : "pin", pinned ? "Unpin from toolbar" : "Pin to toolbar") {}
        pin.contentTintColor = pinned ? Theme.accent : Theme.mutedText
        ClosureTarget.attach(to: pin) { [weak self, weak pin] in
            ExtensionPins.toggle(context.uniqueIdentifier)
            for c in AppDelegate.shared.controllers { c.refreshExtensionButtonsNow() }
            let now = ExtensionPins.isPinned(context.uniqueIdentifier)
            pin?.image = Icons.symbol(now ? "pin.fill" : "pin", size: 14)
            pin?.contentTintColor = now ? Theme.accent : Theme.mutedText
            pin?.toolTip = now ? "Unpin from toolbar" : "Pin to toolbar"
            _ = self
        }

        let more = iconButton("ellipsis", "More") {}
        more.image = ToolbarView.verticalDots()
        ClosureTarget.attach(to: more) { [weak self, weak more] in
            guard let self, let more else { return }
            self.moreMenu(for: context).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
        }

        let row = NSStackView(views: [name, NSView(), pin, more])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 10)
        row.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return row
    }

    private func moreMenu(for context: WKWebExtensionContext) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ object: Any) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = controller
            i.representedObject = object
            return i
        }
        let options = item("Options…", #selector(BrowserWindowController.openExtensionOptions(_:)), context)
        options.isEnabled = context.optionsPageURL != nil
        if context.optionsPageURL == nil { options.action = nil }
        menu.addItem(options)
        let access = NSMenuItem(title: "Can read and change sites", action: nil, keyEquivalent: "")
        let accessMenu = NSMenu()
        for (title, mode) in [("On all sites", ExtensionManager.SiteAccess.allSites), ("Only when you click it", .onClick)] {
            let choice = item(title, #selector(BrowserWindowController.setExtensionSiteAccess(_:)), [context, mode.rawValue] as [Any])
            choice.state = ExtensionManager.siteAccess(for: context.uniqueIdentifier) == mode ? .on : .off
            accessMenu.addItem(choice)
        }
        access.submenu = accessMenu
        menu.addItem(access)
        menu.addItem(item("Problems & Details…", #selector(BrowserWindowController.showExtensionDetails(_:)), context))
        menu.addItem(.separator())
        menu.addItem(item("Remove", #selector(BrowserWindowController.removeExtension(_:)), context))
        return menu
    }

    // MARK: Small helpers

    private func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(image: Icons.symbol(symbol, size: 14) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = Theme.mutedText
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        ClosureTarget.attach(to: b, action)
        return b
    }

    private func textButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Theme.accent, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        ClosureTarget.attach(to: b, action)
        return b
    }
}

/// Lets a button run a closure when clicked.
@MainActor
final class ClosureTarget: NSObject {
    private let action: () -> Void
    private init(_ action: @escaping () -> Void) { self.action = action }
    @objc private func run(_ sender: Any?) { action() }

    private static var key = 0
    static func attach(to button: NSButton, _ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        button.target = target
        button.action = #selector(run(_:))
        objc_setAssociatedObject(button, &key, target, .OBJC_ASSOCIATION_RETAIN)
    }
}
