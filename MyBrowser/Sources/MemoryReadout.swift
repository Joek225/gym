import AppKit
import WebKit

/// Keeps the toolbar's memory label up to date (only while it's switched on).
@MainActor
final class MemoryReadout {
    static let didToggle = Notification.Name("MyBrowserMemoryReadoutToggled")
    private var timer: Timer?
    private var refreshPending = false
    private let label: NSTextField
    private let pages: () -> [WKWebView]

    init(label: NSTextField, pages: @escaping () -> [WKWebView]) {
        self.label = label
        self.pages = pages
    }

    func update() {
        timer?.invalidate()
        timer = nil
        label.isHidden = !Preferences.showsMemory
        guard Preferences.showsMemory else { return }
        refresh()
        // Every 30 seconds (and when you switch tabs) is plenty, and costs almost nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 10
    }

    /// Updates the number a couple of seconds after a tab change (once the page has loaded).
    func refreshSoon() {
        guard Preferences.showsMemory, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        let app = MemoryUse.appMegabytes()
        let views = pages()
        let pageSizes = views.compactMap(MemoryUse.pageMegabytes)
        if pageSizes.count == views.count, !views.isEmpty {
            label.stringValue = "\(app + pageSizes.reduce(0, +)) MB"
            label.toolTip = "Browser: \(app) MB + \(views.count) open page\(views.count == 1 ? "" : "s"): \(pageSizes.reduce(0, +)) MB (unloaded tabs use none)"
        } else {
            label.stringValue = "\(app) MB · \(views.count) loaded"
            label.toolTip = "Memory used by the browser app itself, and how many tabs are loaded (unloaded tabs use none). macOS doesn't let the app measure each page's own WebKit process."
        }
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
