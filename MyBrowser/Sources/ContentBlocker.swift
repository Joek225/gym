import WebKit

/// Blocks well-known ad and tracking servers using WebKit's built-in content
/// blocking (the same engine Safari's ad blockers use). It runs inside WebKit,
/// so it adds almost no memory and makes pages lighter.
@MainActor
enum ContentBlocker {
    private(set) static var ruleList: WKContentRuleList?
    private static var waiting: [WKUserContentController] = []
    private static let identifier = "MyBrowserBlocker-v1"

    /// Ad and tracker servers (blocked only when loaded by another website).
    private static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "adnxs.com", "adsrvr.org",
        "amazon-adsystem.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "scorecardresearch.com",
        "quantserve.com", "hotjar.com", "mixpanel.com", "connect.facebook.net", "ads-twitter.com",
        "analytics.twitter.com", "bat.bing.com", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "moatads.com", "yieldmo.com", "smartadserver.com", "adform.net", "teads.tv",
        "media.net", "bidswitch.net", "3lift.com", "sharethrough.com", "rlcdn.com", "demdex.net",
        "everesttech.net", "krxd.net", "bluekai.com", "mathtag.com", "chartbeat.com", "nr-data.net",
        "clarity.ms", "doubleverify.com", "adsafeprotected.com", "serving-sys.com", "contextweb.com",
        "indexww.com", "gumgum.com", "ads.yahoo.com", "advertising.com", "zedo.com", "adcolony.com",
        "unityads.unity3d.com", "applovin.com", "inmobi.com", "mookie1.com", "turn.com", "tapad.com",
    ]

    private static var rulesJSON: String {
        let rules = domains.map { domain -> String in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^https?://([^/]*\\.)?"# + escaped
                + #"[/:]","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// Prepares the block list (WebKit keeps the compiled list, so this is quick after the first time).
    static func prepare() {
        guard Preferences.blocksAds, let store = WKContentRuleListStore.default() else { return }
        let json = rulesJSON
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            MainActor.assumeIsolated {
                if let list { ready(list); return }
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                    MainActor.assumeIsolated {
                        if let list { ready(list) } else if let error { NSLog("MyBrowser: blocker failed: %@", error.localizedDescription) }
                    }
                }
            }
        }
    }

    private static func ready(_ list: WKContentRuleList) {
        ruleList = list
        waiting.forEach { $0.add(list) }
        waiting = []
    }

    /// Called for each new web view's settings.
    static func apply(to controller: WKUserContentController) {
        guard Preferences.blocksAds else { return }
        if let ruleList { controller.add(ruleList) } else { waiting.append(controller) }
    }
}
