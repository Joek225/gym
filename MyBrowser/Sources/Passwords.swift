import AppKit
import WebKit
import Security
import LocalAuthentication
import UniformTypeIdentifiers

// MARK: - Storage (macOS Keychain)

/// One saved login (the password itself stays in the Keychain until needed).
struct SavedLogin: Hashable {
    let site: String
    let username: String
    let created: Date?
}

/// Saved passwords live in your Mac's Keychain, encrypted, like Safari's.
/// They're tagged "MyBrowser" so they never mix with other apps' passwords.
enum PasswordStore {
    private static let label = "MyBrowser"

    private static func baseQuery(site: String? = nil, username: String? = nil) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassInternetPassword, kSecAttrLabel: label]
        if let site { q[kSecAttrServer] = site }
        if let username { q[kSecAttrAccount] = username }
        return q
    }

    /// Every saved login (sites and usernames only, not the passwords).
    static func all() -> [SavedLogin] {
        var q = baseQuery()
        q[kSecMatchLimit] = kSecMatchLimitAll
        q[kSecReturnAttributes] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { item in
            guard let site = item[kSecAttrServer] as? String else { return nil }
            return SavedLogin(site: site, username: item[kSecAttrAccount] as? String ?? "",
                              created: item[kSecAttrCreationDate] as? Date)
        }
        .sorted { ($0.site, $0.username) < ($1.site, $1.username) }
    }

    static func logins(for site: String) -> [SavedLogin] {
        all().filter { $0.site == site }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    static func password(site: String, username: String) -> String? {
        var q = baseQuery(site: site, username: username)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(site: String, username: String, password: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(baseQuery(site: site, username: username) as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = baseQuery(site: site, username: username)
        add[kSecValueData] = data
        add[kSecAttrProtocol] = kSecAttrProtocolHTTPS
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(site: String, username: String) {
        SecItemDelete(baseQuery(site: site, username: username) as CFDictionary)
    }
}

// MARK: - Watching login forms on web pages

/// Notices when you sign in on a website and offers to save the password,
/// and fills saved passwords into login forms.
///
/// Its script runs in a private "world" on each page: the page's own code
/// can't see it or talk to it, and passwords are only ever filled into the
/// same website they were saved from.
@MainActor
final class PasswordAgent: NSObject, WKScriptMessageHandler {
    static let shared = PasswordAgent()
    static let world = WKContentWorld.world(name: "MyBrowserPasswords")
    private static let handlerName = "mybrowserPasswords"

    private static let neverKey = "neverSavePasswordsFor"
    static var offersToSave: Bool {
        get { UserDefaults.standard.object(forKey: "offerToSavePasswords") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offerToSavePasswords") }
    }

    /// Usernames typed recently, per site (for sites that ask for the password on a second page).
    private var recentUsernames: [String: String] = [:]
    private var isAsking = false

    /// Adds the script and message channel to a new web view's settings.
    func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false, in: Self.world))
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return }
        // Only trust the page's real address, never what the script claims.
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https" || origin.host == "localhost", !origin.host.isEmpty else { return }
        let site = origin.host
        // Private windows never save or fill passwords.
        guard webView.configuration.websiteDataStore.isPersistent else { return }

        switch type {
        case "username":
            if let name = body["username"] as? String, !name.isEmpty { recentUsernames[site] = name }
        case "form":
            fill(webView, frame: message.frameInfo, site: site)
        case "submit":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            var username = body["username"] as? String ?? ""
            if username.isEmpty { username = recentUsernames[site] ?? "" }
            offerToSave(site: site, username: username, password: password, webView: webView)
        default:
            break
        }
    }

    private func fill(_ webView: WKWebView, frame: WKFrameInfo, site: String) {
        guard let login = PasswordStore.logins(for: site).first,
              let password = PasswordStore.password(site: site, username: login.username) else { return }
        webView.callAsyncJavaScript("return window.__mybrowserFill(u, p);",
                                    arguments: ["u": login.username, "p": password],
                                    in: frame, in: Self.world, completionHandler: nil)
    }

    private func offerToSave(site: String, username: String, password: String, webView: WKWebView) {
        guard Self.offersToSave, !isAsking,
              !(UserDefaults.standard.stringArray(forKey: Self.neverKey) ?? []).contains(site) else { return }
        let existing = PasswordStore.logins(for: site).first { $0.username == username }
        if existing != nil, PasswordStore.password(site: site, username: username) == password { return }

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Save password for \(site)?" : "Update password for \(site)?"
        alert.informativeText = "It's stored in your Mac's Keychain. See all saved passwords in beababrowser → Passwords."
        let userField = NSTextField(string: username)
        userField.placeholderString = "Username or email"
        let passField = NSSecureTextField(string: password)
        for f in [userField, passField] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let stack = NSStackView(views: [userField, passField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: existing == nil ? "Save" : "Update")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Never for This Site")

        isAsking = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isAsking = false
            switch response {
            case .alertFirstButtonReturn:
                PasswordStore.save(site: site, username: userField.stringValue, password: passField.stringValue)
            case .alertThirdButtonReturn:
                var never = UserDefaults.standard.stringArray(forKey: Self.neverKey) ?? []
                never.append(site)
                UserDefaults.standard.set(never, forKey: Self.neverKey)
            default:
                break
            }
        }
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Runs on every page, in the private world.
    private static let script = #"""
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.mybrowserPasswords.postMessage(m); } catch (e) {} };
      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      const passwords = () => Array.from(document.querySelectorAll('input[type=password]')).filter(visible);
      const looksLikeUser = (i) => i.tagName === 'INPUT' && /^(email|text|tel)$/i.test(i.type) &&
        (/username|email/i.test(i.autocomplete || '') || i.type === 'email' || /user|email|login|account/i.test((i.name || '') + ' ' + (i.id || '')));
      const userInputs = (scope) => Array.from((scope || document).querySelectorAll('input')).filter(looksLikeUser);
      const usernameFor = (pw) => {
        const list = userInputs(pw.form || document).filter((i) => i.value);
        const before = list.filter((i) => i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
        return (before.pop() || list[0] || {}).value || '';
      };
      let lastSent = '';
      const capture = () => {
        const filled = passwords().filter((p) => p.value);
        if (!filled.length) return;
        const password = filled[filled.length - 1].value;
        const username = usernameFor(filled[0]);
        const key = username + '\u0000' + password;
        if (key === lastSent) return;
        lastSent = key;
        post({ type: 'submit', username, password });
      };
      document.addEventListener('submit', capture, true);
      document.addEventListener('click', (e) => {
        if (e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]')) capture();
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.type === 'password') capture();
      }, true);
      document.addEventListener('change', (e) => {
        if (e.target && looksLikeUser(e.target) && e.target.value) post({ type: 'username', username: e.target.value });
      }, true);

      // Tell the app when you click into a login box, so it can fill a saved password.
      // (Only reacts to clicks into boxes — it never watches the page, so busy pages like
      // Google Docs aren't slowed down.)
      const seen = new WeakSet();
      const offer = (el) => {
        if (!el || el.tagName !== 'INPUT' || seen.has(el)) return;
        if (el.type === 'password' || looksLikeUser(el)) { seen.add(el); post({ type: 'form' }); }
      };
      document.addEventListener('focusin', (e) => offer(e.target), true);
      // A login box that already has the cursor when the page opens.
      if (document.activeElement) offer(document.activeElement);

      window.__mybrowserFill = (u, p) => {
        const set = (el, v) => {
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const pw = passwords().find((x) => !x.value);
        if (pw) set(pw, p);
        const user = userInputs(pw ? (pw.form || document) : document).find((i) => visible(i) && !i.value);
        if (user && u) set(user, u);
        return true;
      };
    })();
    """#
}

// MARK: - Passkeys

/// Passkeys can't work in this browser (see README), so it tells websites
/// they aren't available. Then sites like Google go straight to your password
/// instead of showing a passkey screen that fails.
enum PasskeyFallback {
    static let script = WKUserScript(source: """
        try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}

