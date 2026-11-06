import AppKit

/// The app's starting point. Builds the menu bar and opens browser windows.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var controllers: [BrowserWindowController] = []
    private var windowsOpen = false
    private var pendingURLs: [URL] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // Notice any activity (used to wake windows that blacked out on an idle new tab).
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated {
                (event.window?.windowController as? BrowserWindowController)?.userActed()
                if event.type != .mouseMoved { AppDelegate.shared.controllers.forEach { $0.userActed() } }
            }
            return event
        }
        // Private windows are never saved.
        SessionSaver.shared.windowsProvider = { [weak self] in self?.controllers.filter { !$0.isPrivate }.map(\.store) ?? [] }
        ContentBlocker.prepare()

        // Used by the automatic test: can we read Chrome's folder by ourselves?
        if CommandLine.arguments.contains("--test-chrome-access") {
            let profiles = ChromeData.profiles()
            let bookmarks = profiles.first.flatMap { ChromeBookmarks.read($0.folder.appendingPathComponent("Bookmarks")) }
            NSLog("MyBrowser chrome access: %ld profiles (%@), %ld bookmarks, problem: %@",
                  profiles.count, profiles.map(\.name).joined(separator: ","),
                  bookmarks.map { $0.bar.count + $0.other.count } ?? -1, ChromeData.problem())
            NSApp.terminate(nil)
            return
        }

        Task { @MainActor in
            // Extensions only start (and use memory) if you've installed any.
            if #available(macOS 15.4, *) {
                if let folder = Self.argument(after: "--install-extension") {   // used by the automatic test
                    let failure = await ExtensionManager.shared.install(from: URL(fileURLWithPath: folder))
                    NSLog("MyBrowser extension install: %@", failure ?? "OK")
                    if CommandLine.arguments.contains("--quit-after-install") { NSApp.terminate(nil); return }
                }
                if ExtensionManager.hasInstalledExtensions {
                    await ExtensionManager.shared.loadInstalled()
                    for context in ExtensionManager.shared.contexts {
                        NSLog("MyBrowser extension loaded: %@ (%ld warnings)", ExtensionManager.name(of: context),
                              ExtensionManager.warnings(of: context).count)
                    }
                }
            }
            self.openWindows()
        }
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func openWindows() {
        let sessions = SessionSaver.shared.load()
        if sessions.isEmpty {
            open(BrowserWindowController(session: nil))
        } else {
            for session in sessions { open(BrowserWindowController(session: session)) }
        }

        windowsOpen = true
        pendingURLs.forEach { frontController?.openFromLaunch($0) }
        pendingURLs = []

        // Optional: `MyBrowser --open https://example.com` opens a page at launch.
        if let address = Self.argument(after: "--open"), let url = AddressParser.url(from: address) {
            frontController?.openFromLaunch(url)
        }
        NSApp.activate()

        // Used by the automatic test: make the window very wide and check it stays that size.
        if CommandLine.arguments.contains("--test-resize"), let window = frontController?.window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                window.setFrame(NSRect(x: 0, y: 0, width: 1900, height: 1000), display: true)
                window.layoutIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSLog("MyBrowser window width after resize: %d", Int(window.frame.width))
                    Self.saveSnapshot(of: window)
                }
            }
        }
    }

    /// Used by the automatic test: saves a picture of the window's top part so the layout can be checked.
    private static func saveSnapshot(of window: NSWindow) {
        guard let view = window.contentView else { return }
        let rect = NSRect(x: 0, y: view.bounds.height - 140, width: view.bounds.width, height: 140)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar.png")
        try? png.write(to: url)
        NSLog("MyBrowser snapshot: %@", url.path)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SessionSaver.shared.saveNow()
    }

    // MARK: Windows

    @discardableResult
    func open(_ controller: BrowserWindowController) -> BrowserWindowController {
        if let previous = frontController?.window, let window = controller.window {
            window.setFrame(previous.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        controllers.append(controller)
        controller.showWindow(nil)
        if #available(macOS 15.4, *) { ExtensionManager.active?.controller.didOpenWindow(controller) }
        return controller
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        if #available(macOS 15.4, *) { ExtensionManager.active?.controller.didCloseWindow(controller) }
        // Keep the very last window in the saved session so its tabs come back next time.
        guard controllers.count > 1 else { SessionSaver.shared.saveNow(); return }
        controllers.removeAll { $0 === controller }
        SessionSaver.shared.saveNow()
    }

    /// The window you're using (or the first one).
    var frontController: BrowserWindowController? {
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? BrowserWindowController { return main }
        return controllers.first
    }

    func controller(containing tab: Tab) -> BrowserWindowController? {
        controllers.first { $0.store.allTabs.contains(tab) }
    }

    @objc func makeDefaultBrowser(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
        }
    }

    func findTab(_ id: UUID) -> (Tab, BrowserWindowController)? {
        for c in controllers { if let t = c.store.allTabs.first(where: { $0.id == id }) { return (t, c) } }
        return nil
    }

    func findGroup(_ id: UUID) -> (TabGroup, BrowserWindowController)? {
        for c in controllers { if let g = c.store.groups.first(where: { $0.id == id }) { return (g, c) } }
        return nil
    }

    @objc func newWindow(_ sender: Any?) {
        open(BrowserWindowController(session: nil))
    }

    /// Like Chrome's Incognito: nothing from this window is saved (history, cookies,
    /// passwords, tabs). Everything is forgotten when you close it.
    @objc func newPrivateWindow(_ sender: Any?) {
        open(BrowserWindowController(session: nil, isPrivate: true))
    }

    /// Links opened from other apps (when MyBrowser is your default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard windowsOpen else { pendingURLs += urls; return }   // still starting up
        let target = frontController ?? controllers.first
        for url in urls {
            if let target { target.openFromLaunch(url) } else {
                let c = open(BrowserWindowController(session: nil))
                c.openFromLaunch(url)
            }
        }
    }
}
