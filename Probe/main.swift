import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Dispatch
import Foundation
import LinkCore
import Network
import NotcherKit
import SwiftUI

// NotcherProbe — dev-only instability hunter (NEVER bundled in the app).
//
//   NotcherProbe storm                 pair with the live app, burst traffic
//   NotcherProbe sendfile              send a small labeled probe file live
//   NotcherProbe samplesteady <pid> <s> 60Hz window-frame stability audit
//   NotcherProbe taptest                real synthetic clicks: pill->expand, Esc->collapse
// (taptest posts one CG click at the island pill — our own window — and one
// Esc key event to our own PID. No other app is touched.)
//   NotcherProbe stress                in-process window/state-machine storm
//   NotcherProbe persistence           timer persistence round-trips
//   NotcherProbe reconnect             kill + re-establish a live session
//
// Live modes (storm/sendfile) intentionally cause VISIBLE product behavior
// (flashes, a probe file in ~/Downloads/Notcher Inbox, one 45s timer that is
// cancelled at the end). That is the point: real device behavior, no mocks.

// Entry strategy (learned the hard way — see RECORD "harness lessons"):
// - storm / sendfile / reconnect / samplesteady touch ONLY LinkCore (no
//   @MainActor product classes) and work from any thread: Task + dispatchMain.
// - stress / persistence drive @MainActor UI engines and MUST run on the real
//   main thread with a real runloop (exactly like Snapshot): sync code +
//   MainActor.assumeIsolated + RunLoop.main.run pumps. No Task, no await.
let probeMode = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : ""
switch probeMode {
case "stress", "persistence", "poweredge", "naming", "firstrun", "godmode", "overlap", "external", "socket", "hittest", "sensors":
    MainActor.assumeIsolated {
        switch probeMode {
        case "stress": Probe.StressSync.runStress()
        case "persistence": Probe.StressSync.runPersistence()
        case "poweredge": Probe.StressSync.runPowerEdge()
        case "firstrun": Probe.StressSync.runFirstRun()
        case "godmode": Probe.StressSync.runGodmode()
        case "overlap": Probe.StressSync.runOverlap()
        case "external": Probe.StressSync.runExternal()
        case "socket": Probe.StressSync.runSocket()
        case "hittest": Probe.StressSync.runHitTest()
        case "sensors": Probe.StressSync.runSensors()
        default: Probe.StressSync.runNaming()
        }
    }
    print(Probe.failures == 0 ? "PROBE DONE, ALL PASS" : "PROBE DONE, \(Probe.failures) FAILURE(S)")
    fflush(stdout)
    exit(Probe.failures == 0 ? 0 : 1)
case "storm", "sendfile", "reconnect", "taptest", "cleanup", "shotwatch":
    Task {
        await Probe.runAsync(mode: probeMode)
        print(Probe.failures == 0 ? "PROBE DONE, ALL PASS" : "PROBE DONE, \(Probe.failures) FAILURE(S)")
        fflush(stdout)
        exit(Probe.failures == 0 ? 0 : 1)
    }
    dispatchMain()
case "samplesteady":
    guard CommandLine.arguments.count >= 4,
          let pid = Int32(CommandLine.arguments[2]),
          let secs = Double(CommandLine.arguments[3])
    else { print("usage: NotcherProbe samplesteady <pid> <seconds>"); exit(2) }
    Probe.samplesteady(pid: pid, seconds: secs)
    print(Probe.failures == 0 ? "PROBE DONE, ALL PASS" : "PROBE DONE, \(Probe.failures) FAILURE(S)")
    exit(Probe.failures == 0 ? 0 : 1)
default:
    print("usage: NotcherProbe storm|sendfile|cleanup|shotwatch|samplesteady|taptest|stress|persistence|poweredge|naming|firstrun|godmode|overlap|external|socket|hittest|reconnect")
    exit(2)
}

struct Probe {
    nonisolated(unsafe) static var failures = 0

