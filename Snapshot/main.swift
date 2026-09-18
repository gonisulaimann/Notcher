import AppKit
import CoreGraphics
import NotcherKit
import SwiftUI

// Renders the real island states to PNG files for visual inspection.
// Usage: swift run IslandSnapshot  ->  writes /tmp/notcher-*.png
// (screencapture(1) is permission-gated in this dev environment, so the
// harness photographs its own windows with CGWindowListCreateImage instead.)

@main
struct Snap {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let island = IslandState()
        let timer = TimerEngine()
        timer.permissionPromptEnabled = false
        let media = MediaEngine()
        let power = PowerEngine()
        let harbor = HarborStore()
        let link = LinkHost()
        let center = ExternalCenter()
        let clipboard = ClipboardEngine()
        let hudEngine = HudEngine()
        let privacy = PrivacyWatch()
        link.attach(timer: timer, harbor: harbor, island: island)

        // Deterministic timer content: start, then freeze.
        // Back up the real timer first: this harness shares Application
        // Support with the app, and must not leave a paused timer behind.
        // NOTE: restored EXPLICITLY before exit() — exit() skips defer
        // blocks, so defer-based restore silently never runs (found live).
        let supportTimer = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first!
            .appendingPathComponent("Notcher/timer.json")
        let realTimer = try? Data(contentsOf: supportTimer)
        func restoreTimer() {
            if let realTimer, !realTimer.isEmpty {
                try? realTimer.write(to: supportTimer, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: supportTimer)
            }
        }
        timer.start(seconds: 25 * 60, label: "Focus")
        timer.pause()

        guard let screen = NSScreen.main else { fatalError("no screen") }
        let layout = NotchGeometry.layout(for: screen)
        print("notch: hasNotch=\(layout.hasNotch) width=\(layout.notchWidth) top=\(layout.topInset)")

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: IslandMetrics.canvasSize),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating

        func root() -> IslandRootView {
            IslandRootView(island: island, timer: timer, media: media, power: power,
                           harbor: harbor, link: link, center: center,
                           clipboard: clipboard, hudEngine: hudEngine, privacy: privacy,
                           layout: layout,
                           onDropFiles: { _ in },
                           onInteract: {})
        }

        func place() {
            let f = screen.frame
            let size = IslandMetrics.canvasSize
            // Bottom-right corner: out of the way, fully on-screen.
            win.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.minY + 40,
                                width: size.width, height: size.height),
                         display: true)
        }

        func shoot(_ name: String, dark: Bool) {
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: root())
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            win.contentView = hosting
            place()
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            let hid = CGWindowID(win.windowNumber)
            if let img = CGWindowListCreateImage(CGRect.null, .optionIncludingWindow, hid, [.boundsIgnoreFraming]) {
                let rep = NSBitmapImageRep(cgImage: img)
                rep.size = NSSize(width: img.width, height: img.height)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: "/tmp/notcher-\(name).png")
                    try? png.write(to: url)
                    print("wrote \(url.path) \(img.width)x\(img.height)")
                } else { print("PNG encode failed for \(name)") }
            } else { print("capture failed for \(name)") }
        }

        // 1. idle (nothing live)
        island.mode = .idle; island.activity = .none; island.flash = nil
        shoot("idle", dark: true)

        // 2. compact, timer live (wings)
        island.mode = .compact; island.activity = .timer
        shoot("compact-timer", dark: true)

        // 3. compact, media live (slab; uses whatever Music/Spotify report now)
        island.mode = .compact; island.activity = .media
        shoot("compact-media", dark: true)

        // 3b. remote-timer pill content with stub values (pure view,
        // rendered in equivalent chrome — LinkHost state is private(set)).
        do {
            let pill = ZStack(alignment: .top) {
                Color.black.opacity(0.85)
                RemoteTimerPillContent(peer: "iPhone", remaining: 754,
                                       total: 1500, updatedAt: Date())
                    .padding(.top, layout.hasNotch ? layout.topInset : 0)
            }
            .frame(width: 259, height: (layout.hasNotch ? layout.topInset : 0) + 34,
                   alignment: .top)
            .frame(width: IslandMetrics.canvasSize.width,
                   height: IslandMetrics.canvasSize.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: pill)
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            win.contentView = hosting
            place()
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            let hid = CGWindowID(win.windowNumber)
            if let img = CGWindowListCreateImage(CGRect.null, .optionIncludingWindow, hid, [.boundsIgnoreFraming]) {
                let rep = NSBitmapImageRep(cgImage: img)
                rep.size = NSSize(width: img.width, height: img.height)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/notcher-compact-remote.png"))
                    print("wrote /tmp/notcher-compact-remote.png \(img.width)x\(img.height)")
                }
            }
        }

        // 3c. third-party pill with stub values (pure view).
        island.activity = .external
        shoot("compact-external", dark: true)

        // 3c-2. live activity slab
        island.mode = .compact
        island.activity = .liveActivity
        link.setLiveActivityForTesting(LinkHost.MirroredLiveActivity(
            id: "pizza-order",
            type: "delivery",
            title: "Joe's Pizza",
            subtitle: "Courier on the way",
            progress: 0.70,
            icon: "bag.fill",
            leadingText: "Order #482",
            trailingText: "ETA 8m"
        ))
        shoot("compact-live", dark: true)
        link.setLiveActivityForTesting(nil)

        // 3c-3. charging flash animation
        island.mode = .compact
        island.showFlash(icon: "bolt.fill", text: "Charging")
        shoot("charging-flash", dark: true)
        island.flash = nil

        // 3d. HUD capsule
        island.mode = .hud
        island.hud = IslandState.HudContent(kind: .volume(muted: false), value: 0.65)
        shoot("hud", dark: true)

        // 3e. Godmode key beats (deterministic beat values, no timers).
        island.hud = nil
        island.mode = .idle
        island.overtureBeat = .greetings
        shoot("overture-greet", dark: true)
        island.overtureBeat = .vocabTimer
        shoot("overture-timer", dark: true)
        island.overtureBeat = nil

        // 4. expanded, dark
        island.mode = .expanded
        shoot("expanded-dark", dark: true)

        // 5. expanded, light
        shoot("expanded-light", dark: false)

        win.orderOut(nil)
        print("done")
        restoreTimer()
        fflush(stdout)
        exit(0)
    }
}
