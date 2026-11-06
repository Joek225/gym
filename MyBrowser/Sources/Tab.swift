import AppKit
import WebKit

/// A named, colored set of tabs, like Chrome's tab groups.
@MainActor
final class TabGroup: NSObject {
    let id: UUID
    var name: String
    var color: GroupColor
    var isCollapsed: Bool
    var tabs: [Tab] = []

    init(id: UUID = UUID(), name: String, color: GroupColor, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        super.init()
    }
}

/// One tab. When unloaded, its web page is thrown away to free memory,
/// but its address, title, icon and back/forward history are kept.
@MainActor
final class Tab: NSObject {
    let id: UUID
    var url: URL?
    var title: String
    var favicon: NSImage?
    var faviconPNG: Data?
    var faviconHost: String?
    weak var group: TabGroup?
    /// When you last looked at this tab (used to decide when to unload it).
    var lastActive = Date()
    var errorMessage: String?
    var failedURL: URL?
    /// Back/forward history saved when the tab was unloaded.
    var savedState: Any?
    private(set) var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), url: URL?, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
        super.init()
    }

    var isLoaded: Bool { webView != nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host, !host.isEmpty { return host }
        return "New Tab"
    }

    /// The address to show (blank for empty pages).
    var displayURL: URL? {
        let u = failedURL ?? url
        return u?.absoluteString == "about:blank" ? nil : u
    }

    func attach(_ webView: WKWebView, observations: [NSKeyValueObservation]) {
        self.webView = webView
        self.observations = observations
    }

    /// Frees the page's memory but keeps its title, icon and history.
    func unload() {
        guard let webView else { return }
        if let current = webView.url { url = current }
        savedState = webView.interactionState
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }
}
