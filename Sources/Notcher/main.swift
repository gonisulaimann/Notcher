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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var island = IslandState()
    private var timer = TimerEngine()
    private var media = MediaEngine()
    private var power = PowerEngine()
    private var harbor = HarborStore()
    private var link = LinkHost()
    private var center = ExternalCenter()
    private var shots = ShotWatch()
    private var socket = SocketServer()
    private var clipboard = ClipboardEngine()
    private var hudEngine = HudEngine()
    private var privacy = PrivacyWatch()
    private var watchdog: WatchdogEngine?
    private var controller: IslandController?
    private var statusItem: NSStatusItem?
    private var bag = Set<AnyCancellable>()
    private var overture: Overture?

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
            case .liveActivityReceived(let peer, let title):
                self.island.showFlash(icon: "sparkles", text: "\(title) from \(peer)")
            }
            self.engineChanged()
        }

        // New surfaces: HUD, clipboard, privacy sensors.
        hudEngine.onVolumeChange = { [weak self] value, muted in
            self?.island.showHud(.init(kind: .volume(muted: muted), value: value))
        }
        hudEngine.onBrightnessChange = { [weak self] value in
            self?.island.showHud(.init(kind: .brightness, value: value))
        }
        privacy.cameraActiveChanged = { [weak self] active in
            guard let self, active else { return }
            self.island.showFlash(icon: "video.fill", text: "Camera in use", seconds: 2.5)
        }
        privacy.micActiveChanged = { [weak self] active in
            guard let self, active else { return }
            self.island.showFlash(icon: "mic.fill", text: "Microphone in use", seconds: 2.5)
        }

        // Island UI -> window. All roads lead through requestRefresh(),
        // which coalesces a burst of publications into one window op per
        // runloop turn. In v2 the window op is a pure metrics handoff
        // (shaped hit-testing) — the morph itself lives in SwiftUI.
        island.$mode.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        island.$activity.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        island.$flash.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
        // Overture beats morph the surface; the view reads overtureBeat
        // directly for its content, this subscription moves the metrics.
        island.$overtureBeat.sink { [weak self] _ in self?.requestRefresh() }.store(in: &bag)
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
        link.$liveActivity
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)
        center.$visible
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &bag)

        // Window (single canvas; content morphs inside it).
        let ctl = IslandController()
        controller = ctl
        let layout = ctl.notchLayout
        ctl.setRoot(IslandRootView(
            island: island, timer: timer, media: media, power: power,
            harbor: harbor, link: link, center: center,
            clipboard: clipboard, hudEngine: hudEngine, privacy: privacy,
            layout: layout,
            layoutProvider: { [weak ctl] in ctl?.notchLayout ?? layout },
            onDropFiles: { [weak self] urls in self?.dropFiles(urls) },
            onInteract: { [weak self] in self?.userInteracting() }
        ))
        ctl.onScreenChanged = { [weak self] _ in
            self?.requestRefresh()
        }
        ctl.onOutsideClick = { [weak self] in
            guard let self, self.island.mode == .expanded, !self.island.pinned else { return }
            self.island.collapse()
        }
        ctl.onEscape = { [weak self] in
            guard let self else { return }
            if self.overture != nil {
                self.cancelOverture()
            } else {
                self.island.collapse()
            }
        }
        ctl.contextMenuProvider = { [weak self] in
            self?.buildIslandContextMenu() ?? NSMenu()
        }
        ctl.orderFront()

        setupStatusItem()
        registerURLHandler()
        socket.onIntent = { [weak self] intent in
            Task { @MainActor in
                guard let self else { return }
                switch intent {
                case .push(let activity):
                    self.center.submit(activity)
                case .clearID(let id):
                    self.center.clear(id: id)
                case .clearSender(let prefix):
                    self.center.clearMatching(prefix: prefix)
                }
                self.engineChanged()
            }
        }
        socket.start()
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
    /// nothing, so a fresh user gets a guided intro instead of silence.
    /// A translocated launch (running from the disk image) always guides
    /// toward /Applications — that IS the partial-Gatekeeper path.
    private func firstRunMoment() {
        let translocated = FirstRun.isTranslocated(bundlePath: Bundle.main.bundlePath)
        let didRun = UserDefaults.standard.bool(forKey: FirstRun.overtureKey)
        guard let action = FirstRun.plan(translocated: translocated, didRun: didRun) else { return }
        UserDefaults.standard.set(true, forKey: FirstRun.overtureKey)
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

    // MARK: - Godmode overture (v2: beats inside the morphing surface)

    private var overtureBag = Set<AnyCancellable>()

    private func startOverture() {
        guard controller != nil, overture == nil else { return }
        let ov = Overture(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        ov.onDone = { [weak self] in
            Task { @MainActor in self?.endOverture() }
        }
        overture = ov
        island.pinned = false
        island.overtureBeat = ov.beats[ov.beatIndex]
        // Surface follows the beat machine; content reads overtureBeat.
        ov.$beatIndex.sink { [weak self, weak ov] index in
            guard let self, let ov, self.overture === ov else { return }
            self.island.overtureBeat = ov.beats[index]
        }.store(in: &overtureBag)
        ov.start()
    }

    private func cancelOverture() {
        overture?.cancel()
        // cancel() fires onDone synchronously when unfinished.
        if overture != nil { endOverture() }
    }

    private func endOverture() {
        guard overture != nil else { return }
        overture = nil
        overtureBag.removeAll()
        island.overtureBeat = nil
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

        watchdog = WatchdogEngine(maxLatencySeconds: 6.0, maxMemoryMB: 512, onTeardown: { [weak self] in
            self?.controller?.tearDown()
        })
        watchdog?.start()
    }

    func applicationWillTerminate(_: Notification) {
        watchdog?.stop()
        link.stop()
        socket.stop()
        clipboard.stop()
        power.stop()
        privacy.stop()
        hudEngine.stop()
        controller?.tearDown()
    }

    // MARK: - State resolution

    private func engineChanged() {
        let transferActive = link.receiving != nil
        let remoteTimerActive = !timer.isActive && link.remoteTimer != nil
        let liveActivityActive = link.liveActivity != nil
        island.resolve(timerActive: timer.isActive || timer.state == .done,
                       transferActive: transferActive,
                       remoteTimerActive: remoteTimerActive,
                       liveActivityActive: liveActivityActive,
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
        let metrics = island.surfaceMetrics(layout: ctl.notchLayout)
        ctl.present(metrics: metrics,
                    expanded: island.mode == .expanded,
                    allowKey: island.mode == .expanded)
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

    // MARK: - Menu bar & Context Menu
 
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Notcher")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu(menu)
    }

    private func updateStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let openTitle = (island.mode == .expanded) ? "Collapse Island" : "Open Island"
        let openItem = NSMenuItem(title: openTitle, action: #selector(toggleIslandMode), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let pinItem = NSMenuItem(title: "Keep on Top", action: #selector(togglePinState), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = island.pinned ? .on : .off
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let timerItem = NSMenuItem(title: "Start 25-minute Timer", action: #selector(quickTimer), keyEquivalent: "")
        timerItem.target = self
        menu.addItem(timerItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Notcher", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func buildIslandContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Notcher")
        let toggleTitle = (island.mode == .expanded) ? "Collapse Island" : "Expand Island"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleIslandMode), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pinItem = NSMenuItem(title: "Keep on Top", action: #selector(togglePinState), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = island.pinned ? .on : .off
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let timerItem = NSMenuItem(title: "Start 25-minute Timer", action: #selector(quickTimer), keyEquivalent: "")
        timerItem.target = self
        menu.addItem(timerItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Notcher", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleIslandMode() {
        userInteracting()
        if island.mode == .expanded {
            island.collapse()
        } else {
            island.presentPinned()
        }
    }

    @objc private func togglePinState() {
        userInteracting()
        island.togglePin()
    }

    @objc private func toggleLaunchAtLogin() {
        let next = !LaunchAtLogin.enabled
        try? LaunchAtLogin.set(next)
        island.loginEnabled = next
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
            else { center.clearMatching(prefix: sender.key + ":") }
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
