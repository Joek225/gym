import AppKit
import WebKit

/// Runs web extensions (Chrome-style, Manifest V3) with Apple's WebKit extension
/// support (macOS 15.4+). Chrome's extension folders are copied into the
/// browser and loaded directly, so there is no conversion step.
@available(macOS 15.4, *)
@MainActor
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    static let didChange = Notification.Name("MyBrowserExtensionsDidChange")
    private static var instance: ExtensionManager?

    /// Created on first use. Until then extensions cost no memory at all.
    static var shared: ExtensionManager {
        if let instance { return instance }
        let made = ExtensionManager()
        instance = made
        return made
    }

    /// The manager, only if it's already running.
    static var active: ExtensionManager? { instance }

    static var folder: URL { Storage.folder.appendingPathComponent("Extensions", isDirectory: true) }

    static var hasInstalledExtensions: Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.contains { $0.hasDirectoryPath }
    }

    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []
    private var folders: [String: URL] = [:]

    private override init() {
        controller = WKWebExtensionController(configuration: .default())
        super.init()
        controller.delegate = self
    }

    // MARK: Installing

    /// Loads every installed extension (before windows open, so they work on the first page).
    func loadInstalled() async {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where dir.hasDirectoryPath {
            if let failure = await load(folder: dir) {
                NSLog("MyBrowser: extension in %@ failed to load: %@", dir.lastPathComponent, failure)
            }
        }
    }

    /// Loads one extension folder. Returns an error message, or nil if it worked.
    func load(folder: URL) async -> String? {
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = folder.lastPathComponent
            context.isInspectable = true
            // It's your own browser, so give extensions what they ask for up front.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts.append(context)
            folders[context.uniqueIdentifier] = folder
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Copies an extension folder into the browser and loads it.
    func install(from source: URL) async -> String? {
        let dest = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return error.localizedDescription
        }
        // Chrome's private signature folder isn't part of the extension.
        try? FileManager.default.removeItem(at: dest.appendingPathComponent("_metadata"))
        if let failure = await load(folder: dest) {
            try? FileManager.default.removeItem(at: dest)
            return failure
        }
        return nil
    }

    func remove(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        contexts.removeAll { $0 === context }
        if let folder = folders.removeValue(forKey: context.uniqueIdentifier) {
            try? FileManager.default.removeItem(at: folder)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    static func name(of context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? context.webExtension.displayShortName ?? "Extension"
    }

    /// Problems WebKit noticed (for example Chrome-only features it doesn't support).
    static func warnings(of context: WKWebExtensionContext) -> [String] {
        context.webExtension.errors.map(\.localizedDescription)
    }

    // MARK: Finding Chrome's extensions

    struct ChromeExtension {
        let name: String
        let version: String
        let profile: String
        let folder: URL
    }

    /// Finds extensions in Chrome's folder, in every Chrome profile
    /// (Chrome keeps them as <profile>/Extensions/<id>/<version>/manifest.json).
    /// Also works if you pick a profile's Extensions folder or one extension's folder.
    static func scanChrome(_ root: URL) -> [ChromeExtension] {
        let fm = FileManager.default
        func subfolders(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter(\.hasDirectoryPath)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        // Chrome's names for its profiles ("Default" → "Person 1", "Profile 1" → "School", …)
        var profileNames: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache {
                if let name = (info as? [String: Any])?["name"] as? String { profileNames[dir] = name }
            }
        }

        var found: [String: ChromeExtension] = [:]
        func consider(_ dir: URL, key: String, profile: String) {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let name = localized(json["name"] as? String ?? dir.lastPathComponent, in: dir,
                                 defaultLocale: json["default_locale"] as? String)
            found[key] = ChromeExtension(name: name, version: json["version"] as? String ?? "",
                                         profile: profile, folder: dir)
        }
        func scanExtensionsFolder(_ folder: URL, profile: String) {
            for idFolder in subfolders(folder) {
                consider(idFolder, key: idFolder.path, profile: profile)
                for version in subfolders(idFolder) {   // the newest version wins
                    consider(version, key: idFolder.path, profile: profile)
                }
            }
        }

        consider(root, key: root.path, profile: "")
        scanExtensionsFolder(root, profile: "")
        for profileFolder in subfolders(root) {
            let extensions = profileFolder.appendingPathComponent("Extensions", isDirectory: true)
            if fm.fileExists(atPath: extensions.path) {
                let dir = profileFolder.lastPathComponent
                scanExtensionsFolder(extensions, profile: profileNames[dir] ?? dir)
            }
        }
        // The same extension in two profiles is only listed once.
        var unique: [String: ChromeExtension] = [:]
        for ext in found.values where unique[ext.name + ext.version] == nil { unique[ext.name + ext.version] = ext }
        return unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Turns "__MSG_appName__" into the real name from the extension's translations.
    private static func localized(_ raw: String, in dir: URL, defaultLocale: String?) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        for locale in [defaultLocale, "en", "en_US", "en_GB"].compactMap({ $0 }) {
            let file = dir.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (k, v) in messages where k.lowercased() == key {
                if let message = (v as? [String: Any])?["message"] as? String { return message }
            }
        }
        return raw
    }

    // MARK: What extensions ask the browser

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        AppDelegate.shared.controllers
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        AppDelegate.shared.frontController
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let window = (configuration.window as? BrowserWindowController) ?? AppDelegate.shared.frontController else {
            completionHandler(nil, nil)
            return
        }
        let tab = window.openTabForExtension(configuration.url, active: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let popover = action.popupPopover, let window = AppDelegate.shared.frontController {
            window.showExtensionPopover(popover, for: context)
        }
        completionHandler(nil)
    }
}

// MARK: - Letting extensions see our windows and tabs

@available(macOS 15.4, *)
extension BrowserWindowController: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { store.allTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { store.selected }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.performClose(nil)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    private var owner: BrowserWindowController? { AppDelegate.shared.controller(containing: self) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner?.store.allTabs.firstIndex(of: self) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { self.webView }
    func title(for context: WKWebExtensionContext) -> String? { displayTitle }
    func url(for context: WKWebExtensionContext) -> URL? { self.webView?.url ?? self.url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { pinned }
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.store.selected === self }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(self.webView?.isLoading ?? false) }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.select(self)
        owner?.window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.close(self)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.load(url, in: self)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { self.webView?.reloadFromOrigin() } else { self.webView?.reload() }
        completionHandler(nil)
    }
}

/// Small helpers so the rest of the app can tell extensions about tab changes
/// (only when extensions are running).
@MainActor
enum ExtensionEvents {
    static func tabOpened(_ tab: Tab) {
        if #available(macOS 15.4, *) { ExtensionManager.active?.controller.didOpenTab(tab) }
    }

    static func tabClosed(_ tab: Tab) {
        if #available(macOS 15.4, *) { ExtensionManager.active?.controller.didCloseTab(tab, windowIsClosing: false) }
    }

    static func tabActivated(_ tab: Tab, previous: Tab?) {
        if #available(macOS 15.4, *) {
            ExtensionManager.active?.controller.didActivateTab(tab, previousActiveTab: previous)
        }
    }

    static func windowFocused(_ window: BrowserWindowController) {
        if #available(macOS 15.4, *) { ExtensionManager.active?.controller.didFocusWindow(window) }
    }
}
