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
    /// Safari's version on this Mac: read from Safari itself, or worked out from the macOS version.
    static let safariVersion: String = {
        if let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
           let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        let mac = ProcessInfo.processInfo.operatingSystemVersion
        if mac.majorVersion >= 26 { return "\(mac.majorVersion).\(mac.minorVersion)" }   // macOS 26 ships Safari 26
        return "\(mac.majorVersion + 3).\(mac.minorVersion)"                                // macOS 15 → Safari 18
    }()

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
        // WebKit's old rule "Delete key = go back a page" (Safari and Chrome turned it off long
        // ago): it threw you out of word games and forms whenever a page used Delete itself.
        if config.preferences.responds(to: NSSelectorFromString("_setBackspaceKeyNavigationEnabled:")) {
            config.preferences.setValue(false, forKey: "backspaceKeyNavigationEnabled")
        }
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Identify like Safari so sites (Google etc.) serve their full versions.
        // The Safari version that comes with this macOS (an old-looking version makes Google's
        // sign-in treat the browser as outdated and refuse some verification steps).
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        if CommandLine.arguments.contains("--log-loads") { NSLog("MyBrowser identifies as Safari %@", Self.safariVersion) }
        // Saving and filling passwords, and skipping passkey screens that can't work here.
        if !PasskeyFallback.passkeysAllowed { config.userContentController.addUserScript(PasskeyFallback.script) }
        PasswordAgent.shared.install(in: config.userContentController)
        ContentBlocker.apply(to: config.userContentController)
        // Lets installed extensions see and change pages (only when any are installed).
        // Private windows run without extensions (like Chrome), so nothing private leaks to them.
        if #available(macOS 15.4, *), (store ?? dataStore).isPersistent, let extensions = ExtensionManager.active {
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
        return webView
    }
}
