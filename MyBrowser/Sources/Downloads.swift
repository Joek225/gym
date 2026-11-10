import AppKit
import WebKit

/// Saves downloaded files into your Downloads folder and keeps a list of them.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    static let didChange = Notification.Name("MyBrowserDownloadsDidChange")

    final class Item: NSObject {
        enum State { case running, finished, failed, cancelled }
        let download: WKDownload
        var name: String = "Download"
        var destination: URL?
        var state: State = .running
        var error: String?
        var source: URL?
        init(_ download: WKDownload) { self.download = download }
        @MainActor var fraction: Double { download.progress.fractionCompleted }
    }

    private(set) var items: [Item] = []

    static var folder: URL {
        URL(fileURLWithPath: Storage.realHome).appendingPathComponent("Downloads", isDirectory: true)
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        items.insert(Item(download), at: 0)
        changed()
    }

    private func item(_ download: WKDownload) -> Item? { items.first { $0.download === download } }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: nil) }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename rawName: String, completionHandler: @escaping (URL?) -> Void) {
        // The site picks the name: keep only a plain file name (no folders like "../",
        // no hidden ".name" files), so a download can only ever land in Downloads.
        var suggestedFilename = (rawName as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        while suggestedFilename.hasPrefix(".") { suggestedFilename.removeFirst() }
        if suggestedFilename.isEmpty { suggestedFilename = "download" }
        // Files sent over an insecure connection could have been swapped on the way.
        if response.url?.scheme == "http" {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(suggestedFilename)” is coming over an insecure connection"
            alert.informativeText = "Someone on your network could replace it with something harmful. Only keep going if you really need it."
            alert.addButton(withTitle: "Don't Download")
            alert.addButton(withTitle: "Download Anyway")
            if alert.runModal() != .alertSecondButtonReturn {
                items.removeAll { $0.download === download }
                changed()
                completionHandler(nil)
                return
            }
        }
        item(download)?.source = response.url
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "none"
        DragReport.add("— download: \(suggestedFilename) from \(response.url?.host ?? "?"), type \(response.mimeType ?? "?"), disposition \(disposition.prefix(40))")
        // Files that can run programs: ask first (a common way malware gets onto Macs).
        if Security.riskyExtensions.contains((suggestedFilename as NSString).pathExtension.lowercased()) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Download “\(suggestedFilename)”?"
            alert.informativeText = "This kind of file can install or run programs on your Mac. Only download it if you trust \(response.url?.host ?? "this site")."
            alert.addButton(withTitle: "Don't Download")
            alert.addButton(withTitle: "Download")
            if alert.runModal() != .alertSecondButtonReturn {
                items.removeAll { $0.download === download }
                changed()
                completionHandler(nil)
                return
            }
        }
        // If macOS is blocking the Downloads folder (permission turned off or reset), ask
        // where to save instead of failing with "cannot create file".
        if !Self.canWriteToDownloads() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.message = "beababrowser isn't allowed to save in your Downloads folder right now. Choose where to save it. (To fix: System Settings → Privacy & Security → Files & Folders → beababrowser → Downloads Folder.)"
            if panel.runModal() == .OK, let chosen = panel.url {
                item(download)?.name = chosen.lastPathComponent
                item(download)?.destination = chosen
                changed()
                completionHandler(chosen)
            } else {
                items.removeAll { $0.download === download }
                changed()
                completionHandler(nil)
            }
            return
        }
        // "photo.jpg", then "photo (1).jpg", "photo (2).jpg"… so nothing is overwritten.
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = Self.folder.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        item(download)?.name = url.lastPathComponent
        item(download)?.destination = url
        changed()
        completionHandler(url)
    }

    /// Tries to create (and remove) a small file in Downloads.
    static func canWriteToDownloads() -> Bool {
        let probe = folder.appendingPathComponent(".beababrowser-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    func downloadDidFinish(_ download: WKDownload) {
        item(download)?.state = .finished
        if let entry = item(download), let file = entry.destination { Self.quarantine(file, from: entry.source) }
        changed()
        // Show the Downloads panel so you can open the file straight away.
        if let window = download.webView?.window ?? NSApp.keyWindow, !Overlay.isShowing {
            DownloadsOverlay.show(in: window)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let entry = item(download)
        if entry?.state != .cancelled {
            entry?.state = .failed
            entry?.error = error.localizedDescription
        }
        changed()
    }

    /// Marks a downloaded file as "from the internet", so macOS checks it (Gatekeeper and
    /// XProtect malware scan) and asks before opening it — the same as Safari and Chrome.
    static func quarantine(_ file: URL, from source: URL?) {
        var values: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "beababrowser",
        ]
        if let source { values[kLSQuarantineDataURLKey as String] = source }
        var url = file
        var resource = URLResourceValues()
        resource.quarantineProperties = values
        try? url.setResourceValues(resource)
    }

    func cancel(_ item: Item) {
        item.state = .cancelled
        item.download.cancel { _ in }
        changed()
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        changed()
    }
}

/// The Downloads panel (⇧⌘J).
@MainActor
enum DownloadsOverlay {
    static func show(in window: NSWindow) {
        Overlay.show(title: "Downloads", content: DownloadsView(), size: NSSize(width: 620, height: 520), in: window)
    }
}

final class DownloadsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("name", "File", 330.0), ("state", "Status", 220.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.toolbar
        table.rowHeight = 26
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let buttons = NSStackView(views: [
            button("Open", #selector(openClicked(_:))), button("Show in Finder", #selector(showClicked(_:))),
            button("Cancel", #selector(cancelClicked(_:))), NSView(),
            button("Open Downloads Folder", #selector(folderClicked(_:))), button("Clear List", #selector(clearClicked(_:))),
        ])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        table.reloadData()
        // Refresh progress twice a second while the panel is open.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private var items: [DownloadManager.Item] { DownloadManager.shared.items }
    private var selected: DownloadManager.Item? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let item = items[row]
        if tableColumn?.identifier.rawValue == "name" { return item.name }
        switch item.state {
        case .running: return "Downloading… \(Int(item.fraction * 100))%"
        case .finished: return "Done"
        case .failed: return "Failed: \(item.error ?? "")"
        case .cancelled: return "Cancelled"
        }
    }

    @objc private func openClicked(_ sender: Any?) {
        if let url = selected?.destination, selected?.state == .finished { NSWorkspace.shared.open(url) }
    }

    @objc private func showClicked(_ sender: Any?) {
        if let url = selected?.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        if let item = selected, item.state == .running { DownloadManager.shared.cancel(item) }
    }

    @objc private func folderClicked(_ sender: Any?) { NSWorkspace.shared.open(DownloadManager.folder) }

    @objc private func clearClicked(_ sender: Any?) {
        DownloadManager.shared.clearFinished()
        table.reloadData()
    }
}
