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
case "stress", "persistence":
    MainActor.assumeIsolated {
        if probeMode == "stress" { Probe.StressSync.runStress() } else { Probe.StressSync.runPersistence() }
    }
    print(Probe.failures == 0 ? "PROBE DONE, ALL PASS" : "PROBE DONE, \(Probe.failures) FAILURE(S)")
    fflush(stdout)
    exit(Probe.failures == 0 ? 0 : 1)
case "storm", "sendfile", "reconnect", "taptest":
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
    print("usage: NotcherProbe storm|sendfile|samplesteady|stress|persistence|reconnect")
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
        default: break
        }
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
        // Known island sizes (must match IslandController).
        let known: [(CGFloat, CGFloat)] = [(251, 38), (348, 40), (404, 468)]
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
            Thread.sleep(forTimeInterval: max(0, interval - Date().timeIntervalSince(t0)))
        }
        var hist: [String: Int] = [:]
        for s in sizes { hist[s, default: 0] += 1 }
        print("samples=\(sizes.count) histogram=\(hist.sorted { $0.value > $1.value })")
        check(!sizes.isEmpty, "samplesteady saw the window")
        check(unknown == 0, "samplesteady steady-state frames all known (\(unknown) off-size)")
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
            link.attach(timer: timer, harbor: harbor, island: island)

            let root = IslandRootView(island: island, timer: timer, media: media, power: power,
                                      harbor: harbor, link: link,
                                      notchWidth: 179, hasNotch: true, onDropFiles: { _ in })
            let hosting = NSHostingView(rootView: root)
            let ctl = IslandController(content: hosting)
            // Mirror of the app's refreshWindow wiring (minus coalescing —
            // here every publication hits show() directly, which is exactly
            // what the diff guard must absorb).
            var bag = Set<AnyCancellable>()
            func showForMode() {
                switch island.mode {
                case .idle: ctl.show(.idle, allowKey: false, animate: true)
                case .compact: ctl.show(.compact, allowKey: false, animate: true)
                case .expanded: ctl.show(.expanded, allowKey: true, animate: true)
                }
            }
            island.$mode.sink { _ in showForMode() }.store(in: &bag)
            island.$activity.sink { _ in showForMode() }.store(in: &bag)
            island.$flash.sink { _ in showForMode() }.store(in: &bag)
            ctl.show(.idle, allowKey: false, animate: false)
            print("stress: controller ok")
            _ = bag

            // 1. Priority truth table under 200 rapid oscillations.
            var truthOK = true
            for i in 0 ..< 200 {
                let ta = i % 2 == 0, tr = i % 3 == 0, me = i % 5 == 0
                island.resolve(timerActive: ta, transferActive: tr, mediaPlaying: me)
                let expect: IslandState.Activity = ta ? .timer : (tr ? .transfer : (me ? .media : .none))
                if island.activity != expect { truthOK = false; break }
            }
            check(truthOK, "stress priority truth table x200")
            island.resolve(timerActive: false, transferActive: false, mediaPlaying: false)
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
            print("showCalls=\(ctl.showCalls) showNoops=\(ctl.showNoops) tailFrameChanges=\(changes)")
            // Every kind-changing morph must still show; the guard's job is
            // absorbing the redundant same-frame shows (roughly half here,
            // since this harness bypasses the app's coalescing on purpose).
            check(ctl.showNoops >= ctl.showCalls / 2, "stress diff guard absorbs churn")
            check(changes <= 3, "stress steady tail frames stable (\(changes) changes)")
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
        guard let pid = runningAppPID() else { check(false, "taptest found app"); return }

        var flash = LinkMessage(kind: .textPush, deviceName: "Probe", deviceID: "probe")
        flash.text = "tap me"
        t.broadcast(flash)
        try? await Task.sleep(for: .seconds(1))

        postClick(at: CGPoint(x: 735, y: 20)) // island pill, screen coords
        try? await Task.sleep(for: .seconds(1))
        let expanded = islandSize(pid: pid)
        check(expanded == "404x468", "taptest click expands island (got \(expanded ?? "none"))")

        postEscape(to: pid)
        try? await Task.sleep(for: .seconds(1))
        let collapsed = islandSize(pid: pid)
        let ok = collapsed == "348x40" || collapsed == "251x38"
        check(ok, "taptest escape collapses island (got \(collapsed ?? "none"))")
    }

    static func runningAppPID() -> Int32? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        for w in list ?? [] {
            if let pid = w[kCGWindowOwnerPID as String] as? Int32,
               let b = w[kCGWindowBounds as String] as? [String: CGFloat],
               (b["Width"] ?? 0) >= 200, (b["Height"] ?? 0) <= 40,
               pid != getpid()
            {
                return pid
            }
        }
        return nil
    }

    static func islandSize(pid: Int32) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        var best: CGRect?
        for w in list ?? [] {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], let bh = b["Height"], bw >= 200
            else { continue }
            best = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: bw, height: bh)
        }
        guard let f = best else { return nil }
        return "\(Int(f.width.rounded()))x\(Int(f.height.rounded()))"
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
