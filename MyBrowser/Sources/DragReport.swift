import AppKit
import WebKit

/// A short diary of the last few drags onto pages, for finding out why a drop fails on a
/// particular site. ⋮ menu → Copy Drag-and-Drop Report puts it on the clipboard.
/// It records only drag mechanics (types, answers, which route was taken) — never page
/// contents, picture contents or addresses beyond the site's name.
@MainActor
enum DragReport {
    private static var lines: [String] = []
    private static let start = Date()

    static func add(_ line: String) {
        let t = String(format: "%7.2f", Date().timeIntervalSince(start))
        lines.append("\(t)  \(line)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        if CommandLine.arguments.contains("--test-drop") { NSLog("MyBrowser drag report: %@", line) }
    }

    static var text: String {
        let mac = ProcessInfo.processInfo.operatingSystemVersionString
        return (["beababrowser drag-and-drop report (macOS \(mac))"] + lines).joined(separator: "\n")
    }

    static func names(_ op: NSDragOperation) -> String {
        if op.isEmpty { return "none" }
        var parts: [String] = []
        if op.contains(.copy) { parts.append("copy") }
        if op.contains(.link) { parts.append("link") }
        if op.contains(.generic) { parts.append("generic") }
        if op.contains(.move) { parts.append("move") }
        return parts.joined(separator: "+")
    }

    static func types(_ pb: NSPasteboard) -> String {
        let all = (pb.types ?? []).map(\.rawValue)
        return all.prefix(10).joined(separator: ", ") + (all.count > 10 ? " …(\(all.count) total)" : "")
    }

    // MARK: What the page does with the drag (seen from a walled-off script the page can't touch)

    static let world = WKContentWorld.world(name: "MyBrowserDragProbe")
    static let handlerName = "mybrowserDragProbe"

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.add(Probe.shared, contentWorld: world, name: handlerName)
    }

    /// Runs after the page's own handlers (last stop of the event): did the page accept it?
    private static let probe = #"""
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.mybrowserDragProbe.postMessage(m); } catch (e) {} };
      const where = window === window.top ? 'page' : 'frame ' + location.host;
      let last = '';
      const describe = (e) => {
        const dt = e.dataTransfer;
        const t = e.target;
        const tag = t && t.tagName ? t.tagName.toLowerCase() + (t.id ? '#' + t.id : '') : '?';
        return e.type + ' on ' + tag + ' accepted=' + e.defaultPrevented +
          ' effect=' + (dt ? dt.dropEffect : '?') + ' types=[' + (dt ? Array.from(dt.types).join(',') : '') + ']' +
          (e.type === 'drop' && dt ? ' files=' + dt.files.length : '') + ' trusted=' + e.isTrusted + ' (' + where + ')';
      };
      for (const type of ['dragenter', 'dragover', 'dragleave', 'drop']) {
        window.addEventListener(type, (e) => {
          const line = describe(e);
          if (type === 'dragover' && line === last) return;   // only when something changes
          last = line;
          post(line);
        }, false);
      }
    })();
    """#

    final class Probe: NSObject, WKScriptMessageHandler {
        static let shared = Probe()
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let line = message.body as? String else { return }
            MainActor.assumeIsolated { DragReport.add("  page: " + String(line.prefix(300))) }
        }
    }
}
