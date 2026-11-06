import AppKit

/// A borderless panel that can take keyboard focus (used for our solid pop-ups).
final class PopupPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// What the group editor asks the window to do.
@MainActor
protocol GroupEditorActions: AnyObject {
    var store: TabStore { get }
    func sidebarNewTab(in group: TabGroup?)
    func moveGroupToNewWindow(_ group: TabGroup)
    func closeGroup(_ group: TabGroup, keepSaved: Bool)
    func disableGroup(_ group: TabGroup)
    func sidebarEnableGroup(_ group: TabGroup)
}

/// Chrome's group editor: name field, color dots, and group actions.
/// Opens when you make a new group or right-click a group's header.
@MainActor
final class GroupEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static var current: GroupEditor?

    private let group: TabGroup
    private weak var actions: GroupEditorActions?
    private let panel: PopupPanel
    private let field = NSTextField()
    private var dots: [(button: NSButton, ring: SolidView, color: GroupColor)] = []

    static func show(for group: TabGroup, actions: GroupEditorActions, anchor: NSRect, in parent: NSWindow) {
        current?.close()
        let editor = GroupEditor(group: group, actions: actions)
        current = editor
        editor.present(anchor: anchor, in: parent)
    }

    private init(group: TabGroup, actions: GroupEditorActions) {
        self.group = group
        self.actions = actions
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 340),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false            // only so the corners can be rounded
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = Theme.appearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        buildContent()
    }

    // MARK: Building

    private func buildContent() {
        let box = KeyHandlingView(color: Theme.sidebar)
        box.cornerRadius = 14
        box.borderColor = Theme.toolbar
        box.onKey = { [weak self] event in self?.handleShortcut(event) ?? false }
        panel.contentView = box

        // Name field with a colored outline, like Chrome.
        let fieldBox = SolidView(color: Theme.sidebar)
        fieldBox.cornerRadius = 10
        fieldBox.borderColor = NSColor(hex: 0xB9BDF9)
        fieldBox.borderWidth = 2
        field.stringValue = group.name
        field.placeholderString = "Name this group"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = Theme.text
        field.delegate = self
        field.target = self
        field.action = #selector(nameEntered(_:))
        fieldBox.addSubview(field)

        // Color dots.
        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 6
        dotRow.distribution = .equalSpacing
        for color in [GroupColor.blue, .purple, .pink, .red, .orange, .yellow, .green, .cyan, .grey] {
            let ring = SolidView(color: .clear)
            ring.cornerRadius = 13
            let dot = SolidView(color: color.color)
            dot.cornerRadius = 10
            let button = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
            button.isBordered = false
            button.toolTip = color.name
            for v in [ring, dot, button] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
            ring.addSubview(dot)
            ring.addSubview(button)
            NSLayoutConstraint.activate([
                ring.widthAnchor.constraint(equalToConstant: 26), ring.heightAnchor.constraint(equalToConstant: 26),
                dot.centerXAnchor.constraint(equalTo: ring.centerXAnchor), dot.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 20), dot.heightAnchor.constraint(equalToConstant: 20),
                button.leadingAnchor.constraint(equalTo: ring.leadingAnchor), button.trailingAnchor.constraint(equalTo: ring.trailingAnchor),
                button.topAnchor.constraint(equalTo: ring.topAnchor), button.bottomAnchor.constraint(equalTo: ring.bottomAnchor),
            ])
            dotRow.addArrangedSubview(ring)
            dots.append((button, ring, color))
        }
        updateDots()

        let rows: [NSView] = [
            PopupRow(icon: "plus.square.on.square", title: "New tab in group", shortcut: "^⌘C") { [weak self] in self?.newTab() },
            PopupRow(icon: "macwindow.badge.plus", title: "Move group to new window", shortcut: "") { [weak self] in self?.moveToNewWindow() },
            PopupRow(icon: group.isDisabled ? "power" : "moon.zzz",
                     title: group.isDisabled ? "Turn group on" : "Disable group (free its memory)", shortcut: "") { [weak self] in
                self?.toggleDisabled()
            },
            PopupRow(icon: "xmark.square", title: "Close group", shortcut: "^⌘W") { [weak self] in self?.closeGroup() },
            Self.separator(),
            PopupRow(icon: "rectangle.dashed", title: "Ungroup", shortcut: "") { [weak self] in self?.ungroup() },
            PopupRow(icon: "trash", title: "Delete group", shortcut: "") { [weak self] in self?.deleteGroup() },
        ]

        let stack = NSStackView(views: [fieldBox, dotRow, Self.separator()] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 10, right: 12)
        stack.setCustomSpacing(14, after: fieldBox)
        stack.setCustomSpacing(12, after: dotRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        field.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 300),

            fieldBox.heightAnchor.constraint(equalToConstant: 42),
            fieldBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            field.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            dotRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: row is PopupRow ? -12 : -24).isActive = true
        }
    }

    private static func separator() -> NSView {
        let line = SolidView(color: Theme.toolbar)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func present(anchor: NSRect, in parent: NSWindow) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        // Next to the group's header, kept on screen.
        var origin = NSPoint(x: anchor.maxX + 6, y: anchor.maxY - size.height)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(origin.x, screen.maxX - size.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    static func closeAny() { current?.close() }

    func close() {
        guard GroupEditor.current === self else { return }
        GroupEditor.current = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: Actions

    private func updateDots() {
        for entry in dots {
            entry.ring.borderWidth = 2
            entry.ring.borderColor = entry.color == group.color ? entry.color.color : nil
        }
    }

    @objc private func colorClicked(_ sender: NSButton) {
        guard let entry = dots.first(where: { $0.button === sender }) else { return }
        group.color = entry.color
        updateDots()
        actions?.store.changed()
    }

    func controlTextDidChange(_ notification: Notification) {
        group.name = field.stringValue
        actions?.store.changed()
    }

    @objc private func nameEntered(_ sender: Any?) { close() }

    private func newTab() { close(); actions?.sidebarNewTab(in: group) }
    private func moveToNewWindow() { close(); actions?.moveGroupToNewWindow(group) }
    private func closeGroup() { close(); actions?.closeGroup(group, keepSaved: true) }
    private func deleteGroup() { close(); actions?.closeGroup(group, keepSaved: false) }
    private func ungroup() { close(); actions?.store.ungroup(group) }
    private func toggleDisabled() {
        close()
        if group.isDisabled { actions?.sidebarEnableGroup(group) } else { actions?.disableGroup(group) }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == [.control, .command] else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": newTab(); return true
        case "w": closeGroup(); return true
        default: return false
        }
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// A view that gets first look at keyboard shortcuts.
final class KeyHandlingView: SolidView {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// One clickable line in a pop-up: icon, title, and a shortcut hint.
final class PopupRow: NSView {
    private let action: () -> Void
    private let background = SolidView(color: .clear)

    init(icon: String, title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        background.cornerRadius = 8
        let image = NSImageView(image: Icons.symbol(icon, size: 15) ?? NSImage())
        image.contentTintColor = Theme.icon
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        label.textColor = Theme.text
        let hint = NSTextField(labelWithString: shortcut)
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = Theme.mutedText
        for v in [background, image, label, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { background.fillColor = Theme.hoverTab }
    override func mouseExited(with event: NSEvent) { background.fillColor = .clear }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
