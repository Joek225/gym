import AppKit
import WebKit

/// Gets each site's small icon and shrinks it to 32×32 pixels so it uses
/// almost no memory. Icons are remembered per website.
@MainActor
enum Favicons {
    private static var cache: [String: (image: NSImage, png: Data)] = [:]

    static func cached(for url: URL?) -> NSImage? {
        guard let host = url?.host else { return nil }
        return cache[host]?.image
    }

    static func image(fromPNG data: Data) -> NSImage? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        return image
    }

    static func fetch(for tab: Tab, in webView: WKWebView, completion: @escaping () -> Void) {
        guard let pageURL = webView.url, let host = pageURL.host else { return }
        if let hit = cache[host] {
            tab.favicon = hit.image
            tab.faviconPNG = hit.png
            tab.faviconHost = host
            completion()
            return
        }
        let js = "(function(){var l=document.querySelector('link[rel~=\"icon\"],link[rel=\"apple-touch-icon\"]');return l?l.href:'';})()"
        webView.evaluateJavaScript(js) { result, _ in
            let href = result as? String ?? ""
            var iconURL = URL(string: href)
            if let scheme = iconURL?.scheme, !["http", "https", "data"].contains(scheme) { iconURL = nil }
            if iconURL == nil { iconURL = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL }
            guard let iconURL else { return }
            Task { @MainActor in
                guard let response = try? await URLSession.shared.data(from: iconURL),
                      let made = thumbnail(response.0) else { return }
                if cache.count > 300 { cache.removeAll() }
                cache[host] = made
                tab.favicon = made.image
                tab.faviconPNG = made.png
                tab.faviconHost = host
                completion()
            }
        }
    }

    private static func thumbnail(_ data: Data) -> (image: NSImage, png: Data)? {
        guard let source = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        return (image, png)
    }
}
