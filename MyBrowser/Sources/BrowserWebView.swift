import AppKit
import WebKit
import UniformTypeIdentifiers

/// The web view used for every page. It behaves exactly like WebKit's own, except for drops
/// from other apps (Finder files, the screenshot thumbnail, Photos, Messages…).
///
/// How Chrome does it: its main app reads the dragged file or picture data itself and gives
/// the page a copy; the page's own process never opens your files. We do the same: the
/// dragged files/picture are copied into the browser's own temporary folder, and WebKit then
/// performs a genuine drop of those copies. (Letting WebKit's page process open files
/// elsewhere on your Mac fails because of the app sandbox, which is why drops broke.)
final class BrowserWebView: WKWebView {
    /// The drag as WebKit sees it while we're standing in for it (nil = normal drag).
    private var stand: StandInDrag?

    /// Anything from another app that carries files or a picture. Drags within the page
    /// (selected text, links, images moved inside a site) go straight to WebKit.
    private func needsStandIn(_ info: NSDraggingInfo) -> Bool {
        info.draggingSource == nil && StandInDrag.hasContent(info.draggingPasteboard)
    }

    /// What the page itself last said about the drag (nothing = it doesn't want it here).
    private var pageOperation: NSDragOperation = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        stand?.cleanUp()
        stand = needsStandIn(sender) ? StandInDrag(sender) : nil
        return answer(super.draggingEntered(stand ?? sender))
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        answer(super.draggingUpdated(stand ?? sender))
    }

    /// Some sites (Claude, for one) turn drops down but accept the same picture pasted.
    /// For drags we're carrying, show the green + anyway; if the page still says no when
    /// you let go over a text box, the picture is pasted into that box instead.
    private func answer(_ operation: NSDragOperation) -> NSDragOperation {
        guard stand != nil else { return operation }
        pageOperation = operation
        return operation.isEmpty ? .copy : operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(stand ?? sender)
        stand?.cleanUp()
        stand = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        stand != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let stand else { return super.performDragOperation(sender) }
        // Now get the real picture (a promised file is only written when you let go).
        let files = stand.collectCopies()
        guard !files.isEmpty else { return false }
        stand.use(files)
        let point = convert(sender.draggingLocation, from: nil)
        // The page answers "do you want this?" a moment after the mouse moves. If you let go
        // quickly, its answer may not be in yet: wait for it (up to about a second) instead of
        // treating the drop as refused. This made drops fail now and then.
        let deadline = Date().addingTimeInterval(1.2)
        while pageOperation.isEmpty && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            pageOperation = super.draggingUpdated(stand)
        }
        if pageOperation.isEmpty {
            // The page refused the drop: tell WebKit the drag is over, then paste instead.
            super.draggingExited(stand)
            pasteInstead(files, at: point)
            return true
        }
        _ = super.prepareForDragOperation(stand)
        if super.performDragOperation(stand) { return true }
        // WebKit said no: hand the page the files another way.
        deliver(files: files, at: point)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if stand == nil || !pageOperation.isEmpty { super.concludeDragOperation(stand ?? sender) }
        stand = nil   // the temporary file stays until the app quits, so the page can finish reading it
    }

    /// Puts the cursor in the text box under the drop point and pastes the files there, as if
    /// you'd copied them and pressed ⌘V. Your clipboard is put back right after.
    private func pasteInstead(_ files: [URL], at point: NSPoint) {
        let scale = max(pageZoom * magnification, 0.01)
        let x = point.x / scale
        let y = (isFlipped ? point.y : bounds.height - point.y) / scale
        let js = """
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot && el.shadowRoot.elementFromPoint) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        const box = el && el.closest('textarea, input:not([type=hidden]), [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]');
        if (!box) return false;
        box.focus();
        return true;
        """
        callAsyncJavaScript(js, arguments: ["x": x, "y": y], in: nil, in: .page) { [weak self] result in
            guard let self, case .success(let value) = result, (value as? Bool) == true else { return }
            self.window?.makeFirstResponder(self)
            let general = NSPasteboard.general
            let saved = Self.copyItems(of: general)
            general.clearContents()
            for file in files {
                let item = NSPasteboardItem()
                item.setString(file.absoluteString, forType: .fileURL)
                if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
                   let data = try? Data(contentsOf: file) {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                }
                general.writeObjects([item])
            }
            NSApp.sendAction(#selector(NSText.paste(_:)), to: self, from: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                general.clearContents()
                if !saved.isEmpty { general.writeObjects(saved) }
            }
        }
    }

    private static func copyItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Gives the files to the page as a real drop at the spot where you let go.
    private func deliver(files: [URL], at point: NSPoint) {
        let items: [[String: String]] = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()]
        }
        guard !items.isEmpty else { return }
        let scale = max(pageZoom * magnification, 0.01)
        let x = point.x / scale
        let y = (isFlipped ? point.y : bounds.height - point.y) / scale
        let js = """
        const dt = new DataTransfer();
        for (const f of files) {
          const bin = atob(f.data); const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          dt.items.add(new File([bytes], f.name, { type: f.type }));
        }
        const fire = (target, type) => target.dispatchEvent(new DragEvent(type, {
          bubbles: true, cancelable: true, composed: true, dataTransfer: dt, clientX: x, clientY: y }));
        const first = document.elementFromPoint(x, y) || document.body;
        fire(first, 'dragenter');
        fire(first, 'dragover');
        // Many chat sites show a "drop files here" layer once a drag arrives; give it a
        // moment to appear, then drop onto whatever is under the pointer now.
        await new Promise((r) => setTimeout(r, 120));
        const target = document.elementFromPoint(x, y) || first;
        if (target !== first) { fire(target, 'dragenter'); }
        fire(target, 'dragover');
        fire(target, 'drop');
        return true;
        """
        callAsyncJavaScript(js, arguments: ["files": items, "x": x, "y": y], in: nil, in: .page, completionHandler: nil)
    }
}


