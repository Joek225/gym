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

    /// `store` is a private window's own throwaway storage (nil = normal browsing).
    static func makeConfiguration(store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.isElementFullscreenEnabled = true
        // Security: warn before opening known scam/phishing and malware sites (Safe Browsing),
        // use secure (https) versions of sites that are known to have one, and don't let
        // pages open new windows on their own.
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Identify like Safari so sites (Google etc.) serve their full versions.
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        // Saving and filling passwords, and skipping passkey screens that can't work here.
        config.userContentController.addUserScript(PasskeyFallback.script)
        PasswordAgent.shared.install(in: config.userContentController)
        ContentBlocker.apply(to: config.userContentController)
        // Lets installed extensions see and change pages (only when any are installed).
        if #available(macOS 15.4, *), let extensions = ExtensionManager.active {
            config.webExtensionController = extensions.controller
        }
        return config
    }

    /// Pass `configuration` only when WebKit hands us one (pop-up windows).
    static func makeWebView(configuration: WKWebViewConfiguration? = nil, store: WKWebsiteDataStore? = nil) -> WKWebView {
        let webView = BrowserWebView(frame: .zero, configuration: configuration ?? makeConfiguration(store: store))
        webView.allowsMagnification = true          // pinch to zoom
        // Swipe-to-go-back keeps screenshots of previous pages in memory,
        // so it's off. Use Cmd+[ / Cmd+] or the toolbar buttons instead.
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = Theme.background
        webView.isInspectable = true                // right-click → Inspect Element (Chrome's DevTools)
        return webView
    }
}
