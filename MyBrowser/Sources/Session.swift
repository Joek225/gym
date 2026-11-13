import AppKit

/// Saves every window's tabs and groups to one file, a second after anything changes.
@MainActor
final class SessionSaver: NSObject {
    static let shared = SessionSaver()

    /// Supplies the tab lists of all open windows.
    var windowsProvider: () -> [TabStore] = { [] }

    private struct SessionFile: Codable {
        var windows: [SavedSession]
    }

    func scheduleSave(after delay: TimeInterval = 4) {
        // Batches many small changes into one write. A sooner save already pending stays sooner.
        let due = Date().addingTimeInterval(delay)
        if let pending = pendingSave, pending <= due { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveNow), object: nil)
        pendingSave = due
        perform(#selector(saveNow), with: nil, afterDelay: delay)
    }
    private var pendingSave: Date?

    /// How many windows the last save had (so the backup check doesn't have to re-read the file).
    private var lastSavedWindowCount: Int?
    private var lastSavedData: Data?

    @objc func saveNow() {
        pendingSave = nil
        let windows = windowsProvider().map { $0.snapshot() }.filter { !$0.items.isEmpty }
        // About to save fewer windows than last time: keep last time's session as a backup first,
        // so a closed window's tabs and groups can always be brought back.
        let previousCount = lastSavedWindowCount ?? load().count
        if windows.count < previousCount, FileManager.default.fileExists(atPath: Storage.session.path) {
            try? FileManager.default.removeItem(at: Storage.sessionBackup)
            try? FileManager.default.copyItem(at: Storage.session, to: Storage.sessionBackup)
        }
        lastSavedWindowCount = windows.count
        // Nothing changed (e.g. only a tab's title flickered): don't touch the disk.
        if let data = try? JSONEncoder().encode(SessionFile(windows: windows)), data != lastSavedData {
            try? data.write(to: Storage.session, options: .atomic)
            lastSavedData = data
        }
    }

    /// Last time's windows (also reads the older one-window format).
    func load(from file: URL = Storage.session) -> [SavedSession] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        if let file = try? JSONDecoder().decode(SessionFile.self, from: data) { return file.windows }
        if let single = try? JSONDecoder().decode(SavedSession.self, from: data) { return [single] }
        return []
    }
}

/// Groups you've closed (not deleted). Like Chrome's saved groups, they stay
/// as chips on the bookmarks bar so you can reopen them later.
@MainActor
final class GroupLibrary {
    static let shared = GroupLibrary()
    static let didChange = Notification.Name("MyBrowserGroupLibraryDidChange")

    private(set) var closed: [SavedGroup] = []

    private init() {
        if let data = try? Data(contentsOf: Storage.closedGroups),
           let groups = try? JSONDecoder().decode([SavedGroup].self, from: data) {
            closed = groups
        }
    }

    func add(_ group: SavedGroup) {
        guard !group.tabs.isEmpty else { return }
        closed.removeAll { $0.id == group.id }
        closed.append(group)
        save()
    }

    func remove(id: UUID) {
        closed.removeAll { $0.id == id }
        save()
    }

    func group(id: UUID) -> SavedGroup? { closed.first { $0.id == id } }

    private func save() {
        if let data = try? JSONEncoder().encode(closed) {
            try? data.write(to: Storage.closedGroups, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
