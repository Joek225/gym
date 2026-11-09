import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage

/// The Tools overlay: change an image's file type, remove its background, or copy it
/// (then paste it anywhere with ⌘V). Drop a picture on the Tools button to open it here.
/// It's only created when you open it and is freed when you close it.
@MainActor
enum ToolsOverlay {
    static func show(in window: NSWindow, image: URL? = nil) {
        Overlay.show(title: "Tools", content: ToolsView(image: image), size: NSSize(width: 620, height: 640), in: window)
    }
}

final class ToolsView: NSView {
    private let converter = ConverterPane()
    private let remover = RemoverPane()
    private let picker = NSSegmentedControl(labels: ["File Converter", "Background Remover"],
                                            trackingMode: .selectOne, target: nil, action: nil)

    init(image: URL? = nil) {
        super.init(frame: .zero)
        picker.target = self
        picker.action = #selector(switchPane(_:))
        picker.selectedSegment = 0
        for v in [picker, converter, remover] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        for pane in [converter, remover] as [NSView] {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 14),
                pane.leadingAnchor.constraint(equalTo: leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        switchPane(picker)
        if let image {
            converter.open(image)
            remover.prepare(image)   // the background is removed when you switch to that tab
        }
        // A picture dropped into either box is shared with the other tab too.
        converter.onImage = { [weak self] url in self?.remover.prepare(url) }
        remover.onImage = { [weak self] url in self?.converter.open(url) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func switchPane(_ sender: NSSegmentedControl) {
        converter.isHidden = sender.selectedSegment != 0
        remover.isHidden = sender.selectedSegment != 1
        if sender.selectedSegment == 1 { remover.runIfPrepared() }
    }
}

// MARK: - Shared pieces

enum ImageTools {
    enum Failure: LocalizedError {
        case unreadable, noSubject, writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be opened as an image."
            case .noSubject: "No clear subject (person, animal or object) was found in this image."
            case .writeFailed: "The new file couldn't be saved."
            }
        }
    }

    /// Reads an image the right way up, optionally shrunk so its longest side is `maxSize` pixels.
    static func load(_ url: URL, maxSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 4096
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSize ?? max(w, h), max(w, h)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Puts the image on white (for formats without transparency, like JPEG).
    static func flattened(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double) throws {
        if type == .pdf {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Failure.writeFailed }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
            return
        }
        let needsFlat = [UTType.jpeg, .bmp].contains(type)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, needsFlat ? flattened(image) : image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.writeFailed }
    }

    /// Cuts out the main subject using Apple's on-device AI (nothing is uploaded).
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let output = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(output, from: output.extent) else { throw Failure.writeFailed }
        return cg
    }

    /// Puts a picture on the clipboard both as a picture and as a file, so it pastes into
    /// chat boxes, documents and other apps.
    @MainActor
    static func copy(_ image: CGImage, name: String, type: UTType, quality: Double) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copied", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name).appendingPathExtension(type.preferredFilenameExtension ?? "png")
        guard (try? write(image, to: file, type: type, quality: quality)) != nil,
              let data = try? Data(contentsOf: file) else { return false }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        if type != .png, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        item.setString(file.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }

    static func sizeText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A box you can drop an image onto (or click to choose one). Shows a preview.
final class ImageDropView: SolidView {
    var onImage: ((URL) -> Void)?
    private let preview = NSImageView()
    private let hint = NSTextField(labelWithString: "Drop an image here, or click to choose one")

    init() {
        super.init(color: Theme.toolbar)
        cornerRadius = 12
        preview.imageScaling = .scaleProportionallyDown
        // A big picture must never push the box (and the window) wider or taller: it shrinks to fit.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentCompressionResistancePriority(.init(1), for: orientation)
            preview.setContentHuggingPriority(.init(1), for: orientation)
        }
        preview.unregisterDraggedTypes()
        hint.textColor = Theme.mutedText
        hint.font = .systemFont(ofSize: 13)
        for v in [preview, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes(Self.pictureTypes)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: CGImage?) {
        preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
        hint.isHidden = image != nil
    }

    override func mouseUp(with event: NSEvent) { chooseFile() }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.onImage?(url) }
        }
    }

    /// Files, plain pictures, and pictures other apps promise to write (screenshots, Photos).
    static let pictureTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        StandInDrag.hasContent(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.picture(from: sender) else { return false }
        onImage?(url)
        return true
    }

    /// Saves whatever picture is being dragged as a file the tools can open.
    static func picture(from info: NSDraggingInfo) -> URL? {
        let collector = StandInDrag(info)
        defer { collector.cleanUp() }
        return collector.collectCopies().first
    }
}

