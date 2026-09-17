import AppKit
import SwiftUI

/// Borderless floating panel that hugs the notch. It is always sized to fit
/// exactly the visible island UI, so transparent regions never swallow menu
/// bar clicks: idle covers only the dead notch space, compact is a small
/// pill, expanded is a temporary tray.
public final class IslandPanel: NSPanel {
    public var allowKey = false
    override public var canBecomeKey: Bool { allowKey }
    override public var canBecomeMain: Bool { false }
}

/// Soft radial dim behind the expanded tray. Argument for the extra window
/// (per constitution, written down, not assumed): the tray is translucent
/// glass over the menu bar; bright menu-bar content bleeds through and
/// breaks the island's dark-glass illusion. A temporary scrim — visible
/// ONLY while expanded, mouse-transparent, one level below the island —
/// carves that space. It is not an always-on layer: it lives and dies with
/// the expanded mode transition, guarded the same way.
private final class ScrimView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors = [NSColor.black.withAlphaComponent(0.38).cgColor,
                      NSColor.clear.cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors, locations: [0, 1]) else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.maxY - 60)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 40,
                               endCenter: c, endRadius: max(bounds.width, bounds.height) * 0.62,
                               options: .drawsAfterEndLocation)
        super.draw(dirtyRect)
    }
}

@MainActor
public final class IslandController {
    public let panel: IslandPanel
    private var screen: NSScreen
    private var layout: NotchGeometry.Layout
    private var currentSize = NSSize.zero
    private var currentKind: IslandSize?
    private var currentAllowKey = false
    private var scrim: NSPanel?
    private var scrimVisible = false
    nonisolated(unsafe) private var monitors: [Any] = []

    public var onOutsideClick: (() -> Void)?
    public var onEscape: (() -> Void)?

    /// Lifetime window-op stats (dev tooling): real shows vs. diff-guard
    /// no-ops. A healthy session shows noops >> calls.
    public private(set) var showCalls = 0
    public private(set) var showNoops = 0

    public init(content: NSView) {
        screen = NSScreen.main ?? NSScreen.screens.first!
        layout = NotchGeometry.layout(for: screen)

        panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The island is always dark glass (like the physical notch), in both
        // system appearances — SwiftUI content forces .dark to match.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: 26) // above menu bar, below popups
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = content

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.onOutsideClick?()
                }
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in self?.onEscape?() }
                return nil
            }
            return event
        } as Any)
    }

    deinit {
        for m in monitors { NSEvent.removeMonitor(m) }
    }

    @objc private func screensChanged(_: Notification) {
        Task { @MainActor in
            if let main = NSScreen.main { self.screen = main }
            self.layout = NotchGeometry.layout(for: self.screen)
            IslandDebug.log("screens changed, re-place \(self.currentSize)")
            self.place(size: self.currentSize, animate: false)
            // Re-glue the scrim if it is up.
            if let kind = self.currentKind {
                self.setScrim(kind == .expanded, animate: false)
            }
        }
    }

    public var notchLayout: NotchGeometry.Layout { layout }

    /// Explicit frames for the Godmode overture (the only caller). Bypasses
    /// the diff guard on purpose: the sequence owns every frame. Normal
    /// show() calls resume guarding afterwards.
    public func showCustom(_ frame: NSRect, animate: Bool) {
        currentKind = nil
        currentAllowKey = false
        panel.allowKey = false
        if panel.isKeyWindow { panel.resignKey() }
        currentSize = frame.size
        IslandDebug.log("showCustom frame=\(frame)")
        panel.setFrame(frame, display: true, animate: animate)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Explicit user interaction only (clicks, menu actions). Hovering must
    /// never call this — activating here steals keyboard focus from the
    /// frontmost app. Text fields and buttons need it before they work.
    public func activateForInteraction() {
        panel.allowKey = true
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Sizing

    public enum IslandSize {
        case idle, compact, expanded
    }

    public func show(_ size: IslandSize, allowKey: Bool, animate: Bool) {
        let w: CGFloat
        let h: CGFloat
        switch size {
        case .idle:
            w = layout.hasNotch ? max(180, layout.notchWidth + 72) : 210
            h = layout.hasNotch ? layout.topInset + 6 : 30
        case .compact:
            w = 348
            h = 40
        case .expanded:
            w = 404
            h = 468
        }
        let frame = frameFor(NSSize(width: w, height: h))
        // Diff guard: redundant shows (same kind, same key posture, same
        // frame) are the flicker engine — state publishers fire far more
        // often than the window actually needs to move. Reordering frontmost
        // and re-animating to an identical frame churns the compositor over
        // the menu bar and reads as flicker. Mid-flight frames never compare
        // equal, so genuine re-targets still animate smoothly.
        if currentKind == size, currentAllowKey == allowKey, panel.frame.equalTo(frame) {
            showNoops += 1
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        showCalls += 1
        IslandDebug.log("show \(size) allowKey=\(allowKey) animate=\(animate) frame=\(frame)")
        currentKind = size
        currentAllowKey = allowKey
        panel.allowKey = allowKey
        if !allowKey, panel.isKeyWindow {
            panel.resignKey()
        }
        place(frame: frame, animate: animate)
        if !panel.isVisible { panel.orderFrontRegardless() }
        setScrim(size == .expanded, animate: animate)
    }

    /// Scrim follows expanded mode with its own guard: no repeated fades.
    public var isScrimVisible: Bool { scrimVisible }

    private func setScrim(_ on: Bool, animate: Bool) {
        if on == scrimVisible {
            // Keep a visible scrim glued to the screen on geometry changes.
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
                let v = ScrimView(frame: NSRect(origin: .zero, size: scrimFrame().size))
                v.autoresizingMask = [.width, .height]
                sc.contentView = v
                sc.alphaValue = 0
                scrim = sc
            }
            sc.setFrame(scrimFrame(), display: true)
            sc.orderFrontRegardless()
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    sc.animator().alphaValue = 1
                }
            } else {
                sc.alphaValue = 1
            }
        } else if let sc = scrim {
            if animate {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    sc.animator().alphaValue = 0
                }, completionHandler: { [weak sc] in
                    sc?.orderOut(nil)
                })
            } else {
                sc.alphaValue = 0
                sc.orderOut(nil)
            }
        }
    }

    private func scrimFrame() -> NSRect {
        let f = screen.frame
        let w: CGFloat = 560, h: CGFloat = 520
        return NSRect(x: f.midX - w / 2, y: f.maxY - h + 2, width: w, height: h)
    }

    private func frameFor(_ size: NSSize) -> NSRect {
        let f = screen.frame
        let x = f.midX - size.width / 2
        // Anchor the top edge just inside the screen top; idle on notch
        // hardware overlaps the housing so the blend looks seamless.
        let y = f.maxY - size.height + (layout.hasNotch ? 2 : 6)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func place(size: NSSize, animate: Bool) {
        currentSize = size
        panel.setFrame(frameFor(size), display: true, animate: animate)
    }

    private func place(frame: NSRect, animate: Bool) {
        currentSize = frame.size
        panel.setFrame(frame, display: true, animate: animate)
    }
}
