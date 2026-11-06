# MyBrowser

A lightweight personal Mac web browser built on WebKit (the engine Safari uses).
The top priority is low memory use.

## How to run it

1. Double-click **MyBrowser.xcodeproj**. Xcode opens.
2. Press **⌘R** (or click the ▶ Play button at the top left).
3. The browser window appears. Type an address or a search and press Return.

To stop it, press **⌘Q** in the browser, or click ■ Stop in Xcode.

## Keyboard shortcuts (stage 1)

| Keys | What it does |
|---|---|
| ⌘L | Jump to the address bar |
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / Forward |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / reset |
| Esc (in address bar) | Undo what you typed |
| ⌃⌘F | Full screen |

## Build stages

1. ✅ Window, address bar, back/forward/reload
2. Vertical tabs in a sidebar, with tab unloading
3. Custom colors and themes
4. Tab groups
5. Bookmarks (with Chrome import), history, downloads, shortcuts
6. Content blocking and memory readout
7. Extensions

## Memory choices so far

- Built with AppKit (Apple's original Mac UI toolkit) instead of SwiftUI. It has less overhead.
- All pages share one WebKit setup: one cookie store, one cache, one network process.
- Videos don't autoplay. They start when you click play.
- Swipe-to-go-back is off, because it keeps screenshots of old pages in memory.
- The toolbar is painted as flat colors, with no images, blur, or animations.

## Files

- `Sources/`: all the Swift code. Any new file put here is picked up automatically.
- `MyBrowser.entitlements`: what the app may access (internet, files you pick, Downloads).
