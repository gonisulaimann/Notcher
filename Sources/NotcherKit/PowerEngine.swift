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

    public enum PowerEvent {
        case chargingStarted
        case full
        case low
    }

    private var poll: Timer?
    private var wasCharging: Bool?
    private var lowNotified = false

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
        let was = wasCharging
        percent = info.percent
        charging = info.charging
        if let was, was != info.charging {
            if info.charging { onEvent?(.chargingStarted) }
        }
        wasCharging = info.charging
        if info.charging, info.percent >= 99.5 { onEvent?(.full) }
        if !info.charging, info.percent <= 20 {
            if !lowNotified { lowNotified = true; onEvent?(.low) }
        } else if info.percent > 25 {
            lowNotified = false
        }
        LinkHostBatteryProvider.battery = info.percent / 100
    }

    public struct Snapshot {
        var percent: Double
        var charging: Bool
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
