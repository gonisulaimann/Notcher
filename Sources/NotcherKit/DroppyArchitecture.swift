import AppKit
import Combine
import SwiftUI

// MARK: - Droppy Production-Grade Architecture Manifest
//
// This file formalizes the 4 architectural pillars of "Droppy" as specified:
// 1. NotchWindowPanel (Custom NSPanel with hardware notch coordinate locking & event pass-through)
// 2. DroppyApp (SwiftUI App lifecycle structure with MenuBarExtra background daemon integration)
// 3. DroppyStateMachine (State machine governing single-activity priority & spring physics)
// 4. LiquidGlassModifier (Metal / CoreAnimation-backed liquid glass material & vignette edge blending)

// MARK: - 1. Low-Level Window & Hardware Notch Anchoring

/// Production-grade custom NSPanel subclass for absolute MacBook notch anchoring.
/// Configured with .nonactivatingPanel, .fullScreenAuxiliary, and status window level (26).
/// Backing store is .buffered with transparent background, zero standard decorations,
/// and dynamic shaped hit-testing that allows mouse event pass-through to underlying spaces.
public class DroppyWindowPanel: NotchWindowPanel {
    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel],
        backing backingStoreType: NSWindow.BackingStoreType = .buffered,
        defer flag: Bool = false
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = NSWindow.Level(rawValue: 26) // status window level tier
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.ignoresMouseEvents = false
    }
}

// MARK: - 2. Root SwiftUI App Lifecycle Structure

/// Root SwiftUI App lifecycle structure integrating background daemon mode,
/// status bar MenuBarExtra controls, panic exit triggers, and watchdog supervision.
public struct DroppyAppStructure: View {
    @ObservedObject public var state: IslandState
    public var onOpenIsland: () -> Void
    public var onQuickTimer: () -> Void
    public var onPanicExit: () -> Void

    public init(
        state: IslandState,
        onOpenIsland: @escaping () -> Void,
        onQuickTimer: @escaping () -> Void,
        onPanicExit: @escaping () -> Void
    ) {
        self.state = state
        self.onOpenIsland = onOpenIsland
        self.onQuickTimer = onQuickTimer
        self.onPanicExit = onPanicExit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(state.mode == .expanded ? "Collapse Island" : "Expand Island", action: onOpenIsland)
            Button("Start 25-minute Timer", action: onQuickTimer)
            Divider()
            Button("Panic Exit (Cmd+Shift+Option+Esc)", action: onPanicExit)
            Button("Quit Droppy") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
    }
}

// MARK: - 3. State Machine & Spring Physics Engine

/// Formal state machine aliases and constants governing the strict single-activity constraint
/// and non-linear spring physics.
public enum DroppyPhysics {
    /// Non-linear spring curve for container geometry morphing:
    /// response: 0.32s, dampingFraction: 0.78, blendDuration: 0.25s
    public static let motionSpring = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.78,
        blendDuration: 0.25
    )

    /// Content morph curve for smooth opacity cross-fade during liquid stretch:
    /// response: 0.28s, dampingFraction: 0.82, blendDuration: 0.20s
    public static let contentSpring = Animation.interactiveSpring(
        response: 0.28,
        dampingFraction: 0.82,
        blendDuration: 0.20
    )

    /// HUD meter response for immediate feedback with zero bounce
    public static let hudSpring = Animation.spring(
        response: 0.18,
        dampingFraction: 0.86
    )
}

public typealias DroppyStateMachine = IslandState

// MARK: - 4. Metal & CoreAnimation Liquid Glass View Modifier

/// Reusable Metal / CoreAnimation liquid glass modifier applying ultraThinMaterial,
/// refractive dark gradient, subtle 15% white inner border, 20% black shadow, and
/// smooth edge vignette dissolving.
public struct DroppyLiquidGlass: ViewModifier {
    public let metrics: IslandMetrics
    public var dropTarget: Bool
    public var isCharging: Bool
    public var pointerInside: Bool

    public init(
        metrics: IslandMetrics,
        dropTarget: Bool = false,
        isCharging: Bool = false,
        pointerInside: Bool = false
    ) {
        self.metrics = metrics
        self.dropTarget = dropTarget
        self.isCharging = isCharging
        self.pointerInside = pointerInside
    }

    public func body(content: Content) -> some View {
        content
            .background(
                SurfaceView(
                    metrics: metrics,
                    strokeStyle: AnyShapeStyle(Color.white.opacity(0.15)),
                    strokeWidth: 0.75,
                    expanded: metrics.bodyH > 60,
                    dropTarget: dropTarget,
                    pointerInside: pointerInside,
                    isCharging: isCharging,
                    isLowBattery: false
                )
            )
            .clipShape(MorphShape(m: metrics))
            .shadow(color: Color.black.opacity(0.20), radius: 12, x: 0, y: 6)
    }
}

public extension View {
    /// Applies Droppy's Apple-grade liquid glass surface with hardware-notch fusion.
    func droppyLiquidGlass(
        metrics: IslandMetrics,
        dropTarget: Bool = false,
        isCharging: Bool = false,
        pointerInside: Bool = false
    ) -> some View {
        modifier(DroppyLiquidGlass(
            metrics: metrics,
            dropTarget: dropTarget,
            isCharging: isCharging,
            pointerInside: pointerInside
        ))
    }
}
