import AppKit

/// The window background, in two layers:
///  - back: the two dark slate tones (darker at the top, a touch lighter below)
///  - front: a see-through wash of your chosen tint (rose, periwinkle, sky or ocean)
/// Both are plain colors (no live blur of what's behind the window), which saves energy.
final class ArcBackgroundView: NSView {
    private let back = CAGradientLayer()
    private let tint = CALayer()

    init() {
        super.init(frame: .zero)
        let colors = ThemeColors.load()
        back.colors = [colors.sidebar.cgColor, colors.toolbar.cgColor]
        back.startPoint = CGPoint(x: 0.5, y: 1)   // top
        back.endPoint = CGPoint(x: 0.5, y: 0)     // bottom
        // The tint is strongest at the top and fades out, like tinted glass.
        let wash = CAGradientLayer()
        wash.colors = [colors.accent.withAlphaComponent(0.16).cgColor, colors.accent.withAlphaComponent(0.04).cgColor]
        wash.startPoint = CGPoint(x: 0.2, y: 1)
        wash.endPoint = CGPoint(x: 0.8, y: 0)
        tint.addSublayer(wash)
        back.addSublayer(tint)
        layer = back
        wantsLayer = true
        for l in [tint, wash] { l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable] }
        self.wash = wash
    }

    private var wash: CAGradientLayer?

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        wash?.frame = bounds
        CATransaction.commit()
    }

    // Empty parts of the window can be dragged to move it, like the title bar.
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Safety net for dropped pictures

    /// The page you're looking at. Pictures dropped anywhere over it that macOS didn't hand
    /// to the page directly land here (the whole window is the last stop for a drop), and are
    /// passed on to the page — so a drop can't just bounce back.
    var visiblePage: (() -> BrowserWebView?)?
    private weak var catching: BrowserWebView?

    func enableDropSafetyNet() { registerForDraggedTypes(ImageDropView.pictureTypes) }

    private func page(for info: NSDraggingInfo) -> BrowserWebView? {
        guard let page = visiblePage?(), !page.isHiddenOrHasHiddenAncestor, page.window === window else { return nil }
        let point = page.convert(info.draggingLocation, from: nil)
        return page.bounds.contains(point) ? page : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let page = page(for: sender) else { return [] }
        DragReport.add("— (the window caught this drag; passing it to the page)")
        catching = page
        return page.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let page = page(for: sender) else {
            if let old = catching { old.draggingExited(sender); catching = nil }
            return []
        }
        if catching !== page { catching = page; return page.draggingEntered(sender) }
        return page.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        catching?.draggingExited(sender)
        catching = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        catching?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        catching?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        catching?.concludeDragOperation(sender)
        catching = nil
    }
}
