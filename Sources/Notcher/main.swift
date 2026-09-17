import AppKit
import Combine
import NotcherKit
import SwiftUI

// MARK: - Entry

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()

// MARK: - Coordinator

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island = IslandState()
    private var timer = TimerEngine()
    private var media = MediaEngine()
    private var power = PowerEngine()
    private var harbor = HarborStore()
    private var link = LinkHost()
    private var shots = ShotWatch()
    private var controller: IslandController?
    private var statusItem: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_: Notification) {
        // Single instance: the repo copy and an installed copy share one
        // bundle id (and one island). Same-path double launch quits quietly;
        // a DIFFERENT path means a Keep-Both duplicate — explain, offer to
        // reveal it, then stand down instead of silently dying.
        let me = ProcessInfo.processInfo.processIdentifier
        let myURL = Bundle.main.bundleURL.standardizedFileURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.notcher.Notcher")
            .filter { $0.processIdentifier != me }
        if let other = others.first {
            let otherURL = other.bundleURL?.standardizedFileURL
            if otherURL == nil || otherURL != myURL {
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Notcher is already running"
                alert.informativeText = "Another copy is running from:\n\(otherURL?.path ?? "an unknown location")\n\nThis copy will quit. To avoid this, keep /Applications/Notcher.app and delete any duplicates."
                alert.addButton(withTitle: "Quit This Copy")
                alert.addButton(withTitle: "Reveal Other in Finder")
                if alert.runModal() == .alertSecondButtonReturn,
                   let url = otherURL
                {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                NSLog("[notcher] same-copy relaunch; standing down")
            }
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)

        link.attach(timer: timer, harbor: harbor, island: island)

        // Engine -> island wiring. Edge broadcasts live here (not in
        // engineChanged): timer/media callbacks already fire only on real
        // transitions, so mirrors stay fresh without per-churn traffic.
        timer.onChanged = { [weak self] in
            self?.engineChanged()
            self?.link.broadcastTimerState()
        }
        timer.onFinished = { [weak self] in
            guard let self else { return }
            let label = self.timer.label
            self.island.showFlash(icon: "checkmark.circle.fill",
                                  text: label.isEmpty ? "Timer done" : "\(label) — done",
                                  seconds: 6)
            self.link.broadcastTimerState()
        }
        media.onChanged = { [weak self] in
            guard let self else { return }
            self.engineChanged()
            self.link.broadcastMedia(playing: self.media.playing,
                                     title: self.media.title,
                                     artist: self.media.artist)
        }
        power.onEvent = { [weak self] event in
            switch event {
            case .chargingStarted: self?.island.showFlash(icon: "bolt.fill", text: "Charging")
            case .full: self?.island.showFlash(icon: "battery.100percent", text: "Fully charged")
            case .low: self?.island.showFlash(icon: "battery.25percent", text: "Battery low")
            }
        }
        harbor.onChanged = { [weak self] in self?.engineChanged() }
        link.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .peerJoined(let name):
                self.island.showFlash(icon: "iphone", text: "\(name) nearby")
                // A fresh peer missed earlier state: greet it once with
                // current truth instead of waiting for the next change.
                self.link.broadcastTimerState()
                self.link.broadcastMedia(playing: self.media.playing,
                                         title: self.media.title,
                                         artist: self.media.artist)
            case .peerLeft:
                break
            case .textReceived(let peer, let preview):
                self.island.showFlash(icon: "note.text", text: "Note from \(peer): \(preview)")
            case .fileReceived(let peer, let name):
                self.island.showFlash(icon: "arrow.down.doc.fill", text: "\(name) from \(peer)")
            case .timerStartedRemotely(let peer):
                self.island.showFlash(icon: "timer", text: "Timer from \(peer)")
            }
            self.engineChanged()
        }

        // Island UI -> window. All roads lead through requestRefresh(),
        // which coalesces a burst of publications into one window op per
        // runloop turn (see IslandController.show's diff guard — the second
        // half of the flicker fix). High-frequency publishers are reduced to
        // edges: per-chunk transfer progress and per-tick remote mirrors must
        // never re-resolve the island.
        island.$mode.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        island.$activity.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        island.$flash.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        island.$dropTarget.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        link.$peers
            .map { $0.map(\.deviceID).sorted() }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)
        link.$receiving
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)
        link.$remoteTimer
            .map { $0?.peer }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)

        // Window.
        let root = IslandRootView(
            island: island, timer: timer, media: media, power: power,
            harbor: harbor, link: link,
            notchWidth: 0, hasNotch: true,
            onDropFiles: { [weak self] urls in self?.dropFiles(urls) },
            onInteract: { [weak self] in self?.userInteracting() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let ctl = IslandController(content: hosting)
        let layout = ctl.notchLayout
        // Rebuild root with real geometry (value types need the final copy).
        hosting.rootView = IslandRootView(
            island: island, timer: timer, media: media, power: power,
            harbor: harbor, link: link,
            notchWidth: layout.notchWidth, hasNotch: layout.hasNotch,
            onDropFiles: { [weak self] urls in self?.dropFiles(urls) },
            onInteract: { [weak self] in self?.userInteracting() }
        )
        ctl.onOutsideClick = { [weak self] in
            guard let self, self.island.mode == .expanded, !self.island.pinned else { return }
            self.island.collapse()
        }
        ctl.onEscape = { [weak self] in self?.island.collapse() }
        controller = ctl

        setupStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        engineChanged()
        link.start()
        shots.isEnabled = UserDefaults.standard.object(forKey: ShotWatch.watchShotsKey) as? Bool ?? true
        shots.onShot = { [weak self] url in
            guard let self else { return }
            guard UserDefaults.standard.object(forKey: ShotWatch.watchShotsKey) as? Bool ?? true else { return }
            if self.harbor.add(urls: [url]) > 0 {
                self.island.showFlash(icon: "photo.fill", text: "Parked \(url.lastPathComponent)")
            }
        }
        firstRunMoment()
    }

    /// The first-run moment: LSUIElement apps show no Dock icon and open
    /// nothing, so a fresh user gets a guided tray instead of silence.
    /// A translocated launch (running from the disk image) always guides
    /// toward /Applications — that IS the partial-Gatekeeper path, the only
    /// denied-adjacent state this process can ever observe (a fully denied
    /// launch never reaches code).
    private func firstRunMoment() {
        let translocated = FirstRun.isTranslocated(bundlePath: Bundle.main.bundlePath)
        let didRun = UserDefaults.standard.bool(forKey: FirstRun.didRunKey)
        guard let action = FirstRun.plan(translocated: translocated, didRun: didRun) else { return }
        UserDefaults.standard.set(true, forKey: FirstRun.didRunKey)
        switch action {
        case .welcomeTray:
            island.presentPinned()
            island.showFlash(icon: "water.waves",
                             text: "Welcome to Notcher — hover the notch anytime",
                             seconds: 8)
        case .translocatedTray:
            island.presentPinned()
            island.showFlash(icon: "arrow.down.doc.fill",
                             text: "Running from the disk image — drag Notcher to Applications",
                             seconds: 10)
        }
    }

    @objc private func systemDidWake(_: Notification) {
        // Bonjour advertisements rarely survive sleep; re-announce so the
        // iPhone sees the Mac promptly instead of after a stale timeout.
        IslandDebug.log("system woke, restarting link")
        link.stop()
        link.start()
        // A running timer survived on wall-clock deadline; say what is left.
        if timer.isActive {
            island.showFlash(icon: "timer",
                             text: "Timer: \(TimerFormat.string(timer.remaining)) left",
                             seconds: 5)
        }
    }

    func applicationWillTerminate(_: Notification) {
        link.stop()
    }

    // MARK: - State resolution

    private func engineChanged() {
        let transferActive = link.receiving != nil
        let remoteTimerActive = !timer.isActive && link.remoteTimer != nil
        island.resolve(timerActive: timer.isActive || timer.state == .done,
                       transferActive: transferActive,
                       remoteTimerActive: remoteTimerActive,
                       mediaPlaying: media.playing)
        requestRefresh()
    }

    private var refreshQueued = false

    private func requestRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshWindow()
        }
    }

    private func refreshWindow() {
        guard let ctl = controller else { return }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch island.mode {
        case .idle: ctl.show(.idle, allowKey: false, animate: animate)
        case .compact: ctl.show(.compact, allowKey: false, animate: animate)
        case .expanded: ctl.show(.expanded, allowKey: true, animate: animate)
        }
    }

    private func dropFiles(_ urls: [URL]) {
        island.setDropTarget(false)
        let added = harbor.add(urls: urls)
        if added > 0 {
            // showFlash already lifts idle -> compact; no direct mode poke.
            island.showFlash(icon: "tray.full.fill",
                             text: added == 1 ? "Parked 1 file" : "Parked \(added) files")
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Notcher")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Island", action: #selector(openIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start 25-minute Timer", action: #selector(quickTimer), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openIsland() {
        userInteracting()
        island.presentPinned()
    }

    /// Explicit interaction: allow key status and activate so controls and
    /// text fields work. Never called from hover paths.
    private func userInteracting() {
        controller?.activateForInteraction()
    }

    @objc private func quickTimer() {
        timer.start(seconds: 25 * 60, label: "Focus")
    }
}
