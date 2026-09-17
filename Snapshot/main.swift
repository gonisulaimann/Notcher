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

        let win = NSWindow(contentRect: NSMakeRect(0, 0, 404, 468),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating

        func root() -> IslandRootView {
            IslandRootView(island: island, timer: timer, media: media, power: power,
                           harbor: harbor, link: link,
                           notchWidth: layout.notchWidth, hasNotch: layout.hasNotch,
                           onDropFiles: { _ in })
        }

        func place(_ size: NSSize) {
            let f = screen.frame
            // Bottom-right corner: out of the way, fully on-screen.
            win.setFrame(NSRect(x: f.maxX - size.width - 24, y: f.minY + 40,
                                width: size.width, height: size.height),
                         display: true)
        }

        func shoot(_ size: NSSize, _ name: String, dark: Bool) {
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: root())
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            win.contentView = hosting
            place(size)
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

        let idleW = max(180, layout.notchWidth + 72)
        let idleH = (layout.hasNotch ? layout.topInset : 30) + 6

        // 1. idle (nothing live)
        island.mode = .idle; island.activity = .none; island.flash = nil
        shoot(NSSize(width: idleW, height: idleH), "idle", dark: true)

        // 2. compact, timer live
        island.mode = .compact; island.activity = .timer
        shoot(NSSize(width: 348, height: 40), "compact-timer", dark: true)

        // 3. compact, media live (uses whatever Music/Spotify report now)
        island.mode = .compact; island.activity = .media
        shoot(NSSize(width: 348, height: 40), "compact-media", dark: true)

        // 3b. remote-timer pill content with stub values (pure view: no live
        // session needed). Rendered in equivalent pill chrome.
        do {
            let pill = ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.85))
                RemoteTimerPillContent(peer: "iPhone", remaining: 754, total: 1500, updatedAt: Date())
                    .padding(.horizontal, 14)
            }
            let hosting = NSHostingView(rootView: AnyView(pill))
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            win.contentView = hosting
            win.appearance = NSAppearance(named: .darkAqua)
            place(NSSize(width: 348, height: 40))
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

        // 4. expanded, dark
        island.mode = .expanded
        shoot(NSSize(width: 404, height: 468), "expanded-dark", dark: true)

        // 5. expanded, light
        shoot(NSSize(width: 404, height: 468), "expanded-light", dark: false)

        win.orderOut(nil)
        print("done")
        restoreTimer()
        fflush(stdout)
        exit(0)
    }
}
