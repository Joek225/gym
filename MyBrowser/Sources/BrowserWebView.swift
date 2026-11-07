import AppKit
import WebKit
import UniformTypeIdentifiers

/// The web view used for every page. It behaves exactly like WebKit's own, except for
/// pictures dragged in from other apps that aren't saved files yet (the floating screenshot
/// thumbnail, Photos, Preview, Messages…). WebKit can't hand those to a page, so the browser
/// saves the picture as a real file first and lets WebKit drop *that* — a genuine drop,
/// exactly like dragging a file from Finder, which sites such as Claude and Snapchat need.
final class BrowserWebView: WKWebView {
    /// The drag as WebKit sees it while we're standing in for a picture (nil = normal drag).
    private var stand: StandInDrag?

    /// Pictures from another app that aren't files. Files from Finder and drags within the
    /// page go straight to WebKit untouched.
    private func needsStandIn(_ info: NSDraggingInfo) -> Bool {
        if info.draggingSource != nil { return false }
        let pb = info.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return false }
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        stand?.cleanUp()
        stand = needsStandIn(sender) ? StandInDrag(sender) : nil
        return super.draggingEntered(stand ?? sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        super.draggingUpdated(stand ?? sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(stand ?? sender)
        stand?.cleanUp()
        stand = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        super.prepareForDragOperation(stand ?? sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let stand else { return super.performDragOperation(sender) }
        // Now get the real picture (a promised file is only written when you let go).
        guard let file = stand.collectPicture() else { return false }
        stand.use(file)
        if super.performDragOperation(stand) { return true }
        // WebKit said no: hand the page the file another way.
        deliver(files: [file], at: convert(sender.draggingLocation, from: nil))
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(stand ?? sender)
        stand = nil   // the temporary file stays until the app quits, so the page can finish reading it
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


/// The drag as WebKit sees it while it's carrying a picture from another app: the same drag,
/// except it holds a real file. While hovering, the file is a placeholder (sites only see
/// "a file is coming"); when you let go it is swapped for the actual picture.
@MainActor
final class StandInDrag: NSObject, NSDraggingInfo {
    private let original: NSDraggingInfo
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("beababrowser-drop-\(UUID().uuidString)"))
    private let folder: URL

    init(_ original: NSDraggingInfo) {
        self.original = original
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops/\(UUID().uuidString)", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let promised = (original.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                        as? [NSFilePromiseReceiver])?.first?.fileNames.first
        let placeholder = folder.appendingPathComponent(promised ?? "Image.png")
        FileManager.default.createFile(atPath: placeholder.path, contents: Data())
        use(placeholder)
    }

    func use(_ file: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    /// Saves the dragged picture as a file: the promised file if the app offers one,
    /// otherwise the picture itself as a PNG.
    func collectPicture() -> URL? {
        let pb = original.draggingPasteboard
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           let promise = promises.first {
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
            // Wait (up to 5 seconds) for the other app to write it, keeping the app responsive.
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            if let received { return received }
        }
        if let image = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = folder.appendingPathComponent("Image.png")
            try? png.write(to: url)
            return url
        }
        return nil
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
