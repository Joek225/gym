# MyBrowser

A lightweight personal Mac web browser built on WebKit (the engine Safari uses).
The top priority is low memory use.

## How to run it

1. Double-click **MyBrowser.xcodeproj**. Xcode opens.
2. Press **⌘R** (or click the ▶ Play button at the top left).
3. The browser window appears. Type an address or a search and press Return.

To stop it, press **⌘Q** in the browser, or click ■ Stop in Xcode.

## Keyboard shortcuts

| Keys | What it does |
|---|---|
| ⌘T | New tab |
| ⌘W | Close tab |
| ⇧⌘T | Reopen the last closed tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab (also ⇧⌘] / ⇧⌘[ and ⌥⌘→ / ⌥⌘←) |
| ⌘1 … ⌘8, ⌘9 | Go to tab 1–8, or the last tab |
| ⇧⌘G | Put the current tab in a new group |
| ⌘D | Bookmark this page (or edit the bookmark) |
| ⇧⌘B | Show / hide the bookmarks bar |
| ⌘L | Jump to the address bar |
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / Forward |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / reset |
| ⌘-click a link | Open it in a background tab (⇧⌘-click to switch to it) |
| Middle-click a tab | Close it |

## Tabs and groups

- Tabs are in the sidebar on the left. Drag the sidebar's right edge to resize it.
- Drag tabs up and down to reorder them. Drag a tab onto a group's colored header to add it to the group.
- Right-click a tab: **Add Tab to New Group**, **Add Tab to Group**, **Remove from Group**, or **Unload Tab**.
- Right-click a group's header to rename it, change its color, ungroup it or close it. Click the header to collapse or expand it.
- Groups also appear as colored chips on the left of the bookmarks bar. Click one to jump to any of its tabs.
- Tabs and groups are kept when you quit and reopen the browser.
- Tabs you haven't looked at for 5 minutes are **unloaded** to free memory. Their title shows slightly dimmer. Clicking one reloads it, and its back/forward history is kept. Tabs playing audio or video, or using the camera or microphone, are never unloaded.

## Bookmarks

- Click the ☆ in the address bar (or press ⌘D) to bookmark a page. A box lets you rename it, pick a folder, or remove it.
- Click a folder on the bookmarks bar to see what's inside. Right-click a bookmark to edit or delete it, or to add a folder.
- **Bookmarks menu → Import Bookmarks from Chrome…** opens Chrome's settings folder. Pick the file called **Bookmarks**.

## Build stages

1. ✅ Window, address bar, back/forward/reload
2. ✅ Vertical tabs in a sidebar, with tab unloading
3. ◐ Colors: now using the dark navy colors from your Chrome theme (the Settings panel and color picker come next)
4. ✅ Tab groups
5. ◐ Bookmarks and Chrome import ✅. History and downloads come next.
6. Content blocking and memory readout
7. Extensions

## Memory choices so far

- Built with AppKit (Apple's original Mac UI toolkit) instead of SwiftUI. It has less overhead.
- All pages share one WebKit setup: one cookie store, one cache, one network process.
- Videos don't autoplay. They start when you click play.
- Swipe-to-go-back is off, because it keeps screenshots of old pages in memory.
- Idle tabs are unloaded after 5 minutes. Restored tabs and ⌘-clicked links stay unloaded until you open them.
- Site icons are shrunk to 32×32 pixels and shared between tabs.
- The toolbar is painted as flat colors, with no images, blur, or animations.

## Files

- `Sources/`: all the Swift code. Any new file put here is picked up automatically.
- `MyBrowser.entitlements`: what the app may access (internet, files you pick, Downloads).
