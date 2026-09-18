import SwiftUI

/// The island surface: one continuous shape that morphs between states.
///
/// The shape is defined by six animatable scalars and ALWAYS anchors to the
/// hardware housing:
///
///   ┌──────────────────┐
///   │   housing band   │  chinH tall; chinW wide (≈ notch + 2×pad)
///   └─╮              ╭─┘  shoulders bloom outward (shoulder tall)
///     │    body     │     content band — NEVER behind the housing
///     ╰─────────────╯
///
/// `chinW == width && shoulder == 0` degenerates to the "wings" form (a slab
/// with a bite): content flanks the housing left/right. `shoulder > 0`
/// blooms the "slab" form: a wider body grows below the housing. Both are the
/// same path, so every transition is one continuous spring interpolation —
/// no window resizing, no crossfaded layout swaps.
public struct IslandMetrics: Equatable, Animatable, Sendable {

    public var width: CGFloat
    /// Height of the band that covers the camera housing (= notch height).
    public var chinH: CGFloat
    /// Width of the band that covers the camera housing.
    public var chinW: CGFloat
    /// Height of the outward bloom between housing band and body.
    public var shoulder: CGFloat
    /// Height of the body (content band) below the housing band.
    public var bodyH: CGFloat
    /// Bottom corner radius.
    public var corner: CGFloat

    public init(width: CGFloat, chinH: CGFloat, chinW: CGFloat,
                shoulder: CGFloat, bodyH: CGFloat, corner: CGFloat) {
        self.width = width
        self.chinH = chinH
        self.chinW = chinW
        self.shoulder = shoulder
        self.bodyH = bodyH
        self.corner = corner
    }

    public var height: CGFloat { chinH + shoulder + bodyH }

    /// Top y of the body content band (below housing + shoulder).
    public var contentTop: CGFloat { chinH + shoulder }

    /// Horizontal padding for body content.
    public var contentPad: CGFloat { 16 }

    /// Left inset of the housing band (the bite the notch occupies).
    public var chinPad: CGFloat { (width - chinW) / 2 }

    // MARK: - Surface presets

    public enum Surface: Equatable, Sendable {
        case idle, compact, expanded, hud
    }

    /// Fixed canvas the single window is sized to. Every surface renders
    /// top-anchored inside it; regions outside the current shape are
    /// transparent AND click-through (shaped hit-testing).
    public static let canvasSize = CGSize(width: 440, height: 594)

    public static func idle(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let w = max(180, layout.notchWidth + 72)
        let chin = layout.hasNotch ? layout.topInset : 0
        let lip: CGFloat = layout.hasNotch ? 8 : 30
        return IslandMetrics(width: w, chinH: chin, chinW: w,
                             shoulder: 0, bodyH: lip, corner: layout.hasNotch ? 8 : 15)
    }

    /// Slim "wings" compact: content flanks the housing. Used by data pill
    /// activities (timer, remote timer, transfer).
    public static func compactSlim(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        let w = layout.notchWidth + 80
        return IslandMetrics(width: w, chinH: chin, chinW: w,
                             shoulder: 0, bodyH: 34, corner: 20)
    }

    /// Full "slab" compact: a body blooms below the housing — room for
    /// artwork, two lines of text and controls. Media and external pills.
    public static func compactSlab(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        let w = max(344, layout.notchWidth + 165)
        return IslandMetrics(width: w, chinH: chin, chinW: layout.notchWidth + 24,
                             shoulder: 20, bodyH: 48, corner: 24)
    }

    public static func expanded(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 6
        return IslandMetrics(width: IslandMetrics.canvasSize.width,
                             chinH: chin, chinW: layout.notchWidth + 24,
                             shoulder: 26, bodyH: IslandMetrics.canvasSize.height - chin - 26,
                             corner: 26)
    }

    /// HUD capsule: a small slab under the housing for volume feedback.
    public static func hud(_ layout: NotchGeometry.Layout) -> IslandMetrics {
        let chin = layout.hasNotch ? layout.topInset : 0
        return IslandMetrics(width: 240, chinH: chin, chinW: layout.notchWidth + 24,
                             shoulder: 18, bodyH: 46, corner: 22)
    }

    /// Overture surfaces: melt beats collapse to the idle blend; teaching
    /// beats use the slab form below the housing.
    public static func overture(_ beat: Overture.Beat,
                                layout: NotchGeometry.Layout) -> IslandMetrics {
        switch beat {
        case .melt, .recede:
            return .idle(layout)
        case .greetings, .vocabTimer, .vocabFile, .vocabMedia:
            let chin = layout.hasNotch ? layout.topInset : 0
            let w = max(344, layout.notchWidth + 165)
            return IslandMetrics(width: w, chinH: chin, chinW: layout.notchWidth + 24,
                                 shoulder: 20, bodyH: 44, corner: 24)
        }
    }

