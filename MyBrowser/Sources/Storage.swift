import Foundation

/// Where the browser keeps its saved files (inside the app's private sandbox folder).
enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let session = folder.appendingPathComponent("session.json")
    static let bookmarks = folder.appendingPathComponent("bookmarks.json")
}
