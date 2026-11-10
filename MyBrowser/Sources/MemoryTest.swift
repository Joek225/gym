import AppKit
import WebKit

/// Used by the automatic test (--test-memory): how much memory the browser app itself uses
/// with several loaded tabs, and what detaching or unloading the hidden ones saves.
@MainActor
enum MemoryTest {
    static func run(in controller: BrowserWindowController) {
        let pages = ["https://en.wikipedia.org/wiki/Web_browser",
                     "https://en.wikipedia.org/wiki/WebKit",
                     "https://en.wikipedia.org/wiki/MacOS"].compactMap(URL.init(string:))
        func log(_ step: String) {
            NSLog("MyBrowser memory test: %@ — app %d MB", step, MemoryUse.appMegabytes())
        }
        log("start")
        func open(_ i: Int) {
            guard i < pages.count else { return measureHidden() }
            controller.openInNewTab(pages[i], background: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                log("\(i + 1) tab(s) opened (\(controller.loadedPageCount) loaded)")
                open(i + 1)
            }
        }
        func measureHidden() {
            controller.testDetachHiddenPages()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                log("hidden pages detached from the window")
                controller.testUnloadHiddenPages()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    log("hidden pages unloaded (\(controller.loadedPageCount) loaded)")
                }
            }
        }
        open(0)
    }
}