@MainActor
private func makeButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    return b
}

@MainActor
private func makeStatus() -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: "")
    l.textColor = Theme.mutedText
    l.font = .systemFont(ofSize: 12)
    return l
}

// MARK: - File converter

final class ConverterPane: NSView {
    private struct Format { let name: String; let type: UTType; let lossy: Bool }
    private let formats = [
        Format(name: "PNG", type: .png, lossy: false),
        Format(name: "JPEG", type: .jpeg, lossy: true),
        Format(name: "HEIC", type: .heic, lossy: true),
        Format(name: "TIFF", type: .tiff, lossy: false),
        Format(name: "GIF", type: .gif, lossy: false),
        Format(name: "BMP", type: .bmp, lossy: false),
        Format(name: "PDF", type: .pdf, lossy: false),
    ]
    private let sizes: [(String, Int?)] = [("Original size", nil), ("4096 px", 4096), ("2048 px", 2048),
                                           ("1024 px", 1024), ("512 px", 512), ("256 px", 256)]

    private let drop = ImageDropView()
    private let formatPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let quality = NSSlider(value: 0.85, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality")
    private let status = makeStatus()
    private var source: URL?
    var onImage: ((URL) -> Void)?

    init() {
        super.init(frame: .zero)
        formats.forEach { formatPopup.addItem(withTitle: $0.name) }
        sizes.forEach { sizePopup.addItem(withTitle: $0.0) }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        drop.onImage = { [weak self] url in self?.open(url); self?.onImage?(url) }

        let choose = makeButton("Choose Image…", self, #selector(chooseClicked(_:)))
        let save = makeButton("Convert & Save…", self, #selector(saveClicked(_:)))
        save.keyEquivalent = "\r"
        let copy = makeButton("Copy", self, #selector(copyClicked(_:)))
        let options = NSStackView(views: [NSTextField(labelWithString: "Convert to"), formatPopup,
                                          NSTextField(labelWithString: "Size"), sizePopup])
        options.spacing = 8
        let qualityRow = NSStackView(views: [qualityLabel, quality])
        qualityRow.spacing = 8
        quality.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let buttons = NSStackView(views: [choose, save, copy])
        buttons.spacing = 8

        let stack = NSStackView(views: [drop, options, qualityRow, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drop.heightAnchor.constraint(equalToConstant: 320),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        formatChanged(formatPopup)
        status.stringValue = "Turns any image (PNG, JPEG, HEIC, WebP, TIFF, GIF, BMP, RAW…) into another format, and can shrink it."
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func open(_ url: URL) {
        guard let preview = ImageTools.load(url, maxSize: 900) else {
            status.stringValue = ImageTools.Failure.unreadable.localizedDescription
            return
        }
        source = url
        drop.show(preview)
        status.stringValue = "\(url.lastPathComponent) — \(ImageTools.sizeText(url))"
    }

    @objc private func formatChanged(_ sender: Any?) {
        let lossy = formats[max(0, formatPopup.indexOfSelectedItem)].lossy
        quality.isEnabled = lossy
        qualityLabel.textColor = lossy ? Theme.text : Theme.mutedText
    }

    @objc private func chooseClicked(_ sender: Any?) { drop.chooseFile() }

    /// Copies the picture, converted to the chosen type and size, ready to paste with ⌘V.
    @objc private func copyClicked(_ sender: Any?) {
        guard let source else { status.stringValue = "Choose an image first."; return }
        let format = formats[max(0, formatPopup.indexOfSelectedItem)]
        let maxSize = sizes[max(0, sizePopup.indexOfSelectedItem)].1
        guard let image = ImageTools.load(source, maxSize: maxSize) else {
            status.stringValue = ImageTools.Failure.unreadable.localizedDescription
            return
        }
        // Pages paste PNG/JPEG best; other types are copied as PNG.
        let type: UTType = format.type == .jpeg ? .jpeg : .png
        let name = source.deletingPathExtension().lastPathComponent
        if ImageTools.copy(image, name: name, type: type, quality: quality.doubleValue) {
            status.stringValue = "Copied. Click where you want it (a chat box, a document…) and press ⌘V."
        } else {
            status.stringValue = "Couldn't copy that picture."
        }
    }

    @objc private func saveClicked(_ sender: Any?) {
        guard let source, let window else { status.stringValue = "Choose an image first."; return }
        let format = formats[max(0, formatPopup.indexOfSelectedItem)]
        let maxSize = sizes[max(0, sizePopup.indexOfSelectedItem)].1
        let q = quality.doubleValue
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let out = panel.url else { return }
            guard let image = ImageTools.load(source, maxSize: maxSize) else {
                self?.status.stringValue = ImageTools.Failure.unreadable.localizedDescription
                return
            }
            do {
                try ImageTools.write(image, to: out, type: format.type, quality: q)
                self?.status.stringValue = "Saved \(out.lastPathComponent) — \(ImageTools.sizeText(out)) (was \(ImageTools.sizeText(source)))"
            } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }
}

// MARK: - Background remover

final class RemoverPane: NSView {
    private let drop = ImageDropView()
    private let status = makeStatus()
    private let saveButton = NSButton(title: "Save as PNG…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var result: CGImage?
    private var source: URL?
    private var prepared: URL?
    var onImage: ((URL) -> Void)?

    init() {
        super.init(frame: .zero)
        drop.onImage = { [weak self] url in self?.process(url); self?.onImage?(url) }
        let choose = makeButton("Choose Image…", self, #selector(chooseClicked(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))
        saveButton.isEnabled = false
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyClicked(_:))
        copyButton.isEnabled = false
        let buttons = NSStackView(views: [choose, saveButton, copyButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [drop, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            drop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drop.heightAnchor.constraint(equalToConstant: 360),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        status.stringValue = "Drop a photo to cut out the person, pet or object and remove the background. It all happens on your Mac; nothing is uploaded."
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func chooseClicked(_ sender: Any?) { drop.chooseFile() }

    /// Remembers a picture; its background is removed when this tab is shown.
    func prepare(_ url: URL) {
        prepared = url
        if !isHidden { runIfPrepared() }
    }

    func runIfPrepared() {
        guard let url = prepared else { return }
        prepared = nil
        process(url)
    }

    @objc private func copyClicked(_ sender: Any?) {
        guard let result else { return }
        let name = (source?.deletingPathExtension().lastPathComponent ?? "image") + " (no background)"
        status.stringValue = ImageTools.copy(result, name: name, type: .png, quality: 1)
            ? "Copied with a transparent background. Click where you want it and press ⌘V."
            : "Couldn't copy that picture."
    }

    private func process(_ url: URL) {
        guard let image = ImageTools.load(url) else {
            status.stringValue = ImageTools.Failure.unreadable.localizedDescription
            return
        }
        source = url
        result = nil
        saveButton.isEnabled = false
        copyButton.isEnabled = false
        drop.show(image)
        status.stringValue = "Removing the background…"
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try ImageTools.removeBackground(image) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let cut):
                    self.result = cut
                    self.drop.show(cut)
                    self.saveButton.isEnabled = true
                    self.copyButton.isEnabled = true
                    self.status.stringValue = "Done. “Copy” to paste it somewhere with ⌘V, or “Save as PNG…” to keep it (the background is transparent)."
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func saveClicked(_ sender: Any?) {
        guard let result, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (source?.deletingPathExtension().lastPathComponent ?? "image") + " (no background)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let out = panel.url else { return }
            do {
                try ImageTools.write(result, to: out, type: .png, quality: 1)
                self?.status.stringValue = "Saved \(out.lastPathComponent)."
            } catch {
                self?.status.stringValue = error.localizedDescription
            }
        }
    }
}


/// The Tools button on the top bar. Drag a picture onto it: let go to open Tools with that
/// picture, or hold it there a moment to open Tools and drop into its box.
final class ToolsDropButton: NSButton {
    private var springTimer: Timer?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    private func setUp() { registerForDraggedTypes(ImageDropView.pictureTypes) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard StandInDrag.hasContent(sender.draggingPasteboard) else { return [] }
        highlight(true)
        springTimer?.invalidate()
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.openTools(with: nil) }
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        springTimer?.invalidate()
        highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springTimer?.invalidate()
        highlight(false)
        guard let url = ImageDropView.picture(from: sender) else { return false }
        openTools(with: url)
        return true
    }

    private func openTools(with url: URL?) {
        guard let window else { return }
        ToolsOverlay.show(in: window, image: url)
    }
}
