import AppKit

/// A panel shown on top of the browser window, with everything behind it blurred.
/// Click outside the panel, press Esc, or click × to close it.
@MainActor
final class Overlay: NSObject {
    private static var current: Overlay?

    private let backdrop = OverlayBackdrop()
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

        // The blur: everything in the window behind this view is blurred.
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.appearance = Theme.appearance
        backdrop.onClick = { [weak self] in self?.close() }
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)

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
        backdrop.addSubview(card)
        card.addSubview(titleLabel)
        card.addSubview(closeButton)
        card.addSubview(content)
        // The panel's preferred size gives way when the window is smaller.
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: size.width)
        let preferredHeight = card.heightAnchor.constraint(equalToConstant: size.height)
        preferredWidth.priority = .defaultHigh
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            preferredWidth,
            preferredHeight,
            card.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -40),
            card.heightAnchor.constraint(lessThanOrEqualTo: backdrop.heightAnchor, constant: -40),

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
        backdrop.removeFromSuperview()   // frees everything inside
    }
}

/// The blurred background. Clicking it (outside the panel) closes the overlay,
/// and it stops clicks and scrolling from reaching the page underneath.
final class OverlayBackdrop: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if hitTest(convert(event.locationInWindow, from: nil)) === self { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
}
