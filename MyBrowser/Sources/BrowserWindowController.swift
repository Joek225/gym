import AppKit
import WebKit

/// The browser window: toolbar on top, web page below.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                     NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate {
    private let toolbar = ToolbarView()
    private let webView = WebKitEnvironment.makeWebView()
    private let errorView = ErrorView()
    private var observations: [NSKeyValueObservation] = []
    /// The address of a page that failed to load, so Reload can try it again.
    private var failedURL: URL?
    private let logLoads = CommandLine.arguments.contains("--log-loads")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = Theme.toolbar
        window.tabbingMode = .disallowed        // our tabs will live in the sidebar
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.setFrameAutosaveName("MainWindow") // remembers size and position
        super.init(window: window)
        window.delegate = self

        buildLayout(in: window)
        wireUp()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        let content = SolidView(color: Theme.background)
        window.contentView = content

        for v in [toolbar, webView, errorView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        errorView.isHidden = true

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: ToolbarView.height),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            errorView.topAnchor.constraint(equalTo: webView.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
    }

    private func wireUp() {
        toolbar.backButton.target = self
        toolbar.backButton.action = #selector(goBack(_:))
        toolbar.forwardButton.target = self
        toolbar.forwardButton.action = #selector(goForward(_:))
        toolbar.reloadButton.target = self
        toolbar.reloadButton.action = #selector(reloadOrStop(_:))
        toolbar.addressField.target = self
        toolbar.addressField.action = #selector(addressEntered(_:))
        toolbar.addressField.delegate = self

        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Watch the page for changes and keep the toolbar in sync.
        observations = [
            webView.observe(\.canGoBack, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.canGoForward, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.isLoading, options: [.initial]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.showCurrentAddress() }
            },
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    let title = webView.title ?? ""
                    self?.window?.title = title.isEmpty ? "MyBrowser" : title
                }
            },
        ]
    }

    private func updateButtons() {
        toolbar.backButton.isEnabled = webView.canGoBack
        toolbar.forwardButton.isEnabled = webView.canGoForward
        toolbar.setLoading(webView.isLoading)
    }

    private var isEditingAddress: Bool {
        guard let editor = toolbar.addressField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// Shows the page's address in the address bar (unless you're typing in it).
    private func showCurrentAddress() {
        guard !isEditingAddress else { return }
        if let url = webView.url, url.absoluteString != "about:blank" {
            toolbar.addressField.stringValue = url.absoluteString
        } else if let failedURL {
            toolbar.addressField.stringValue = failedURL.absoluteString
        }
    }

    // MARK: Actions (buttons, menu items, keyboard shortcuts)

    func load(_ url: URL) {
        failedURL = nil
        errorView.isHidden = true
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        toolbar.addressField.stringValue = url.absoluteString
    }

    @objc func addressEntered(_ sender: NSTextField) {
        guard let url = AddressParser.url(from: sender.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(webView)
    }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(toolbar.addressField)
        toolbar.addressField.currentEditor()?.selectAll(nil)
    }

    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }

    @objc func reloadPage(_ sender: Any?) {
        if let failedURL { load(failedURL) } else { webView.reload() }
    }

    @objc func reloadOrStop(_ sender: Any?) {
        if webView.isLoading { webView.stopLoading() } else { reloadPage(sender) }
    }

    @objc func zoomInPage(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOutPage(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.3) }
    @objc func actualSize(_ sender: Any?) { webView.pageZoom = 1 }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return webView.canGoBack
        case #selector(goForward(_:)): return webView.canGoForward
        default: return true
        }
    }

    // Esc in the address bar puts back the current page's address.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === toolbar.addressField, selector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        toolbar.addressField.stringValue = webView.url?.absoluteString ?? failedURL?.absoluteString ?? ""
        window?.makeFirstResponder(webView)
        return true
    }

    // MARK: Window

    // In full screen the red/yellow/green buttons are hidden, so use that space.
    func windowWillEnterFullScreen(_ notification: Notification) { toolbar.leadingInset = 12 }
    func windowWillExitFullScreen(_ notification: Notification) { toolbar.leadingInset = 78 }

    // MARK: Page loading

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failedURL = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if logLoads {
            NSLog("MyBrowser loaded: %@ — %@", webView.url?.absoluteString ?? "", webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    private func showError(_ error: Error) {
        let e = error as NSError
        // Ignore "cancelled" (you clicked stop or a new link) and
        // "interrupted" (a file download — handled in stage 5).
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        failedURL = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? failedURL
        showCurrentAddress()
        if logLoads { NSLog("MyBrowser failed: %@", e.localizedDescription) }
        errorView.show(message: e.localizedDescription, address: failedURL?.host ?? "")
    }

    // MARK: Page requests (new windows, alerts, file pickers)

    /// Links that want a new window open in this one for now (new tabs come in stage 2).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(prompt, frame)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func makeAlert(_ message: String, _ frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host.map { "\($0) says:" } ?? "This page says:"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