// MARK: - The Passwords overlay

@MainActor
enum PasswordsOverlay {
    static func show(in window: NSWindow, filter: String = "") {
        Overlay.show(title: "Passwords", content: PasswordsView(filter: filter),
                     size: NSSize(width: 720, height: 560), in: window)
    }
}

final class PasswordsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var logins: [SavedLogin] = []
    private var shown: [SavedLogin] = []
    private var revealed: [SavedLogin: String] = [:]
    private var unlockedUntil = Date.distantPast

    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let offerBox = NSButton(checkboxWithTitle: "Offer to save passwords", target: nil, action: nil)

    init(filter: String) {
        super.init(frame: .zero)
        search.placeholderString = "Search passwords"
        search.stringValue = filter
        search.delegate = self

        for (id, title, width) in [("site", "Website", 240.0), ("user", "Username", 220.0), ("pass", "Password", 180.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.toolbar
        table.rowHeight = 24
        table.target = self
        table.doubleAction = #selector(revealClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let reveal = button("Show", #selector(revealClicked(_:)))
        let copy = button("Copy Password", #selector(copyClicked(_:)))
        let delete = button("Delete", #selector(deleteClicked(_:)))
        let importButton = button("Import from Chrome…", #selector(importClicked(_:)))
        offerBox.target = self
        offerBox.action = #selector(offerToggled(_:))
        offerBox.state = PasswordAgent.offersToSave ? .on : .off
        status.textColor = Theme.mutedText
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail

        let buttons = NSStackView(views: [reveal, copy, delete, NSView(), importButton])
        buttons.spacing = 8
        let bottom = NSStackView(views: [offerBox, NSView(), status])
        let stack = NSStackView(views: [search, scroll, buttons, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func reload() {
        logins = PasswordStore.all()
        applyFilter()
    }

    private func applyFilter() {
        let text = search.stringValue.lowercased()
        shown = text.isEmpty ? logins : logins.filter { $0.site.lowercased().contains(text) || $0.username.lowercased().contains(text) }
        table.reloadData()
        status.stringValue = logins.isEmpty ? "No saved passwords yet. Sign in to a website and choose Save."
            : "\(logins.count) saved password\(logins.count == 1 ? "" : "s")"
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let login = shown[row]
        switch tableColumn?.identifier.rawValue {
        case "site": return login.site
        case "user": return login.username
        default: return revealed[login] ?? "••••••••"
        }
    }

    private var selected: SavedLogin? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    /// Asks for your Mac password or Touch ID before showing or copying a password.
    private func unlock(_ then: @escaping () -> Void) {
        if Date() < unlockedUntil { then(); return }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved passwords") { ok, _ in
            DispatchQueue.main.async { [weak self] in
                guard ok, let self else { return }
                self.unlockedUntil = Date().addingTimeInterval(120)
                then()
            }
        }
    }

    @objc private func revealClicked(_ sender: Any?) {
        guard let login = selected else { status.stringValue = "Pick a password first."; return }
        if revealed[login] != nil { revealed[login] = nil; table.reloadData(); return }
        unlock { [weak self] in
            guard let self else { return }
            self.revealed[login] = PasswordStore.password(site: login.site, username: login.username) ?? "(couldn't read)"
            self.table.reloadData()
        }
    }

    @objc private func copyClicked(_ sender: Any?) {
        guard let login = selected else { status.stringValue = "Pick a password first."; return }
        unlock { [weak self] in
            guard let password = PasswordStore.password(site: login.site, username: login.username) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
            self?.status.stringValue = "Copied the password for \(login.site)."
        }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let login = selected else { status.stringValue = "Pick a password first."; return }
        PasswordStore.delete(site: login.site, username: login.username)
        revealed[login] = nil
        reload()
    }

    @objc private func offerToggled(_ sender: NSButton) {
        PasswordAgent.offersToSave = sender.state == .on
    }

    /// Chrome can export its passwords as a CSV file; this reads that file.
    @objc private func importClicked(_ sender: Any?) {
        guard let window else { return }
        let intro = NSAlert()
        intro.messageText = "Import passwords from Chrome"
        intro.informativeText = "1. In Chrome, open: chrome://password-manager/settings\n2. Click “Export passwords” and save the file.\n3. Click Continue here and pick that file.\n\nAfterwards, delete the exported file: it contains your passwords as plain text."
        intro.addButton(withTitle: "Continue")
        intro.addButton(withTitle: "Cancel")
        intro.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.beginSheetModal(for: window) { result in
                guard result == .OK, let url = panel.url else { return }
                let count = Self.importCSV(url)
                self.reload()
                self.status.stringValue = "Imported \(count) password\(count == 1 ? "" : "s") from Chrome."
            }
        }
    }

    private static func importCSV(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let urlIndex = header.firstIndex(of: "url"),
              let userIndex = header.firstIndex(of: "username"),
              let passIndex = header.firstIndex(of: "password") else { return 0 }
        var count = 0
        for row in rows.dropFirst() where row.count > max(urlIndex, userIndex, passIndex) {
            guard let host = URL(string: row[urlIndex])?.host, !row[passIndex].isEmpty else { continue }
            if PasswordStore.save(site: host, username: row[userIndex], password: row[passIndex]) { count += 1 }
        }
        return count
    }

    /// A small CSV reader that understands quotes ("a, b" and "" inside quotes).
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }
}
