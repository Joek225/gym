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

        // Extensions only start (and use memory) if you've installed any.
        if #available(macOS 15.4, *), ExtensionManager.hasInstalledExtensions {
            ExtensionManager.shared.loadInstalled()
        }

        let sessions = SessionSaver.shared.load()
        if sessions.isEmpty {
            open(BrowserWindowController(session: nil))
        } else {
            for session in sessions { open(BrowserWindowController(session: session)) }
        }

        // Optional: `MyBrowser --open https://example.com` opens a page at launch.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count,
           let url = AddressParser.url(from: args[i + 1]) {
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
