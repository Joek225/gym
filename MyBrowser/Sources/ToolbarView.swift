import AppKit

/// The strip at the top: back, forward, reload, and the address bar.
@MainActor
final class ToolbarView: NSView {
    static let height: CGFloat = 40

    /// Shown only while the tab sidebar is hidden, to bring it back.
    let sidebarButton = ToolbarView.makeButton("sidebar.leading", "Show the tab sidebar (⌃⌘S)")
    /// Opens the extensions menu (like Chrome's puzzle-piece button).
    let puzzleButton = ToolbarView.makeButton("puzzlepiece.extension", "Extensions")
    let downloadsButton = ToolbarView.makeButton("arrow.down.to.line", "Downloads (⇧⌘J)")
    /// Chrome's "⋮" menu: settings and everything else.
    let menuButton = ToolbarView.makeButton("ellipsis", "Settings and more")
    /// The optional memory readout (Settings → Show memory use).
    let memoryLabel = NSTextField(labelWithString: "")
    let backButton = ToolbarView.makeButton("chevron.left", "Back")
    let forwardButton = ToolbarView.makeButton("chevron.right", "Forward")
    let reloadButton = ToolbarView.makeButton("arrow.clockwise", "Reload")
    let addressField = NSTextField()
    let starButton = ToolbarView.makeButton("star", "Bookmark This Page (⌘D)")

    /// One extension's button (its icon from the extension's toolbar action).
    struct ExtensionButton {
        let id: String
        let icon: NSImage?
        let label: String
        let badge: String
    }

    var onExtensionClicked: ((String) -> Void)?
    private let extensionStack = NSStackView()
    private var extensionButtons: [String: NSButton] = [:]

    private let background = SolidView(color: Theme.chromeFill)
    private let fieldBox = SolidView(color: Theme.field)
    private var leadingConstraint: NSLayoutConstraint!

    /// Space on the left for the red/yellow/green window buttons.
    var leadingInset: CGFloat = 78 { didSet { leadingConstraint.constant = leadingInset } }

    init() {
        super.init(frame: .zero)
        background.movesWindow = true

        fieldBox.cornerRadius = 14

        addressField.isBordered = false
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: 13)
        addressField.textColor = Theme.text
        addressField.placeholderString = ""   // blank on new tabs
        // Display only: you type on the new tab page, never up here.
        addressField.isEditable = false
        addressField.isSelectable = true
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.cell?.wraps = false

        sidebarButton.isHidden = true
        let buttons = NSStackView(views: [sidebarButton, backButton, forwardButton, reloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2

        // Right side, always at the far right: extensions │ downloads ⋮
        extensionStack.orientation = .horizontal
        extensionStack.spacing = 2
        let divider = SolidView(color: Theme.mutedText.withAlphaComponent(0.35))
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        menuButton.image = ToolbarView.verticalDots()   // "⋮" like Chrome
        let right = NSStackView(views: [extensionStack, puzzleButton, divider, downloadsButton, menuButton])
        right.spacing = 6
        right.setCustomSpacing(10, after: puzzleButton)
        right.setCustomSpacing(10, after: divider)

        // Memory use, just left of the address bar.
        memoryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        memoryLabel.textColor = Theme.mutedText
        memoryLabel.alignment = .right
        memoryLabel.isHidden = true

        for v in [background, buttons, fieldBox, addressField, starButton, right, memoryLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        addSubview(buttons)
        addSubview(fieldBox)
        addSubview(right)
        addSubview(memoryLabel)
        fieldBox.addSubview(addressField)
        fieldBox.addSubview(starButton)

        leadingConstraint = buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset)
        // The bar stays centered and stretches until it meets the icons on the right.
        let reachRight = fieldBox.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -14)
        reachRight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            leadingConstraint,
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),

            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),

            fieldBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            fieldBox.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -14),
            reachRight,
            fieldBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 28),

            memoryLabel.trailingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: -10),
            memoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memoryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 10),
            fieldBox.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 12),

            addressField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 14),
            addressField.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -4),
            addressField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            starButton.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -2),
            starButton.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setStarred(_ starred: Bool) {
        starButton.image = ToolbarView.symbol(starred ? "star.fill" : "star", starred ? "Edit Bookmark" : "Bookmark This Page")
        starButton.contentTintColor = starred ? Theme.accent : Theme.icon
        starButton.toolTip = starred ? "Edit Bookmark (⌘D)" : "Bookmark This Page (⌘D)"
    }

    func setExtensionButtons(_ items: [ExtensionButton]) {
        extensionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        extensionButtons = [:]
        for item in items {
            let button = ToolbarView.makeButton("puzzlepiece.extension", item.label)
            if let icon = item.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 18, height: 18)   // extensions often supply big icons
                button.image = icon
            }
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = item.badge.isEmpty ? item.label : "\(item.label) (\(item.badge))"
            button.target = self
            button.action = #selector(extensionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            extensionStack.addArrangedSubview(button)
            extensionButtons[item.id] = button
        }
    }

    func extensionButton(id: String) -> NSView? { extensionButtons[id] }

    /// Chrome's three vertical dots, drawn as a template image (it takes the icon color).
    private static func verticalDots() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            for y in [3.0, 8.0, 13.0] {
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shows a page's address the way Chrome does: no "https://" or "www.",
    /// and without the long tracking part after "?". The full address is in the tooltip.
    func showAddress(_ url: URL?) {
        guard let url else {
            addressField.stringValue = ""
            addressField.toolTip = nil
            return
        }
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var text = host.isEmpty ? url.absoluteString : host + (url.path == "/" ? "" : url.path)
        if let fragment = url.fragment, !fragment.isEmpty, fragment.count < 30 { text += "#" + fragment }
        addressField.stringValue = text
        addressField.toolTip = url.absoluteString
    }

    @objc private func extensionClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onExtensionClicked?(id) }
    }

    func setLoading(_ loading: Bool) {
        let name = loading ? "xmark" : "arrow.clockwise"
        let label = loading ? "Stop" : "Reload"
        reloadButton.image = ToolbarView.symbol(name, label)
        reloadButton.toolTip = label
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    private static func makeButton(_ symbolName: String, _ label: String) -> NSButton {
        let button = NSButton()
        button.image = symbol(symbolName, label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = Theme.icon
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }
}
