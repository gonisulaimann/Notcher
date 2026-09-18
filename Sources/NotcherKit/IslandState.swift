import AppKit
import Combine
import Foundation
import SwiftUI

/// The island shows exactly ONE live activity at a time, chosen by priority.
/// This is the core product decision: a shoreline, not a widget pile.
@MainActor
public final class IslandState: ObservableObject {
    public enum Mode: Equatable, Sendable {
        case idle      // thin glow hugging the notch; covers dead space only
        case compact   // one live activity pill (wings or slab, per activity)
        case expanded  // full tray
        case hud       // volume / brightness capsule (auto-recedes)
    }

    /// A transient HUD surface: a small capsule under the housing with one
    /// meter. Value updates IN PLACE (Apple-HUD behavior) — the shape does
    /// not re-morph on each key press, only the bar moves.
    public struct HudContent: Equatable {
        public enum Kind: Equatable, Sendable {
            case volume(muted: Bool)
            case brightness
        }
        public var kind: Kind
        public var value: Double // 0...1
        public init(kind: Kind, value: Double) {
            self.kind = kind
            self.value = min(1, max(0, value))
        }
    }

    public enum Activity: Equatable, Sendable {
        case none
        case timer
        case transfer
        case remoteTimer
        case media
        case external
    }

    /// Transient flashes interrupt the idle state for a few seconds
    /// (power events, link events, timer completion) then recede.
    public struct Flash: Equatable {
        public var id = UUID()
        public var icon: String
        public var text: String
        public static func == (lhs: Flash, rhs: Flash) -> Bool { lhs.id == rhs.id }
    }

    @Published public var mode: Mode = .idle
    @Published public var activity: Activity = .none
    @Published public var flash: Flash?
    @Published public var hud: HudContent?
    @Published public var pinned = false
    /// While the first-run overture is live, this drives the surface beats.
    @Published public var overtureBeat: Overture.Beat?
    @Published public var loginEnabled = false
    /// True while a real file drag hovers the island (drives drop glow).
    @Published public var dropTarget = false
    /// Pointer inside the island window (drives hover light, never layout).
    @Published public var pointerInside = false

    private var flashWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var hoverExitWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var hudResume: Mode = .idle
    public let reduceMotion: Bool

    /// The island's one animation curve — a mass-spring-damper (SwiftUI's
    /// spring is a solved damped harmonic oscillator; response ≈ ω, damping
    /// fraction ≈ ζ). ζ 0.85: critically-damped-plus, one breath of
    /// overshoot, zero wobble; fully interruptible (retargeting mid-flight
    /// continues from current velocity — the definition of fluid).
    /// Reduced Motion keeps a short ease — motion still exists, no bounce.
    public var motionAnimation: Animation {
        reduceMotion ? Animation.easeOut(duration: 0.12)
                     : Animation.spring(response: 0.45, dampingFraction: 0.85)
    }

    /// Content morph curve: crossfade + settle, slightly quicker than the
    /// container morph so text lands as the glass arrives.
    public var contentAnimation: Animation {
        reduceMotion ? Animation.easeOut(duration: 0.1)
                     : Animation.spring(response: 0.32, dampingFraction: 0.88)
    }

    /// HUD meter curve: fast tracking, no bounce (Apple-HUD feel).
    public var hudAnimation: Animation {
        reduceMotion ? Animation.easeOut(duration: 0.08)
                     : Animation.spring(response: 0.24, dampingFraction: 1.0)
    }

    /// The metrics preset for the CURRENT island state. Single source of
    /// truth for both the view (rendering) and the coordinator (shaped
    /// hit-testing) — one pure function, two consumers. The overture
    /// overrides everything while it plays.
    public func surfaceMetrics(layout: NotchGeometry.Layout) -> IslandMetrics {
        if let beat = overtureBeat {
            return IslandMetrics.overture(beat, layout: layout)
        }
        let surface: IslandMetrics.Surface = switch mode {
        case .idle: .idle
        case .compact: .compact
        case .expanded: .expanded
        case .hud: .hud
        }
        return IslandMetrics.metrics(for: surface, layout: layout, activity: activity)
    }

