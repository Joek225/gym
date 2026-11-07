import AppKit

/// Security rules shared by all windows.
@MainActor
enum Security {
    /// Sites you chose to open without encryption this session (after the secure version failed).
    private static var insecureAllowed = Set<String>()
    /// Sites we just tried to upgrade to https (so a failure can offer the insecure version).
    private static var upgraded = Set<String>()

    /// HTTPS-first: returns the secure version of an insecure address, or nil if it should load as is.
    static func secureVersion(of url: URL) -> URL? {
        // Each site is upgraded once per session (so a site that insists on http can't loop).
        guard url.scheme == "http", let host = url.host, !isLocal(host), !insecureAllowed.contains(host),
              !upgraded.contains(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        upgraded.insert(host)
        return parts.url
    }

    /// After the secure version failed: the insecure address you could continue to (if any).
    static func insecureFallback(for failed: URL?) -> URL? {
        guard let failed, failed.scheme == "https", let host = failed.host, upgraded.contains(host),
              var parts = URLComponents(url: failed, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "http"
        return parts.url
    }

    static func allowInsecure(_ host: String) { insecureAllowed.insert(host) }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("192.168.")
            || host.hasPrefix("10.") || host.hasPrefix("172.16.") || host.range(of: "^[0-9.]+$", options: .regularExpression) != nil
    }

    /// File types that can run programs on your Mac — the browser asks before downloading them.
    static let riskyExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app", "command", "sh", "zsh", "bash", "tool",
                                                "terminal", "jar", "scpt", "applescript", "workflow", "exe", "msi",
                                                "bat", "dylib", "kext", "plugin", "osax", "action"]
}
