import AppKit

/// A plain opaque colored box. It's drawn as a single layer color, with no
/// image buffer behind it, which is the cheapest way to paint a view.
class SolidView: NSView {
    var fillColor: NSColor = .black { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    /// When true, dragging this view moves the window (used for the toolbar).
    var movesWindow = false

    init(color: NSColor) {
        fillColor = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = borderColor?.cgColor
        }
        layer.borderWidth = borderColor == nil ? 0 : borderWidth
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
    }

    override var mouseDownCanMoveWindow: Bool { movesWindow }

    override func mouseDown(with event: NSEvent) {
        if movesWindow && event.clickCount == 2 {
            window?.performZoom(nil)   // double-click toolbar = zoom, like other Mac apps
        } else {
            super.mouseDown(with: event)
        }
    }
}
