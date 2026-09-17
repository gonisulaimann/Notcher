// NOTE (dev-machine limitation): this target is NOT compiled here — the dev
// machine has Command Line Tools only (no Xcode, no iOS SDK). It is written
// against public iOS 17+ APIs and the shared Sources/LinkCore protocol, and
// is marked EXPECTED TO WORK / NOT TESTED until built in Xcode. See
// Companion-iOS/README-iOS.md. Status tracking: docs/RECORD.md.

import SwiftUI

@main
struct NotcherLinkApp: App {
    @StateObject private var peer = LinkPeer()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(peer: peer)
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active: peer.start()
            case .background: peer.stop()
            default: break
            }
        }
    }
}
