import AppKit

/// The strip at the top: back, forward, reload, and the address bar.
@MainActor
final class ToolbarView: NSView {
    static let height: CGFloat = 40

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

    private let background = SolidView(color: Theme.toolbar)
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
        addressField.placeholderString = "Search or enter address"
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.cell?.wraps = false

        let buttons = NSStackView(views: [backButton, forwardButton, reloadButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2

        extensionStack.orientation = .horizontal
        extensionStack.spacing = 2
        for v in [background, buttons, fieldBox, addressField, starButton, extensionStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        addSubview(buttons)
        addSubview(fieldBox)
        addSubview(extensionStack)
        fieldBox.addSubview(addressField)
        fieldBox.addSubview(starButton)

        leadingConstraint = buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            leadingConstraint,
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),

            fieldBox.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 8),
            fieldBox.trailingAnchor.constraint(equalTo: extensionStack.leadingAnchor, constant: -6),
            extensionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            extensionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 28),

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
            if let icon = item.icon { button.image = icon }
            button.toolTip = item.badge.isEmpty ? item.label : "\(item.label) (\(item.badge))"
            button.target = self
            button.action = #selector(extensionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            extensionStack.addArrangedSubview(button)
            extensionButtons[item.id] = button
        }
    }

    func extensionButton(id: String) -> NSView? { extensionButtons[id] }

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
