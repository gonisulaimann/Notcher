# Notcher — the tide line between Mac and iPhone

The MacBook notch, designed from scratch as a living surface: exactly **one**
live activity at a time (timer › file transfer › media), transient flashes
for everything else, and a real local link to an iPhone companion. When
nothing is alive, the island melts back into the camera housing.

Native AppKit + SwiftUI. No Electron. No cloud, no accounts, no telemetry.
MIT licensed (see LICENSE).

## Download

Get **Notcher-0.2.1.dmg** from
[Releases](https://github.com/gonisulaimann/Notcher/releases) (also:
`./Scripts/release.sh` builds it reproducibly from source).

![Expanded island tray](docs/images/notcher-expanded-dark.png)

![Timer pill](docs/images/notcher-compact-timer.png)
![iPhone timer mirror](docs/images/notcher-compact-remote.png)
![Now Playing pill](docs/images/notcher-compact-media.png)

## First 5 Minutes

1. Download Notcher-0.2.1.dmg from Releases; verify sha256 if you like.
2. Open the DMG, drag Notcher into Applications.
3. First launch: right-click → Open → Open (ad-hoc signature, one time).
4. Look for the waves icon in the menu bar; hover the notch.
5. Try: Start 25-minute Timer → watch the notch; drag a file onto the
   notch; open the tray → iPhone Link for the pairing code.
6. Quit from the tray footer, not by killing the process.

## KNOWN ISSUES (honest list)

- **Ad-hoc signature.** No Developer ID in the build environment, so the app
  is not notarized. First launch needs right-click → Open, once.
- **Single display.** The island anchors to the main screen only.
- **iPhone companion untested on hardware.** The iOS app builds from
  `Companion-iOS/` + shared `Sources/LinkCore`, but this machine has no
  Xcode/iOS SDK, so it is EXPECTED TO WORK / NOT TESTED until paired on a
  real iPhone. See `Companion-iOS/README-iOS.md`.
- **Requirements:** MacBook with notch (falls back to a floating capsule
  otherwise), macOS 14+.

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
