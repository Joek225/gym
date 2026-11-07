import AppKit
import WebKit
import UniformTypeIdentifiers

/// The web view used for every page. It behaves exactly like WebKit's own, except for one
/// safety net: if WebKit turns down something dropped onto the page — for example the
/// floating screenshot thumbnail, or a photo from the Photos app, which hand over a
/// "promised" file instead of a finished one — we collect the file ourselves and hand it
/// to the page as a normal file drop (the way upload areas like chat boxes expect).
final class BrowserWebView: WKWebView {
    private var handlingDropOurselves = false

    /// Pictures from other apps that aren't real files yet (the floating screenshot
    /// thumbnail, Photos, Preview, Messages…). WebKit says "yes" to these but then hands the
    /// page nothing, so we take them ourselves. Real files (from Finder) and drags inside
    /// the page are left to WebKit, which handles those properly.
    private func shouldHandleOurselves(_ info: NSDraggingInfo) -> Bool {
        if info.draggingSource != nil { return false }                        // dragged within the browser
        let pb = info.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return false }
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingDropOurselves = shouldHandleOurselves(sender)
        return handlingDropOurselves ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingDropOurselves ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if handlingDropOurselves { handlingDropOurselves = false } else { super.draggingExited(sender) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlingDropOurselves ? true : super.prepareForDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if !handlingDropOurselves { super.concludeDragOperation(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handlingDropOurselves else { return super.performDragOperation(sender) }
        DispatchQueue.main.async { [weak self] in self?.handlingDropOurselves = false }
        let point = convert(sender.draggingLocation, from: nil)
        let pb = sender.draggingPasteboard

        // 1. Promised files (screenshot thumbnail, Photos): ask for them to be written into a temporary folder.
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drops-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let queue = OperationQueue()
            var collected: [URL] = []
            let group = DispatchGroup()
            for promise in promises {
                for _ in promise.fileNames { group.enter() }
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                    if error == nil { DispatchQueue.main.async { collected.append(url) } }
                    DispatchQueue.main.async { group.leave() }
                }
            }
            group.notify(queue: .main) { [weak self] in self?.deliver(files: collected, at: point) }
            return true
        }

        // 2. A plain picture on the clipboard of the drag: save it as a PNG.
        if let image = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first,
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Image \(Int(Date().timeIntervalSince1970)).png")
            try? png.write(to: url)
            deliver(files: [url], at: point)
            return true
        }
        return false
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
        const target = document.elementFromPoint(x, y) || document.body;
        for (const type of ['dragenter', 'dragover', 'drop']) {
          target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, composed: true,
                                                     dataTransfer: dt, clientX: x, clientY: y }));
        }
        return true;
        """
        callAsyncJavaScript(js, arguments: ["files": items, "x": x, "y": y], in: nil, in: .page, completionHandler: nil)
    }
}
