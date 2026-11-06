import AppKit

/// The app's starting point. Builds the menu bar and opens browser windows.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var controllers: [BrowserWindowController] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        SessionSaver.shared.windowsProvider = { [weak self] in self?.controllers.map(\.store) ?? [] }

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

        // Optional: `MyBrowser --open https://example.com` opens a page at launch.
        if let address = Self.argument(after: "--open"), let url = AddressParser.url(from: address) {
            frontController?.openFromLaunch(url)
        }
        NSApp.activate()
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

    @objc func newWindow(_ sender: Any?) {
        open(BrowserWindowController(session: nil))
    }
}
