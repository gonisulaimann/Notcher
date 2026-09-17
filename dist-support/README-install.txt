Installing Notcher
=====================

1. Drag Notcher.app into the Applications folder shortcut.
2. Open Notcher from Applications (or Spotlight).
   A small waves icon appears in the menu bar — there is no Dock icon.
3. Hover the notch at the top of the screen to expand the island.

First launch note (please read)
-------------------------------
This build is ad-hoc signed, not notarized. On first launch macOS may say
the app cannot be verified. If that happens: in Finder, right-click (or
Control-click) Notcher.app → Open → Open. You only need to do this once;
afterwards it launches normally. (A Developer-ID signed and notarized build
would skip this step; this release pipeline documents exactly what it is.)

What it needs, and why
----------------------
- Local Network: finds your iPhone companion on the same Wi-Fi.
- Automation for Music/Spotify: only when you press play/pause/skip, or to
  show what is currently playing in an already-running player.
- Notifications: timer completion only.
- Files: only files you drag onto the notch or pick yourself.

Uninstall
---------
Quit Notcher from its menu-bar menu, then drag Notcher.app to the Trash.
Optional leftovers live in ~/Library/Application Support/Notcher
(timers, parked-file references) and ~/Downloads/Notcher Inbox
(files received from the iPhone). Delete those folders to remove everything.

Version information and checksums are in the accompanying .sha256 file.
