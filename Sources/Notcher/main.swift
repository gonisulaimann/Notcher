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
    private var center = ExternalCenter()
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
        center.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .needsConsent(let name):
                // Visible but never expanded uninvited: a flash, not a grab.
                self.island.showFlash(icon: "app.badge.fill",
                                      text: "\(name) wants the waterline")
            case .shownNow, .drained:
                break
            }
            self.engineChanged()
        }
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
        // External visibility changes are already edge-shaped (nil edges and
        // content replacement both matter for the pill), but they arrive at
        // most on user/consent/TTL events — never per-tick.
        center.$visible
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)

        // Window.
        let root = IslandRootView(
            island: island, timer: timer, media: media, power: power,
            harbor: harbor, link: link, center: center,
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
            harbor: harbor, link: link, center: center,
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
        registerURLHandler()
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
        case .overture:
            startOverture()
        case .translocatedTray:
            island.presentPinned()
            island.showFlash(icon: "arrow.down.doc.fill",
                             text: "Running from the disk image — drag Notcher to Applications",
                             seconds: 10)
        }
    }

    // MARK: - Godmode overture

    private var overture: Overture?
    private var overturePoll: Timer?
    private var overtureBeatShown = -1
    private var savedHosting: NSView?
    private var savedOutsideClick: (() -> Void)?
    private var savedEscape: (() -> Void)?

    private func startOverture() {
        guard let ctl = controller,
              let screen = NSScreen.main,
              overture == nil
        else { return }
        let f = screen.frame
        let corner = CGRect(x: f.maxX - 224, y: f.minY + 40, width: 200, height: 40)
        // Land on the compact pill geometry (centered top).
        let target = CGRect(x: f.midX - 174, y: f.maxY - 40 + 2, width: 348, height: 40)
        let ov = Overture(corner: corner, notchFrame: target,
                          reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ov.onDone = { [weak self] in
            Task { @MainActor in self?.endOverture() }
        }
        overture = ov
        // Swap content; reroute every exit to cancel.
        savedHosting = ctl.panel.contentView
        let view = OvertureView(overture: ov) { [weak self] in
            Task { @MainActor in self?.cancelOverture() }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        ctl.panel.contentView = hosting
        savedOutsideClick = ctl.onOutsideClick
        savedEscape = ctl.onEscape
        ctl.onOutsideClick = { [weak self] in
            Task { @MainActor in self?.cancelOverture() }
        }
        ctl.onEscape = { [weak self] in
            Task { @MainActor in self?.cancelOverture() }
        }
        ctl.showCustom(ov.frame(at: 0), animate: false)
        overtureBeatShown = 0
        ov.start()
        // Advance frames on beats: one guarded op per beat change, never a
        // per-tick window op (the poll itself is displayless).
        overturePoll?.invalidate()
        overturePoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak ov, weak ctl] _ in
            Task { @MainActor in
                guard let self, let ov, let ctl, self.overture === ov, !ov.finished else { return }
                if ov.beatIndex != self.overtureBeatShown {
                    self.overtureBeatShown = ov.beatIndex
                    ctl.showCustom(ov.frame(at: ov.beatIndex), animate: true)
                }
                if ov.finished { self.endOverture() }
            }
        }
    }

    private func cancelOverture() {
        overture?.cancel()
        // cancel() fires onDone synchronously when unfinished.
        if overture != nil { endOverture() }
    }

    private func endOverture() {
        guard let ctl = controller, overture != nil else { return }
        overture = nil
        overturePoll?.invalidate()
        overturePoll = nil
        overtureBeatShown = -1
        if let saved = savedHosting {
            ctl.panel.contentView = saved
            savedHosting = nil
        }
        ctl.onOutsideClick = savedOutsideClick
        ctl.onEscape = savedEscape
        savedOutsideClick = nil
        savedEscape = nil
        engineChanged()
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
                       mediaPlaying: media.playing,
                       externalActive: center.visible != nil)
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

    // MARK: - IslandKit v1: URL scheme

    private func registerURLHandler() {
        // 'GURL' / kInternetEventClass + kAEGetURL, without importing Carbon.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(0x4755524C),
            andEventID: AEEventID(0x4755524C))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply _: NSAppleEventDescriptor) {
        // keyDirectObject == '----'
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,
              let comps = URLComponents(string: raw),
              comps.scheme == "notcher",
              let items = comps.queryItems
        else { return }
        if comps.host == "clear" {
            func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
            // Ids are namespaced per sender at submit; namespace here too so
            // one sender can only ever clear its own activities.
            let sender = senderIdentity()
            if let id = q("id"), !id.isEmpty { center.clear(id: sender.key + ":" + id) }
            else {
                for id in center.ids(matchingPrefix: sender.key + ":") { center.clear(id: id) }
            }
            engineChanged()
            return
        }
        guard comps.host == "activity" else { return }
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let title = q("title"), !title.isEmpty else { return }
        let sender = senderIdentity()
        let rawID = (q("id")?.isEmpty == false) ? q("id")! : UUID().uuidString
        let activity = ExternalActivity(
            id: sender.key + ":" + rawID,
            source: (q("source")?.isEmpty == false) ? q("source")! : sender.name,
            bundleID: sender.bundleID,
            title: title,
            subtitle: q("subtitle"),
            progress: q("progress").flatMap(Double.init),
            priority: q("priority").flatMap(ExternalActivity.Priority.init(rawValue:)) ?? .normal,
            icon: Self.sanitizedIcon(q("icon")),
            ttl: Self.parseTTL(q("ttl")))
        IslandDebug.log("url activity from \(sender.key): \(title)")
        center.submit(activity)
    }

    /// Who sent this Apple Event? Direct app-to-app opens resolve to a real
    /// bundle; `open(1)`-mediated pushes resolve to the tool (no bundle) and
    /// fall through to the declared source string. Either way the consent
    /// card shows something truthful about provenance.
    private func senderIdentity() -> (key: String, name: String, bundleID: String?) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           // keySenderPIDAttr == 'spid'
           let pidDesc = event.attributeDescriptor(forKeyword: AEKeyword(0x73706964)),
           let app = NSRunningApplication(processIdentifier: pidDesc.int32Value)
        {
            if let bid = app.bundleIdentifier, !bid.isEmpty {
                return ("bundle:" + bid, app.localizedName ?? bid, bid)
            }
            if let name = app.localizedName, !name.isEmpty {
                return ("source:" + name, name, nil)
            }
        }
        return ("source:script", "script", nil)
    }

    private static func sanitizedIcon(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty,
              raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }),
              NSImage(systemSymbolName: raw, accessibilityDescription: nil) != nil
        else { return "app.badge" }
        return raw
    }

    fileprivate static func parseTTL(_ raw: String?) -> TimeInterval {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return ExternalActivity.defaultTTL
        }
        if raw.hasSuffix("h"), let n = Double(raw.dropLast()) { return n * 3600 }
        if raw.hasSuffix("m"), let n = Double(raw.dropLast()) { return n * 60 }
        let digits = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return Double(digits) ?? ExternalActivity.defaultTTL
    }
}