    public init() {
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Re-resolve which single activity owns the pill. Priority:
    /// local timer › transfer › remote (iPhone) timer › media › external.
    /// Third-party activities can never preempt anything alive on this Mac.
    public func resolve(timerActive: Bool, transferActive: Bool, remoteTimerActive: Bool, mediaPlaying: Bool, externalActive: Bool) {
        let next: Activity
        if timerActive { next = .timer }
        else if transferActive { next = .transfer }
        else if remoteTimerActive { next = .remoteTimer }
        else if mediaPlaying { next = .media }
        else if externalActive { next = .external }
        else { next = .none }
        if next != activity {
            IslandDebug.log("activity \(activity) -> \(next)")
            activity = next
        }
        if mode == .compact, next == .none, flash == nil { setMode(.idle, why: "resolve drained") }
        if mode == .idle, next != .none { setMode(.compact, why: "resolve live") }
    }

    private func setMode(_ m: Mode, why: String) {
        if mode == m { return }
        IslandDebug.log("mode \(mode) -> \(m) (\(why))")
        mode = m
    }

    public func showFlash(icon: String, text: String, seconds: TimeInterval = 4) {
        flashWork?.cancel()
        flash = Flash(icon: icon, text: text)
        IslandDebug.log("flash '\(text)'")
        if mode == .idle || mode == .hud { setMode(.compact, why: "flash") }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.flash = nil
                if self.mode == .compact, self.activity == .none, !self.pinned {
                    self.setMode(.idle, why: "flash receded")
                }
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    public func hoverEntered() {
        hoverWork?.cancel()
        hoverExitWork?.cancel()
        guard mode != .expanded else { return }
        let delay: TimeInterval = reduceMotion ? 0 : 0.18
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.mode != .expanded else { return }
                self.setMode(.expanded, why: "hover")
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func hoverExited() {
        hoverWork?.cancel()
        hoverExitWork?.cancel()
        // Hysteresis: the window shrinks under a stationary cursor on
        // collapse, which re-fires exit at the boundary. A short delay —
        // cancelled by any re-enter — breaks the enter/exit oscillation
        // without making dismissal feel laggy.
        guard mode == .expanded, !pinned else { return }
        let delay: TimeInterval = reduceMotion ? 0.05 : 0.28
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.mode == .expanded, !self.pinned else { return }
                self.collapse()
            }
        }
        hoverExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func togglePin() {
        hoverExitWork?.cancel()
        if mode == .expanded {
            if pinned { pinned = false; collapse() }
            else { pinned = true }
        } else {
            pinned = true
            setMode(.expanded, why: "pin")
        }
    }

    /// Explicit, unpinned reveal (menu-bar action). Logged like hover so the
    /// debug trace distinguishes user intent from pointer intent.
    public func presentPinned() {
        hoverExitWork?.cancel()
        pinned = true
        setMode(.expanded, why: "menu")
    }

    public func collapse() {
        pinned = false
        if activity == .none, flash == nil { setMode(.idle, why: "collapse drained") }
        else { setMode(.compact, why: "collapse") }
    }

    /// File-drag hover state. Auto-clears so a missed drag-exit (e.g. drop
    /// outside any window) can never leave the glow stuck on.
    public func setDropTarget(_ on: Bool) {
        if dropTarget == on { return }
        dropTarget = on
        if on {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                Task { @MainActor in
                    if self?.dropTarget == true { self?.dropTarget = false }
                }
            }
        }
    }

    // MARK: - HUD surface (volume / brightness)

    /// Show or UPDATE the HUD capsule. Repeated key presses update the value
    /// in place and extend the lifetime — one morph in, N value updates, one
    /// morph out. Never steals focus; ignored while the tray is open.
    public func showHud(_ content: HudContent) {
        guard mode != .expanded else { return }
        hudWork?.cancel()
        if mode != .hud {
            hudResume = mode == .hud ? hudResume : mode
            setMode(.hud, why: "hud")
        }
        hud = content
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.mode == .hud else { return }
                self.hud = nil
                // A flash that arrived mid-HUD takes precedence on exit.
                if self.flash != nil {
                    self.setMode(.compact, why: "hud flash")
                } else if self.hudResume == .expanded {
                    self.setMode(.idle, why: "hud receded")
                } else {
                    // collapse() picks idle when nothing is alive, compact
                    // otherwise — never leaves an empty pill parked.
                    self.collapse()
                }
            }
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    public func refreshLogin() {
        loginEnabled = LaunchAtLogin.enabled
    }

    public func commitLogin(_ on: Bool) {
        try? LaunchAtLogin.set(on)
        loginEnabled = LaunchAtLogin.enabled
    }
}
