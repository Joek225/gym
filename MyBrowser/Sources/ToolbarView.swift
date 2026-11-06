import AppKit

/// The strip at the top: back, forward, reload, and the address bar.
@MainActor
final class ToolbarView: NSView {
    static let height: CGFloat = 40

    let backButton = ToolbarView.makeButton("chevron.left", "Back")
    let forwardButton = ToolbarView.makeButton("chevron.right", "Forward")
    let reloadButton = ToolbarView.makeButton("arrow.clockwise", "Reload")
    let addressField = NSTextField()

    private let background = SolidView(color: Theme.toolbar)
    private let fieldBox = SolidView(color: Theme.field)
    private let bottomLine = SolidView(color: Theme.separator)
    private var leadingConstraint: NSLayoutConstraint!

    /// Space on the left for the red/yellow/green window buttons.
    var leadingInset: CGFloat = 78 { didSet { leadingConstraint.constant = leadingInset } }

    init() {
        super.init(frame: .zero)
        background.movesWindow = true

        fieldBox.cornerRadius = 7
        fieldBox.borderColor = Theme.fieldBorder

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

        for v in [background, bottomLine, buttons, fieldBox, addressField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        addSubview(bottomLine)
        addSubview(buttons)
        addSubview(fieldBox)
        fieldBox.addSubview(addressField)

        leadingConstraint = buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),

            bottomLine.heightAnchor.constraint(equalToConstant: 1),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),

            leadingConstraint,
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),

            fieldBox.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 8),
            fieldBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            fieldBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 26),

            addressField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 9),
            addressField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -9),
            addressField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