/// The drag as WebKit sees it while we stand in for a drop from another app: the same drag,
/// except it carries copies of the files in the browser's own folder. While hovering, the
/// copies are empty placeholders with the right names (sites only see "files are coming");
/// when you let go they're filled in. Reading the data follows Chrome's order: real files,
/// then a picture's "promised file" data, then any picture on the drag, then (last resort)
/// asking the other app to write its promised file.
@MainActor
final class StandInDrag: NSObject, NSDraggingInfo {
    private let original: NSDraggingInfo
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("beababrowser-drop-\(UUID().uuidString)"))
    private let folder: URL
    private static let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
    private static let maxBytes = 256 * 1024 * 1024   // same limit as Chrome

    init(_ original: NSDraggingInfo) {
        self.original = original
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops/\(UUID().uuidString)", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = Self.names(on: original.draggingPasteboard)
        use(names.enumerated().map { i, name in
            let url = slot(i).appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return url
        })
    }

    /// Whether a drag from another app carries anything we can turn into files.
    static func hasContent(_ pb: NSPasteboard) -> Bool {
        !fileURLs(pb).isEmpty || pictureData(pb) != nil
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        ((pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            .filter { !$0.hasDirectoryPath }
    }

    /// A picture carried as data: the "promised file" content first (screenshots, Photos),
    /// then any image type on the drag.
    private static func pictureData(_ pb: NSPasteboard) -> (data: Data, ext: String)? {
        let types = pb.types ?? []
        if types.contains(promisedContentType), let id = pb.string(forType: promisedContentType),
           types.contains(NSPasteboard.PasteboardType(id)), let data = pb.data(forType: NSPasteboard.PasteboardType(id)) {
            return (data, UTType(id)?.preferredFilenameExtension ?? "png")
        }
        for type in types {
            if let ut = UTType(type.rawValue), ut.conforms(to: .image), let data = pb.data(forType: type) {
                // Pages understand PNG/JPEG/GIF/WebP/HEIC; turn anything else (like TIFF) into PNG.
                if ["png", "jpeg", "gif", "webp", "heic"].contains(ut.preferredFilenameExtension ?? "") {
                    return (data, ut.preferredFilenameExtension ?? "png")
                }
                if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                    return (png, "png")
                }
            }
        }
        return nil
    }

    private static func names(on pb: NSPasteboard) -> [String] {
        let files = fileURLs(pb)
        if !files.isEmpty { return files.map(\.lastPathComponent) }
        if let picture = pictureData(pb) { return ["Image.\(picture.ext)"] }
        let promised = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver])?
            .first?.fileNames.first
        return [promised ?? "Image.png"]
    }

    /// Each file gets its own folder, so two files with the same name don't collide.
    private func slot(_ i: Int) -> URL {
        let url = folder.appendingPathComponent("\(i)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func use(_ files: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
    }

    /// Copies what's being dragged into the browser's folder and returns the copies.
    func collectCopies() -> [URL] {
        let pb = original.draggingPasteboard
        // 1. Real files (Finder, the desktop, a screenshot): read here, in the browser itself.
        let files = Self.fileURLs(pb)
        if !files.isEmpty {
            return files.enumerated().compactMap { i, file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxBytes, let data = try? Data(contentsOf: file) else { return nil }
                let copy = slot(i).appendingPathComponent(file.lastPathComponent)
                return (try? data.write(to: copy)) != nil ? copy : nil
            }
        }
        // 2. A picture carried as data.
        if let picture = Self.pictureData(pb), picture.data.count <= Self.maxBytes {
            let copy = slot(0).appendingPathComponent("Image.\(picture.ext)")
            if (try? picture.data.write(to: copy)) != nil { return [copy] }
        }
        // 3. Last resort: ask the other app to write its promised file.
        if let promise = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver])?.first {
            let target = folder.appendingPathComponent("received", isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var received: URL?
            var finished = false
            promise.receivePromisedFiles(atDestination: target, options: [:], operationQueue: OperationQueue()) { url, error in
                DispatchQueue.main.async {
                    if error == nil, received == nil { received = url }
                    finished = true
                }
            }
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            if let received { return [received] }
        }
        return []
    }

    func cleanUp() { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { original.draggingDestinationWindow }
    var draggingSourceOperationMask: NSDragOperation { original.draggingSourceOperationMask.union(.copy) }
    var draggingLocation: NSPoint { original.draggingLocation }
    var draggedImageLocation: NSPoint { original.draggedImageLocation }
    var draggedImage: NSImage? { original.draggedImage }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { original.draggingSequenceNumber }
    func slideDraggedImage(to screenPoint: NSPoint) { original.slideDraggedImage(to: screenPoint) }
    var draggingFormation: NSDraggingFormation {
        get { original.draggingFormation }
        set { original.draggingFormation = newValue }
    }
    var animatesToDestination: Bool {
        get { original.animatesToDestination }
        set { original.animatesToDestination = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { original.numberOfValidItemsForDrop }
        set { original.numberOfValidItemsForDrop = newValue }
    }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        withoutActuallyEscaping(block) { block in
            original.enumerateDraggingItems(options: enumOpts, for: view, classes: classArray, searchOptions: searchOptions, using: block)
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { original.springLoadingHighlight }
    func resetSpringLoading() { original.resetSpringLoading() }
}
