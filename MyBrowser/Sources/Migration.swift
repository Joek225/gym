import Foundation

/// The browser used to run inside Apple's App Sandbox, which keeps an app's files in a private
/// "container" folder. Now that it runs like Chrome (no sandbox), its files live in the normal
/// places. On first launch this copies everything over once: tabs, groups, bookmarks, history,
/// settings, extensions, and website data (logins/cookies). Nothing is deleted.
enum Migration {
    static func moveOutOfSandboxIfNeeded() {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: Storage.realHome)
        let bundleID = Bundle.main.bundleIdentifier ?? "local.personal.MyBrowser"
        let container = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let done = library.appendingPathComponent("Application Support/MyBrowser/.moved-from-sandbox")
        guard fm.fileExists(atPath: container.path), !fm.fileExists(atPath: done.path) else { return }

        // Folders to bring over (old place inside the container → new normal place).
        let moves = [
            ("Application Support/MyBrowser", "Application Support/MyBrowser"),
            ("WebKit", "WebKit/\(bundleID)"),
            ("HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID)"),
            ("Cookies", "Cookies"),
        ]
        for (from, to) in moves {
            let source = container.appendingPathComponent(from, isDirectory: true)
            let target = library.appendingPathComponent(to, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            copyMerging(source, into: target)
        }

        // Settings: copy every saved preference that isn't already set here.
        let oldPrefs = container.appendingPathComponent("Preferences/\(bundleID).plist")
        if let saved = NSDictionary(contentsOf: oldPrefs) as? [String: Any] {
            let defaults = UserDefaults.standard
            for (key, value) in saved where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        try? fm.createDirectory(at: done.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: done.path, contents: Data())
    }

    /// Copies a folder's contents, keeping anything already at the destination.
    private static func copyMerging(_ source: URL, into target: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                copyMerging(item, into: destination)
            } else if !fm.fileExists(atPath: destination.path) {
                try? fm.copyItem(at: item, to: destination)
            }
        }
    }
}
