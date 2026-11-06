import AppKit

/// Finds things in Chrome's own folder (read-only — Chrome is never changed).
enum ChromeData {
    struct Profile {
        let folder: URL
        let name: String
    }

    /// The real home folder (inside the sandbox, the normal one points to a private copy).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static let defaultFolder = URL(fileURLWithPath: realHome)
        .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)

    /// Chrome's folder (or the one you picked, if macOS wouldn't let us read it directly).
    @MainActor static var folder = defaultFolder

    /// Why Chrome's folder couldn't be read (empty if it could).
    @MainActor static func problem() -> String {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return profiles().isEmpty ? "No Chrome profiles were found in that folder." : ""
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    /// Chrome's profiles, with the names you gave them ("Person 1", "School", …).
    @MainActor static func profiles() -> [Profile] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Local State")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache { names[dir] = (info as? [String: Any])?["name"] as? String }
        }
        let dirs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath && fm.fileExists(atPath: $0.appendingPathComponent("Preferences").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return dirs.map { Profile(folder: $0, name: names[$0.lastPathComponent] ?? $0.lastPathComponent) }
    }

    /// Chrome's most recent session file (it lists the windows, tabs and tab groups that were open).
    static func latestSession(in profile: Profile) -> URL? {
        let dir = profile.folder.appendingPathComponent("Sessions", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Session_") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }
}

/// Reads the tab groups out of Chrome's session file.
/// (Chrome's format isn't documented; this reads the parts it needs and skips the rest.)
enum ChromeSessionReader {
    private struct Reader {
        let bytes: [UInt8]
        var pos: Int

        mutating func int32() -> Int32? {
            guard pos + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
            pos += 4
            return Int32(bitPattern: v)
        }

        mutating func uint64() -> UInt64? {
            guard let lo = int32(), let hi = int32() else { return nil }
            return UInt64(UInt32(bitPattern: lo)) | UInt64(UInt32(bitPattern: hi)) << 32
        }

        mutating func string() -> String? {
            guard let n = int32(), n >= 0, pos + Int(n) <= bytes.count else { return nil }
            let s = String(decoding: bytes[pos..<pos + Int(n)], as: UTF8.self)
            pos += (Int(n) + 3) & ~3
            return s
        }

        mutating func string16() -> String? {
            guard let n = int32(), n >= 0, pos + Int(n) * 2 <= bytes.count else { return nil }
            var units: [UInt16] = []
            for i in 0..<Int(n) { units.append(UInt16(bytes[pos + i * 2]) | UInt16(bytes[pos + i * 2 + 1]) << 8) }
            pos += (Int(n) * 2 + 3) & ~3
            return String(decoding: units, as: UTF16.self)
        }
    }

    static func groups(in file: URL) -> [SavedGroup] {
        guard let data = try? Data(contentsOf: file), data.count > 8 else { return [] }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x53, bytes[1] == 0x4E, bytes[2] == 0x53, bytes[3] == 0x53 else { return [] }   // "SNSS"

        var navigations: [Int32: [Int32: (url: String, title: String)]] = [:]
        var selectedNavigation: [Int32: Int32] = [:]
        var tabIndex: [Int32: Int32] = [:]
        var tabWindow: [Int32: Int32] = [:]
        var tabGroup: [Int32: String] = [:]
        var groupInfo: [String: (title: String, color: UInt32)] = [:]
        var groupOrder: [String] = []
        var closed = Set<Int32>()

        var pos = 8
        while pos + 3 <= bytes.count {
            let size = Int(bytes[pos]) | Int(bytes[pos + 1]) << 8
            pos += 2
            guard size >= 1, pos + size <= bytes.count else { break }
            let command = bytes[pos]
            let payload = Array(bytes[(pos + 1)..<(pos + size)])
            pos += size
            var r = Reader(bytes: payload, pos: 0)
            switch command {
            case 0:  // tab → window
                if let window = r.int32(), let tab = r.int32() { tabWindow[tab] = window }
            case 2:  // tab position in its window
                if let tab = r.int32(), let index = r.int32() { tabIndex[tab] = index }
            case 6:  // a page in a tab's history
                r.pos = 4   // skip the size header
                if let tab = r.int32(), let index = r.int32(), let url = r.string(), let title = r.string16() {
                    navigations[tab, default: [:]][index] = (url, title)
                }
            case 7:  // which history entry is current
                if let tab = r.int32(), let index = r.int32() { selectedNavigation[tab] = index }
            case 16:  // tab closed
                if let tab = r.int32() { closed.insert(tab) }
            case 25:  // tab put in (or taken out of) a group
                if let tab = r.int32() {
                    r.pos = 8
                    if let high = r.uint64(), let low = r.uint64(), payload.count > 24 {
                        if payload[24] != 0 {
                            let key = "\(high)-\(low)"
                            tabGroup[tab] = key
                            if !groupOrder.contains(key) { groupOrder.append(key) }
                        } else {
                            tabGroup[tab] = nil
                        }
                    }
                }
            case 27:  // a group's name and color
                r.pos = 4
                if let high = r.uint64(), let low = r.uint64(), let title = r.string16(), let color = r.int32() {
                    groupInfo["\(high)-\(low)"] = (title, UInt32(bitPattern: color))
                }
            default:
                break
            }
        }

        return groupOrder.compactMap { key in
            let tabs = tabGroup.filter { $0.value == key && !closed.contains($0.key) }.map(\.key)
                .sorted { (tabWindow[$0] ?? 0, tabIndex[$0] ?? 0) < (tabWindow[$1] ?? 0, tabIndex[$1] ?? 0) }
            let saved: [SavedTab] = tabs.compactMap { tab in
                guard let entries = navigations[tab], !entries.isEmpty else { return nil }
                let current = selectedNavigation[tab].flatMap { entries[$0] } ?? entries[entries.keys.max()!]!
                guard let url = URL(string: current.url), url.scheme?.hasPrefix("http") == true else { return nil }
                return SavedTab(id: UUID(), url: url, title: current.title, icon: nil, pinned: nil)
            }
            guard !saved.isEmpty else { return nil }
            let info = groupInfo[key]
            let color = info.map { Int($0.color) }.flatMap { $0 < GroupColor.allCases.count ? GroupColor.allCases[$0] : nil } ?? .grey
            return SavedGroup(id: UUID(), name: info?.title ?? "", color: color, collapsed: true, tabs: saved)
        }
    }
}

/// The "Import from Chrome" panel: bookmarks, tab groups and extensions in one go.
@MainActor
enum ChromeImportOverlay {
    static func show(in window: NSWindow) {
        Overlay.show(title: "Import from Chrome", content: ChromeImportView(),
                     size: NSSize(width: 560, height: 600), in: window)
    }
}

final class ChromeImportView: NSView {
    private let profiles = ChromeData.profiles()
    private let profilePopup = NSPopUpButton()
    private let bookmarksBox = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
    private let groupsBox = NSButton(checkboxWithTitle: "Tab groups", target: nil, action: nil)
    private let extensionList = NSStackView()
    private var extensionBoxes: [(box: NSButton, ext: ExtensionManagerInfo)] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)

    /// What we know about one Chrome extension (kept simple so it works on any macOS).
    struct ExtensionManagerInfo {
        let name: String
        let folder: URL
    }

    init() {
        super.init(frame: .zero)
        let intro = NSTextField(wrappingLabelWithString: "Brings your Chrome bookmarks, tab groups and extensions into MyBrowser. Chrome itself isn't changed.")
        intro.textColor = Theme.mutedText

        status.textColor = Theme.mutedText
        status.font = .systemFont(ofSize: 12)
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.target = self
        importButton.action = #selector(importClicked(_:))

        guard !profiles.isEmpty else {
            // macOS didn't let us read Chrome's folder by ourselves: ask you to point at it once.
            let missing = NSTextField(wrappingLabelWithString: "To read your Chrome data, macOS needs you to point to Chrome's folder once. Click the button below; a window opens already showing Chrome's folder. Just click “Use This Folder”.\n\n(Details: \(ChromeData.problem()))")
            missing.textColor = Theme.text
            let choose = NSButton(title: "Choose Chrome's Folder…", target: self, action: #selector(chooseFolder(_:)))
            choose.bezelStyle = .rounded
            choose.keyEquivalent = "\r"
            let stack = NSStackView(views: [intro, missing, choose])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            place(stack)
            NSLayoutConstraint.activate([
                missing.widthAnchor.constraint(equalTo: stack.widthAnchor),
                intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            return
        }

        for profile in profiles { profilePopup.addItem(withTitle: profile.name) }
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        let profileRow = NSStackView(views: [NSTextField(labelWithString: "Chrome profile:"), profilePopup])
        profileRow.spacing = 8

        extensionList.orientation = .vertical
        extensionList.alignment = .leading
        extensionList.spacing = 4
        let extensionScroll = NSScrollView()
        extensionScroll.hasVerticalScroller = true
        extensionScroll.drawsBackground = false
        extensionScroll.borderType = .noBorder
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        extensionList.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(extensionList)
        extensionScroll.documentView = flipped
        NSLayoutConstraint.activate([
            extensionList.topAnchor.constraint(equalTo: flipped.topAnchor),
            extensionList.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            extensionList.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            extensionList.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: extensionScroll.contentView.widthAnchor),
        ])

        let extensionsTitle = NSTextField(labelWithString: "Extensions")
        extensionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let passwordsButton = NSButton(title: "Import passwords…", target: self, action: #selector(passwordsClicked(_:)))
        passwordsButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [importButton, passwordsButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [intro, profileRow, bookmarksBox, groupsBox, extensionsTitle, extensionScroll, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: groupsBox)
        place(stack)
        NSLayoutConstraint.activate([
            extensionScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            extensionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        extensionScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        profileChanged(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func place(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private var profile: ChromeData.Profile { profiles[max(0, profilePopup.indexOfSelectedItem)] }

    /// Counts what this profile has, so you can see it before importing.
    @objc private func profileChanged(_ sender: Any?) {
        let bookmarks = ChromeBookmarks.read(profile.folder.appendingPathComponent("Bookmarks"))
        let bookmarkCount = bookmarks.map { ($0.bar + $0.other + $0.mobile).reduce(0) { $0 + $1.bookmarkCount } } ?? 0
        bookmarksBox.title = "Bookmarks (\(bookmarkCount))"
        bookmarksBox.state = bookmarkCount > 0 ? .on : .off
        bookmarksBox.isEnabled = bookmarkCount > 0

        let groups = ChromeData.latestSession(in: profile).map(ChromeSessionReader.groups(in:)) ?? []
        groupsBox.title = "Tab groups (\(groups.count)) — from Chrome's open windows; they appear as chips on your bookmarks bar"
        groupsBox.state = groups.isEmpty ? .off : .on
        groupsBox.isEnabled = !groups.isEmpty

        extensionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        extensionBoxes = []
        let extensionsFolder = profile.folder.appendingPathComponent("Extensions", isDirectory: true)
        var found: [ExtensionManagerInfo] = []
        if #available(macOS 15.4, *) {
            found = ExtensionManager.scanChrome(extensionsFolder).map { ExtensionManagerInfo(name: $0.name, folder: $0.folder) }
        }
        for ext in found {
            let box = NSButton(checkboxWithTitle: ext.name, target: nil, action: nil)
            box.state = .on
            extensionList.addArrangedSubview(box)
            extensionBoxes.append((box, ext))
        }
        if found.isEmpty {
            let note: String
            if #available(macOS 15.4, *) { note = "No extensions in this profile." } else { note = "Extensions need macOS 15.4 or newer." }
            let label = NSTextField(labelWithString: note)
            label.textColor = Theme.mutedText
            extensionList.addArrangedSubview(label)
        }
        status.stringValue = "Each extension uses some memory while the browser is open (often 10–40 MB), so untick ones you don't need."
    }

    @objc private func importClicked(_ sender: Any?) {
        var lines: [String] = []
        if bookmarksBox.state == .on, let b = ChromeBookmarks.read(profile.folder.appendingPathComponent("Bookmarks")) {
            BookmarkStore.shared.importChrome(bar: b.bar, other: b.other, mobile: b.mobile)
            lines.append("✓ Bookmarks imported")
            bookmarksBox.state = .off
        }
        if groupsBox.state == .on, let session = ChromeData.latestSession(in: profile) {
            let groups = ChromeSessionReader.groups(in: session)
            groups.forEach { GroupLibrary.shared.add($0) }
            lines.append("✓ \(groups.count) tab group\(groups.count == 1 ? "" : "s") added to the bookmarks bar (click one to open it)")
            groupsBox.state = .off
        }
        let picked = extensionBoxes.filter { $0.box.state == .on }
        if picked.isEmpty {
            status.stringValue = lines.isEmpty ? "Nothing ticked." : lines.joined(separator: "\n")
            return
        }
        guard #available(macOS 15.4, *) else { return }
        importButton.isEnabled = false
        status.stringValue = (lines + ["Installing extensions…"]).joined(separator: "\n")
        Task { @MainActor in
            for entry in picked {
                if let failure = await ExtensionManager.shared.install(from: entry.ext.folder) {
                    lines.append("✗ \(entry.ext.name): \(failure)")
                } else {
                    lines.append("✓ \(entry.ext.name)")
                }
                entry.box.state = .off
            }
            lines.append("\nQuit (⌘Q) and reopen the browser so the extensions work on every tab.")
            status.stringValue = lines.joined(separator: "\n")
            importButton.isEnabled = true
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Folder"
        panel.message = "This is Chrome's folder (Library → Application Support → Google → Chrome). Just click “Use This Folder”."
        panel.directoryURL = ChromeData.defaultFolder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, var url = panel.url else { return }
            // If you picked a folder inside Chrome's (like "Default"), use Chrome's folder itself.
            if url.lastPathComponent != "Chrome", url.deletingLastPathComponent().lastPathComponent == "Chrome" {
                url = url.deletingLastPathComponent()
            }
            ChromeData.folder = url
            ChromeImportOverlay.show(in: window)   // reopen with your Chrome data
        }
    }

    @objc private func passwordsClicked(_ sender: Any?) {
        guard let window else { return }
        PasswordsOverlay.show(in: window)
    }
}

/// A view whose coordinates start at the top (so scrolling lists start at the top).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
