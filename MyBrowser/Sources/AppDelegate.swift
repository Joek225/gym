import AppKit

/// The app's starting point. Builds the menu bar and opens the browser window.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let controller = BrowserWindowController()
        windowController = controller
        controller.showWindow(nil)

        // Optional: `MyBrowser --open https://example.com` opens a page at launch.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count,
           let url = AddressParser.url(from: args[i + 1]) {
            controller.load(url)
        } else {
            controller.focusAddressBar(nil)
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
