import AppKit

/// Arc-style window background: what's behind the window shows through, blurred,
/// with your theme colors laid over it as a gradient. (Settings → turn off for solid colors.)
final class ArcBackgroundView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        let colors = ThemeColors.load()
        tint.colors = [colors.sidebar.withAlphaComponent(0.78).cgColor,
                       colors.toolbar.withAlphaComponent(0.70).cgColor]
        tint.startPoint = CGPoint(x: 0, y: 1)
        tint.endPoint = CGPoint(x: 1, y: 0)
        blur.wantsLayer = true
        let overlay = NSView(frame: bounds)
        overlay.layer = tint          // a layer-hosting view: it simply shows the gradient
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Empty parts of the window can be dragged to move it, like the title bar.
    override var mouseDownCanMoveWindow: Bool { true }
}
