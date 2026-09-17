# Notcher Link — iPhone companion

**Status: EXPECTED TO WORK / NOT TESTED.** The dev machine for this project
has Command Line Tools only (no Xcode, no iOS SDK), so this target has never
been compiled. It uses only public iOS 17+ APIs (`Network`, `CryptoKit`,
`SwiftUI`, `UIKit` document picker) plus the shared `Sources/LinkCore`
protocol, which **is** tested on macOS via `swift run LinkSelfTest`.

## What it does

- Discovers the Mac on the same Wi-Fi via Bonjour `_notcherlink._tcp`
- Pairs with the 6-digit code shown in the Mac island (iPhone Link section)
- Mirrors the Mac timer live (5s truth broadcasts from the Mac)
- Starts / cancels timers on the Mac
- Sends text notes and files to the Mac; receives files/text from the Mac
- Optionally shares battery level (toggle, on by default)
- Shows what the Mac is playing (informational mirror)

Everything is foreground-only: iOS suspends Bonjour sockets when the app
backgrounds, and the Mac island surfaces that as the iPhone leaving.

## Build it (requires Xcode on a Mac with an Apple ID)

1. Xcode → File → New → Project → iOS → App. Name: `NotcherLink`,
   interface SwiftUI, language Swift, minimum iOS 17.
2. Add files to the target:
   - everything in this folder (`NotcherLinkApp.swift`, `LinkPeer.swift`,
     `ContentView.swift`), AND
   - the shared protocol: `../Sources/LinkCore/*.swift`
     (add by reference — do not copy, so protocol changes stay in sync).
3. Merge `Info-additions.plist` into the target's Info.plist
   (`NSBonjourServices` + `NSLocalNetworkUsageDescription`).
4. Signing & Capabilities → add your Team (free Apple ID works for
   local-network apps; no special entitlement needed).
5. Run on your iPhone (physical device — the simulator has no Bonjour
   reachability to the LAN in some configs; same Wi-Fi as the Mac required).
6. On first launch iOS asks for Local Network access → Allow. Enter the
   6-digit code from the Mac island → Connect.

## Protocol reference

Wire format, message kinds, crypto, and limits are defined once in
`Sources/LinkCore/LinkProtocol.swift` and documented in `docs/RECORD.md`.
iOS and macOS must always build against the same `LinkCore` revision.
