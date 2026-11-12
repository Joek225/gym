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
    /// The last saved session that had more windows than now (History → Restore Previous Session).
    static let sessionBackup = folder.appendingPathComponent("session-backup.json")
    static let bookmarks = folder.appendingPathComponent("bookmarks.json")
    static let closedGroups = folder.appendingPathComponent("closed-groups.json")

    /// The real home folder (inside the sandbox, the normal one points to a private copy).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
}
