import WebKit

/// One shared, memory-lean setup for every web view in the app.
///
/// Memory notes:
/// - Since macOS 12, all web views in an app automatically share one WebKit
///   process pool (Apple deprecated making separate pools), so pages share
///   WebKit's network process and caches instead of each getting their own.
/// - Every web view uses the same website data store (cookies, cache), so
///   there's only one copy of it in memory.
/// - Videos never autoplay on their own (they start when you click play).
@MainActor
enum WebKitEnvironment {
    static let dataStore = WKWebsiteDataStore.default()

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Identify like Safari so sites (Google etc.) serve their full versions.
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        // Lets installed extensions see and change pages (only when any are installed).
        if #available(macOS 15.4, *), let extensions = ExtensionManager.active {
            config.webExtensionController = extensions.controller
        }
        return config
    }

    /// Pass `configuration` only when WebKit hands us one (pop-up windows).
    static func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        webView.allowsMagnification = true          // pinch to zoom
        // Swipe-to-go-back keeps screenshots of previous pages in memory,
        // so it's off. Use Cmd+[ / Cmd+] or the toolbar buttons instead.
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = Theme.background
        #if DEBUG
        webView.isInspectable = true                // right-click > Inspect Element
        #endif
        return webView
    }
}
