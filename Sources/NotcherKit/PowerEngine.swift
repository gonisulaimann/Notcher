import AppKit
import Foundation
import IOKit.ps

/// Battery / power state via public IOKit power-source APIs.
/// Emits edge-triggered events (charging started, full, low) that the island
/// shows as transient flashes — never as a permanent widget.
@MainActor
public final class PowerEngine: ObservableObject {
    @Published public private(set) var percent: Double?
    @Published public private(set) var charging: Bool = false

    public var onEvent: ((PowerEvent) -> Void)?

    public enum PowerEvent: Sendable, Equatable {
        case chargingStarted
        case full
        case low
    }

    /// Edge-decision state. Lives on the engine in production; passed
    /// explicitly so the transition table is unit-testable without IOKit.
    public struct EdgeState: Sendable {
        public var wasCharging: Bool?
        public var lowNotified = false
        public var fullNotified = false
        public init() {}
    }

    private var poll: Timer?
    private var edges = EdgeState()

    public init() {
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(woke(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func woke(_: Notification) { refresh() }

    public func refresh() {
        guard let info = PowerEngine.snapshot() else { return }
        percent = info.percent
        charging = info.charging
        for event in PowerEngine.edgeEvents(info: info, state: &edges) {
            onEvent?(event)
        }
        LinkHostBatteryProvider.battery = info.percent / 100
    }

    /// Pure edge table: level inputs in, at-most-once events out.
    /// - `.full` latches until the charger disconnects or charge drops below
    ///   95 % (without the latch it re-fires on every 30 s poll near 100 %).
    /// - `.low` latches until charge rises above 25 % (pre-existing).
    nonisolated public static func edgeEvents(info: Snapshot, state: inout EdgeState) -> [PowerEvent] {
        var out: [PowerEvent] = []
        if let was = state.wasCharging, was != info.charging {
            if info.charging { out.append(.chargingStarted) }
        }
        state.wasCharging = info.charging
        if info.charging, info.percent >= 99.5 {
            if !state.fullNotified { state.fullNotified = true; out.append(.full) }
        } else if !info.charging || info.percent < 95 {
            state.fullNotified = false
        }
        if !info.charging, info.percent <= 20 {
            if !state.lowNotified { state.lowNotified = true; out.append(.low) }
        } else if info.percent > 25 {
            state.lowNotified = false
        }
        return out
    }

    public struct Snapshot: Sendable {
        public var percent: Double
        public var charging: Bool
        public init(percent: Double, charging: Bool) {
            self.percent = percent
            self.charging = charging
        }
    }

    public static func snapshot() -> Snapshot? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else { return nil }
        var pct = 0.0
        var chg = false
        var n = 0
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0
            {
                pct += Double(cur) / Double(max) * 100
                n += 1
            }
            if let isCharging = desc[kIOPSIsChargingKey as String] as? Bool, isCharging { chg = true }
            if let state = desc[kIOPSPowerSourceStateKey as String] as? String,
               state == kIOPSACPowerValue as String { chg = true }
        }
        guard n > 0 else { return nil }
        return Snapshot(percent: pct / Double(n), charging: chg)
    }
}

/// Set by PowerEngine so LinkCore can stamp battery without importing IOKit.
public enum LinkHostBatteryProvider {
    nonisolated(unsafe) public static var battery: Double?
}