    public static func metrics(for surface: Surface, layout: NotchGeometry.Layout,
                               activity: IslandState.Activity) -> IslandMetrics {
        switch surface {
        case .idle: return .idle(layout)
        case .compact:
            switch activity {
            case .media, .external: return .compactSlab(layout)
            default: return .compactSlim(layout)
            }
        case .expanded: return .expanded(layout)
        case .hud: return .hud(layout)
        }
    }

    // MARK: - Animatable

    public typealias AnimatableData = AnimatablePair<
        CGFloat,
        AnimatablePair<CGFloat,
        AnimatablePair<CGFloat,
        AnimatablePair<CGFloat,
        AnimatablePair<CGFloat, CGFloat> > > > >

    public var animatableData: AnimatableData {
        get {
            AnimatablePair(width, AnimatablePair(chinH, AnimatablePair(chinW,
                AnimatablePair(shoulder, AnimatablePair(bodyH, corner)))))
        }
        set {
            width = newValue.first
            chinH = newValue.second.first
            chinW = newValue.second.second.first
            shoulder = newValue.second.second.second.first
            bodyH = newValue.second.second.second.second.first
            corner = newValue.second.second.second.second.second
        }
    }

    // MARK: - Path (top-left origin, y down)

    /// The morph path inside a rect of (width × height), horizontally
    /// CENTERED in that rect (the window is the fixed canvas; a compact
    /// surface is narrower than the canvas and must hug the notch, which is
    /// screen-centered). Clockwise from the housing band's top-left, with
    /// outward shoulder curves.
    public static func path(in rect: CGSize, m: IslandMetrics) -> Path {
        var p = Path()
        let dx = (rect.width - m.width) / 2
        let h = m.height
        let chinPad = dx + m.chinPad
        let chinRight = chinPad + m.chinW
        let right = dx + m.width

        p.move(to: CGPoint(x: chinPad, y: 0))
        p.addLine(to: CGPoint(x: chinRight, y: 0))                       // housing top edge
        p.addLine(to: CGPoint(x: chinRight, y: m.chinH))                 // housing right edge
        // Right shoulder: bloom from housing edge out to the body's right edge.
        p.addQuadCurve(to: CGPoint(x: right, y: m.chinH + m.shoulder),
                       control: CGPoint(x: chinRight, y: m.chinH + m.shoulder))
        p.addLine(to: CGPoint(x: right, y: h - m.corner))                // right edge
        p.addQuadCurve(to: CGPoint(x: right - m.corner, y: h),
                       control: CGPoint(x: right, y: h))                 // bottom-right corner
        p.addLine(to: CGPoint(x: dx + m.corner, y: h))                   // bottom edge
        p.addQuadCurve(to: CGPoint(x: dx, y: h - m.corner),
                       control: CGPoint(x: dx, y: h))                    // bottom-left corner
        p.addLine(to: CGPoint(x: dx, y: m.chinH + m.shoulder))           // left edge
        // Left shoulder mirrors right.
        p.addQuadCurve(to: CGPoint(x: chinPad, y: m.chinH),
                       control: CGPoint(x: chinPad, y: m.chinH + m.shoulder))
        p.addLine(to: CGPoint(x: chinPad, y: 0))                         // housing left edge
        p.closeSubpath()
        return p
    }

    /// NSBezierPath twin for AppKit-shaped hit-testing (same geometry as
    /// `path(in:m:)`).
    public static func hitPath(size: CGSize, m: IslandMetrics) -> NSBezierPath {
        let p = path(in: size, m: m)
        let bez = NSBezierPath()
        bez.append(NSBezierPath(cgPath: p.cgPath))
        return bez
    }

    /// Point-in-shape test in a top-left-origin coordinate space (the shape's
    /// own space). `slop` grows the region for hysteresis against boundary
    /// flapping on enter. Cardinal samples approximate the grown region
    /// without stroking a second path (cheap, exact enough for pointer work).
    public static func hitTest(_ point: CGPoint, in size: CGSize, m: IslandMetrics,
                               slop: CGFloat = 0) -> Bool
    {
        let path = path(in: size, m: m)
        if path.contains(point) { return true }
        guard slop > 0 else { return false }
        for d in [CGPoint(x: slop, y: 0), CGPoint(x: -slop, y: 0),
                  CGPoint(x: 0, y: slop), CGPoint(x: 0, y: -slop)] {
            if path.contains(CGPoint(x: point.x + d.x, y: point.y + d.y)) { return true }
        }
        return false
    }
}

/// The one shape view used for fill, material mask, stroke and shadow.
public struct MorphShape: Shape {
    public var m: IslandMetrics
    public init(m: IslandMetrics) { self.m = m }

    public var animatableData: IslandMetrics.AnimatableData { m.animatableData }

    public func path(in rect: CGRect) -> Path {
        IslandMetrics.path(in: rect.size, m: m)
    }
}
