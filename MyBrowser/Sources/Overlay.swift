import AppKit

/// A panel shown on top of the browser window, with everything behind it blurred.
/// Click outside the panel, press Esc, or click × to close it.
@MainActor
final class Overlay: NSObject {
    private static var current: Overlay?

    private let root = OverlayRoot()
    private let backdrop = NSVisualEffectView()
    private let card = KeyHandlingView(color: Theme.sidebar)
    private weak var window: NSWindow?

    static func show(title: String, content: NSView, size: NSSize, in window: NSWindow) {
        current?.close()
        let overlay = Overlay(window: window)
        current = overlay
        overlay.install(title: title, content: content, size: size)
    }

    static func closeCurrent() { current?.close() }
    static var isShowing: Bool { current != nil }

    private init(window: NSWindow) {
        self.window = window
        super.init()
    }

    private func install(title: String, content: NSView, size: NSSize) {
        guard let window, let host = window.contentView else { return }

        // Catches clicks outside the panel (to close it) and keeps them off the page.
        root.onClick = { [weak self] in self?.close() }
        root.frame = host.bounds
        root.autoresizingMask = [.width, .height]
        host.addSubview(root)

        // A light blur: the blurred layer is only partly see-through,
        // so the browser behind stays recognizable.
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.appearance = Theme.appearance
        backdrop.alphaValue = 0.45
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)

        // The solid panel in the middle.
        card.cornerRadius = 16
        card.borderColor = Theme.toolbar
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = Theme.text
        let closeButton = NSButton(image: Icons.symbol("xmark", size: 13, weight: .semibold) ?? NSImage(),
                                   target: self, action: #selector(closeClicked(_:)))
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.mutedText
        closeButton.keyEquivalent = "\u{1b}"   // Esc closes
        closeButton.toolTip = "Close (Esc)"

        for v in [card, titleLabel, closeButton, content] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(card)
        card.addSubview(titleLabel)
        card.addSubview(closeButton)
        card.addSubview(content)
        // The panel's preferred size gives way when the window is smaller.
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: size.width)
        let preferredHeight = card.heightAnchor.constraint(equalToConstant: size.height)
        preferredWidth.priority = .defaultHigh
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            preferredWidth,
            preferredHeight,
            card.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
            card.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, constant: -40),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        window.makeFirstResponder(nil)   // stop typing from reaching the page underneath
    }

    @objc private func closeClicked(_ sender: Any?) { close() }

    func close() {
        guard Overlay.current === self else { return }
        Overlay.current = nil
        root.removeFromSuperview()   // frees everything inside
    }
}

/// Covers the window behind the panel. Clicking it (outside the panel) closes the
/// overlay, and it stops clicks and scrolling from reaching the page underneath.
final class OverlayRoot: NSView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSVisualEffectView ? self : hit   // the blur layer counts as "outside"
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
}
