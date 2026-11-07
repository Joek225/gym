import AppKit

/// The window background: a soft, solid gradient of your theme color (lighter at the top).
/// It looks a little see-through, like Arc, but nothing behind the window is shown or
/// blurred, so macOS doesn't keep redrawing it — that saves energy.
final class ArcBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        // Navy with a faint wash of your accent at the top, so it reads as tinted glass.
        let colors = ThemeColors.load()
        let base = colors.sidebar.usingColorSpace(.sRGB) ?? .black
        let top = base.blended(withFraction: 0.16, of: colors.accent) ?? base
        let bottom = base.blended(withFraction: 0.18, of: .black) ?? base
        gradient.colors = [top.cgColor, base.cgColor, bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.2, y: 1)
        gradient.endPoint = CGPoint(x: 0.8, y: 0)
        layer = gradient          // a layer-hosting view: it just shows the gradient
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Empty parts of the window can be dragged to move it, like the title bar.
    override var mouseDownCanMoveWindow: Bool { true }
}
