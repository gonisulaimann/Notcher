import AppKit
import SwiftUI

/// Borderless, non-activating panel for the island. The window is FIXED at
/// the canvas size and never resizes; the visible island is a shaped SwiftUI
/// surface inside it (MorphShape), and clicks outside that shape fall through
/// to whatever is beneath (shaped hit-testing in IslandController).
/// Non-Activating AppKit Panel subclass for absolute hardware notch anchoring.
/// Configured with .nonactivatingPanel, .fullScreenAuxiliary, and .status level.
public class NotchWindowPanel: NSPanel {
    public var allowKey = false
    public var hitTestCheck: ((NSPoint) -> Bool)?
    private var lastInside = false

    override public var canBecomeKey: Bool { allowKey }
    override public var canBecomeMain: Bool { false }

    override public func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            if let check = hitTestCheck {
                let inside = check(event.locationInWindow)
                if !inside && !lastInside {
                    // Cursor is outside and was outside: discard event completely
                    return
                }
                lastInside = inside
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

public typealias IslandPanel = NotchWindowPanel

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        if let custom = menuProvider?() {
            return custom
        }
        return super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Container that clips event delivery to the CURRENT morph shape: hits
/// outside the path return nil, so clicks fall through to the menu bar and
/// desktop beneath — no polling, no ignoresMouseEvents toggling, no missed
/// fast moves. (Replaces the 30 Hz cursor watcher: same shaping, zero
/// wakeups. The watcher cost ~3 % idle CPU by measurement.)
final class ShapeHitView: NSView {
    /// Window-coordinates test, installed by the controller per present().
    var test: ((NSPoint) -> Bool)?
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let test, test(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Single-window island host.
///
/// v2 architecture (replaces the per-mode window resizing of ≤0.4):
/// - One panel, fixed at `IslandMetrics.canvasSize`, top-anchored to the
///   screen so the housing band always sits exactly over the camera notch.
/// - Every state (idle → wings → slab → tray → HUD) is one `IslandMetrics`
///   value handed to SwiftUI; the shape MORPHS with spring physics inside
///   the window. The window itself never moves or resizes — no compositor
///   churn, no flicker class of bugs, fully interruptible transitions.
/// - Click-through: the content sits in a ShapeHitView that answers hits
///   only inside the current morph path, so the menu bar and desktop stay
///   clickable around the island (real hit-test shaping, not a rect, and
///   no polling timer).
@MainActor
public final class IslandController {
    public let panel: IslandPanel
    private var screen: NSScreen
    private var layout: NotchGeometry.Layout
    private var metrics = IslandMetrics(width: 440, chinH: 0, chinW: 440,
                                        shoulder: 0, bodyH: 0, corner: 0)
    private var expandedVisible = false
    private var scrim: NSPanel?
    private var scrimVisible = false
    private var hitView: ShapeHitView?
    nonisolated(unsafe) private var monitors: [Any] = []

    public var onOutsideClick: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var contextMenuProvider: (() -> NSMenu?)?
    public var onScreenChanged: ((NotchGeometry.Layout) -> Void)?

    /// Whether the hover-exclusion scrim window is currently on screen.
    public var isScrimVisible: Bool { scrimVisible }

    public init() {
        screen = NSScreen.main ?? NSScreen.screens.first!
        layout = NotchGeometry.layout(for: screen)
        metrics = IslandMetrics.idle(layout)

        let initialFrame = NSRect(
            x: ((layout.hasNotch ? layout.housingRect.midX : screen.frame.midX) - metrics.width / 2).rounded(),
            y: screen.frame.maxY - metrics.height,
            width: metrics.width,
            height: metrics.height
        )

        panel = IslandPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: 26) // status window level tier (above menu bar, below popups)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.hitTestCheck = { [weak self] pt in
            self?.shapeContains(windowPoint: pt, slop: 0) ?? false
        }
        placeCanvas()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                if !self.containsCursor() {
                    self.onOutsideClick?()
                }
            }
        } as Any)
        // Global panic exit listener: Cmd + Shift + Option + Esc
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift, .option]) {
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Panic exit: Cmd + Shift + Option + Esc
            if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift, .option]) {
                NSApp.terminate(nil)
                return nil
            }
            if event.keyCode == 53 { // Escape
                Task { @MainActor in self?.onEscape?() }
                return nil
            }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                if event.charactersIgnoringModifiers == "w" {
                    Task { @MainActor in self?.onEscape?() }
                    return nil
                }
            }
            return event
        } as Any)
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    /// Explicit cleanup of event monitors and window resources
    public func tearDown() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        scrim?.orderOut(nil)
        scrim = nil
        panel.orderOut(nil)
    }

    // MARK: - Content

    public func frameFor(metrics: IslandMetrics) -> NSRect {
        let f = screen.frame
        let centerX = layout.hasNotch ? layout.housingRect.midX : f.midX
        let h = max(24, metrics.height)
        let w = max(160, metrics.width)
        let x = (centerX - w / 2).rounded()
        let y = f.maxY - h
        return NSRect(x: x, y: y, width: w, height: h)
    }

    public func updateFrame(animate: Bool) {
        let targetFrame = frameFor(metrics: metrics)
        if panel.frame.equalTo(targetFrame) { return }

        if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    /// Install the SwiftUI root (NSHostingView). Called once by the
    /// coordinator; the view reads island state and morphs itself.
    /// Wrapped in a ShapeHitView so only the live shape takes events.
    public func setRoot(_ view: some View) {
        let initialSize = frameFor(metrics: metrics).size
        let hosting = IslandHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]
        hosting.menuProvider = { [weak self] in
            self?.contextMenuProvider?()
        }
        let hit = ShapeHitView(frame: NSRect(origin: .zero, size: initialSize))
        hit.autoresizingMask = [.width, .height]
        hit.addSubview(hosting)
        // Reads live metrics at hit time: morphs never desync hit-testing.
        hit.test = { [weak self] point in
            guard let self else { return false }
            return self.shapeContains(windowPoint: point, slop: 0)
        }
        hit.menuProvider = { [weak self] in
            self?.contextMenuProvider?()
        }
        hitView = hit
        panel.contentView = hit
    }

    public func orderFront() {
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Surface presentation

    /// The coordinator's single window touch: hand over the surface's
    /// metrics. Resizes the window to hug the visible island exactly.
    public func present(metrics: IslandMetrics, expanded: Bool, allowKey: Bool) {
        self.metrics = metrics
        presentCalls += 1
        updateFrame(animate: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.allowKey = allowKey
        if !allowKey, panel.isKeyWindow { panel.resignKey() }
        setScrim(expanded, animate: true)
        expandedVisible = expanded
    }

    public func activateForInteraction() {
        panel.allowKey = true
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    public var notchLayout: NotchGeometry.Layout { layout }

    /// Dev/probe introspection: how many metrics handoffs happened (the v2
    /// analogue of the old showCalls counter).
    public private(set) var presentCalls = 0
    /// The metrics currently driving shaped hit-testing.
    public var currentMetrics: IslandMetrics { metrics }

    // MARK: - Geometry

    private func placeCanvas() {
        let f = frameFor(metrics: metrics)
        panel.setFrame(f, display: true)
    }

    @objc private func screensChanged(_: Notification) {
        Task { @MainActor in
            if let main = NSScreen.main { self.screen = main }
            self.layout = NotchGeometry.layout(for: self.screen)
            IslandDebug.log("screens changed, re-place canvas")
            self.placeCanvas()
            // Re-glue a visible scrim; setScrim re-places when already on.
            if self.scrimVisible { self.setScrim(true, animate: false) }
            self.onScreenChanged?(self.layout)
        }
    }

    /// Precision hit testing in window coordinates (bottom-left origin).
    /// Enforces strict top-edge proximity in idle mode: only the physical camera housing
    /// pixels or a microscopic 2–3 pixel top bezel strip will intercept events.
    private func shapeContains(windowPoint: NSPoint, slop: CGFloat) -> Bool {
        let bounds = panel.contentView?.bounds.size ?? frameFor(metrics: metrics).size
        let contentH = bounds.height
        let tl = CGPoint(x: windowPoint.x, y: contentH - windowPoint.y)

        // In idle mode (collapsed with no live activity body), enforce strict top-edge proximity.
        // Sweeping across the menu bar or below the notch falls through cleanly to macOS.
        let isIdle = (!expandedVisible && metrics.bodyH <= 12)
        if isIdle {
            let midX = bounds.width / 2
            if layout.hasNotch {
                let notchHalfW = max(layout.notchWidth / 2, metrics.chinW / 2)
                let inNotchHousing = (tl.y >= 0 && tl.y <= layout.topInset && abs(tl.x - midX) <= notchHalfW)
                let inTopEdgeStrip = (tl.y >= 0 && tl.y <= 3.0 && abs(tl.x - midX) <= (metrics.width / 2))
                return inNotchHousing || inTopEdgeStrip
            } else {
                return (tl.y >= 0 && tl.y <= 3.0 && abs(tl.x - midX) <= (metrics.width / 2))
            }
        }

        // In compact or expanded mode, hit-test against the exact morph path.
        return IslandMetrics.hitTest(tl, in: bounds, m: metrics, slop: slop)
    }

    /// Cursor containment against the CURRENT morph shape, for the global
    /// click-outside monitor.
    private func containsCursor() -> Bool {
        guard panel.isVisible else { return false }
        let mouse = NSEvent.mouseLocation
        let windowPt = panel.convertFromScreen(NSRect(origin: mouse, size: .zero)).origin
        let bounds = panel.contentView?.bounds ?? NSRect(origin: .zero, size: frameFor(metrics: metrics).size)
        if !bounds.contains(windowPt) { return false }
        return shapeContains(windowPoint: windowPt, slop: 0)
    }

    // MARK: - Scrim (expanded only)

    private func setScrim(_ on: Bool, animate: Bool) {
        if on == scrimVisible {
            if on, let sc = scrim { sc.setFrame(scrimFrame(), display: true) }
            return
        }
        scrimVisible = on
        if on {
            let sc: NSPanel
            if let existing = scrim {
                sc = existing
            } else {
                sc = NSPanel(contentRect: scrimFrame(), styleMask: .borderless,
                             backing: .buffered, defer: false)
                sc.isOpaque = false
                sc.backgroundColor = .clear
                sc.hasShadow = false
                sc.level = NSWindow.Level(rawValue: 25)
                sc.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                sc.hidesOnDeactivate = false
                sc.isMovable = false
                sc.ignoresMouseEvents = true
                sc.alphaValue = 0
                scrim = sc
            }
            sc.setFrame(scrimFrame(), display: true)
            sc.orderFrontRegardless()
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.28, 1)
                    sc.animator().alphaValue = 1
                }
            } else {
                sc.alphaValue = 1
            }
        } else if let sc = scrim {
            if animate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    sc.animator().alphaValue = 0
                }, completionHandler: { [weak sc] in
                    MainActor.assumeIsolated {
                        sc?.orderOut(nil)
                    }
                })
            } else {
                sc.alphaValue = 0
                sc.orderOut(nil)
            }
        }
    }

    private func scrimFrame() -> NSRect {
        let f = screen.frame
        let centerX = layout.hasNotch ? layout.housingRect.midX : f.midX
        let w: CGFloat = 620, h: CGFloat = 620
        return NSRect(x: (centerX - w / 2).rounded(), y: f.maxY - h + 2, width: w, height: h)
    }
}
