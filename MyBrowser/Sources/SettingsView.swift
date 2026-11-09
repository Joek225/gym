import AppKit
import WebKit

/// Settings (⌘,): colors and themes, search engine, memory options, default browser.
@MainActor
enum SettingsOverlay {
    static func show(in window: NSWindow) {
        Overlay.show(title: "Settings", content: SettingsView(), size: NSSize(width: 620, height: 700), in: window)
    }
}

final class SettingsView: NSView {
    private let restartNote = NSTextField(labelWithString: "")
    private let adsBox = NSButton(checkboxWithTitle: "Block ads and trackers (makes pages lighter)", target: nil, action: nil)
    private let memoryBox = NSButton(checkboxWithTitle: "Show memory use in the toolbar", target: nil, action: nil)

    init() {
        super.init(frame: .zero)

        // Accent: the four colors from your calendar.
        let swatches = NSStackView(views: ThemeColors.Accent.allCases.map { accent in
            let b = NSButton(title: accent.name, image: Self.swatch(accent.color, chosen: accent == ThemeColors.accentChoice),
                             target: self, action: #selector(accentChosen(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(accent.rawValue)
            b.isBordered = false
            b.imagePosition = .imageAbove
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = Theme.text
            return b
        })
        swatches.spacing = 18
        restartNote.textColor = Theme.accent
        restartNote.font = .systemFont(ofSize: 12)

        // Browsing

        // Memory
        adsBox.state = Preferences.blocksAds ? .on : .off
        adsBox.target = self
        adsBox.action = #selector(adsChanged(_:))
        memoryBox.state = Preferences.showsMemory ? .on : .off
        memoryBox.target = self
        memoryBox.action = #selector(memoryChanged(_:))


        let clearButton = button("Clear Browsing Data…", #selector(clearDataClicked(_:)))

        let defaultButton = button("Make beababrowser Your Default Browser", #selector(defaultClicked(_:)))

        let stack = NSStackView(views: [
            heading("Tint color"), swatches,
            heading("Memory"), memoryNote(), adsBox, memoryBox,
            heading("Privacy & security"), securityNote(), clearButton, restartNote,
            heading("Default browser"), defaultButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for h in stack.arrangedSubviews where (h as? NSTextField)?.font?.pointSize == 15 {
            stack.setCustomSpacing(6, after: h)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = Theme.text
        return l
    }

    private func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textColor = Theme.text
        return l
    }

    private func row(_ text: String, _ control: NSView) -> NSStackView {
        let r = NSStackView(views: [label(text), control])
        r.spacing = 8
        return r
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private static func swatch(_ color: NSColor, chosen: Bool) -> NSImage {
        NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            if chosen {
                Theme.text.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
            return true
        }
    }

    @objc private func accentChosen(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let accent = ThemeColors.Accent(rawValue: raw),
              accent != ThemeColors.accentChoice else { return }
        ThemeColors.accentChoice = accent
        AppDelegate.shared.rebuildWindows(thenShowSettings: true)   // applies straight away
    }

    private func memoryNote() -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: "Tabs you haven't used for 5 minutes are unloaded to free memory (they reload when you click them), and tab groups you haven't used for 30 minutes are turned off. Searches use Google.")
        note.textColor = Theme.mutedText
        note.font = .systemFont(ofSize: 12)
        note.preferredMaxLayoutWidth = 560
        return note
    }

    private func securityNote() -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: "Always on: warnings for scam and malware sites, secure connections for sites that support them, ad and tracker blocking, cross-site tracking protection, passwords kept in your Keychain and only filled after you click into the box, a check before downloading files that can run programs, downloads marked so macOS checks them before they open, extensions that only work where you allow them, and a question before a site opens another app.")
        note.textColor = Theme.mutedText
        note.font = .systemFont(ofSize: 12)
        note.preferredMaxLayoutWidth = 560
        return note
    }

    @objc private func clearDataClicked(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear browsing data"
        alert.informativeText = "Choose what to delete from all time."
        let history = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
        let cookies = NSButton(checkboxWithTitle: "Cookies and site data (signs you out of sites)", target: nil, action: nil)
        let cache = NSButton(checkboxWithTitle: "Cached images and files", target: nil, action: nil)
        [history, cache].forEach { $0.state = .on }
        let stack = NSStackView(views: [history, cookies, cache])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if history.state == .on { HistoryStore.shared.clear() }
            var types = Set<String>()
            if cookies.state == .on { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes()) }
            if cache.state == .on { types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]) }
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
                self?.restartNote.stringValue = "Cleared."
            }
        }
    }

    @objc private func adsChanged(_ sender: NSButton) {
        Preferences.blocksAds = sender.state == .on
        restartNote.stringValue = "Ad blocking changes apply to pages you open from now on."
        if Preferences.blocksAds { ContentBlocker.prepare() }
    }

    @objc private func memoryChanged(_ sender: NSButton) {
        Preferences.showsMemory = sender.state == .on
        NotificationCenter.default.post(name: MemoryReadout.didToggle, object: nil)
    }

    @objc private func defaultClicked(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
        }
    }
}

