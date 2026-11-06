import Foundation

/// Your settings (from the Settings panel), saved between launches.
enum Preferences {
    private static let d = UserDefaults.standard

    enum SearchEngine: String, CaseIterable {
        case google = "Google", duckDuckGo = "DuckDuckGo", bing = "Bing"

        func url(for query: String) -> URL? {
            var c: URLComponents
            switch self {
            case .google: c = URLComponents(string: "https://www.google.com/search")!
            case .duckDuckGo: c = URLComponents(string: "https://duckduckgo.com/")!
            case .bing: c = URLComponents(string: "https://www.bing.com/search")!
            }
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            return c.url
        }

        func isResultsPage(_ url: URL) -> Bool {
            switch self {
            case .google: return url.host == "www.google.com" && url.path == "/search"
            case .duckDuckGo: return url.host == "duckduckgo.com" && url.query?.hasPrefix("q=") == true
            case .bing: return url.host == "www.bing.com" && url.path == "/search"
            }
        }
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .google }
        set { d.set(newValue.rawValue, forKey: "searchEngine") }
    }

    /// Minutes before an unused tab is unloaded (0 = never).
    static var unloadMinutes: Int {
        get { d.object(forKey: "unloadMinutes") as? Int ?? 5 }
        set { d.set(newValue, forKey: "unloadMinutes") }
    }

    static var blocksAds: Bool {
        get { d.object(forKey: "blockAds") as? Bool ?? true }
        set { d.set(newValue, forKey: "blockAds") }
    }

    static var showsMemory: Bool {
        get { d.bool(forKey: "showMemory") }
        set { d.set(newValue, forKey: "showMemory") }
    }
}
