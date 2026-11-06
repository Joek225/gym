import AppKit
import WebKit

/// Chrome-style find box (⌘F): a small bar at the top right of the page.
final class FindBar: SolidView, NSSearchFieldDelegate {
    var webView: () -> WKWebView? = { nil }
    var onClose: (() -> Void)?
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")

    init() {
        super.init(color: Theme.toolbar)
        cornerRadius = 10
        borderColor = Theme.hoverTab
        field.placeholderString = "Find in page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.mutedText
        let previous = iconButton("chevron.up", "Previous (⇧⌘G)", #selector(previousClicked(_:)))
        let next = iconButton("chevron.down", "Next (⌘G)", #selector(nextClicked(_:)))
        let close = iconButton("xmark", "Close (Esc)", #selector(closeClicked(_:)))
        let row = NSStackView(views: [field, status, previous, next, close])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: Icons.symbol(symbol, size: 12, weight: .semibold) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = Theme.icon
        b.toolTip = tip
        return b
    }

    func open() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func find(backwards: Bool = false) {
        guard let webView = webView(), !field.stringValue.isEmpty else { status.stringValue = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(field.stringValue, configuration: config) { [weak self] result in
            self?.status.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    func controlTextDidChange(_ obj: Notification) { find() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSEvent.modifierFlags.contains(.shift)); return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeClicked(nil); return true
        default:
            return false
        }
    }

    @objc private func previousClicked(_ sender: Any?) { find(backwards: true) }
    @objc private func nextClicked(_ sender: Any?) { find() }
    @objc private func closeClicked(_ sender: Any?) {
        isHidden = true
        status.stringValue = ""
        onClose?()
    }
}

/// The optional memory readout (Settings → Show memory use).
enum MemoryUse {
    /// How much memory this app itself is using, in megabytes (the same number Activity Monitor shows).
    static func appMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    /// Memory used by one web page's separate WebKit process, if macOS lets us see it.
    static func pageMegabytes(_ webView: WKWebView) -> Int? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 else { return nil }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Int(usage.ri_phys_footprint / 1_048_576) : nil
    }
}
