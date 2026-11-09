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
            #if DEBUG
            context.isInspectable = true
            #endif
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            // Which websites it may read and change: all of them, or only when you click it.
            Self.applySiteAccess(context)
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
        // New extensions start safe: they only touch a site when you click them.
        Self.setSiteAccess(.onClick, for: dest.lastPathComponent)
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

    // MARK: Site access (like Chrome's "This can read and change site data")

    enum SiteAccess: String { case allSites, onClick }
    private static let accessKey = "extensionSiteAccess"

    /// Extensions installed before this setting existed keep working on all sites.
    static func siteAccess(for id: String) -> SiteAccess {
        let saved = UserDefaults.standard.dictionary(forKey: accessKey) as? [String: String] ?? [:]
        return saved[id].flatMap(SiteAccess.init(rawValue:)) ?? .allSites
    }

    static func setSiteAccess(_ access: SiteAccess, for id: String) {
        var saved = UserDefaults.standard.dictionary(forKey: accessKey) as? [String: String] ?? [:]
        saved[id] = access.rawValue
        UserDefaults.standard.set(saved, forKey: accessKey)
    }

    static func applySiteAccess(_ context: WKWebExtensionContext) {
        let all = siteAccess(for: context.uniqueIdentifier) == .allSites
        for pattern in context.webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(all ? .grantedExplicitly : .deniedExplicitly, for: pattern)
        }
    }

    /// "On click" mode: clicking the extension lets it work on the current site for an hour.
    static func allowOnClick(_ context: WKWebExtensionContext, url: URL?) {
        guard siteAccess(for: context.uniqueIdentifier) == .onClick,
              let url, url.scheme == "https" || url.scheme == "http" else { return }
        context.setPermissionStatus(.grantedExplicitly, for: url, expirationDate: Date().addingTimeInterval(3600))
    }

    static func name(of context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? context.webExtension.displayShortName ?? "Extension"
    }

    /// Problems WebKit noticed (for example Chrome-only features it doesn't support).
    static func warnings(of context: WKWebExtensionContext) -> [String] {
        context.webExtension.errors.map(\.localizedDescription)
    }

    // MARK: Extension folders

    struct ChromeExtension {
        let name: String
        let version: String
        let profile: String
        let folder: URL
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
