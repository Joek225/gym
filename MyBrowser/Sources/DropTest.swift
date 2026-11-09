import AppKit
import WebKit

/// Used by the automatic test (--test-drop): drops a picture onto a chat-style page the way
/// macOS does, and logs what the page received. Not used in normal browsing.
@MainActor
enum DropTest {
    static func run(in controller: BrowserWindowController) {
        guard let webView = controller.selectedTab?.webView else { NSLog("MyBrowser drop test: no page"); return }
        // Like Claude/Snapchat: the drop area only appears once a drag arrives, and only
        // a real (trusted) drop counts.
        let html = """
        <html><body style="margin:0;height:100vh">drop here<div id="z" style="position:fixed;inset:0;display:none"></div><script>
        const z = document.getElementById('z');
        document.addEventListener('dragenter', () => setTimeout(() => { z.style.display = 'block'; }, 50));
        z.addEventListener('dragover', (e) => e.preventDefault());
        z.addEventListener('drop', (e) => {
          e.preventDefault();
          z.style.display = 'none';
          const f = e.dataTransfer.files;
          document.title = 'dropped ' + f.length + (f[0] ? ' ' + f[0].name + ' ' + f[0].size + ' ' + f[0].type : '') + ' trusted=' + e.isTrusted;
        });
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // Several drops in a row, mixing both kinds (one working and then stopping was a real problem).
            runCase("file", webView: webView) {
                runCase("image", webView: webView) {
                    runCase("file again", webView: webView) {
                        runCase("image again", webView: webView) {
                            runCase("quick file", webView: webView) {
                            runCase("photo", webView: webView) {
                                // Like Claude: the message box refuses drops but accepts pasted pictures.
                                webView.loadHTMLString(editorPage, baseURL: URL(string: "https://example.com/"))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    runCase("refused drop", webView: webView) {
                                        checkHiddenTabs(controller: controller)
                                    }
                                }
                            }
                            }
                        }
                    }
                }
            }
        }
    }

    private static let editorPage = """
    <html><body style="margin:0"><div id="box" contenteditable="true" style="position:fixed;inset:0">message</div><script>
    // Refuses drops outright, the way Claude's message box does (no green + while hovering).
    document.addEventListener('dragover', (e) => { e.preventDefault(); e.dataTransfer.dropEffect = 'none'; });
    document.addEventListener('drop', (e) => e.preventDefault());
    document.getElementById('box').addEventListener('paste', (e) => {
      e.preventDefault();
      const f = e.clipboardData.files;
      document.title = 'dropped ' + f.length + (f[0] ? ' ' + f[0].name + ' ' + f[0].size + ' ' + f[0].type : '') + ' trusted=' + e.isTrusted;
    });
    </script></body></html>
    """

    /// With a second tab open and then left in the background, only the visible page may
    /// accept drops (a hidden tab catching a screenshot was a real problem).
    private static func checkHiddenTabs(controller: BrowserWindowController) {
        guard let first = controller.selectedTab else { return }
        controller.openInNewTab(URL(string: "https://example.com/?second")!, background: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            controller.select(first)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let pages = (first.webView?.superview?.subviews ?? []).compactMap { $0 as? WKWebView }
                let visible = pages.filter { !$0.isHidden }
                let hiddenTaking = pages.filter { $0.isHidden && !$0.registeredDraggedTypes.isEmpty }
                NSLog("MyBrowser drop registration: pages %d, visible taking drops %d, hidden taking drops %d",
                      pages.count, visible.filter { !$0.registeredDraggedTypes.isEmpty }.count, hiddenTaking.count)
            }
        }
    }

    private static func picture() -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemPink.setFill(); rect.fill(); return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private static func runCase(_ name: String, webView: WKWebView, then next: @escaping () -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("beababrowser-drop-test-\(name)"))
        pb.clearContents()
        let png = picture()
        if name.hasPrefix("file") || name.hasPrefix("quick") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(name).png")
            try? png.write(to: url)
            pb.writeObjects([url as NSURL])
        } else if name == "photo" {
            // How Photos and the screenshot thumbnail describe a picture.
            pb.setString("public.png", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
            pb.setData(png, forType: .png)
        } else {
            pb.setData(png, forType: .png)
            pb.setData(NSImage(data: png)?.tiffRepresentation, forType: .tiff)
        }
        let center = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let info = FakeDrag(pasteboard: pb, location: center, window: webView.window)
        var ops: [String] = ["entered \(webView.draggingEntered(info).rawValue)"]
        func step(_ n: Int) {
            if n > 0 {
                ops.append("updated \(webView.draggingUpdated(info).rawValue)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { step(n - 1) }
                return
            }
            _ = webView.prepareForDragOperation(info)
            let performed = webView.performDragOperation(info)
            webView.concludeDragOperation(info)
            ops.append("performed \(performed)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                webView.evaluateJavaScript("document.title") { title, _ in
                    NSLog("MyBrowser drop test %@: %@ — page got: %@", name, ops.joined(separator: ", "), (title as? String) ?? "?")
                    webView.evaluateJavaScript("document.title = ''") { _, _ in next() }
                }
            }
        }
        // "quick": let go the instant the drag arrives, before the page has answered.
        step(name.hasPrefix("quick") ? 0 : 4)
    }
}

/// Stands in for macOS's description of an ongoing drag.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var window: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
        self.pasteboard = pasteboard
        self.location = location
        self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
