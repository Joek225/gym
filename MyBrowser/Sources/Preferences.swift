import Foundation

/// Your settings (from the Settings panel), saved between launches.
enum Preferences {
    private static let d = UserDefaults.standard

    /// Searches go to Google.
    static func searchURL(for query: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }

    static func isSearchPage(_ url: URL) -> Bool { url.host == "www.google.com" && url.path == "/search" }

    /// Fixed times: tabs you haven't used for 5 minutes are unloaded (their memory freed),
    /// and groups you haven't used for 30 minutes are turned off.
    static let unloadMinutes = 5
    static let disableGroupsMinutes = 30

    static var showsMemory: Bool {
        get { d.object(forKey: "showMemory2") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMemory2") }
    }

    static var blocksAds: Bool {
        get { d.object(forKey: "blockAds") as? Bool ?? true }
        set { d.set(newValue, forKey: "blockAds") }
    }

}
