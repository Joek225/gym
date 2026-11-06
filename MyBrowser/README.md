# beababrowser

A lightweight personal Mac web browser built on WebKit (the engine Safari uses).
The top priority is low memory use.

## Install it as a normal app (no Xcode needed afterwards)

1. Open **MyBrowser.xcodeproj** in Xcode.
2. Menu bar: **Product → Archive**. Wait for the Organizer window.
3. Right-click the newest archive → **Show in Finder**.
4. Right-click the `.xcarchive` file → **Show Package Contents** → open **Products → Applications**.
5. Drag **beababrowser** into your **Applications** folder. Open it from Launchpad, Spotlight or the Dock like any app.

Repeat these steps whenever you get a new version. Your tabs, bookmarks and passwords stay.

## How to run it from Xcode (while testing)

1. Double-click **MyBrowser.xcodeproj**. Xcode opens.
2. Press **⌘R** (or click the ▶ Play button at the top left).
3. The browser window appears with a search box in the middle. Type a search or address and press Return.

To stop it, press **⌘Q** in the browser, or click ■ Stop in Xcode.

## More Chrome features

| Keys | What it does |
|---|---|
| ⌘, | Settings: colors & themes, search engine, unload timer, ad blocking, memory readout, default browser |
| ⌘Y | History (search, open, delete, clear) |
| ⇧⌘J | Downloads (saved to your Downloads folder) |
| ⌘F / ⌘G / ⇧⌘G | Find in page / next / previous |
| ⌘P | Print |
| ⇧⌘N | New private window (nothing is saved) |
| Right-click a page → Inspect Element | Developer tools |

Drag any tab anywhere: reorder tiles, drop on the tiles to pin, drag a tile into the list to unpin, drag tabs or groups into another window, or drag a tab out of the window to open it in a new one.

## Keyboard shortcuts

| Keys | What it does |
|---|---|
| ⌘T | New tab |
| ⌘W | Close tab |
| ⇧⌘T | Reopen the last closed tab |
| ⌃Tab / ⌃⇧Tab | Next / previous tab (also ⇧⌘] / ⇧⌘[ and ⌥⌘→ / ⌥⌘←) |
| ⌘1 … ⌘8, ⌘9 | Go to tab 1–8, or the last tab |
| ⌥1 … ⌥8, ⌥9 | Go to tab 1–8 (or the last tab) **inside the current group** |
| ⇧⌘G | Put the current tab in a new group |
| ⌃⌘C | New tab in the current group |
| ⌃⌘W | Close the current group (it stays on the bookmarks bar to reopen) |
| ⌘N | New window |
| ⌘D | Bookmark this page (or edit the bookmark) |
| ⇧⌘B | Show / hide the bookmarks bar |
| ⌘L | Search box (on a new tab) — or opens a new tab to search from |
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / Forward |
| ⌘= / ⌘- / ⌘0 | Zoom in / out / reset |
| ⌘-click a link | Open it in a background tab (⇧⌘-click to switch to it) |
| Middle-click a tab | Close it |

## New tab page

- Every new tab (⌘T) shows a **search box in the middle**. That's the only place you type.
- As you type, a small box shows **Google suggestions** and matching bookmarks. Use ↑/↓ and Return, or click one.
- The bar at the top only **shows** the page's address (you can still select and copy it).
- To go somewhere else, open a new tab and search there. Links and Back/Forward work as usual.
- Bookmarks open in a new tab (or in the current tab if it's a blank new tab).

## Import from Chrome

Open a new tab (⌘T) and click **“Import bookmarks, tab groups & extensions from Chrome”** at the bottom (also in the File, Bookmarks and Extensions menus). Pick your Chrome profile, untick anything you don't want, and click **Import**.
- **Bookmarks**: added to your bookmarks bar.
- **Tab groups**: groups that are open in Chrome's windows become chips on your bookmarks bar. Click one to open it. (Groups you've closed in Chrome are stored in Google's sync data and can't be read.)
- **Extensions**: copied in; quit and reopen the browser afterwards.
- **Passwords**: Chrome keeps them locked, so use **Import passwords…** and follow the steps (export from Chrome, then pick the file).

The browser is allowed to *read* Chrome's folder, never change it.

## Tabs and groups

- Tabs are in the sidebar on the left. Drag the sidebar's right edge to resize it.
- Drag tabs up and down to reorder them. Drag a tab onto a group's colored header to add it to the group.
- Right-click a tab: **Add Tab to New Group**, **Add Tab to Group**, **Remove from Group**, or **Unload Tab**.
- Right-click a group's header to open the group editor (like Chrome): name, color, new tab in group, move group to a new window, close, ungroup or delete. Click the header to collapse or expand it.
- **Close group** keeps it as an outlined chip on the bookmarks bar so you can reopen it. **Delete group** forgets it.
- Right-click a tab and choose **Pin Tab**. Pinned tabs become square tiles at the top of their group (or of the sidebar). Click a tile to open it, middle-click to close it, right-click for options.
- At the top of the sidebar: **⫷** hides the sidebar (⌃⌘S; a button in the toolbar brings it back), **▦** lists all tab groups (open and closed), **🔍** searches your tabs in every window (⇧⌘A).
- Groups also appear as colored chips on the left of the bookmarks bar. Click one to jump to any of its tabs.
- Tabs and groups are kept when you quit and reopen the browser.
- Tabs you haven't looked at for 5 minutes are **unloaded** to free memory. Their title shows slightly dimmer. Clicking one reloads it, and its back/forward history is kept. Tabs playing audio or video, or using the camera or microphone, are never unloaded.

## Tools

The **Tools** button under **+** opens a panel over the lightly blurred browser (Esc or click outside to close):
- **File Converter**: turn any image (PNG, JPEG, HEIC, WebP, TIFF, GIF, BMP, RAW…) into PNG, JPEG, HEIC, TIFF, GIF, BMP or PDF, optionally smaller.
- **Background Remover**: cuts out the person, pet or object using Apple's on-device AI. Nothing is uploaded. Saves a transparent PNG.

It uses no memory until you open it and frees it when you close it.

## Passwords

- When you sign in on a website, the browser offers to **save** the password (Save / Not Now / Never for This Site).
- Saved passwords are **filled in automatically** next time, but only on the same website.
- **MyBrowser → Passwords…** (⌥⌘P) lists them. **Show** and **Copy** ask for your Mac password or Touch ID first.
- Passwords are stored in your Mac's **Keychain** (encrypted, like Safari's), not in a plain file.
- **Import from Chrome…** reads the file Chrome makes with “Export passwords”.
- After you rebuild the app in Xcode, macOS may ask once whether MyBrowser can use its Keychain items. Click **Always Allow**.

## Passkeys

Passkeys can't work in a home-made browser. macOS only lets apps use passkeys for other websites if Apple grants them a special browser permission, and that needs a paid Apple Developer account plus Apple's approval. So this browser tells websites that passkeys aren't available. Google then asks for your password instead, and the browser can save that password for you.

## Extensions (macOS 15.4 or newer)

- Click the **puzzle piece** at the right end of the toolbar → **Import from Chrome…** (see “Import from Chrome” above).
- **Add Extension from Folder…**: for any unpacked extension (a folder with `manifest.json`).
- Extension buttons appear at the right end of the toolbar.
- Extensions → (name) → **Problems & Details…** lists anything WebKit couldn't support.

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