    static func check(_ cond: Bool, _ name: String) {
        if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); failures += 1 }
    }

    // Async modes (LinkCore only — thread-agnostic).
    static func runAsync(mode: String) async {
        switch mode {
        case "storm": await storm()
        case "sendfile": await sendfile()
        case "reconnect": await reconnect()
        case "taptest": await taptest()
        case "cleanup": cleanup()
        case "shotwatch": await shotwatch()
        default: break
        }
    }

    /// End-to-end screenshot wash: writes a real PNG to the live Desktop and
    /// proves the running app parks it in Harbor (observed via its store).
    /// Requires the live app (with ShotWatch) running. Cleans up after itself.
    static func shotwatch() async {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Notcher/harbor.json")
        func parked() -> Bool {
            guard let d = try? Data(contentsOf: support),
                  let s = String(data: d, encoding: .utf8)
            else { return false }
            return s.contains("notcher-probe-shot.png")
        }
        let url = fm.urls(for: .desktopDirectory, in: .userDomainMask).first!
            .appendingPathComponent("notcher-probe-shot.png")
        // Minimal valid 1x1 PNG.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
                        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
                        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
                        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        try? png.write(to: url, options: .atomic)
        var ok = false
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(250))
            if parked() { ok = true; break }
        }
        try? fm.removeItem(at: url)
        check(ok, "shotwatch desktop PNG parks in Harbor")
    }

    /// Quarantine enforcement: every probe artifact matches a known prefix;
    /// this mode removes them from the live inbox. Harbor dead-entries prune
    /// themselves on the next app launch (resolve fails) — relaunch Notcher
    /// after cleanup to finish. Run this after every storm/sendfile/taptest.
    static func cleanup() {
        let inbox = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Notcher Inbox", isDirectory: true)
        let patterns = ["Note from Probe", "notcher-probe-note", "Notcher probe tap"]
        var removed = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
            for u in files where patterns.contains(where: { u.lastPathComponent.hasPrefix($0) }) {
                if (try? FileManager.default.removeItem(at: u)) != nil { removed += 1 }
            }
        }
        print("cleanup removed \(removed) probe file(s); relaunch Notcher to prune Harbor")
    }

    // MARK: - Shared: reach the live app

    static func liveCode() -> String? {
        CFPreferencesCopyAppValue("link.code" as CFString, "dev.notcher.Notcher" as CFString) as? String
    }

    static func browseEndpoint(timeout: TimeInterval = 12) async -> NWEndpoint? {
        final class Box: @unchecked Sendable { var endpoint: NWEndpoint? }
        let box = Box()
        let browser = NWBrowser(for: .bonjour(type: LinkProtocol.serviceType, domain: nil),
                                using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { results, _ in
            if box.endpoint == nil, let first = results.first {
                box.endpoint = first.endpoint
            }
        }
        browser.start(queue: DispatchQueue.global())
        defer { browser.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.endpoint != nil { return box.endpoint }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return box.endpoint
    }

    static func pairedTransport() async -> LinkTransport? {
        guard let code = liveCode(), !code.isEmpty else {
            print("no live pairing code (is Notcher.app running?)")
            return nil
        }
        guard let endpoint = await browseEndpoint() else {
            print("no Bonjour endpoint found")
            return nil
        }
        let t = LinkTransport(deviceName: "Probe", deviceID: "probe-\(UInt32.random(in: 0 ... 99999))",
                              code: { code }, callbackQueue: DispatchQueue(label: "probe"))
        t.connectToEndpoint(endpoint)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !t.connectedPeers.isEmpty { return t }
            try? await Task.sleep(for: .milliseconds(150))
        }
        print("pairing timed out (wrong code?)")
        t.stop()
        return nil
    }

    // MARK: - storm: burst of real traffic at the live island

    static func storm() async {
        guard let t = await pairedTransport() else { check(false, "storm paired"); return }
        defer { t.stop() }
        check(true, "storm paired")
        for i in 0 ..< 30 {
            var m = LinkMessage(kind: .textPush, deviceName: "Probe", deviceID: "probe")
            m.text = "burst \(i)"
            t.broadcast(m)
            try? await Task.sleep(for: .milliseconds(150))
        }
        for _ in 0 ..< 10 {
            var m = LinkMessage(kind: .timerState, deviceName: "Probe", deviceID: "probe")
            m.seconds = 42; m.total = 60; m.label = "Probe"
            t.broadcast(m)
            try? await Task.sleep(for: .milliseconds(200))
        }
        var start = LinkMessage(kind: .timerStart, deviceName: "Probe", deviceID: "probe")
        start.seconds = 45; start.label = "Probe"
        t.broadcast(start)
        try? await Task.sleep(for: .seconds(3))
        t.broadcast(LinkMessage(kind: .timerCancel, deviceName: "Probe", deviceID: "probe"))
        try? await Task.sleep(for: .seconds(1))
        print("storm sent (watch the island: flashes must queue, never overlap-jitter)")
    }

    // MARK: - sendfile: one small labeled file, end to end

    static func sendfile() async {
        guard let t = await pairedTransport() else { check(false, "sendfile paired"); return }
        defer { t.stop() }
        let url = URL(fileURLWithPath: "/tmp/notcher-probe-note.txt")
        let body = "Notcher probe file — safe to delete. If this arrived, Mac receive → Harbor → flash works end to end.\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        guard let data = try? Data(contentsOf: url) else { check(false, "sendfile read"); return }
        for m in LinkChunker.pack(data: data, fileName: url.lastPathComponent,
                                  deviceName: "Probe", deviceID: "probe")
        {
            t.broadcast(m)
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .seconds(2))
        print("sendfile sent (check ~/Downloads/Notcher Inbox + Harbor + flash)")
    }

    // MARK: - samplesteady: is the live window still when it should be?

    static func samplesteady(pid: Int32, seconds: Double) {
        // Known island windows: the FIXED canvas + the expanded-only scrim
        // (morphs happen inside the canvas; neither window ever resizes).
        let known: [(CGFloat, CGFloat)] = [(440, 594), (620, 620)]
        func knownSize(_ w: CGFloat, _ h: CGFloat) -> Bool {
            known.contains { abs($0.0 - w) <= 2 && abs($0.1 - h) <= 2 }
        }
        func islandFrame() -> CGRect? {
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
            else { return nil }
            var best: CGRect?
            for w in list {
                guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let bw = b["Width"], let bh = b["Height"], bw >= 200
                else { continue }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: bw, height: bh)
                if best == nil || r.minY < best!.minY { best = r }
            }
            return best
        }
        var sizes: [String] = []
        var unknown = 0
        var contentHeights: [CGFloat] = []
        var contentSamples = 0
        let interval = 1.0 / 60.0
        let end = Date().addingTimeInterval(seconds)
        // Settle grace: ignore the first second (an animation may be mid-flight).
        let graceEnd = Date().addingTimeInterval(1.0)
        while Date() < end {
            let t0 = Date()
            if let f = islandFrame() {
                let key = "\(Int(f.width.rounded()))x\(Int(f.height.rounded()))"
                sizes.append(key)
                if Date() > graceEnd, !knownSize(f.width, f.height) {
                    unknown += 1
                    print("off-size frame: \(f)")
                }
            }
            // Content-extent stability (every ~0.5 s): the shape must not
            // breathe when idle. Captures are ~10 ms; cadence absorbs them.
            contentSamples += 1
            if contentSamples % 30 == 0, Date() > graceEnd,
               let c = canvasContent(pid: pid)
            {
                contentHeights.append(c.height)
            }
            Thread.sleep(forTimeInterval: max(0, interval - Date().timeIntervalSince(t0)))
        }
        var hist: [String: Int] = [:]
        for s in sizes { hist[s, default: 0] += 1 }
        print("samples=\(sizes.count) histogram=\(hist.sorted { $0.value > $1.value })")
        check(!sizes.isEmpty, "samplesteady saw the window")
        check(unknown == 0, "samplesteady steady-state frames all known (\(unknown) off-size)")
        if contentHeights.count >= 2 {
            let spread = (contentHeights.max() ?? 0) - (contentHeights.min() ?? 0)
            print("content heights: \(contentHeights.map { Int($0) }) spread=\(String(format: "%.1f", spread))pt")
            // A present user (parked cursor) legitimately expands/collapses
            // the island; what must NOT happen is oscillation. Count cluster
            // transitions (compact <200pt vs expanded >400pt) instead.
            var transitions = 0
            var wasExpanded: Bool?
            for h in contentHeights {
                let expanded = h > 400
                if let prev = wasExpanded, prev != expanded { transitions += 1 }
                wasExpanded = expanded
            }
            check(transitions <= 6, "samplesteady no content oscillation (\(transitions) transitions)")
        }
    }

    // MARK: - App-support backup (stress/persistence must not eat user state)

    static func supportDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Notcher", isDirectory: true)
    }

    struct SupportBackup {
        var files: [String: Data] = [:]
        var missing: Set<String> = []
    }

    static func backupSupport() -> SupportBackup {
        var backup = SupportBackup()
        for name in ["timer.json", "harbor.json"] {
            let url = supportDir().appendingPathComponent(name)
            // NB: dict subscript assignment with nil REMOVES the key, so
            // absence is tracked explicitly — otherwise restore() cannot tell
            // "was missing" from "was never backed up".
            if let data = try? Data(contentsOf: url) {
                backup.files[name] = data
            } else {
                backup.missing.insert(name)
            }
        }
        return backup
    }

    static func restoreSupport(_ saved: SupportBackup) {
        for (name, data) in saved.files {
            try? data.write(to: supportDir().appendingPathComponent(name), options: .atomic)
        }
        for name in saved.missing {
            try? FileManager.default.removeItem(at: supportDir().appendingPathComponent(name))
        }
    }

    // MARK: - stress + persistence (SYNC, main thread, real runloop)

    /// Sync MainActor driver. Runs on the real main thread (via
    /// MainActor.assumeIsolated at entry) with real RunLoop pumps — the same
    /// environment the app enjoys via NSApp.run, which a Task-based CLI
    /// cannot faithfully reproduce (see RECORD "harness lessons").
    @MainActor
    enum StressSync {
        static func check(_ cond: Bool, _ name: String) {
            if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); Probe.failures += 1 }
        }

        /// Regression for the full-flash spam defect: two consecutive
        /// >=99.5 % charging polls must emit exactly one `.full`.
        static func runPowerEdge() {
            var s = PowerEngine.EdgeState()
            let full = PowerEngine.Snapshot(percent: 100, charging: true)
            let first = PowerEngine.edgeEvents(info: full, state: &s)
            let second = PowerEngine.edgeEvents(info: full, state: &s)
            check(first == [.full] && second.isEmpty,
                  "poweredge full latches (1 event across 2 polls)")
            _ = PowerEngine.edgeEvents(info: PowerEngine.Snapshot(percent: 100, charging: false), state: &s)
            // Replug correctly emits chargingStarted AND exactly one full.
            check(PowerEngine.edgeEvents(info: full, state: &s) == [.chargingStarted, .full],
                  "poweredge latch resets on disconnect")
            _ = PowerEngine.edgeEvents(info: PowerEngine.Snapshot(percent: 94, charging: true), state: &s)
            check(PowerEngine.edgeEvents(info: full, state: &s) == [.full],
                  "poweredge latch resets below 95%")
            var s2 = PowerEngine.EdgeState()
            let low1 = PowerEngine.edgeEvents(info: PowerEngine.Snapshot(percent: 15, charging: false), state: &s2)
            let low2 = PowerEngine.edgeEvents(info: PowerEngine.Snapshot(percent: 15, charging: false), state: &s2)
            check(low1 == [.low] && low2.isEmpty, "poweredge low latches")
        }

        static func pump(_ s: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(s))
        }

        static func nap(_ s: TimeInterval) {
            Thread.sleep(forTimeInterval: s)
        }

        static func runStress() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            print("stress: app ready")
            let saved = Probe.backupSupport()
            defer { Probe.restoreSupport(saved) }

            let island = IslandState()
            let timer = TimerEngine()
            timer.permissionPromptEnabled = false
            let media = MediaEngine()
            let power = PowerEngine()
            _ = power
            let harbor = HarborStore()
            let link = LinkHost()
        let center = ExternalCenter()
            link.attach(timer: timer, harbor: harbor, island: island)

            let clipboard = ClipboardEngine()
            let hudEngine = HudEngine()
            let privacy = PrivacyWatch()
            let root = IslandRootView(island: island, timer: timer, media: media, power: power,
                                      harbor: harbor, link: link, center: center,
                                      clipboard: clipboard, hudEngine: hudEngine,
                                      privacy: privacy,
                                      layout: NotchGeometry.layout(for: NSScreen.main!),
                                      onDropFiles: { _ in })
            let ctl = IslandController()
            ctl.setRoot(root)
            // Mirror of the app's refreshWindow wiring (minus coalescing —
            // here every publication hits present() directly; the morph
            // itself lives in SwiftUI inside the fixed canvas window).
            var bag = Set<AnyCancellable>()
            func presentForMode() {
                ctl.present(metrics: island.surfaceMetrics(layout: ctl.notchLayout),
                            expanded: island.mode == .expanded,
                            allowKey: island.mode == .expanded)
            }
            island.$mode.sink { _ in presentForMode() }.store(in: &bag)
            island.$activity.sink { _ in presentForMode() }.store(in: &bag)
            island.$flash.sink { _ in presentForMode() }.store(in: &bag)
            presentForMode()
            print("stress: controller ok")
            _ = bag

            // 1. Priority truth table under 200 rapid oscillations.
            // Priority: timer › transfer › remoteTimer › media › external › none.
            var truthOK = true
            for i in 0 ..< 200 {
                let ta = i % 2 == 0, tr = i % 3 == 0, re = i % 7 == 0, me = i % 5 == 0, ex = i % 11 == 0
                island.resolve(timerActive: ta, transferActive: tr, remoteTimerActive: re, mediaPlaying: me, externalActive: ex)
                let expect: IslandState.Activity =
                    ta ? .timer : (tr ? .transfer : (re ? .remoteTimer : (me ? .media : (ex ? .external : .none))))
                if island.activity != expect { truthOK = false; break }
            }
            check(truthOK, "stress priority truth table x200")
            island.resolve(timerActive: false, transferActive: false, remoteTimerActive: false, mediaPlaying: false, externalActive: false)
            pump(0.6)

            // 2. Flash bursts (overlapping cancellation).
            for i in 0 ..< 30 {
                island.showFlash(icon: "bolt.fill", text: "burst \(i)", seconds: 0.4)
            }
            pump(1.0)
            check(island.flash == nil, "stress flash bursts settle")

            // 3. Hover enter/exit spam — the oscillation probe.
            for _ in 0 ..< 40 {
                island.hoverEntered()
                nap(0.02)
                island.hoverExited()
                nap(0.02)
            }
            pump(1.2)
            check(island.mode == .idle || island.mode == .compact,
                  "stress hover spam settles (no stuck expanded)")

            // 4. Pin toggling.
            for _ in 0 ..< 10 { island.togglePin() }
            check(island.mode == .idle, "stress even pin toggles return to idle")
            pump(0.6)

            // 5. Real timer engine cycle.
            timer.start(seconds: 3600, label: "Stress")
            timer.pause()
            timer.resume()
            timer.cancel()
            check(timer.state == .idle, "stress timer start/pause/resume/cancel")

            // 6. Drop-target glow toggling.
            for i in 0 ..< 10 { island.setDropTarget(i % 2 == 0) }
            island.setDropTarget(false)
            check(true, "stress drop-target toggles")

            // 7. Screen-params storm mid-run.
            for _ in 0 ..< 5 {
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
                nap(0.05)
            }
            pump(0.8)
            check(true, "stress screen-params storm survived")

            // 8. Real Harbor round-trip with real files.
            var harborOK = false
            do {
                var urls: [URL] = []
                for i in 0 ..< 3 {
                    let u = URL(fileURLWithPath: "/tmp/probe-harbor-\(i).txt")
                    try "probe \(i)".write(to: u, atomically: true, encoding: .utf8)
                    urls.append(u)
                }
                let added = harbor.add(urls: urls)
                var resolved = 0
                for it in harbor.items {
                    if harbor.resolve(it) != nil { resolved += 1 }
                    harbor.remove(id: it.id)
                }
                harborOK = (added == 3 && resolved == 3)
                for u in urls { try? FileManager.default.removeItem(at: u) }
            } catch { harborOK = false }
            check(harborOK, "stress harbor add/resolve/remove x3")

            // 9. Live 3-second timer through done → flash → recede.
            // (Mirrors the app coordinator: done surfaces as a flash.)
            var fired = false
            timer.onFinished = {
                fired = true
                island.showFlash(icon: "checkmark.circle.fill", text: "Probe — done", seconds: 6)
            }
            timer.start(seconds: 3, label: "Probe")
            pump(5.0)
            check(fired, "stress live 3s timer fired")
            check(island.flash != nil || island.mode != .idle, "stress done path surfaced")
            pump(8.0)

            // 10. Frame settle tail: sample the real panel directly.
            var changes = 0
            var last = ctl.panel.frame
            for _ in 0 ..< 120 {
                nap(0.016)
                let f = ctl.panel.frame
                if !f.equalTo(last) { changes += 1; last = f }
            }
            print("presentCalls=\(ctl.presentCalls) tailFrameChanges=\(changes)")
            // v2: the window frame is FIXED (morphs happen inside SwiftUI),
            // so the steady tail must be literally zero-change.
            check(changes == 0, "stress steady tail frames stable (\(changes) changes)")
        }

        /// Regression for the accumulated-suffix defect: repeated collisions
        /// must count from the original stem ("a 2.ext", "a 3.ext").
        static func runNaming() {
            func name(_ base: String, taken: Set<String>) -> String {
                LinkHost.uniqueFilename(name: base, exists: { taken.contains($0) })
            }
            check(name("a.txt", taken: []) == "a.txt", "naming no collision")
            check(name("a.txt", taken: ["a.txt"]) == "a 2.txt", "naming first collision")
            check(name("a.txt", taken: ["a.txt", "a 2.txt"]) == "a 3.txt",
                  "naming counts from stem, never accumulates")
            check(name("note", taken: ["note"]) == "note 2", "naming extensionless")
            check(name("a.b.txt", taken: ["a.b.txt"]) == "a.b 2.txt", "naming multi-dot stem")
        }

        /// Shaped hit-testing table: the hit container's contract, asserted
        /// against the same path the renderer draws (top-left origin).
        static func runHitTest() {
            let size = IslandMetrics.canvasSize // 440 x 594
            // Mirrors compactSlab on this Mac's notch: chin covers housing,
            // body blooms below.
            let slab = IslandMetrics(width: 344, chinH: 32, chinW: 203,
                                     shoulder: 20, bodyH: 48, corner: 24)
            let bodyMid = CGPoint(x: 220, y: 32 + 20 + 24)
            check(IslandMetrics.hitTest(bodyMid, in: size, m: slab), "hittest body center hits")
            check(IslandMetrics.hitTest(CGPoint(x: 220, y: 16), in: size, m: slab),
                  "hittest chin covers housing")
            check(!IslandMetrics.hitTest(CGPoint(x: 10, y: 500), in: size, m: slab),
                  "hittest far corner misses")
            check(!IslandMetrics.hitTest(CGPoint(x: 20, y: 40), in: size, m: slab),
                  "hittest beside chin misses")
            // Body right edge: dx=(440-344)/2=48, right=392, mid-body y=76.
            check(!IslandMetrics.hitTest(CGPoint(x: 395, y: 76), in: size, m: slab),
                  "hittest 3pt outside misses without slop")
            check(IslandMetrics.hitTest(CGPoint(x: 395, y: 76), in: size, m: slab, slop: 6),
                  "hittest slop catches boundary")
            // Idle melt: almost nothing hits.
            let idle = IslandMetrics(width: 251, chinH: 32, chinW: 251,
                                     shoulder: 0, bodyH: 8, corner: 8)
            check(!IslandMetrics.hitTest(CGPoint(x: 220, y: 300), in: size, m: idle),
                  "hittest idle ignores deep canvas")
            check(IslandMetrics.hitTest(CGPoint(x: 220, y: 16), in: size, m: idle),
                  "hittest idle chin still catches notch taps")

            // 2. AppKit view-level hit-test and context menu verification:
            let ctl = IslandController()
            ctl.setRoot(Text("Test Root"))
            ctl.present(metrics: slab, expanded: false, allowKey: false)
            let menu = NSMenu(title: "TestMenu")
            menu.addItem(NSMenuItem(title: "Quit Notcher", action: nil, keyEquivalent: "q"))
            ctl.contextMenuProvider = { menu }

            // Inside slab (top-left y=76 in 594-height canvas -> bottom-left y=518)
            let insidePt = NSPoint(x: 220, y: size.height - (32 + 20 + 24))
            let hitInside = ctl.panel.contentView?.hitTest(insidePt)
            check(hitInside != nil, "hittest inside shape returns view")
            let dummyEvent = NSEvent.mouseEvent(with: .rightMouseDown,
                                                location: insidePt,
                                                modifierFlags: [],
                                                timestamp: 0,
                                                windowNumber: ctl.panel.windowNumber,
                                                context: nil,
                                                eventNumber: 0,
                                                clickCount: 1,
                                                pressure: 1.0)
            let menuReturned = hitInside?.menu(for: dummyEvent ?? NSEvent())
            check(menuReturned?.items.first?.title == "Quit Notcher", "hittest right-click menu resolved")

            // Outside shape (bottom-left y=100 in 594-height canvas)
            let outsidePt = NSPoint(x: 10, y: 100)
            let hitOutside = ctl.panel.contentView?.hitTest(outsidePt)
            check(hitOutside == nil, "hittest outside shape returns nil view")
            ctl.tearDown()
        }

        /// New-sensor coverage (0.5.0 surfaces): clipboard acceptance table +
        /// live round-trip with pasteboard save/restore, HUD read-only paths,
        /// brightness-unsupported fallback, privacy readers, artwork cache.
        static func runSensors() {
            // 1. Acceptance table (pure).
            check(ClipboardEngine.shouldCapture(text: nil, lastText: "", secondsSinceLast: 9) == false,
                  "sensors nil text rejected")
            check(ClipboardEngine.shouldCapture(text: "   \n ", lastText: "", secondsSinceLast: 9) == false,
                  "sensors blank text rejected")
            check(ClipboardEngine.shouldCapture(text: "hello", lastText: "", secondsSinceLast: 9) == true,
                  "sensors real text accepted")
            check(ClipboardEngine.shouldCapture(text: "x", lastText: "x", secondsSinceLast: 0.1) == false,
                  "sensors machine double-copy deduped")
            check(ClipboardEngine.shouldCapture(text: "x", lastText: "x", secondsSinceLast: 5) == true,
                  "sensors genuine re-copy accepted")
            // 2. Live round-trip: save the user's clipboard, capture a probe
            // string end to end, then restore byte-for-byte.
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            let engine = ClipboardEngine()
            engine.setEnabled(true)
            pb.declareTypes([.string], owner: nil)
            pb.setString("notcher-probe-clip", forType: .string)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let captured = engine.entries.first?.text == "notcher-probe-clip"
            engine.setEnabled(false)
            let cleared = engine.entries.isEmpty
            pb.declareTypes([.string], owner: nil)
            if let saved { pb.setString(saved, forType: .string) }
            check(captured, "sensors live clipboard capture")
            check(cleared, "sensors disable clears memory")
            check(pb.string(forType: .string) == saved, "sensors clipboard restored")
            // 3. HUD read-only paths (never touch the user's volume).
            let hud = HudEngine()
            check((0...1).contains(hud.volume), "sensors volume in range (\(hud.volume))")
            check(hud.brightnessSupported == false && HudEngine.readBrightness() == nil,
                  "sensors brightness unsupported here (honest fallback)")
            // 4. Privacy readers run without crashing; record, don't assert
            // state (the user may legitimately be on a call).
            let cam = PrivacyWatch.cameraInUse()
            let mic = PrivacyWatch.micInUse()
            print("sensors privacy now: camera=\(cam) mic=\(mic)")
            check(true, "sensors privacy readers execute")
            // 5. Artwork cache round-trip.
            let url = URL(string: "https://example.invalid/a.jpg")!
            let img = NSImage(size: NSSize(width: 4, height: 4))
            ArtworkCache.shared[url] = img
            check(ArtworkCache.shared[url] != nil, "sensors artwork cache round-trip")
            ArtworkCache.shared[url] = nil
        }

        /// First-run decision matrix: translocated always guides (even repeat launches), normal first launch plays the overture once, afterwards silence.
        static func runFirstRun() {
            check(FirstRun.plan(translocated: false, didRun: false) == .overture,
                  "firstrun fresh launch plays overture")
            check(FirstRun.plan(translocated: false, didRun: true) == nil,
                  "firstrun repeat launch silent")
            check(FirstRun.plan(translocated: true, didRun: false) == .translocatedTray,
                  "firstrun translocated guides")
            check(FirstRun.plan(translocated: true, didRun: true) == .translocatedTray,
                  "firstrun translocated guides every time")
            check(FirstRun.isTranslocated(bundlePath: "/Applications/Notcher.app") == false,
                  "firstrun normal path not translocated")
            check(FirstRun.isTranslocated(bundlePath: "/private/var/folders/xx/T/AppTranslocation/yy/d/Notcher.app") == true,
                  "firstrun translocation path detected")
        }

        /// Godmode overture: beat machine (counts, order, durations),
        /// manual walk, cancel path, reduce-motion variant, live timed run.
        static func runGodmode() {
            // 1. Structure: beats and durations cohere.
            let ov = Overture(reduceMotion: false)
            check(ov.count == 6, "godmode full beat count (\(ov.count))")
            check(ov.beats.first == .melt && ov.beats.last == .recede,
                  "godmode opens with melt, closes with recede")
            check(ov.durations.count == ov.count, "godmode every beat has a duration")
            // 2. Manual advance visits every beat in order, then finishes.
            var seen: [Overture.Beat] = []
            var guard_ = 0
            while ov.advance(), guard_ < 20 {
                guard_ += 1
                seen.append(ov.beats[ov.beatIndex])
            }
            check(ov.finished && seen.count == ov.count - 1 && !ov.advance(),
                  "godmode manual walk completes (\(seen.count) steps)")
            // 3. Cancel path fires onDone exactly once and finishes.
            let ov2 = Overture(reduceMotion: false)
            var doneCount = 0
            ov2.onDone = { doneCount += 1 }
            _ = ov2.advance(); _ = ov2.advance()
            ov2.cancel()
            ov2.cancel()
            check(ov2.finished && doneCount == 1, "godmode cancel finishes once")
            // 4. Reduce-motion variant: melt → greet → recede.
            let ovr = Overture(reduceMotion: true)
            check(ovr.count == 3 && ovr.beats.first == .melt && ovr.beats.last == .recede,
                  "godmode reduced variant coherent")
            // 5. Live timed run: real timers to completion (~5 s).
            let ov3 = Overture(reduceMotion: false)
            var liveDone = false
            ov3.onDone = { liveDone = true }
            ov3.start()
            RunLoop.main.run(until: Date().addingTimeInterval(5.5))
            check(liveDone && ov3.finished, "godmode live run completes on schedule")
        }

        /// Overlap sovereignty: scrim lifecycle + compositor z-order against
        /// synthetic crowders at levels 20 / 25 / 27 near the notch. Crowders
        /// are real windows (documented as synthetic — no crowder app is
        /// installed here); the order assertions query the live compositor.
        static func runOverlap() {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let island = IslandState()
            let timer = TimerEngine()
            timer.permissionPromptEnabled = false
            let media = MediaEngine()
            let power = PowerEngine()
            _ = power
            let harbor = HarborStore()
            let link = LinkHost()
            link.attach(timer: timer, harbor: harbor, island: island)
            let center = ExternalCenter()
            let clipboard = ClipboardEngine()
            let hudEngine = HudEngine()
            let privacy = PrivacyWatch()
            let root = IslandRootView(island: island, timer: timer, media: media, power: power,
                                      harbor: harbor, link: link, center: center,
                                      clipboard: clipboard, hudEngine: hudEngine,
                                      privacy: privacy,
                                      layout: NotchGeometry.layout(for: NSScreen.main!),
                                      onDropFiles: { _ in })
            let ctl = IslandController()
            ctl.setRoot(root)
            func presentMode(_ m: IslandState.Mode) {
                island.mode = m
                ctl.present(metrics: island.surfaceMetrics(layout: ctl.notchLayout),
                            expanded: m == .expanded, allowKey: m == .expanded)
            }

            func crowder(level: Int) -> NSWindow {
                let w = NSWindow(contentRect: NSRect(x: 585, y: 876, width: 300, height: 60),
                                 styleMask: .borderless, backing: .buffered, defer: false)
                w.backgroundColor = NSColor.systemRed.withAlphaComponent(0.5)
                w.level = NSWindow.Level(rawValue: level)
                w.orderFrontRegardless()
                return w
            }

            func layerOf(_ id: CGWindowID) -> Int? {
                guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                    as? [[String: Any]]
                else { return nil }
                for w in list {
                    if (w[kCGWindowNumber as String] as? CGWindowID) == id {
                        return w[kCGWindowLayer as String] as? Int
                    }
                }
                return nil
            }

            func belowIsland(_ id: CGWindowID) -> [CGWindowID] {
                guard let list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], id)
                    as? [[String: Any]]
                else { return [] }
                return list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            }

            func aboveIsland(_ id: CGWindowID) -> [CGWindowID] {
                guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], id)
                    as? [[String: Any]]
                else { return [] }
                return list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            }

            let islandID = CGWindowID(ctl.panel.windowNumber)
            // 1. Scrim lifecycle follows expanded mode.
            presentMode(.idle)
            check(!ctl.isScrimVisible, "overlap scrim hidden at idle")
            presentMode(.expanded)
            check(ctl.isScrimVisible, "overlap scrim shows with tray")
            presentMode(.compact)
            check(!ctl.isScrimVisible, "overlap scrim hides on collapse")
            // 2. Level audit: island reports 26.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            check(layerOf(islandID) == 26, "overlap island layer is 26")
            // 3. Live z-order vs crowders.
            let low = crowder(level: 20)
            let mid = crowder(level: 25)
            let high = crowder(level: 27)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let lowID = CGWindowID(low.windowNumber)
            let midID = CGWindowID(mid.windowNumber)
            let highID = CGWindowID(high.windowNumber)
            let below = belowIsland(islandID)
            let above = aboveIsland(islandID)
            check(below.contains(lowID) && below.contains(midID),
                  "overlap level-20/25 crowders composite below island")
            check(above.contains(highID) && !below.contains(highID),
                  "overlap level-27 crowder above island (expected, documented)")
            low.orderOut(nil); mid.orderOut(nil); high.orderOut(nil)
        }

        /// IslandKit consent/TTL/eviction/priority/revocation table — pure
        /// store, no UI, deterministic clock.
        static func runExternal() {
            let t0 = Date()
            func act(_ id: String, _ source: String, _ priority: ExternalActivity.Priority = .normal, ttl: TimeInterval = 120) -> ExternalActivity {
                ExternalActivity(id: id, source: source, title: "T " + id, priority: priority, ttl: ttl, now: t0)
            }
            // 1. Unknown source parks in consent, shows nothing.
            var s = ExternalStore()
            let d1 = s.submit(act("a", "Chef"), now: t0)
            check(d1 == .pendingConsent(firstSeen: true) && s.visible(now: t0) == nil,
                  "external first push pends, shows nothing")
            // 2. Repeat push does not duplicate the card.
            let d2 = s.submit(act("b", "Chef"), now: t0.addingTimeInterval(1))
            check(d2 == .pendingConsent(firstSeen: false) && s.pending.count == 1,
                  "external repeat push collapses to one card")
            // 3. Approve shows the first activity.
            s.approve(identityKey: "source:Chef")
            check(s.visible(now: t0)?.id == "a", "external approve reveals")
            // 4. Priority class beats recency; recency breaks ties.
            s.submit(act("low-new", "Chef", .low), now: t0.addingTimeInterval(2))
            s.submit(act("high-old", "Ops", .high), now: t0.addingTimeInterval(2))
            var s2 = s
            s2.grants["source:Ops"] = true
            s2.submit(act("high-old", "Ops", .high), now: t0.addingTimeInterval(3))
            check(s2.visible(now: t0)?.id == "high-old", "external priority beats recency")
            // 5. TTL expiry recedes.
            var s3 = ExternalStore(grants: ["source:X": true])
            s3.submit(act("tmp", "X", .high, ttl: 5), now: t0)
            check(s3.visible(now: t0) != nil && s3.visible(now: t0.addingTimeInterval(6)) == nil,
                  "external TTL expiry recedes")
            // 6. Flood eviction: 12 ids, cap 8, highs retained.
            var s4 = ExternalStore(grants: ["source:F": true])
            for i in 0 ..< 10 {
                s4.submit(act("low-\(i)", "F", .low), now: t0.addingTimeInterval(Double(i) + 1))
            }
            s4.grants["source:G"] = true
            s4.submit(act("hi", "G", .high), now: t0.addingTimeInterval(20))
            check(s4.activities.count == 8 && s4.activities["hi"] != nil,
                  "external flood evicts oldest-lowest, keeps high")
            // 7. Rate limit: same-instant resubmit drops.
            var s5 = ExternalStore(grants: ["source:R": true])
            let r1 = s5.submit(act("x", "R"), now: t0)
            let r2 = s5.submit(act("x", "R"), now: t0)
            check((r1 == .shown || r1 == .updated) && r2 == .droppedRateLimited,
                  "external same-instant resubmit rate-limited")
            // 8. Deny drops; revoke removes live activities too.
            var s6 = ExternalStore()
            s6.deny(identityKey: "source:Nope")
            check(s6.submit(act("z", "Nope"), now: t0) == .droppedDenied, "external deny drops")
            var s7 = ExternalStore(grants: ["source:Q": true])
            s7.submit(act("q", "Q"), now: t0)
            s7.revoke(identityKey: "source:Q")
            check(s7.visible(now: t0) == nil && s7.grants["source:Q"] == false,
                  "external revoke removes live activity")
        }

        /// IslandKit v2 socket: real loopback client against a live server —
        /// consent gate, streaming, malformed-line survival, clear.
        /// Waits pump the main runloop (never block it: the intent hop needs
        /// the MainActor, which lives on this thread).
        static func runSocket() {
            // Fresh-install path every run: ExternalCenter persists grants to
            // UserDefaults, so snapshot and clear them first (a previous run's
            // approval would otherwise make step 1 show instead of pend).
            let d = UserDefaults.standard
            let savedGrants = d.dictionary(forKey: "external.grants")
            let savedNames = d.dictionary(forKey: "external.names")
            d.removeObject(forKey: "external.grants")
            d.removeObject(forKey: "external.names")
            defer {
                if let g = savedGrants { d.set(g, forKey: "external.grants") }
                if let n = savedNames { d.set(n, forKey: "external.names") }
            }
            final class Inbox: @unchecked Sendable {
                var text = ""
                let lock = NSLock()
                func append(_ s: String) { lock.withLock { text += s } }
                func takeLines() -> [String] {
                    lock.withLock {
                        let parts = text.components(separatedBy: "\n")
                        if parts.count <= 1 { return [] }
                        text = parts.last ?? ""
                        return Array(parts.dropLast())
                    }
                }
            }
            let center = ExternalCenter()
            let server = SocketServer()
            server.onIntent = { intent in
                Task { @MainActor in
                    switch intent {
                    case .push(let a): center.submit(a)
                    case .clearID(let id): center.clear(id: id)
                    case .clearSender(let p): center.clearMatching(prefix: p)
                    }
                }
            }
            server.start()
            var up = false
            for _ in 0 ..< 40 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if server.isRunning { up = true; break }
            }
            check(up, "socket server binds loopback")
            guard up else { server.stop(); return }

            let inbox = Inbox()
            let conn = NWConnection(host: "127.0.0.1",
                                    port: NWEndpoint.Port(rawValue: SocketServer.port)!,
                                    using: .tcp)
            // Recursive drain helper as a small object: a nested func would
            // inherit MainActor isolation and be uncallable from the
            // @Sendable receive closure.
            final class Drain: @unchecked Sendable {
                let conn: NWConnection
                let inbox: Inbox
                init(_ c: NWConnection, _ i: Inbox) { conn = c; inbox = i }
                func go() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, _ in
                        guard let self else { return }
                        if let data, let s = String(data: data, encoding: .utf8) { self.inbox.append(s) }
                        if !isDone { self.go() }
                    }
                }
            }
            let drain = Drain(conn, inbox)
            let queue = DispatchQueue(label: "probe.socket")
            conn.stateUpdateHandler = { state in
                if case .ready = state { drain.go() }
            }
            conn.start(queue: queue)
            func send(_ line: String) {
                conn.send(content: Data((line + "\n").utf8), completion: .idempotent)
            }
            func waitReply(_ want: String, timeout: TimeInterval = 3) -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    if inbox.takeLines().contains(where: { $0.contains(want) }) { return true }
                }
                return false
            }
            // 1. Unknown source: accepted at the socket, pends at consent.
            send(#"{"op":"push","id":"s1","source":"SockTest","title":"Hello"}"#)
            check(waitReply(#""ok":true"#) && center.pending.count == 1 && center.visible == nil,
                  "socket first push pends consent")
            // 2. Approve, push again: visible.
            center.approve(identityKey: "source:SockTest")
            send(#"{"op":"push","id":"s1","source":"SockTest","title":"Hello"}"#)
            check(waitReply(#""ok":true"#) && center.visible?.title == "Hello",
                  "socket approved push shows")
            // 3. Malformed line: rejected, connection survives.
            send("this is not json")
            let survived = waitReply(#""ok":false"#)
            send(#"{"op":"push","id":"s2","source":"SockTest","title":"Again"}"#)
            check(survived && waitReply(#""ok":true"#), "socket malformed rejected, stream survives")
            // 4. Clear one id.
            send(#"{"op":"clear","id":"s1","source":"SockTest"}"#)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            check(center.visible?.title == "Again", "socket clear removes one id")
            conn.cancel()
            server.stop()
        }

        static func runPersistence() {
            let saved = Probe.backupSupport()
            defer { Probe.restoreSupport(saved) }

            func fresh() -> TimerEngine {
                let t = TimerEngine()
                t.permissionPromptEnabled = false
                return t
            }
            // (a) paused timer survives with remaining intact.
            let t1 = fresh()
            t1.start(seconds: 3600, label: "Persist")
            t1.pause()
            let t2 = fresh()
            check(t2.state == .paused && abs(t2.remaining - 3600) < 30 && t2.label == "Persist",
                  "persistence paused round-trip (state=\(t2.state) remaining=\(Int(t2.remaining)))")

            // (b) running timer restores running with a live deadline.
            t1.start(seconds: 3600, label: "Run")
            let t3 = fresh()
            check(t3.state == .running && t3.remaining > 3500, "persistence running round-trip")
            t1.cancel(); t3.cancel()

            // (c) corrupt file -> clean idle, no crash.
            try? "garbage{{{".write(to: Probe.supportDir().appendingPathComponent("timer.json"),
                                    atomically: true, encoding: .utf8)
            check(fresh().state == .idle, "persistence corrupt file -> idle")

            // (d) legacy schema (no remaining field) -> idle, no crash.
            try? #"{"total":60,"label":"Old","state":"paused"}"#.write(
                to: Probe.supportDir().appendingPathComponent("timer.json"),
                atomically: true, encoding: .utf8)
            check(fresh().state == .idle, "persistence legacy schema -> idle")
        }
    }

    // MARK: - taptest: real click in, real Escape out

    /// Posts one synthetic left-click at the island pill (our own window —
    /// nothing else is touched) to prove click-to-expand, then posts Escape
    /// to our own PID to prove key-dismissal. A flash is raised first so the
    /// pill (not the idle blend) is on screen to click.
    static func taptest() async {
        print("taptest AX trusted=\(AXIsProcessTrusted())")
        guard let t = await pairedTransport() else { check(false, "taptest paired"); return }
        defer { t.stop() }
        guard let pid = notchAppPID() else { check(false, "taptest found app"); return }

        var flash = LinkMessage(kind: .textPush, deviceName: "Probe", deviceID: "probe")
        flash.text = "Notcher probe tap"
        t.broadcast(flash)
        try? await Task.sleep(for: .seconds(1))

        // Click the vertical middle of the live content (data-driven: works
        // for wings and slab alike, no hardcoded pill geometry).
        guard var before = canvasContent(pid: pid) else {
            check(false, "taptest photographed island"); return
        }
        if before.height > 300 {
            // Already expanded (e.g. a parked cursor is hovering it):
            // normalize via Escape first so the click tests a real transition.
            postEscape(to: pid)
            try? await Task.sleep(for: .seconds(1))
            guard let reset = canvasContent(pid: pid) else {
                check(false, "taptest re-photographed island"); return
            }
            before = reset
        }
        let midY = before.top + (before.bottom - before.top) / 2
        postClick(at: CGPoint(x: before.midX, y: midY))
        try? await Task.sleep(for: .seconds(1))
        guard let expanded = canvasContent(pid: pid) else {
            check(false, "taptest re-photographed island"); return
        }
        check(expanded.height - before.height > 200,
              "taptest click expands island (content \(before.height)pt -> \(expanded.height)pt)")

        postEscape(to: pid)
        try? await Task.sleep(for: .seconds(1))
        guard let collapsed = canvasContent(pid: pid) else {
            check(false, "taptest photographed collapse"); return
        }
        check(abs(collapsed.height - before.height) < 40,
              "taptest escape collapses island (content \(collapsed.height)pt)")
    }

    /// The island's canvas window, found by owner name (geometry no longer
    /// encodes state under the single-canvas architecture).
    static func notchAppPID() -> Int32? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        for w in list ?? [] {
            if (w[kCGWindowOwnerName as String] as? String) == "Notcher",
               let b = w[kCGWindowBounds as String] as? [String: CGFloat],
               abs((b["Width"] ?? 0) - 440) < 3
            {
                return w[kCGWindowOwnerPID as String] as? Int32
            }
        }
        return nil
    }

    struct CanvasContent {
        var midX: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var height: CGFloat { bottom - top }
    }

    /// Photograph the live canvas and return the vertical span containing
    /// non-transparent content, in screen points. Nil when capture fails.
    static func canvasContent(pid: Int32) -> CanvasContent? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }
        var target: CGWindowID?
        var frame = CGRect.zero
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], abs(bw - 440) < 3,
                  let id = w[kCGWindowNumber as String] as? Int
            else { continue }
            target = CGWindowID(id)
            frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: bw, height: b["Height"] ?? 0)
            break
        }
        guard let id = target,
              let img = CGWindowListCreateImage(CGRect.null, .optionIncludingWindow, id, [.boundsIgnoreFraming]),
              let provider = img.dataProvider,
              let cfdata = provider.data,
              let bytes = CFDataGetBytePtr(cfdata)
        else { return nil }
        let wpx = img.width, hpx = img.height
        let bpr = img.bytesPerRow
        let bpp = img.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        // Alpha channel location from the image's alpha info.
        let alpha = img.alphaInfo
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first
        let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
        guard hasAlpha else { return nil }
        let aOff = alphaFirst ? 0 : bpp - 1
        var top: Int?, bottom: Int?
        for y in 0 ..< hpx {
            var rowMax = 0
            var x = 0
            while x < wpx {
                let a = Int(bytes[y * bpr + x * bpp + aOff])
                if a > rowMax { rowMax = a }
                x += 2 // 2px stride: plenty for extent detection
            }
            if rowMax > 12 {
                if top == nil { top = y }
                bottom = y
            }
        }
        guard let t = top, let btm = bottom else { return nil }
        let scale = CGFloat(wpx) / frame.width
        return CanvasContent(midX: frame.midX,
                             top: frame.minY + CGFloat(t) / scale,
                             bottom: frame.minY + CGFloat(btm) / scale)
    }

    static func postClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.post(tap: .cghidEventTap)
        // A real press has duration; back-to-back post can outrun tracking.
        Thread.sleep(forTimeInterval: 0.06)
        up.post(tap: .cghidEventTap)
    }

    static func postEscape(to pid: Int32) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false)
        else { return }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: - reconnect: kill a session, prove it comes back
    static func reconnect() async {
        func waitHello(_ t: LinkTransport, _ id: String) async -> Bool {
            let box = ReconnectBox()
            t.onMessage = { msg in if msg.kind == .hello { box.got = true } }
            _ = id
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if box.got { return true }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return box.got
        }
        final class ReconnectBox: @unchecked Sendable { var got = false }

        let h1 = LinkTransport(deviceName: "H", deviceID: "h-1", code: { "123456" },
                               callbackQueue: DispatchQueue(label: "r1"))
        let port = try! h1.listenDirect()
        let p1 = LinkTransport(deviceName: "P", deviceID: "p-1", code: { "123456" },
                               callbackQueue: DispatchQueue(label: "r2"))
        p1.connectDirect(port: port)
        check(await waitHello(p1, "p-1"), "reconnect first handshake")
        h1.stop(); p1.stop()
        try? await Task.sleep(for: .seconds(1))

        let h2 = LinkTransport(deviceName: "H", deviceID: "h-1", code: { "123456" },
                               callbackQueue: DispatchQueue(label: "r3"))
        let port2 = try! h2.listenDirect()
        let p2 = LinkTransport(deviceName: "P", deviceID: "p-1", code: { "123456" },
                               callbackQueue: DispatchQueue(label: "r4"))
        p2.connectDirect(port: port2)
        check(await waitHello(p2, "p-1"), "reconnect second handshake after kill")
        h2.stop(); p2.stop()
    }
}
