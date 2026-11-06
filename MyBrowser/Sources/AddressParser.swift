import Foundation

/// Turns whatever you type in the address bar into a web address.
/// "apple.com" -> https://apple.com, "cute cats" -> a Google search.
enum AddressParser {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already a full address (https://…, file://…, about:blank).
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }

        // Looks like a website name (no spaces, has a dot) or a local server.
        if !text.contains(" ") {
            let host = String(text.split(separator: "/").first ?? Substring(text)).lowercased()
            if host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") {
                return URL(string: "http://" + text)
            }
            if host.contains("."), !host.hasSuffix("."), let url = URL(string: "https://" + text) {
                return url
            }
        }

        // Otherwise, search for it.
        return Preferences.searchEngine.url(for: text)
    }
}
