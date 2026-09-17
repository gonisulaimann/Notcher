# Notcher — the tide line between Mac and iPhone

The MacBook notch, designed from scratch as a living surface: exactly **one**
live activity at a time (timer › file transfer › media), transient flashes
for everything else, and a real local link to an iPhone companion. When
nothing is alive, the island melts back into the camera housing.

Native AppKit + SwiftUI. No Electron. No cloud, no accounts, no telemetry.

## Run it (MacBook with notch, macOS 14+, CLT or Xcode)

```sh
cd /Users/goni/Desktop/Notcher
./Scripts/build-app.sh   # swift build (release) → Notcher.app
open ./Notcher.app
```

## Install it (release DMG)

```sh
./Scripts/release.sh            # → dist/Notcher-<ver>.dmg (+ .sha256)
```

Open the DMG, drag Notcher.app into Applications, launch. Ad-hoc signed
(not notarized — no Developer ID in this environment): on first launch, if
macOS blocks it, right-click → Open → Open, once. Never run the repo copy
and the installed copy together — the second launch quits itself by design.

First launch: no Dock icon (menu-bar app — look for the waves icon `≈`).
Hover the notch to expand. Drag files onto the notch to park them.

Useful without touching the notch:

- Menu bar → **Start 25-minute Timer**
- Hover → tray → Timer / Now Playing / Harbor / iPhone Link / Open at Login

## iPhone companion

`Companion-iOS/` — pair with the 6-digit code in the island's iPhone Link
section (same Wi-Fi). Mirror/start the Mac timer, exchange text and files.
Requires Xcode to build; see `Companion-iOS/README-iOS.md`.

## Verify it

```sh
swift run LinkSelfTest    # protocol: crypto, handshake, transfer, auth (8 checks)
swift run IslandSnapshot  # renders idle/compact/expanded to /tmp/notcher-*.png
swift run NotcherProbe stress          # window/state-machine storm (12 checks)
swift run NotcherProbe persistence     # timer relaunch round-trips (4 checks)
swift run NotcherProbe reconnect       # kill + re-handshake (2 checks)
swift run NotcherProbe samplesteady <pid> <sec>  # live frame-stability audit
swift run NotcherProbe taptest         # real click->expand, Esc->collapse
swift run NotcherProbe storm           # burst traffic at the live island
swift run NotcherProbe sendfile        # one small file, live end to end
```

## Privacy

Local network only. Pairing code never leaves your devices. Text/files move
only when you explicitly send them. No clipboard snooping, no analytics.

Details, decisions, limitations: [`docs/RECORD.md`](docs/RECORD.md).
