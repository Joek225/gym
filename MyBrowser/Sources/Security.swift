import AppKit

/// Security rules shared by all windows.
@MainActor
enum Security {
    /// File types that can run programs on your Mac — the browser asks before downloading them.
    static let riskyExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app", "command", "sh", "zsh", "bash", "tool",
                                                "terminal", "jar", "scpt", "applescript", "workflow", "exe", "msi",
                                                "bat", "dylib", "kext", "plugin", "osax", "action"]
}
