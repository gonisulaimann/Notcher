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
        case compact   // one live activity pill
        case expanded  // full tray
    }

    public enum Activity: Equatable, Sendable {
        case none
        case timer
        case transfer
        case remoteTimer
        case media
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
    @Published public var pinned = false
    @Published public var loginEnabled = false
    /// True while a real file drag hovers the island (drives drop glow).
    @Published public var dropTarget = false

    private var flashWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var hoverExitWork: DispatchWorkItem?
    public let reduceMotion: Bool

    /// The island's one animation curve. Reduced-motion swaps the spring for
    /// a short ease — the motion still exists, it just stops bouncing.
    public var motionAnimation: Animation {
        reduceMotion ? Animation.easeOut(duration: 0.12)
                     : Animation.spring(response: 0.42, dampingFraction: 0.82)
    }

    public init() {
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Re-resolve which single activity owns the pill. Priority:
    /// local timer › transfer › remote (iPhone) timer › media.
    /// A mirrored iPhone timer is timer-class attention, but never preempts
    /// something happening on this Mac right now.
    public func resolve(timerActive: Bool, transferActive: Bool, remoteTimerActive: Bool, mediaPlaying: Bool) {
        let next: Activity
        if timerActive { next = .timer }
        else if transferActive { next = .transfer }
        else if remoteTimerActive { next = .remoteTimer }
        else if mediaPlaying { next = .media }
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
        if mode == .idle { setMode(.compact, why: "flash") }
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

    public func refreshLogin() {
        loginEnabled = LaunchAtLogin.enabled
    }

    public func commitLogin(_ on: Bool) {
        try? LaunchAtLogin.set(on)
        loginEnabled = LaunchAtLogin.enabled
    }
}
